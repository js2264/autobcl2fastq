"""Tests for autobcl2fastq.pipeline (DemuxPipeline)."""

from __future__ import annotations

import gzip
import json
import re
import shutil
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

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
        patch.object(DemuxPipeline, "_stage_bcl"),
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
        patch.object(DemuxPipeline, "_stage_bcl"),
        patch.object(DemuxPipeline, "_submit") as mock_submit,
        patch("autobcl2fastq.pipeline.SamplesheetManager") as MockMgr,
    ):
        MockMgr.return_value.fetch_and_fix.return_value = ss
        pipeline = DemuxPipeline(tmp_settings)
        result = pipeline.run(url, samplesheet_path=ss, dry_run=True)

    assert result == "dry-run"
    mock_submit.assert_not_called()


def test_render_sequencer_nxq_default(tmp_settings, tmp_path: Path):
    """Default sequencer uses nxq rename pattern."""
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

    assert "_nxq_\\1" in content
    assert "_nvq_" not in content


def test_render_sequencer_nvq(tmp_settings, tmp_path: Path):
    """nvq sequencer uses NovaSeq rename pattern."""
    ss = tmp_path / "ss.csv"
    ss.write_text("")
    tmp_settings.resources_dir = tmp_path
    tmp_settings.ensure_dirs()

    run_info = RunInfo.from_url(
        "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AATEST123__ts.tar"
    )
    pipeline = DemuxPipeline(tmp_settings)
    sbatch_path = pipeline._render(run_info, ss, sequencer="nvq")
    content = sbatch_path.read_text()

    assert "_nvq_\\1" in content
    assert "_nxq_" not in content


# ---------------------------------------------------------------------------
# Index reads + Undetermined split
# ---------------------------------------------------------------------------

_URL = "https://dl.pasteur.fr/fop/XXXX/230516_VH00537_116_AATEST123__ts.tar"


def _render_script(tmp_settings, tmp_path: Path, **kwargs) -> str:
    ss = tmp_path / "ss.csv"
    ss.write_text("")
    tmp_settings.resources_dir = tmp_path
    tmp_settings.ensure_dirs()
    pipeline = DemuxPipeline(tmp_settings)
    return pipeline._render(RunInfo.from_url(_URL), ss, **kwargs).read_text()


def _step_code(script: str, step: str) -> str:
    """Return the shell code of a numbered step (e.g. "2", "5b") of the rendered script."""
    m = re.search(rf"^# {step}\. .*?^# -+\n(.*?)(?=^# -+\n# \d|\Z)", script, re.M | re.S)
    assert m, f"step {step} not found"
    return m.group(1)


def _run_step(code: str, working_dir: Path, run_id: str) -> None:
    prelude = f'log() {{ :; }}; WORKING_DIR="{working_dir}"; RUN_ID="{run_id}"\n'
    subprocess.run(["bash", "-euo", "pipefail", "-c", prelude + code], check=True)


def _write_fq(path: Path, reads: list[tuple[str, str]], read_nb: int) -> None:
    with gzip.open(path, "wt") as fh:
        for name, bc in reads:
            fh.write(f"@{name} {read_nb}:N:0:{bc}\nACGT\n+\nFFFF\n")


def _read_names(path: Path) -> list[str]:
    with gzip.open(path, "rt") as fh:
        return [line.split()[0][1:] for i, line in enumerate(fh) if i % 4 == 0]


def test_render_index_reads_kept_local(tmp_settings, tmp_path: Path):
    content = _render_script(tmp_settings, tmp_path)

    assert "--create-fastq-for-index-reads" in content
    assert "--exclude='*_I[12].fq.gz'" in content
    assert "--exclude='/Undetermined/'" in content
    # Remote chmod skips folders collaborators may own
    assert "-user \\$(id -un) -exec chmod" in content
    # QC only ever globs R1 files
    assert "_I1.fq.gz" not in _step_code(content, "3")
    assert "_I1.fq.gz" not in _step_code(content, "4")


def test_render_split_undetermined_disabled_by_default(tmp_settings, tmp_path: Path):
    content = _render_script(tmp_settings, tmp_path)
    assert "Splitting Undetermined" not in content


