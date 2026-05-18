"""Shared pytest fixtures for autobcl2fastq tests."""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from autobcl2fastq.config import Settings


@pytest.fixture()
def tmp_settings(tmp_path: Path) -> Settings:
    """Return a Settings instance pointing at tmp_path for all directories."""
    return Settings(
        config_dir=tmp_path / "config",
        data_dir=tmp_path / "data",
        state_dir=tmp_path / "state",
        working_dir=str(tmp_path / "work"),
        ssh_hostname="sftpcampus",
        reads_dir="/pasteur/reads/",
    )


@pytest.fixture()
def indices_txt(tmp_path: Path) -> Path:
    """Create a minimal indices.txt file for testing."""
    content = textwrap.dedent("""\
        barcode_well\ti7_sequence\ti5_sequence
        A1\tATCACG\tATCACG
        A2\tCGATGT\tCGATGT
        A3\tTTAGGC\tTTAGGC
        D501\tTAAGGC\tTATCCT
        D502\tCGTACT\tATAGAG
    """)
    p = tmp_path / "indices.txt"
    p.write_text(content)
    return p


@pytest.fixture()
def raw_tsv(tmp_path: Path) -> Path:
    """Create a minimal raw RSG samplesheet TSV for testing."""
    content = "JS1\tA1\nJS2\tA2\n"
    p = tmp_path / "rsgsheet_AATEST123.tsv"
    p.write_text(content)
    return p
