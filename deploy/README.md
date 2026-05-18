# Deploying autobcl2fastq on maestro

Steps to run autobcl2fastq as a `systemd --user` service on the maestro login
node.  The daemon polls IMAP every 60 s; when a Biomics download-link email
arrives from `ekornobi@pasteur.fr` it automatically fetches the samplesheet,
downloads the BCL archive, submits a `bcl2fastq` Slurm job, and sends you a
completion notification with the MultiQC report attached.

---

## First-time setup

```sh
# 1. Clone the repo (if not already present)
cd ~/repos
git clone https://github.com/js2264/autobcl2fastq.git
cd autobcl2fastq

# 2. Install uv (if not already present)
curl -LsSf https://astral.sh/uv/install.sh | sh
# uv is installed to ~/.local/bin/uv — make sure it is on PATH.

# 3. Install the autobcl2fastq package
#    uv creates an isolated .venv inside the project directory.
uv sync --extra dev

# 4. Configure shared RSG infrastructure (mail, Slurm binaries, etc.)
#    This writes to ~/.config/rsgutils/config.yaml and stores the IMAP/SMTP
#    password encrypted in ~/.config/rsgutils/.secrets.yaml.
rsgutils setup

# 5. Create the autobcl2fastq-specific config section (once)
#    Edit ~/.config/rsgutils/config.yaml and add / adjust:
#
#      autobcl2fastq:
#        working_dir: /pasteur/appa/scratch/jaseriza/autobcl2fastq/
#        reads_dir:   /pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/
#        biomics:
#          poll_interval_s: 60          # how often to check IMAP (seconds)
#        hpc:
#          sacct_poll_interval_s: 60    # how often to query sacct (seconds)
#          partition: common,dedicated
#          qos: fast

# 6. Copy the users config (maps sample prefixes → project IDs / recipients)
mkdir -p ~/.config/autobcl2fastq
# Edit ~/.config/autobcl2fastq/users.conf with one entry per line:
#   <prefix>  <email>

# 7. Smoke-test with a manual poll (hits IMAP but does not loop)
autobcl2fastq poll-once --verbose

# 8. Install + enable the user service
mkdir -p ~/.config/systemd/user
cp deploy/autobcl2fastq.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now autobcl2fastq.service

# 9. Survive logout
loginctl enable-linger "$USER"

# 10. Tail the log
tail -f ~/.local/state/autobcl2fastq/daemon.log
```

---

## Day-to-day commands

| Purpose | Command |
|---------|---------|
| Start daemon | `autobcl2fastq daemon start` (foreground) or `systemctl --user start autobcl2fastq.service` |
| Stop daemon | `autobcl2fastq daemon stop` |
| Restart daemon | `autobcl2fastq daemon restart` |
| Service status | `autobcl2fastq daemon status` |
| One-shot poll | `autobcl2fastq poll-once --verbose` |
| Manual run | `autobcl2fastq run --url <URL>` |
| Recent runs | `autobcl2fastq status` |

---

## Updating autobcl2fastq

```sh
cd ~/repos/autobcl2fastq
git pull
uv sync
systemctl --user restart autobcl2fastq.service
```

---

## Logs and state

| Path | Contents |
|------|----------|
| `~/.local/state/autobcl2fastq/daemon.log` | Daemon stdout/stderr (appended) |
| `~/.local/share/autobcl2fastq/state.db` | SQLite run state |
| `~/.local/share/autobcl2fastq/sbatch/` | Rendered sbatch scripts |
| `<working_dir>/samplesheets/` | Fixed Illumina CSV samplesheets |
| `<working_dir>/fastq/` | Demultiplexed FASTQ files |
