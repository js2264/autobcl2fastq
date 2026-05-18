"""Tests for autobcl2fastq.samplesheet."""

from __future__ import annotations

from pathlib import Path

import pytest

from autobcl2fastq.pipeline import RunInfo
from autobcl2fastq.samplesheet import SamplesheetManager, _project_from_sample

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_manager(tmp_settings, indices_file: Path) -> SamplesheetManager:
    """Return a SamplesheetManager whose resolved_resources_dir contains the given indices.txt."""
    resources_dir = indices_file.parent
    tmp_settings.resources_dir = resources_dir
    # Ensure samplesheets directories exist
    tmp_settings.samplesheets_dir.mkdir(parents=True, exist_ok=True)
    tmp_settings.samplesheets_raw_dir.mkdir(parents=True, exist_ok=True)
    return SamplesheetManager(tmp_settings)


def _run_info(run_hash: str = "AATEST123") -> RunInfo:
    return RunInfo.from_url(
        f"https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_{run_hash}__timestamp.tar"
    )


# ---------------------------------------------------------------------------
# _project_from_sample
# ---------------------------------------------------------------------------


def test_project_from_sample_basic():
    assert _project_from_sample("rsgA1") == "rsgA"


def test_project_from_sample_no_digits():
    assert _project_from_sample("proj") == "proj"


def test_project_from_sample_leading_digit():
    # First character is a digit → match is empty → return full name
    result = _project_from_sample("1test")
    assert result == "1test"


# ---------------------------------------------------------------------------
# RunInfo.from_url
# ---------------------------------------------------------------------------


def test_run_info_from_url():
    url = "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AACLHW3M5__Wed_May_17.tar"
    info = RunInfo.from_url(url)
    assert info.run_name == "230516_VH00537_116_AACLHW3M5"
    assert info.run_date == "230516"
    assert info.seq_id == "VH00537"
    assert info.run_nb == "116"
    assert info.run_hash == "AACLHW3M5"
    assert info.run_id == "230516_116_AACLHW3M5"


def test_run_info_invalid_url():
    with pytest.raises(ValueError, match="Cannot parse"):
        RunInfo.from_url("https://dl.pasteur.fr/fop/bad_name.tar")


# ---------------------------------------------------------------------------
# SamplesheetManager._load_raw_tsv
# ---------------------------------------------------------------------------


def test_load_raw_tsv(raw_tsv: Path):
    rows = SamplesheetManager._load_raw_tsv(raw_tsv)
    assert rows == [("JS1", "A1"), ("JS2", "A2")]


def test_load_raw_tsv_skips_blank(tmp_path: Path):
    p = tmp_path / "sheet.tsv"
    p.write_text("JS1\tA1\n\t\nJS2\tA2\n")
    rows = SamplesheetManager._load_raw_tsv(p)
    assert len(rows) == 2


# ---------------------------------------------------------------------------
# SamplesheetManager.validate_rows
# ---------------------------------------------------------------------------


def test_validate_rows_ok(tmp_settings, indices_txt: Path, raw_tsv: Path):
    manager = _make_manager(tmp_settings, indices_txt)
    indices = manager._load_indices()
    rows = manager._load_raw_tsv(raw_tsv)
    errors = manager.validate_rows(rows, indices, "AATEST123")
    # users.conf not present → skipped; barcodes valid → no errors
    assert errors == []


def test_validate_rows_unknown_barcode(tmp_settings, indices_txt: Path):
    manager = _make_manager(tmp_settings, indices_txt)
    indices = manager._load_indices()
    rows = [("sampleX", "ZZZZ")]  # barcode not in indices.txt
    errors = manager.validate_rows(rows, indices, "AATEST123")
    assert any("ZZZZ" in e for e in errors)


def test_validate_rows_duplicate_barcode(tmp_settings, indices_txt: Path):
    manager = _make_manager(tmp_settings, indices_txt)
    indices = manager._load_indices()
    # Two samples pointing to the same barcode well → same i7/i5 → duplicate
    rows = [("JS1", "A1"), ("JS2", "A1")]
    errors = manager.validate_rows(rows, indices, "AATEST123")
    assert any("Duplicate" in e for e in errors)


# ---------------------------------------------------------------------------
# SamplesheetManager.fix (write Illumina CSV)
# ---------------------------------------------------------------------------


def test_fix_writes_illumina_csv(tmp_settings, indices_txt: Path, raw_tsv: Path):
    manager = _make_manager(tmp_settings, indices_txt)
    run_info = _run_info()
    # Copy raw TSV to expected location
    dest = tmp_settings.samplesheets_raw_dir / "rsgsheet_AATEST123.tsv"
    dest.write_text(raw_tsv.read_text())

    csv_path = manager.fix(dest, run_info)
    assert csv_path.exists()
    content = csv_path.read_text()
    assert "[Header]" in content
    assert "[Data]" in content
    assert "JS1" in content
    assert "ATCACG" in content  # i7 for A1


def test_fix_raises_on_unknown_barcode(tmp_settings, indices_txt: Path, tmp_path: Path):
    manager = _make_manager(tmp_settings, indices_txt)
    bad_tsv = tmp_path / "bad.tsv"
    bad_tsv.write_text("sampleX\tZZZZ\n")
    run_info = _run_info()
    with pytest.raises(ValueError, match="validation failed"):
        manager.fix(bad_tsv, run_info)
