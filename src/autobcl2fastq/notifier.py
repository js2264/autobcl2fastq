"""Email notifications for autobcl2fastq run events.

Sends:
  - A *start* notification when a run is submitted to Slurm.
  - A *completion* or *failure* notification after sacct reports terminal state.

Uses :class:`~rsgutils.mail.SMTPClient` for all outbound email.
"""

from __future__ import annotations

import logging
from pathlib import Path

from rsgutils.mail import SMTPClient
from rsgutils.secrets import get_mail_password

from . import __version__ as PACKAGE_VERSION
from .config import Settings
from .pipeline import RunInfo

log = logging.getLogger(__name__)


class Notifier:
    """Send email notifications for autobcl2fastq events."""

    def __init__(self, settings: Settings):
        self.settings = settings

    # ---------------------------------------------------------------- public

    def notify_start(self, run_info: RunInfo, samplesheet_path: Path) -> None:
        """Send a 'run submitted' notification to the admin address."""
        settings = self.settings
        subject = f"[CLUSTER INFO] Submitted run {run_info.run_id} to autobcl2fastq"
        body = (
            f"Run {run_info.run_name} submitted to Slurm.\n\n"
            f"  run_id       : {run_info.run_id}\n"
            f"  run_hash     : {run_info.run_hash}\n"
            f"  url          : {run_info.url}\n"
            f"  samplesheet  : {samplesheet_path}\n"
            f"  version      : autobcl2fastq {PACKAGE_VERSION}\n"
        )
        self._send(
            to=settings.mail.address,
            subject=subject,
            body=body,
            attachments=[samplesheet_path] if samplesheet_path.exists() else [],
        )

    def notify_result(
        self,
        run_info: RunInfo,
        *,
        ok: bool,
        slurm_jobid: str | None,
        sacct_state: str | None,
        exit_code: str | None,
        samplesheet_path: Path | None = None,
        multiqc_report: Path | None = None,
        error_message: str | None = None,
    ) -> None:
        """Send a run-completion or run-failure notification."""
        settings = self.settings
        tag = "Finished" if ok else "FAILED"
        subject = f"[CLUSTER INFO] {tag} processing run {run_info.run_id} with autobcl2fastq"
        status_line = (
            "completed successfully" if ok else f"FAILED (sacct={sacct_state}, exit={exit_code})"
        )
        body = (
            f"Run {run_info.run_id} {status_line}.\n\n"
            f"  run_id       : {run_info.run_id}\n"
            f"  slurm_jobid  : {slurm_jobid or 'unknown'}\n"
            f"  sacct_state  : {sacct_state or 'unknown'}\n"
        )
        if error_message:
            body += f"\n  error: {error_message}\n"
        if not ok:
            body += (
                "\nFiles may be partially available in the reads directory.\n"
                "Check the Slurm logs for details.\n"
            )
        else:
            body += (
                f"\nFiles stored at: {settings.ssh_hostname}:{settings.reads_dir}"
                f"/run_{run_info.run_id}/\n"
            )

        attachments: list[Path] = []
        if samplesheet_path and samplesheet_path.exists():
            attachments.append(samplesheet_path)
        if multiqc_report and multiqc_report.exists():
            attachments.append(multiqc_report)

        self._send(
            to=settings.mail.address,
            subject=subject,
            body=body,
            attachments=attachments,
        )

    def notify_error(self, message: str, run_name: str | None = None) -> None:
        """Send an error notification (e.g. validation failures)."""
        settings = self.settings
        tag = f" for run {run_name}" if run_name else ""
        subject = f"[CLUSTER INFO] ERROR{tag} in autobcl2fastq"
        self._send(to=settings.mail.address, subject=subject, body=message)

    # -------------------------------------------------------------- private

    def _smtp_client(self) -> SMTPClient:
        try:
            password = get_mail_password(self.settings)
        except RuntimeError as exc:
            raise RuntimeError(str(exc)) from exc
        m = self.settings.mail
        return SMTPClient(
            host=m.smtp_host,
            port=m.smtp_port,
            username=m.address,
            password=password,
        )

    def _send(
        self,
        to: str,
        subject: str,
        body: str,
        attachments: list[Path] | None = None,
    ) -> None:
        try:
            client = self._smtp_client()
            attach_tuples = None
            if attachments:
                attach_tuples = [(p.name, p.read_bytes()) for p in attachments if p.exists()]
            client.send(to=to, subject=subject, body=body, attachments=attach_tuples)
            log.info("Notification sent: %s → %s", subject, to)
        except Exception as exc:
            log.error("Failed to send notification %r: %s", subject, exc)
