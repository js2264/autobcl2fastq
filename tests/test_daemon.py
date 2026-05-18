"""Tests for autobcl2fastq.daemon.Daemon."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from autobcl2fastq.daemon import Daemon
from autobcl2fastq.watcher import BiomicsRunInfo

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_RUN_URL = "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AACLHW3M5__ts.tar"

_BIOMICS_RUN_INFO = BiomicsRunInfo(
    url=_RUN_URL,
    sender="ekornobi@pasteur.fr",
    subject="Biomics downloadable link",
    received_at=None,  # type: ignore[arg-type]
)


# ---------------------------------------------------------------------------
# _poll_inbox — no email
# ---------------------------------------------------------------------------


def test_poll_inbox_no_email(tmp_settings):
    """When the inbox is empty, pipeline.run is never called."""
    daemon = Daemon(tmp_settings)

    with (
        patch("autobcl2fastq.daemon.BiomicsEmailWatcher") as MockWatcher,
        patch("autobcl2fastq.daemon.DemuxPipeline") as MockPipeline,
        patch("autobcl2fastq.daemon.Notifier"),
    ):
        MockWatcher.return_value.poll.return_value = []
        daemon._poll_inbox()

    MockPipeline.return_value.run.assert_not_called()


# ---------------------------------------------------------------------------
# _poll_inbox — email triggers pipeline
# ---------------------------------------------------------------------------


def test_poll_inbox_with_email_submits_run(tmp_settings):
    """A new Biomics email triggers DemuxPipeline.run and notify_start."""
    daemon = Daemon(tmp_settings)

    mock_notifier = MagicMock()
    mock_pipeline = MagicMock()
    mock_pipeline.run.return_value = "12345"

    with (
        patch("autobcl2fastq.daemon.BiomicsEmailWatcher") as MockWatcher,
        patch("autobcl2fastq.daemon.DemuxPipeline", return_value=mock_pipeline),
        patch("autobcl2fastq.daemon.Notifier", return_value=mock_notifier),
        patch("autobcl2fastq.daemon.RunInfo") as MockRunInfo,
    ):
        MockWatcher.return_value.poll.return_value = [_BIOMICS_RUN_INFO]
        MockRunInfo.from_url.return_value = MagicMock(
            run_id="230516_VH00537_116_AACLHW3M5",
            run_date="230516",
            run_nb="116",
            run_hash="AACLHW3M5",
            run_name="230516_VH00537_116_AACLHW3M5",
        )
        daemon._poll_inbox()

    mock_pipeline.run.assert_called_once_with(_RUN_URL)
    mock_notifier.notify_start.assert_called_once()


# ---------------------------------------------------------------------------
# _poll_inbox — pipeline failure sends error notification
# ---------------------------------------------------------------------------


def test_poll_inbox_pipeline_failure_notifies_error(tmp_settings):
    """If pipeline.run raises, notify_error is called and no exception propagates."""
    daemon = Daemon(tmp_settings)

    mock_notifier = MagicMock()
    mock_pipeline = MagicMock()
    mock_pipeline.run.side_effect = RuntimeError("bcl2fastq exploded")

    with (
        patch("autobcl2fastq.daemon.BiomicsEmailWatcher") as MockWatcher,
        patch("autobcl2fastq.daemon.DemuxPipeline", return_value=mock_pipeline),
        patch("autobcl2fastq.daemon.Notifier", return_value=mock_notifier),
        patch("autobcl2fastq.daemon.RunInfo") as MockRunInfo,
    ):
        MockWatcher.return_value.poll.return_value = [_BIOMICS_RUN_INFO]
        MockRunInfo.from_url.return_value = MagicMock(run_name="test_run")
        daemon._poll_inbox()  # must not raise

    mock_notifier.notify_error.assert_called_once()
    assert "bcl2fastq exploded" in mock_notifier.notify_error.call_args[0][0]


# ---------------------------------------------------------------------------
# _poll_slurm — no active runs
# ---------------------------------------------------------------------------


def test_poll_slurm_no_active_runs(tmp_settings):
    """When the DB has no active runs, sacct is never queried."""
    daemon = Daemon(tmp_settings)

    mock_db = MagicMock()
    mock_db.get_active_runs.return_value = []

    with (
        patch("autobcl2fastq.daemon.StateDB", return_value=mock_db),
        patch("autobcl2fastq.daemon.SacctClient") as MockSacct,
        patch("autobcl2fastq.daemon.Notifier"),
    ):
        daemon._poll_slurm()

    MockSacct.return_value.query.assert_not_called()


# ---------------------------------------------------------------------------
# _poll_slurm — marks completed and notifies
# ---------------------------------------------------------------------------


def test_poll_slurm_marks_completed(tmp_settings):
    """A terminal Slurm job is marked completed and notify_result is called."""
    daemon = Daemon(tmp_settings)

    active_run = MagicMock(
        run_id="run_abc",
        slurm_jobid="9001",
        url=_RUN_URL,
        samplesheet_path=None,
    )
    terminal_status = MagicMock(
        is_terminal=True,
        is_success=True,
        state="COMPLETED",
        exit_code=0,
    )

    mock_db = MagicMock()
    mock_db.get_active_runs.return_value = [active_run]

    mock_sacct = MagicMock()
    mock_sacct.query.return_value = {"9001": terminal_status}

    mock_notifier = MagicMock()

    with (
        patch("autobcl2fastq.daemon.StateDB", return_value=mock_db),
        patch("autobcl2fastq.daemon.SacctClient", return_value=mock_sacct),
        patch("autobcl2fastq.daemon.Notifier", return_value=mock_notifier),
        patch("autobcl2fastq.daemon.RunInfo") as MockRunInfo,
    ):
        MockRunInfo.from_url.return_value = MagicMock()
        daemon._poll_slurm()

    # State updated to completed then notified
    update_calls = mock_db.update_run.call_args_list
    states = [c.kwargs.get("state") or c.args[1] for c in update_calls]
    assert "completed" in states
    assert "notified" in states
    mock_notifier.notify_result.assert_called_once()


# ---------------------------------------------------------------------------
# run_once — delegates to both polls
# ---------------------------------------------------------------------------


def test_run_once_calls_both_polls(tmp_settings):
    """run_once() must call _poll_inbox and _poll_slurm each exactly once."""
    daemon = Daemon(tmp_settings)

    with (
        patch.object(daemon, "_poll_inbox") as mock_inbox,
        patch.object(daemon, "_poll_slurm") as mock_slurm,
    ):
        daemon.run_once()

    mock_inbox.assert_called_once()
    mock_slurm.assert_called_once()


# ---------------------------------------------------------------------------
# run_forever — loops until interrupted
# ---------------------------------------------------------------------------


def test_run_forever_loops(tmp_settings):
    """run_forever iterates until KeyboardInterrupt (raised via time.sleep)."""
    daemon = Daemon(tmp_settings)

    # Swap settings for a mock that provides poll intervals; avoids depending
    # on rsgutils version having these fields.
    daemon.settings = MagicMock()
    daemon.settings.biomics.poll_interval_s = 5
    daemon.settings.hpc.sacct_poll_interval_s = 5

    call_count = 0

    def fake_sleep(_interval):
        nonlocal call_count
        call_count += 1
        if call_count >= 2:
            raise KeyboardInterrupt

    mock_inbox = MagicMock()
    mock_slurm = MagicMock()

    with (
        patch.object(daemon, "_poll_inbox", mock_inbox),
        patch.object(daemon, "_poll_slurm", mock_slurm),
        patch("autobcl2fastq.daemon.time.sleep", side_effect=fake_sleep),
        pytest.raises(KeyboardInterrupt),
    ):
        daemon.run_forever()

    assert mock_inbox.call_count >= 1
    assert mock_slurm.call_count >= 1