def test_run_passes_split_undetermined_top(tmp_settings, tmp_path: Path):
    ss = tmp_path / "ss.csv"
    ss.write_text("")
    tmp_settings.resources_dir = tmp_path

    with (
        patch.object(DemuxPipeline, "_stage_bcl"),
        patch("autobcl2fastq.pipeline.SamplesheetManager") as MockMgr,
    ):
        MockMgr.return_value.fix.return_value = ss
        DemuxPipeline(tmp_settings).run(
            _URL, samplesheet_path=ss, split_undetermined_top=7, dry_run=True
        )

    content = (tmp_settings.sbatch_archive_dir / "230516_116_AATEST123.sh").read_text()
    assert "Splitting Undetermined reads by barcode pair (top 7)" in content


@pytest.mark.skipif(not shutil.which("bash"), reason="requires bash")
def test_rename_step_handles_index_reads(tmp_settings, tmp_path: Path):
    content = _render_script(tmp_settings, tmp_path)
    run_dir = Path(tmp_settings.working_dir) / "fastq" / "230516_116_AATEST123"
    (run_dir / "SB").mkdir(parents=True)
    names = [
        "SB/SB120_S1_R1_001.fastq.gz",
        "SB/SB120_S1_I1_001.fastq.gz",
        "SB/SB120_S1_I2_001.fastq.gz",
        "Undetermined_S0_R2_001.fastq.gz",
        "Undetermined_S0_I1_001.fastq.gz",
    ]
    for name in names:
        (run_dir / name).touch()

    _run_step(_step_code(content, "2"), Path(tmp_settings.working_dir), "230516_116_AATEST123")

    found = sorted(str(p.relative_to(run_dir)) for p in run_dir.rglob("*.fq.gz"))
    assert found == [
        "SB/SB120_nxq_I1.fq.gz",
        "SB/SB120_nxq_I2.fq.gz",
        "SB/SB120_nxq_R1.fq.gz",
        "Undetermined_nxq_I1.fq.gz",
        "Undetermined_nxq_R2.fq.gz",
    ]


@pytest.mark.skipif(not shutil.which("bash"), reason="requires bash")
def test_split_undetermined_step(tmp_settings, tmp_path: Path):
    content = _render_script(tmp_settings, tmp_path, split_undetermined_top=2)
    run_id = "230516_116_AATEST123"
    run_dir = Path(tmp_settings.working_dir) / "fastq" / run_id
    (run_dir / "Stats").mkdir(parents=True)
    # Mimic bcl2fastq's pretty-printed Stats.json; counts are summed across lanes.
    stats = {
        "UnknownBarcodes": [
            {"Lane": 1, "Barcodes": {"AAAA+CCCC": 40, "GGGG+TTTT": 30, "ACGT+ACGT": 5}},
            {"Lane": 2, "Barcodes": {"ACGT+ACGT": 50}},
        ]
    }
    (run_dir / "Stats" / "Stats.json").write_text(json.dumps(stats, indent=1))
    reads = [
        ("r1", "AAAA+CCCC"),
        ("r2", "GGGG+TTTT"),
        ("r3", "ACGT+ACGT"),
        ("r4", "AAAA+CCCC"),
    ]
    for nb in (1, 2):
        _write_fq(run_dir / f"Undetermined_nxq_R{nb}.fq.gz", reads, nb)

    _run_step(_step_code(content, "5b"), Path(tmp_settings.working_dir), run_id)

    undet = run_dir / "Undetermined"
    assert sorted(p.name for p in undet.iterdir()) == [
        "Undetermined_AAAA-CCCC_nxq_R1.fq.gz",
        "Undetermined_AAAA-CCCC_nxq_R2.fq.gz",
        "Undetermined_ACGT-ACGT_nxq_R1.fq.gz",
        "Undetermined_ACGT-ACGT_nxq_R2.fq.gz",
    ]
    for nb in (1, 2):
        assert _read_names(undet / f"Undetermined_AAAA-CCCC_nxq_R{nb}.fq.gz") == ["r1", "r4"]
        assert _read_names(undet / f"Undetermined_ACGT-ACGT_nxq_R{nb}.fq.gz") == ["r3"]
        # The full Undetermined files are left untouched
        assert _read_names(run_dir / f"Undetermined_nxq_R{nb}.fq.gz") == ["r1", "r2", "r3", "r4"]
