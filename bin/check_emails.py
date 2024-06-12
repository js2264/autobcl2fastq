#!/usr/bin/env python3
import yaml
from pathlib import Path
import imaplib
import email
import email.message
from email.message import Message
from itertools import compress
from cryptography.fernet import Fernet

def get_secrets(secrets_file):
    full_file_path = Path(secrets_file).parent.joinpath(secrets_file)
    with open(full_file_path) as settings:
        settings_data = yaml.load(settings, Loader=yaml.Loader)
    return settings_data

def get_mailbox(secrets, key):
    username = secrets['username']
    f = Fernet(key)
    token = bytes(secrets['token'], 'utf-8')
    #f.encrypt(b"<pasteur_webmail_password>") --> store in secrets[["token"]]
    password = f.decrypt(token).decode(encoding = 'utf-8')
    imap_server = secrets['imap_server']
    mail = imaplib.IMAP4_SSL(imap_server)
    mail.login(username, password)
    return(mail)

def read_mail(mailbox, sender):
    mailbox.select("INBOX")
    _, mail = mailbox.search(None, '(UNSEEN FROM "' + sender + '" SUBJECT "Biomics downloadable link")')
    uid = [int(s) for s in mail[0].split()]
    if len(uid) == 0: 
        raise Exception("No new email found.")
    if len(uid) > 1: 
        raise Exception("More than 1 email detected. Please make up your mind!")
    _, content = mailbox.fetch(str(uid[0]), '(RFC822 BODY[TEXT])')
    message = email.message_from_bytes(content[0][1], _class = Message) 
    for part in message.walk():
        if part.get_content_type() == 'text/plain':
            txt = part.get_payload(decode=1)
    return(txt.decode())

def find_link(mail): 
    lines = mail.splitlines()
    url = list(compress(lines, [x.startswith('https') for x in lines]))[0]
    return(url)

def main():
    secrets = get_secrets("/pasteur/appa/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/.secrets.yaml")
    key = get_secrets("/pasteur/appa/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/.fernet.key")
    mailbox = get_mailbox(secrets, key)
    try:
        mail = read_mail(mailbox, secrets['sender'])
        link = find_link(mail)
    except:
        link = ""
    return(link)

if __name__ == "__main__":
    print(main())

