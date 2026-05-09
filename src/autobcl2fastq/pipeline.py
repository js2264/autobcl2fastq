"""Pipeline orchestration for autobcl2fastq.

``DemuxPipeline.run()`` ties together all phases:
  1. Parse the Biomics URL → :class:`RunInfo`
  2. Fetch + fix the RSG samplesheet
  3. Download raw BCL data via curl
  4. Render the Jinja2 sbatch template
  5. Submit the rendered script via :class:`~rsgutils.slurm.SbatchClient`
  6. Persist the run to the SQLite state DB
"""

from __future__ import annotations

import logging
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from . import __version__ as PACKAGE_VERSION
from .config import Settings
from .samplesheet import SamplesheetManager
from .state import RunRecord, StateDB

log = logging.getLogger(__name__)

_TEMPLATE_DIR = Path(__file__).parent / "templates"


# ---------------------------------------------------------------------------
# Run info
# ---------------------------------------------------------------------------


@dataclass
class RunInfo:
    """Metadata extracted from a Biomics download URL."""

    url: str
    run_name: str  # e.g. 230516_VH00537_116_AACLHW3M5
    run_date: str  # e.g. 230516
    seq_id: str  # e.g. VH00537
    run_nb: str  # e.g. 116
    run_hash: str  # e.g. AACLHW3M5

    @property
    def run_id(self) -> str:
        """Short run identifier used in file/directory names."""
        return f"{self.run_date}_{self.run_nb}_{self.run_hash}"

    @classmethod
    def from_url(cls, url: str) -> RunInfo:
        """Parse a Biomics download URL into a RunInfo.

        Expected URL pattern::

            https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AACLHW3M5__<timestamp>.tar
        """
        basename = Path(url).name
        # Strip everything from the double-underscore separator onward
        run_name = re.split(r"__", basename)[0]
        parts = run_name.split("_", 3)
        if len(parts) < 4:
            raise ValueError(
                f"Cannot parse run name from URL basename {basename!r}. "
                "Expected format: DATE_SEQID_RUNNB_RUNHASH"
            )
        run_date, seq_id, run_nb, run_hash = parts
        return cls(
            url=url,
            run_name=run_name,
            run_date=run_date,
            seq_id=seq_id,
            run_nb=run_nb,
            run_hash=run_hash,
        )


# ---------------------------------------------------------------------------
# Jinja2 environment
# ---------------------------------------------------------------------------


