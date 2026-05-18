"""Tests for autobcl2fastq.pipeline (DemuxPipeline)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from autobcl2fastq.pipeline import DemuxPipeline, RunInfo

# ---------------------------------------------------------------------------
# RunInfo
# ---------------------------------------------------------------------------


def test_run_info_properties():
    info = RunInfo.from_url("https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AACLHW3M5__ts.tar")
    assert info.run_id == "230516_116_AACLHW3M5"
    assert info.run_name == "230516_VH00537_116_AACLHW3M5"


# ---------------------------------------------------------------------------
# DemuxPipeline._render
# ---------------------------------------------------------------------------


def test_render_template(tmp_settings, tmp_path: Path):
    """_render should produce a valid bash script at the expected path."""
    # Create a minimal samplesheet
    ss = tmp_path / "SampleSheet.csv"
    ss.write_text("[Header]\n[Data]\n")

    # Create a minimal resources dir so the template's resources_dir is valid
    res_dir = tmp_path / "data"
    res_dir.mkdir()
    tmp_settings.resources_dir = res_dir

    run_info = RunInfo.from_url(
        "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AATEST123__ts.tar"
    )
    tmp_settings.ensure_dirs()

    pipeline = DemuxPipeline(tmp_settings)
    sbatch_path = pipeline._render(run_info, ss)

    assert sbatch_path.exists()
    content = sbatch_path.read_text()

    # Check key Jinja2 variables were rendered
    assert "230516_116_AATEST123" in content
    assert "AATEST123" in content
    assert "#SBATCH --cpus-per-task=20" in content
    assert "#SBATCH --mem=48G" in content
    assert "module purge" in content
    assert "bcl2fastq" in content


def test_render_includes_all_modules(tmp_settings, tmp_path: Path):
    ss = tmp_path / "ss.csv"
    ss.write_text("")
    tmp_settings.resources_dir = tmp_path
    tmp_settings.ensure_dirs()

    run_info = RunInfo.from_url(
        "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AATEST123__ts.tar"
    )
    pipeline = DemuxPipeline(tmp_settings)
    sbatch_path = pipeline._render(run_info, ss)
    content = sbatch_path.read_text()

    for mod in tmp_settings.hpc.modules:
        assert mod in content, f"Module {mod} not found in rendered script"


# ---------------------------------------------------------------------------
# DemuxPipeline.run — submit path (mocked)
# ---------------------------------------------------------------------------


def test_run_submits_and_records(tmp_settings, tmp_path: Path):
    """pipeline.run() should call sbatch and insert a DB record."""
    ss = tmp_path / "ss.csv"
    ss.write_text("[Header]\nDate,230516\n[Data]\n")
    tmp_settings.resources_dir = tmp_path

    url = "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AATEST123__ts.tar"

    with (
        patch.object(DemuxPipeline, "_download_bcl"),
        patch.object(DemuxPipeline, "_submit", return_value="12345"),
        patch("autobcl2fastq.pipeline.SamplesheetManager") as MockMgr,
    ):
        MockMgr.return_value.fetch_and_fix.return_value = ss
        pipeline = DemuxPipeline(tmp_settings)
        job_id = pipeline.run(url, samplesheet_path=ss)

    assert job_id == "12345"

    from autobcl2fastq.state import StateDB

    db = StateDB(tmp_settings.db_path)
    record = db.get_run("230516_116_AATEST123")
    assert record is not None
    assert record.slurm_jobid == "12345"
    assert record.state == "submitted"


def test_run_dry_run(tmp_settings, tmp_path: Path):
    ss = tmp_path / "ss.csv"
    ss.write_text("")
    tmp_settings.resources_dir = tmp_path

    url = "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AATEST123__ts.tar"

    with (
        patch.object(DemuxPipeline, "_download_bcl"),
        patch.object(DemuxPipeline, "_submit") as mock_submit,
        patch("autobcl2fastq.pipeline.SamplesheetManager") as MockMgr,
    ):
        MockMgr.return_value.fetch_and_fix.return_value = ss
        pipeline = DemuxPipeline(tmp_settings)
        result = pipeline.run(url, samplesheet_path=ss, dry_run=True)

    assert result == "dry-run"
    mock_submit.assert_not_called()
