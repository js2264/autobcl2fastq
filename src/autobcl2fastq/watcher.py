"""IMAP watcher for Biomics new-run notification emails.

Replaces ``bin/check_emails.py``.  Uses :class:`~rsgutils.mail.IMAPClient`
from the shared ``rsgutils`` library rather than raw ``imaplib``.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime

from rsgutils.mail import IMAPClient
from rsgutils.secrets import get_mail_password

from .config import Settings

log = logging.getLogger(__name__)

_URL_PREFIX = "https"


@dataclass
class BiomicsRunInfo:
    """A new Biomics run URL extracted from an email."""

    url: str
    sender: str
    subject: str
    received_at: datetime


class BiomicsEmailWatcher:
    """Poll the IMAP inbox for Biomics run-notification emails."""

    def __init__(self, settings: Settings):
        self.settings = settings

    def poll(self) -> list[BiomicsRunInfo]:
        """Return all unseen Biomics emails as a list, or an empty list if there are none.

        Each email is marked as seen on the server only after its URL has been
        successfully extracted, so emails that cannot be parsed are left unseen
        for the next poll.
        """
        settings = self.settings
        try:
            password = get_mail_password(settings)
        except RuntimeError as exc:
            raise RuntimeError(str(exc)) from exc

        client = IMAPClient(
            host=settings.mail.imap_host,
            port=settings.mail.imap_port,
            username=settings.mail.address,
            password=password,
        )

        emails = client.find_emails(
            sender=settings.biomics.sender,
            subject_contains=settings.biomics.subject,
            unseen_only=True,
        )

        if not emails:
            log.debug("No new Biomics emails found.")
            return []

        log.info("%d unseen Biomics email(s) found.", len(emails))

        results: list[BiomicsRunInfo] = []
        for msg in emails:
            url = _extract_url(msg.body)
            if url is None:
                log.warning(
                    "Biomics email (uid=%s) contained no download URL. Skipping.",
                    msg.uid,
                )
                continue
            client.mark_seen(msg.uid)
            log.info("Found Biomics run URL: %s", url)
            results.append(
                BiomicsRunInfo(
                    url=url,
                    sender=msg.sender,
                    subject=msg.subject,
                    received_at=msg.received_at,
                )
            )

        return results


def _extract_url(body: str) -> str | None:
    """Return the first HTTPS URL found in the email body."""
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith(_URL_PREFIX):
            return stripped
    return None
