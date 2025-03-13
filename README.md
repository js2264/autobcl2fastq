## Usage 

To demultiplex a run for which a link to the data archive has been sent by 
Biomics: 

```sh
/pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq/bin/autobcl2fastq_biomics.sh \
    --url <BIOMICS_URL>
```

## Options 

```sh
--email <EMAIL>                  | Default: jaseriza@pasteur.fr"
                                     Email address for notifications."
--ssh_hostname <SSH_HOSTNAME>    | Default: sftpcampus"
                                     Alias for access to sftpcampus set up in your ~/.ssh/config."
--reads_dir <DESTINATION>        | Default: /pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/"
                                     Directory where the reads are going to be copied (available from sftpcampus)."
--working_dir <WORKING_DIR>      | Default: /pasteur/appa/scratch/jaseriza/autobcl2fastq/"
                                     Directory where demultiplexing takes place (available from maestro)."
                                     Samplesheets are going to be formatted and backed up here."
--sbatch_dir <SBATCH_DIR>        | Default: /opt/hpc/slurm/current/bin/"
                                     Directory for sbatch dependency."
--bin_dir <BIN_DIR>              | Default: /pasteur/appa/homes/jaseriza/miniforge/bin/"
                                     Directory for xlsx2csv and Rscript dependencies."
--rclone_conf <RCLONE_CONFIG>    | Default: /pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq/rclone.conf"
                                     This file contains credentials to authenticate to RSG Teams repository."
```

## Dependencies 

### SSH config 

SSH key-based, passwordless access must be set up in `~/.ssh/config` to acces
the server where demultiplexed reads will be copied. 

### Secrets

Several secrets have to be defined for automated fetching from Biomics: 

- `username`: Pasteur email address
- `password`: Pasteur email password
- `sender`: Pasteur email address of Biomics team sender
- `imap_server`: Pasateur imap server

### rclone access

A specific rclone config is required to fetch RSG sequencing run sample sheets.

```sh
conda install -y -c conda-forge rclone 
rclone config
# name: rsg
# storage: onedrive
# client_id: <LEAVE BLANK>
# client_secret: <LEAVE BLANK>
# region: global
# edit advanced config: n
# use auto config: n
# ... Open a terminal on your local machine, type `rclone authorize "onedrive"` then login from the web page
# config_token: <COPY-PASTE THE TOKEN OBTAINED FROM PREVIOUS STEP>
# config_type: search
# config_search_term: RSG
# config_driveid: 1 (Documents)
# Drive OK: y
rclone ls rsgteams:'Experimentalist group/sequencing_runs/'
```

### Other 

The following binaries should be available in the system. Their directory 
can be set up using `--sbatch_dir <SBATCH_DIR>` and/or `--bin_dir <BIN_DIR>`. 

- `xlsx2csv`
- `Rscript`
- `sbatch`
