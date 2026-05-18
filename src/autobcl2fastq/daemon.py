"""Top-level orchestration: poll IMAP, submit jobs, watch sacct, notify.

A single synchronous loop is sufficient — IMAP polling and `sacct` queries
are both cheap and do not require real-time latency.
"""

from __future__ import annotations

import logging
import time
from datetime import datetime
from pathlib import Path

from rsgutils.slurm import SacctClient

from . import __version__
from .config import Settings
from .notifier import Notifier
from .pipeline import DemuxPipeline, RunInfo
from .state import StateDB
from .watcher import BiomicsEmailWatcher

log = logging.getLogger(__name__)


def _now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


class Daemon:
    """Glue layer.  One instance per process."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        settings.ensure_dirs()

    # ------------------------------------------------------------------
    # Public entry points
    # ------------------------------------------------------------------

    def run_forever(self) -> None:
        """Block forever, polling at the configured intervals."""
        log.info("autobcl2fastq %s daemon starting", __version__)
        last_inbox = 0.0
        last_sacct = 0.0
        while True:
            now = time.monotonic()
            try:
                if now - last_inbox >= self.settings.biomics.poll_interval_s:
                    self._poll_inbox()
                    last_inbox = time.monotonic()
                if now - last_sacct >= self.settings.hpc.sacct_poll_interval_s:
                    self._poll_slurm()
                    last_sacct = time.monotonic()
            except Exception:
                log.exception("Daemon iteration failed; will retry.")
            time.sleep(
                min(
                    self.settings.biomics.poll_interval_s,
                    self.settings.hpc.sacct_poll_interval_s,
                )
            )

    def run_once(self) -> None:
        """Single iteration — useful for cron jobs and debugging."""
        self._poll_inbox()
        self._poll_slurm()

    # ------------------------------------------------------------------
    # Private: inbox
    # ------------------------------------------------------------------

    def _poll_inbox(self) -> None:
        notifier = Notifier(self.settings)
        watcher = BiomicsEmailWatcher(self.settings)

        try:
            run_email = watcher.poll()
        except Exception as exc:
            log.error("IMAP poll failed: %s", exc)
            return

        if not run_email:
            log.debug("No new Biomics email.")
            return

        run_info = RunInfo.from_url(run_email.url)
        log.info("New Biomics run: %s", run_info.run_id)
        pipeline = DemuxPipeline(self.settings)
        try:
            job_id = pipeline.run(run_email.url)
            ss_path = (
                self.settings.samplesheets_dir
                / f"SampleSheet_{run_info.run_date}_{run_info.run_nb}_{run_info.run_hash}.csv"
            )
            notifier.notify_start(run_info, ss_path)
            log.info("Submitted run %s as Slurm job %s", run_info.run_id, job_id)
        except Exception as exc:
            log.error("Failed to process run %s: %s", run_email.url, exc)
            notifier.notify_error(str(exc), run_name=run_info.run_name)

    # ------------------------------------------------------------------
    # Private: sacct
    # ------------------------------------------------------------------

    def _poll_slurm(self) -> None:
        db = StateDB(self.settings.db_path)
        notifier = Notifier(self.settings)
        active = db.get_active_runs()

        if not active:
            log.debug("No active runs to poll.")
            return

        job_ids = [r.slurm_jobid for r in active if r.slurm_jobid]
        if not job_ids:
            return

        sacct = SacctClient(self.settings.slurm.sacct_bin)
        try:
            statuses = sacct.query(job_ids)
        except Exception as exc:
            log.error("sacct query failed: %s", exc)
            return

        for record in active:
            if not record.slurm_jobid:
                continue
            status = statuses.get(record.slurm_jobid)
            if status is None or not status.is_terminal:
                continue

            new_state = "completed" if status.is_success else "failed"
            db.update_run(
                record.run_id,
                state=new_state,
                sacct_state=status.state,
                exit_code=status.exit_code,
                finished_at=_now(),
            )
            log.info(
                "Run %s finished: %s (exit %s)", record.run_id, status.state, status.exit_code
            )

            run_info = RunInfo.from_url(record.url)
            multiqc = (
                Path(self.settings.working_dir)
                / "multiqc"
                / record.run_id
                / f"{record.run_id}_multiqc_report.html"
            )
            ss_path = Path(record.samplesheet_path) if record.samplesheet_path else None

            notifier.notify_result(
                run_info,
                ok=status.is_success,
                slurm_jobid=record.slurm_jobid,
                sacct_state=status.state,
                exit_code=status.exit_code,
                samplesheet_path=ss_path,
                multiqc_report=multiqc if multiqc.exists() else None,
            )
            db.update_run(record.run_id, state="notified", notified_at=_now())
