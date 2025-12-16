## Usage 

To demultiplex a run for which a link to the data archive has been sent by 
Biomics: 

```sh
/pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq/bin/autobcl2fastq_biomics.sh \
    --url <BIOMICS_URL>
```

With a CRON job, to automatically check for new Biomics runs and
demultiplex them:

```sh
/pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq/bin/autobcl2fastq_biomics.sh 
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
```

## Dependencies 

### SSH config 

SSH key-based, passwordless access must be set up in `~/.ssh/config` to acces
the server where demultiplexed reads will be copied. 

### Secrets

Several secrets have to be defined for automated fetching from Biomics: 

- `password`: Pasteur email password

### Python environment for email checking

A `micromamba` environment named `autobcl2fastq` must be created with
the dependencies listed in `environment.yml`.

```shell
micromamba env create -f environment.yml
```
