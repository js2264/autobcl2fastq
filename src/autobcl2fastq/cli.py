"""rich-click CLI for autobcl2fastq."""

from __future__ import annotations

import logging
import sys
from pathlib import Path

import rich_click as click
from rich.console import Console
from rich.table import Table

from . import __version__
from .config import Settings

console = Console()
log = logging.getLogger("autobcl2fastq")

click.rich_click.USE_RICH_MARKUP = True
click.rich_click.STYLE_HELPTEXT = ""


# ---------------------------------------------------------------------------
# Root group
# ---------------------------------------------------------------------------


@click.group()
@click.version_option(version=__version__, prog_name="autobcl2fastq")
@click.option("--config", type=click.Path(path_type=Path), default=None, hidden=True)
@click.pass_context
def cli(ctx: click.Context, config: Path | None) -> None:
    """Automated BCL demultiplexing pipeline for Illumina NextSeq runs.

    Uses shared RSG infrastructure (IMAP, SMTP, Slurm) from ``rsgutils``.
    Run [bold]rsgutils setup[/bold] once per machine to store the shared
    IMAP/SMTP password.
    """
    ctx.ensure_object(dict)
    ctx.obj["settings"] = Settings.load(config)
    logging.basicConfig(
        level=ctx.obj["settings"].log_level,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )


# ---------------------------------------------------------------------------
# Run commands
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Daemon commands
# ---------------------------------------------------------------------------


@cli.group("daemon")
def daemon_group() -> None:
    """Manage the autobcl2fastq background daemon."""


@daemon_group.command("start")
@click.pass_context
def daemon_start(ctx: click.Context) -> None:
    """Start the daemon in the foreground (used by the systemd service)."""
    from .daemon import Daemon

    settings: Settings = ctx.obj["settings"]
    Daemon(settings).run_forever()


@daemon_group.command("run")
@click.pass_context
def daemon_run(ctx: click.Context) -> None:  # alias for start
    """Alias for [bold]daemon start[/bold]."""
    from .daemon import Daemon

    settings: Settings = ctx.obj["settings"]
    Daemon(settings).run_forever()


@daemon_group.command("stop")
def daemon_stop() -> None:
    """Stop the systemd user service."""
    import subprocess

    console.print("[yellow]Stopping autobcl2fastq.service...[/yellow]")
    subprocess.run(["systemctl", "--user", "stop", "autobcl2fastq.service"], check=False)


@daemon_group.command("restart")
def daemon_restart() -> None:
    """Restart the systemd user service."""
    import subprocess

    console.print("[yellow]Restarting autobcl2fastq.service...[/yellow]")
    subprocess.run(["systemctl", "--user", "restart", "autobcl2fastq.service"], check=False)


@daemon_group.command("status")
def daemon_status() -> None:
    """Show the status of the systemd user service."""
    import subprocess

    subprocess.run(["systemctl", "--user", "status", "autobcl2fastq.service"], check=False)


# ---------------------------------------------------------------------------
# Run commands
# ---------------------------------------------------------------------------


def _validate_url(
    ctx: click.Context,  # noqa: ARG001
    param: click.Parameter,  # noqa: ARG001
    value: str | None,
) -> str | None:
    """Validate --url: accept remote URLs or existing local tar files."""
    if value is None:
        return None
    if value.startswith(("http://", "https://", "ftp://")):
        return value
    path = Path(value)
    if not path.exists():
        raise click.BadParameter(f"URL or archive file does not exist: {value}")
    if not path.is_file():
        raise click.BadParameter(f"Archive path is not a file: {value}")
    return value


@cli.command("run")
@click.option(
    "--url",
    required=True,
    callback=_validate_url,
    help="Biomics download URL or local path to a BCL .tar archive.",
)
@click.option(
    "--samplesheet",
    type=click.Path(exists=True, path_type=Path),
    default=None,
    help="Pre-fixed Illumina CSV samplesheet (skips SharePoint fetch).",
)
@click.option(
    "--sequencer",
    type=click.Choice(["nxq", "nvq"], case_sensitive=False),
    default="nxq",
    show_default=True,
    help="Sequencer type controlling FASTQ rename convention.",
)
@click.option("--dry-run", is_flag=True, help="Render the sbatch script but do not submit.")
@click.pass_context
def run_cmd(
    ctx: click.Context,
    url: str,
    samplesheet: Path | None,
    sequencer: str,
    dry_run: bool,
) -> None:
    """Manually trigger demultiplexing of a single Biomics run."""
    from .notifier import Notifier
    from .pipeline import DemuxPipeline, RunInfo

    settings: Settings = ctx.obj["settings"]
    pipeline = DemuxPipeline(settings)

    source = url
    run_info = RunInfo.from_url(source)
    notifier = Notifier(settings)

    try:
        job_id = pipeline.run(
            source,
            samplesheet_path=samplesheet,
            sequencer=sequencer,
            dry_run=dry_run,
        )
    except Exception as exc:
        notifier.notify_error(str(exc), run_name=run_info.run_name)
        console.print(f"[red]Error: {exc}[/red]")
        sys.exit(1)

    if dry_run:
        console.print("[yellow]Dry run: sbatch script written but not submitted.[/yellow]")
    else:
        console.print(f"[green]Run {run_info.run_id} submitted (Slurm job {job_id}).[/green]")
        # Send start notification
        from .samplesheet import SamplesheetManager

        ss_path = samplesheet or SamplesheetManager(settings).fetch_local(run_info.run_hash)
        if ss_path:
            notifier.notify_start(run_info, ss_path)


@cli.command("poll-once")
@click.option("--verbose", is_flag=True, help="Show detailed progress information.")
@click.pass_context
def poll_once(ctx: click.Context, verbose: bool) -> None:
    """Single daemon iteration: check inbox + poll sacct for active runs.

    Safe to call from a cron job or systemd timer.
    """
    from .daemon import Daemon

    settings: Settings = ctx.obj["settings"]
    if verbose:
        console.print("[cyan]Starting poll iteration...[/cyan]")
    Daemon(settings).run_once()
    if verbose:
        console.print("[cyan]Poll complete.[/cyan]")


# ---------------------------------------------------------------------------
# Status command
# ---------------------------------------------------------------------------


@cli.command("status")
@click.option("--limit", default=20, show_default=True, help="Number of runs to show.")
@click.option(
    "--state",
    type=click.Choice(["submitted", "running", "completed", "failed", "notified"]),
    default=None,
)
@click.pass_context
def status_cmd(ctx: click.Context, limit: int, state: str | None) -> None:
    """Display recent run states."""
    from .state import StateDB

    settings: Settings = ctx.obj["settings"]
    db = StateDB(settings.db_path)
    runs = db.list_runs(state=state, limit=limit)

    if not runs:
        console.print("[yellow]No runs found.[/yellow]")
        return

    table = Table(title="autobcl2fastq runs", show_lines=False)
    table.add_column("run_id", style="cyan")
    table.add_column("slurm_jobid")
    table.add_column("state")
    table.add_column("sacct_state")
    table.add_column("submitted_at")

    for r in runs:
        state_style = (
            "green" if r.state == "completed" else "red" if r.state == "failed" else "yellow"
        )
        table.add_row(
            r.run_id,
            r.slurm_jobid or "—",
            f"[{state_style}]{r.state}[/{state_style}]",
            r.sacct_state or "—",
            (r.submitted_at or "—")[:19],
        )

    console.print(table)
