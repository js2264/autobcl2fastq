"""Tests for autobcl2fastq.config."""

from __future__ import annotations

from pathlib import Path

from autobcl2fastq.config import BiomicsConfig, HPCConfig, Settings


def test_settings_defaults():
    s = Settings()
    assert s.ssh_hostname == "sftpcampus"
    assert s.reads_dir == "/pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/"
    assert isinstance(s.biomics, BiomicsConfig)
    assert isinstance(s.hpc, HPCConfig)


def test_hpc_defaults():
    hpc = HPCConfig()
    assert hpc.cpus_per_task == 20
    assert hpc.mem == "48G"
    assert "bcl2fastq" in hpc.modules[0]
    assert hpc.threads == 18


def test_biomics_defaults():
    b = BiomicsConfig()
    assert b.sender == "ekornobi@pasteur.fr"
    assert b.subject == "Biomics downloadable link"


def test_settings_dir_properties(tmp_settings: Settings):
    assert tmp_settings.log_dir == tmp_settings.state_dir / "logs"
    assert tmp_settings.db_path == tmp_settings.data_dir / "state.db"
    assert tmp_settings.sbatch_archive_dir == tmp_settings.data_dir / "sbatch"


def test_resolved_resources_dir_default():
    s = Settings()
    resolved = s.resolved_resources_dir
    assert resolved.name == "data"
    # Should be inside the installed package
    assert "autobcl2fastq" in str(resolved)


def test_resolved_resources_dir_override(tmp_path: Path):
    s = Settings(resources_dir=tmp_path / "mydata")
    assert s.resolved_resources_dir == tmp_path / "mydata"


def test_ensure_dirs(tmp_settings: Settings):
    tmp_settings.ensure_dirs()
    assert tmp_settings.config_dir.exists()
    assert tmp_settings.data_dir.exists()
    assert tmp_settings.log_dir.exists()
    assert tmp_settings.sbatch_archive_dir.exists()
