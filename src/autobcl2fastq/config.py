"""Configuration model for autobcl2fastq.

Loads from ``~/.config/autobcl2fastq/config.yaml`` and env vars prefixed
``AUTOBCL2FASTQ_``.  Shared infrastructure settings (IMAP/SMTP hosts, Slurm
binary paths, encrypted credential store) are inherited from
:class:`~rsgutils.config.RsgBaseSettings` and live in
``~/.config/rsgutils/``; configure them once via ``rsgutils setup``.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Optional

import yaml
from pydantic import BaseModel, Field, field_validator
from pydantic_settings import SettingsConfigDict

from rsgutils.config import RsgBaseSettings


def _xdg(env: str, default: Path) -> Path:
    raw = os.environ.get(env)
    return Path(raw) if raw else default


XDG_CONFIG = _xdg("XDG_CONFIG_HOME", Path.home() / ".config") / "autobcl2fastq"
XDG_DATA = _xdg("XDG_DATA_HOME", Path.home() / ".local" / "share") / "autobcl2fastq"
XDG_STATE = _xdg("XDG_STATE_HOME", Path.home() / ".local" / "state") / "autobcl2fastq"


class BiomicsConfig(BaseModel):
    """Biomics platform email settings for new-run notifications."""

    sender: str = "ekornobi@pasteur.fr"
    subject: str = "Biomics downloadable link"


class HPCConfig(BaseModel):
    """Slurm job resource and HPC module settings for maestro."""

    partition: str = "common,dedicated"
    qos: Optional[str] = "fast"
    cpus_per_task: int = 20
    mem: str = "48G"

    # HPC environment modules loaded at the start of the compute job.
    # Override in config.yaml to update to newer module versions.
    modules: list[str] = Field(
        default_factory=lambda: [
            "bcl2fastq/2.20.0",
            "graalvm/ce-java19-22.3.1",
            "fastqc/0.11.9",
            "bowtie2/2.1.0",
            "MultiQC/1.9",
            "fastq_screen/v0.14.0",
        ]
    )

    # Number of parallel threads for bcl2fastq and FastQC/fastq_screen.
    # bcl2fastq splits across loading/processing/writing; fastqc and
    # fastq_screen both receive this value directly.
    threads: int = 12


class Settings(RsgBaseSettings):
    """Top-level settings, loaded from YAML and overridden by env vars.

    Shared fields (mail infra, Slurm binary paths, secrets paths) are
    inherited from :class:`~rsgutils.config.RsgBaseSettings`.  Configure
    them once with ``rsgutils setup`` / ``~/.config/rsgutils/config.yaml``.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOBCL2FASTQ_",
        env_nested_delimiter="__",
        yaml_file=str(XDG_CONFIG / "config.yaml"),
        yaml_file_encoding="utf-8",
        extra="ignore",
        populate_by_name=True,
    )

    config_dir: Path = XDG_CONFIG
    data_dir: Path = XDG_DATA
    state_dir: Path = XDG_STATE

    # SSH alias for sftpcampus (set up in ~/.ssh/config).
    ssh_hostname: str = "sftpcampus"

    # Remote directory where demultiplexed FASTQ files are published.
    reads_dir: str = "/pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/"

    # Local scratch directory where BCL data is downloaded and processed.
    working_dir: str = "/pasteur/appa/scratch/jaseriza/autobcl2fastq/"

    # SharePoint coordinates for fetching RSG samplesheets.
    sharepoint_url: str = "https://pasteurfr.sharepoint.com/sites/RSGteam"
    sharepoint_entrypoint: str = (
        "/sites/RSGteam/Documents partages/Experimentalist group/sequencing_runs/"
    )

    # Path to users.conf (INI-style file mapping project IDs to users).
    # When absent, user validation is skipped with a warning.
    users_conf_file: Optional[Path] = XDG_CONFIG / "users.conf"

    # Path to a directory containing adapters.txt, fastq_screen.conf,
    # and indices.txt.  Defaults to the installed package data directory.
    resources_dir: Optional[Path] = None

    biomics: BiomicsConfig = Field(default_factory=BiomicsConfig)
    hpc: HPCConfig = Field(default_factory=HPCConfig)

    # ------------------------------------------------------------------ paths

    @property
    def log_dir(self) -> Path:
        return self.state_dir / "logs"

    @property
    def db_path(self) -> Path:
        return self.data_dir / "state.db"

    @property
    def sbatch_archive_dir(self) -> Path:
        return self.data_dir / "sbatch"

    @property
    def samplesheets_dir(self) -> Path:
        return Path(self.working_dir) / "samplesheets"

    @property
    def samplesheets_raw_dir(self) -> Path:
        return Path(self.working_dir) / "samplesheets_raw"

    @property
    def resolved_resources_dir(self) -> Path:
        """Return path to the data files (adapters.txt, indices.txt, etc.).

        Resolution order:
          1. Explicit ``resources_dir`` from config YAML / env var.
          2. Installed package data directory (``autobcl2fastq/data/``).
        """
        if self.resources_dir:
            return self.resources_dir
        return Path(__file__).parent / "data"

    # ---------------------------------------------------------------- helpers

    @classmethod
    def load(cls, config_file: Optional[Path] = None) -> "Settings":
        """Load settings; missing YAML file → defaults + env-var overrides."""
        path = config_file or (XDG_CONFIG / "config.yaml")
        if path.exists():
            data = yaml.safe_load(path.read_text()) or {}
            return cls(**data)
        return cls()

    def ensure_dirs(self) -> None:
        for d in (
            self.config_dir,
            self.data_dir,
            self.state_dir,
            self.log_dir,
            self.sbatch_archive_dir,
            self.samplesheets_dir,
            self.samplesheets_raw_dir,
            Path(self.working_dir) / "runs",
            Path(self.working_dir) / "batch_logs",
        ):
            d.mkdir(parents=True, exist_ok=True)
