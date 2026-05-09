"""Tests for autobcl2fastq.watcher (BiomicsEmailWatcher)."""

from __future__ import annotations

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from autobcl2fastq.watcher import BiomicsEmailWatcher, _extract_url

# ---------------------------------------------------------------------------
# _extract_url
# ---------------------------------------------------------------------------


def test_extract_url_finds_https():
    body = "Some text\nhttps://dl.pasteur.fr/fop/XXXX/run.tar\nMore text"
    assert _extract_url(body) == "https://dl.pasteur.fr/fop/XXXX/run.tar"


def test_extract_url_strips_whitespace():
    body = "  https://example.com/run.tar  "
    assert _extract_url(body) == "https://example.com/run.tar"


def test_extract_url_returns_none_when_absent():
    assert _extract_url("No URL here.") is None


# ---------------------------------------------------------------------------
# BiomicsEmailWatcher.poll
# ---------------------------------------------------------------------------


def _make_email_message(url: str):
    """Create a minimal mock EmailMessage."""
    msg = MagicMock()
    msg.uid = "42"
    msg.sender = "biomics@pasteur.fr"
    msg.subject = "Biomics downloadable link"
    msg.received_at = datetime(2023, 5, 17, 10, 0, 0, tzinfo=timezone.utc)
    msg.body = f"Your run is ready.\n{url}\nThanks."
    return msg


def test_poll_returns_run_info(tmp_settings):
    url = "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AACLHW3M5__ts.tar"
    mock_email = _make_email_message(url)

    mock_client = MagicMock()
    mock_client.find_emails.return_value = [mock_email]

    with (
        patch("autobcl2fastq.watcher.get_mail_password", return_value="secret"),
        patch("autobcl2fastq.watcher.IMAPClient", return_value=mock_client),
    ):
        watcher = BiomicsEmailWatcher(tmp_settings)
        result = watcher.poll()

    assert result is not None
    assert result.url == url
    mock_client.mark_seen.assert_called_once_with("42")


def test_poll_returns_none_when_no_emails(tmp_settings):
    mock_client = MagicMock()
    mock_client.find_emails.return_value = []

    with (
        patch("autobcl2fastq.watcher.get_mail_password", return_value="secret"),
        patch("autobcl2fastq.watcher.IMAPClient", return_value=mock_client),
    ):
        watcher = BiomicsEmailWatcher(tmp_settings)
        result = watcher.poll()

    assert result is None


def test_poll_returns_none_when_body_has_no_url(tmp_settings):
    mock_email = MagicMock()
    mock_email.uid = "1"
    mock_email.body = "No URL in this message."
    mock_email.sender = "biomics@pasteur.fr"
    mock_email.subject = "Biomics downloadable link"
    mock_email.received_at = datetime.now(timezone.utc)

    mock_client = MagicMock()
    mock_client.find_emails.return_value = [mock_email]

    with (
        patch("autobcl2fastq.watcher.get_mail_password", return_value="secret"),
        patch("autobcl2fastq.watcher.IMAPClient", return_value=mock_client),
    ):
        watcher = BiomicsEmailWatcher(tmp_settings)
        result = watcher.poll()

    assert result is None


def test_poll_raises_when_password_missing(tmp_settings):
    with patch(
        "autobcl2fastq.watcher.get_mail_password",
        side_effect=RuntimeError(
            "Mail password not found in the shared RSG secrets store. Run 'rsgutils setup' to store it."
        ),
    ):
        watcher = BiomicsEmailWatcher(tmp_settings)
        with pytest.raises(RuntimeError, match="rsgutils setup"):
            watcher.poll()
