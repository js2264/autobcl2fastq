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


@cli.command("run")
@click.option("--url", required=True, help="Biomics download URL.")
@click.option(
    "--samplesheet",
    type=click.Path(exists=True, path_type=Path),
    default=None,
    help="Pre-fixed Illumina CSV samplesheet (skips SharePoint fetch).",
)
@click.option("--dry-run", is_flag=True, help="Render the sbatch script but do not submit.")
@click.pass_context
def run_cmd(
    ctx: click.Context,
    url: str,
    samplesheet: Path | None,
    dry_run: bool,
) -> None:
    """Manually trigger demultiplexing of a single Biomics run."""
    from .notifier import Notifier
    from .pipeline import DemuxPipeline, RunInfo

    settings: Settings = ctx.obj["settings"]
    pipeline = DemuxPipeline(settings)

    run_info = RunInfo.from_url(url)
    notifier = Notifier(settings)

    try:
        job_id = pipeline.run(url, samplesheet_path=samplesheet, dry_run=dry_run)
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
    settings: Settings = ctx.obj["settings"]
    _do_poll(settings, verbose=verbose)


def _do_poll(settings: Settings, verbose: bool = False) -> None:
    """Core polling logic shared by poll-once and the daemon."""
    from .notifier import Notifier
    from .pipeline import DemuxPipeline, RunInfo
    from .state import StateDB
    from .watcher import BiomicsEmailWatcher

    notifier = Notifier(settings)

    if verbose:
        console.print("[cyan]Starting poll iteration...[/cyan]")

    # 1. Check for new Biomics emails
    if verbose:
        console.print("[cyan]  Checking for new Biomics emails...[/cyan]")
    watcher = BiomicsEmailWatcher(settings)
    try:
        run_email = watcher.poll()
    except Exception as exc:
        log.error("IMAP poll failed: %s", exc)
        if verbose:
            console.print(f"[red]  IMAP poll failed: {exc}[/red]")
        run_email = None

    if run_email:
        run_info = RunInfo.from_url(run_email.url)
        if verbose:
            console.print(f"[green]  Found new run: {run_info.run_id}[/green]")
        pipeline = DemuxPipeline(settings)
        try:
            job_id = pipeline.run(run_email.url)
            notifier.notify_start(
                run_info,
                settings.samplesheets_dir
                / f"SampleSheet_{run_info.run_date}_{run_info.run_nb}_{run_info.run_hash}.csv",
            )
            log.info("Submitted run %s as Slurm job %s", run_info.run_id, job_id)
            if verbose:
                console.print(f"[green]  Submitted as Slurm job {job_id}[/green]")
        except Exception as exc:
            log.error("Failed to process run %s: %s", run_email.url, exc)
            notifier.notify_error(str(exc), run_name=run_info.run_name)
            if verbose:
                console.print(f"[red]  Failed to process run: {exc}[/red]")
    else:
        if verbose:
            console.print("[cyan]  No new Biomics emails found.[/cyan]")

    # 2. Poll sacct for active runs
    if verbose:
        console.print("[cyan]  Checking for active runs...[/cyan]")
    db = StateDB(settings.db_path)
    active = db.get_active_runs()
    if not active:
        if verbose:
            console.print("[cyan]  No active runs in database.[/cyan]")
        return

    if verbose:
        console.print(f"[cyan]  Found {len(active)} active run(s), querying sacct...[/cyan]")

    from rsgutils.slurm import SacctClient

    sacct = SacctClient(settings.slurm.sacct_bin)
    job_ids = [r.slurm_jobid for r in active if r.slurm_jobid]
    if not job_ids:
        if verbose:
            console.print("[cyan]  No Slurm job IDs to query.[/cyan]")
        return

    try:
        statuses = sacct.query(job_ids)
    except Exception as exc:
        log.error("sacct query failed: %s", exc)
        if verbose:
            console.print(f"[red]  sacct query failed: {exc}[/red]")
        return

    terminal_count = 0
    for record in active:
        if not record.slurm_jobid:
            continue
        status = statuses.get(record.slurm_jobid)
        if status is None or not status.is_terminal:
            continue

        terminal_count += 1
        new_state = "completed" if status.is_success else "failed"
        db.update_run(
            record.run_id,
            state=new_state,
            sacct_state=status.state,
            exit_code=status.exit_code,
            finished_at=_now(),
        )
        run_info = RunInfo.from_url(record.url)

        # Locate MultiQC report (best effort)
        run_id = record.run_id
        multiqc = Path(settings.working_dir) / "multiqc" / run_id / f"{run_id}_multiqc_report.html"
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
        
        if verbose:
            color = "green" if status.is_success else "red"
            console.print(
                f"[{color}]  Run {record.run_id} finished ({status.state}, "
                f"exit code {status.exit_code})[/{color}]"
            )

    if verbose:
        console.print(f"[cyan]Poll complete: {terminal_count} run(s) finished.[/cyan]")


def _now() -> str:
    from datetime import datetime

    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


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
