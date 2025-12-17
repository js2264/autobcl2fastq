#!/usr/bin/env python3
import argparse
import imaplib
import email
import sys
from email.message import Message
from itertools import compress
from passwords import get_passwd


def fetch_new_run_email(
    username,
    sender,
    subject,
    secrets_file="/pasteur/appa/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/.secrets.yaml",
    fernet_key="/pasteur/appa/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/.fernet.key",
):
    # Read emails
    passwd = get_passwd(secrets_file, fernet_key)
    mailbox = imaplib.IMAP4_SSL("email.pasteur.fr", 993)
    mailbox.login(username, passwd)
    mailbox.select("INBOX")
    _, mail = mailbox.search(
        None,
        '(UNSEEN FROM "' + sender + '" SUBJECT "' + subject + '")',
    )

    # Fetch the only one new email expected
    uid = [int(s) for s in mail[0].split()]
    if len(uid) == 0:
        print("No new email found.", file=sys.stderr)
        return None
    if len(uid) > 1:
        print("More than 1 email detected. Please make up your mind!", file=sys.stderr)
        return None
    _, content = mailbox.fetch(str(uid[0]), "(RFC822 BODY[TEXT])")
    message = email.message_from_bytes(content[0][1], _class=Message)
    for part in message.walk():
        if part.get_content_type() == "text/plain":
            txt = part.get_payload(decode=1)

    lines = txt.decode().splitlines()
    url = list(compress(lines, [x.startswith("https") for x in lines]))[0]
    mailbox.close()
    mailbox.logout()
    return url


def main(username, sender, subject):
    url = fetch_new_run_email(username=username, sender=sender, subject=subject)
    if url is None:
        return 1
    print(f"New URL found:", file=sys.stderr)
    print(f"  {url}", file=sys.stderr)
    print(url)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fetch new run email from inbox")
    parser.add_argument("--username", required=True, help="Email username")
    parser.add_argument("--sender", required=True, help="Email sender")
    parser.add_argument("--subject", required=True, help="Email subject")
    args = parser.parse_args()
    exit(
        main(
            username=args.username,
            sender=args.sender,
            subject=args.subject,
        )
    )