def _build_jinja_env() -> Environment:
    return Environment(
        loader=FileSystemLoader(str(_TEMPLATE_DIR)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------


class DemuxPipeline:
    """Orchestrate BCL demultiplexing: samplesheet → BCL download → Slurm job."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._jinja = _build_jinja_env()

    # ---------------------------------------------------------------- public

    def run(
        self,
        url: str,
        *,
        samplesheet_path: Path | None = None,
        dry_run: bool = False,
    ) -> str:
        """Full pipeline. Returns the Slurm job ID (or ``"dry-run"``).

        Parameters
        ----------
        url:
            Biomics download URL.
        samplesheet_path:
            When provided, skip the SharePoint fetch and use this file
            directly (must already be in Illumina CSV format with a
            ``[Header]`` + ``[Data]`` section).
        dry_run:
            Render the sbatch script and write it to disk, but do not call
            ``sbatch``.  Returns the string ``"dry-run"``.
        """
        run_info = RunInfo.from_url(url)
        log.info("Processing run %s (hash=%s)", run_info.run_name, run_info.run_hash)

        settings = self.settings
        settings.ensure_dirs()

        # ---- samplesheet ---------------------------------------------------
        if samplesheet_path is None:
            manager = SamplesheetManager(settings)
            samplesheet_path = manager.fetch_and_fix(run_info)
        log.info("Using samplesheet: %s", samplesheet_path)

        # ---- PROCESSING lock -----------------------------------------------
        processing_flag = Path(settings.working_dir) / "PROCESSING"
        if processing_flag.exists():
            existing = processing_flag.read_text().strip()
            raise RuntimeError(
                f"Another run is currently being processed ({existing}). "
                "Remove PROCESSING flag manually if this is stale."
            )
        processing_flag.write_text(run_info.run_name)

        try:
            # ---- download BCL data -----------------------------------------
            self._download_bcl(run_info)

            # ---- render sbatch script --------------------------------------
            sbatch_path = self._render(run_info, samplesheet_path)

            # ---- submit to Slurm -------------------------------------------
            if dry_run:
                log.info("[dry-run] Script rendered at %s — not submitting.", sbatch_path)
                return "dry-run"

            job_id = self._submit(sbatch_path)
            log.info("Submitted Slurm job %s for run %s", job_id, run_info.run_id)

            # ---- persist to state DB ---------------------------------------
            db = StateDB(settings.db_path)
            db.insert_run(
                RunRecord(
                    run_id=run_info.run_id,
                    url=url,
                    run_name=run_info.run_name,
                    run_hash=run_info.run_hash,
                    samplesheet_path=str(samplesheet_path),
                    slurm_jobid=job_id,
                    sbatch_path=str(sbatch_path),
                    state="submitted",
                    autobcl2fastq_version=PACKAGE_VERSION,
                )
            )
            return job_id

        except Exception:
            # Only remove the flag here when we failed *before* sbatch ran
            # (once the compute job starts, it owns the flag).
            processing_flag.unlink(missing_ok=True)
            raise

    # --------------------------------------------------------------- private

    def _download_bcl(self, run_info: RunInfo) -> None:
        """Download the BCL TAR archive from Biomics and unpack it."""
        runs_dir = Path(self.settings.working_dir) / "runs"
        runs_dir.mkdir(parents=True, exist_ok=True)

        tar_file = runs_dir / Path(run_info.url).name
        log.info("Downloading BCL data to %s", tar_file)

        curl_cmd = ["curl", "-L"]
        if tar_file.exists():
            # Only fetch newer data (resume-like behaviour)
            curl_cmd += ["-z", str(tar_file)]
        curl_cmd += [run_info.url, "-o", str(tar_file)]

        subprocess.run(curl_cmd, check=True)

        log.info("Unpacking %s", tar_file)
        subprocess.run(
            ["tar", "-xf", str(tar_file), "--directory", str(runs_dir)],
            check=True,
        )
        tar_file.unlink(missing_ok=True)

    def _render(self, run_info: RunInfo, samplesheet_path: Path) -> Path:
        """Render the sbatch Jinja2 template; write and return the script path."""
        settings = self.settings
        ctx = {
            "run": run_info,
            "hpc": settings.hpc,
            "ssh_hostname": settings.ssh_hostname,
            "working_dir": settings.working_dir,
            "destination": settings.reads_dir,
            "email": settings.mail.address,
            "samplesheet_path": str(samplesheet_path),
            "resources_dir": str(settings.resolved_resources_dir),
            "log_dir": str(settings.log_dir),
            "autobcl2fastq_version": PACKAGE_VERSION,
            "submitted_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        rendered = self._jinja.get_template("process_run.sh.j2").render(**ctx)

        settings.sbatch_archive_dir.mkdir(parents=True, exist_ok=True)
        sbatch_path = settings.sbatch_archive_dir / f"{run_info.run_id}.sh"
        sbatch_path.write_text(rendered)
        sbatch_path.chmod(0o755)
        log.debug("Rendered sbatch script: %s", sbatch_path)
        return sbatch_path

    def _submit(self, sbatch_path: Path) -> str:
        """Call sbatch and return the Slurm job ID."""
        from rsgutils.slurm import SbatchClient

        client = SbatchClient(self.settings.slurm.sbatch_bin)
        return client.submit(sbatch_path)
