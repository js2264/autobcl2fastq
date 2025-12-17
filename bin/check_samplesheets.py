#!/usr/bin/env python3
import tempfile
import sys
import argparse
import pandas as pd
from pathlib import Path
from passwords import get_passwd
from office365.runtime.auth.authentication_context import UserCredential
from office365.sharepoint.client_context import ClientContext


## Functions
def fetch_samplesheet(
    hash,
    email,
    sharepoint_url,
    entrypoint,
    samplesheets_folder,
    secrets_file="/pasteur/appa/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/.secrets.yaml",
    fernet_key="/pasteur/appa/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/.fernet.key",
):
    passwd = get_passwd(secrets_file, fernet_key)
    ctx = ClientContext(sharepoint_url).with_credentials(UserCredential(email, passwd))
    folder = ctx.web.get_folder_by_server_relative_url(entrypoint)
    files = folder.files
    ctx.load(files)
    ctx.execute_query()

    # Check that `rsgsheet_{hash}.xlsx` exists
    target_filename = f"rsgsheet_{hash}.xlsx"
    target_file = None
    for file in files:
        if file.properties["Name"] == target_filename:
            target_file = file
            break

    # If not found, raise error
    if not target_file:
        raise FileNotFoundError(
            f"File {target_filename} not found in SharePoint folder."
        )

    # If found, download the file in tmp folder
    tmp_path = tempfile.NamedTemporaryFile(suffix=".xlsx")
    with open(tmp_path.name, "wb") as tmp_file:
        target_file.download(tmp_file).execute_query()

    # Convert it from xlsx to tsv
    local_path = Path(samplesheets_folder) / f"rsgsheet_{hash}.tsv"
    df = pd.read_excel(tmp_path.name).iloc[:, 1:3]
    df = df.dropna()
    df.to_csv(local_path, sep="\t", index=False, header=False)
    return str(local_path)


def main(hash, email, sharepoint_url, entrypoint, samplesheets_folder):
    if not (hash.startswith("AA") and len(hash) == 9):
        raise ValueError("Hash should start with 'AA' and be 9 characters long.")

    out_file = fetch_samplesheet(
        hash=hash,
        email=email,
        sharepoint_url=sharepoint_url,
        entrypoint=entrypoint,
        samplesheets_folder=samplesheets_folder,
    )

    print(f"Samplesheet for hash {hash} fetched and saved:", file=sys.stderr)
    print(f"  {out_file}", file=sys.stderr)
    print(out_file)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fetch samplesheet from SharePoint")
    parser.add_argument(
        "--hash", required=True, help="Hash starting with 'AA' (9 characters)"
    )
    parser.add_argument("--email", required=True, help="Email address")
    parser.add_argument("--sharepoint-url", required=True, help="SharePoint site URL")
    parser.add_argument("--entrypoint", required=True, help="SharePoint folder path")
    parser.add_argument(
        "--samplesheets-folder", required=True, help="Local folder to save samplesheets"
    )
    args = parser.parse_args()
    exit(
        main(
            hash=args.hash,
            email=args.email,
            sharepoint_url=args.sharepoint_url,
            entrypoint=args.entrypoint,
            samplesheets_folder=args.samplesheets_folder,
        )
    )
