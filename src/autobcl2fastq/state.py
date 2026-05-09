"""SQLite state database for tracking BCL demultiplexing runs.

One table, one row per run.  Plain ``sqlite3`` — no ORM, stays
human-inspectable.
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator, Optional

RUN_STATES = (
    "pending",
    "submitted",
    "running",
    "completed",
    "failed",
    "cancelled",
    "notified",
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    run_id                  TEXT PRIMARY KEY,
    url                     TEXT NOT NULL,
    run_name                TEXT NOT NULL,
    run_hash                TEXT NOT NULL,
    samplesheet_path        TEXT,
    slurm_jobid             TEXT,
    sbatch_path             TEXT,
    state                   TEXT NOT NULL,
    sacct_state             TEXT,
    exit_code               TEXT,
    error_message           TEXT,
    submitted_at            TEXT,
    finished_at             TEXT,
    notified_at             TEXT,
    autobcl2fastq_version   TEXT,
    updated_at              TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_runs_state   ON runs(state);
CREATE INDEX IF NOT EXISTS idx_runs_slurm   ON runs(slurm_jobid);
"""


def _now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


@dataclass
class RunRecord:
    run_id: str
    url: str
    run_name: str
    run_hash: str
    samplesheet_path: Optional[str] = None
    slurm_jobid: Optional[str] = None
    sbatch_path: Optional[str] = None
    state: str = "pending"
    sacct_state: Optional[str] = None
    exit_code: Optional[str] = None
    error_message: Optional[str] = None
    submitted_at: Optional[str] = field(default_factory=_now)
    finished_at: Optional[str] = None
    notified_at: Optional[str] = None
    autobcl2fastq_version: Optional[str] = None
    updated_at: str = field(default_factory=_now)


class StateDB:
    """Thin wrapper around sqlite3 for autobcl2fastq run state."""

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    # ------------------------------------------------------------------ runs

    def insert_run(self, record: RunRecord) -> None:
        record.updated_at = _now()
        d = asdict(record)
        cols = ", ".join(d)
        placeholders = ", ".join("?" for _ in d)
        with self.transaction() as conn:
            conn.execute(
                f"INSERT OR REPLACE INTO runs ({cols}) VALUES ({placeholders})",
                list(d.values()),
            )

    def update_run(self, run_id: str, **fields: Any) -> None:
        fields["updated_at"] = _now()
        assignments = ", ".join(f"{k} = ?" for k in fields)
        values = list(fields.values()) + [run_id]
        with self.transaction() as conn:
            conn.execute(
                f"UPDATE runs SET {assignments} WHERE run_id = ?", values
            )

    def get_run(self, run_id: str) -> Optional[RunRecord]:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM runs WHERE run_id = ?", (run_id,)
            ).fetchone()
        return RunRecord(**dict(row)) if row else None

    def list_runs(
        self,
        *,
        state: Optional[str] = None,
        limit: int = 50,
    ) -> list[RunRecord]:
        query = "SELECT * FROM runs"
        params: list[Any] = []
        if state:
            query += " WHERE state = ?"
            params.append(state)
        query += " ORDER BY submitted_at DESC LIMIT ?"
        params.append(limit)
        with self._connect() as conn:
            rows = conn.execute(query, params).fetchall()
        return [RunRecord(**dict(r)) for r in rows]

    def get_active_runs(self) -> list[RunRecord]:
        """Return runs that are submitted or running (need sacct polling)."""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM runs WHERE state IN ('submitted', 'running')"
            ).fetchall()
        return [RunRecord(**dict(r)) for r in rows]
