"""Samplesheet fetch, conversion and validation.

Replaces the two bash-era helpers:
  - ``bin/check_samplesheets.py``  (SharePoint download + XLSX→TSV)
  - the ``fix_local_samplesheet()`` function in ``autobcl2fastq_biomics.sh``
    (TSV + indices.txt → Illumina CSV)

The public interface is :class:`SamplesheetManager`, whose
:meth:`~SamplesheetManager.fetch_and_fix` method handles the end-to-end flow.
"""

from __future__ import annotations

import configparser
import csv
import logging
from io import StringIO
from pathlib import Path
from typing import Optional

import pandas as pd

from .config import Settings

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# SamplesheetManager
# ---------------------------------------------------------------------------


class SamplesheetManager:
    """Download, convert and validate RSG samplesheets."""

    def __init__(self, settings: Settings):
        self.settings = settings

    # ---------------------------------------------------------------- public

    def fetch_and_fix(self, run_info) -> Path:  # RunInfo imported lazily to avoid circular
        """Full flow: fetch raw TSV (SharePoint or local) → fixed Illumina CSV.

        Returns the path to the final Illumina CSV file.
        """
        raw_tsv = self._fetch_raw(run_info.run_hash)
        if raw_tsv is None:
            raise FileNotFoundError(
                f"No samplesheet found for run hash {run_info.run_hash!r}. "
                "Upload the RSG sheet to SharePoint or place it at: "
                f"{self.settings.samplesheets_raw_dir}/rsgsheet_{run_info.run_hash}.tsv"
            )
        return self.fix(raw_tsv, run_info)

    def fetch_from_sharepoint(self, run_hash: str) -> Optional[Path]:
        """Download ``rsgsheet_{run_hash}.xlsx`` from SharePoint → local TSV.

        Returns the local TSV path, or *None* if not found or if the
        optional ``rsgutils.sharepoint`` dependency is absent.
        """
        try:
            from rsgutils.sharepoint import DeviceFlowSharePointClient
        except ImportError:
            log.warning(
                "rsgutils.sharepoint not available — cannot fetch from SharePoint."
            )
            return None

        settings = self.settings
        log.info("Fetching rsgsheet_%s.xlsx from SharePoint", run_hash)
        client = DeviceFlowSharePointClient(settings.sharepoint_url)
        target_name = f"rsgsheet_{run_hash}.xlsx"
        out_dir = settings.samplesheets_raw_dir
        out_dir.mkdir(parents=True, exist_ok=True)

        try:
            import tempfile

            with tempfile.NamedTemporaryFile(suffix=".xlsx", delete=False) as tmp:
                tmp_path = Path(tmp.name)

            client.download_file(
                f"{settings.sharepoint_entrypoint}{target_name}",
                tmp_path,
            )
            # Convert XLSX columns 2-3 (0-indexed: 1, 2) → TSV
            df = pd.read_excel(tmp_path).iloc[:, 1:3].dropna()
            tsv_path = out_dir / f"rsgsheet_{run_hash}.tsv"
            df.to_csv(tsv_path, sep="\t", index=False, header=False)
            tmp_path.unlink(missing_ok=True)
            log.info("Samplesheet saved: %s", tsv_path)
            return tsv_path
        except Exception as exc:
            log.warning("SharePoint fetch failed for %s: %s", target_name, exc)
            return None

    def fetch_local(self, run_hash: str) -> Optional[Path]:
        """Return the local raw TSV path if it exists."""
        path = self.settings.samplesheets_raw_dir / f"rsgsheet_{run_hash}.tsv"
        return path if path.exists() else None

    def fix(self, raw_tsv: Path, run_info) -> Path:
        """Convert a raw two-column TSV (sample_id, barcode_well) to an
        Illumina CSV with [Header] + [Data] sections.

        Raises :exc:`ValueError` if validation fails (unknown users or indices,
        duplicate barcode combinations).
        """
        indices = self._load_indices()
        rows = self._load_raw_tsv(raw_tsv)

        errors = self.validate_rows(rows, indices, run_info.run_hash)
        if errors:
            raise ValueError(
                f"Samplesheet validation failed for run {run_info.run_hash}:\n"
                + "\n".join(f"  - {e}" for e in errors)
            )

        csv_path = (
            self.settings.samplesheets_dir
            / f"SampleSheet_{run_info.run_date}_{run_info.run_nb}_{run_info.run_hash}.csv"
        )
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        self._write_illumina_csv(rows, indices, run_info, csv_path)
        log.info("Fixed samplesheet written: %s", csv_path)
        return csv_path

    def validate_rows(
        self,
        rows: list[tuple[str, str]],
        indices: dict[str, tuple[str, str]],
        run_hash: str,
    ) -> list[str]:
        """Return a list of validation error messages (empty = valid)."""
        errors: list[str] = []

        # Check barcode wells exist in indices.txt
        for sample_id, barcode_well in rows:
            if barcode_well not in indices:
                errors.append(
                    f"Barcode well {barcode_well!r} (sample {sample_id!r}) "
                    "not found in indices.txt."
                )

        # Check all project IDs are registered in users.conf
        users_conf = self.settings.users_conf_file
        if users_conf and users_conf.exists():
            registered = self._load_registered_users(users_conf)
            for sample_id, _ in rows:
                project = _project_from_sample(sample_id)
                if project not in registered:
                    errors.append(
                        f"Project {project!r} (sample {sample_id!r}) not registered "
                        f"in {users_conf}."
                    )
        else:
            log.warning(
                "users.conf not found at %s — skipping user validation.", users_conf
            )

        # Check for duplicate barcode combinations
        seen: dict[tuple[str, str], list[str]] = {}
        for sample_id, barcode_well in rows:
            if barcode_well in indices:
                i7, i5 = indices[barcode_well]
                key = (i7, i5)
                seen.setdefault(key, []).append(sample_id)
        for (i7, i5), samples in seen.items():
            if len(samples) > 1:
                errors.append(
                    f"Duplicate barcode pair ({i7}, {i5}) shared by: {', '.join(samples)}"
                )

        return errors

    # -------------------------------------------------------------- private

    def _fetch_raw(self, run_hash: str) -> Optional[Path]:
        """Try SharePoint first, fall back to local file."""
        path = self.fetch_from_sharepoint(run_hash)
        if path is None:
            path = self.fetch_local(run_hash)
        return path

    def _load_indices(self) -> dict[str, tuple[str, str]]:
        """Load indices.txt → {barcode_well: (i7_sequence, i5_sequence)}."""
        indices_file = self.settings.resolved_resources_dir / "indices.txt"
        if not indices_file.exists():
            raise FileNotFoundError(f"indices.txt not found at {indices_file}")
        indices: dict[str, tuple[str, str]] = {}
        with indices_file.open() as fh:
            reader = csv.reader(fh, delimiter="\t")
            next(reader, None)  # skip header
            for row in reader:
                if len(row) >= 3:
                    indices[row[0]] = (row[1], row[2])
        return indices

    @staticmethod
    def _load_raw_tsv(path: Path) -> list[tuple[str, str]]:
        """Load raw two-column TSV → [(sample_id, barcode_well), ...]."""
        rows: list[tuple[str, str]] = []
        with path.open() as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[0] and parts[1]:
                    rows.append((parts[0].strip(), parts[1].strip()))
        return rows

    @staticmethod
    def _load_registered_users(users_conf: Path) -> set[str]:
        """Return the set of section names from users.conf ([ProjectID])."""
        parser = configparser.ConfigParser()
        parser.read(users_conf)
        return set(parser.sections())

    @staticmethod
    def _write_illumina_csv(
        rows: list[tuple[str, str]],
        indices: dict[str, tuple[str, str]],
        run_info,
        out_path: Path,
    ) -> None:
        buf = StringIO()
        buf.write("[Header]\n")
        buf.write(f"Date,{run_info.run_date}\n")
        buf.write("Workflow,GenerateFASTQ\n")
        buf.write(f"Experiment Name,NSQ{run_info.run_nb}\n")
        buf.write("\n")
        buf.write("[Data]\n")
        buf.write(
            "Sample_ID,Sample_Name,Sample_Plate,Sample_Well,"
            "I7_Index_ID,index,I5_Index_ID,index2,Sample_Project\n"
        )
        for sample_id, barcode_well in rows:
            project = _project_from_sample(sample_id)
            i7, i5 = indices.get(barcode_well, ("", ""))
            buf.write(
                f"{sample_id},{sample_id},,{barcode_well},,{i7},,{i5},{project}\n"
            )
        out_path.write_text(buf.getvalue())


def _project_from_sample(sample_id: str) -> str:
    """Extract the project name: everything before the first digit."""
    import re

    m = re.match(r"([A-Za-z_-]+)", sample_id)
    return m.group(1) if m else sample_id
