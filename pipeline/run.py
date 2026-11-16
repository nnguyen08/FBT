"""Idempotent refresh: fetch -> stage -> validate -> freshness -> load -> report.

    python -m pipeline.run                     # download from Kaggle and refresh
    python -m pipeline.run --from-dir ./csvs   # use local CSVs (offline / tests)
    python -m pipeline.run --force             # reload even if the data hash is unchanged

Schedule it daily: unchanged upstream data is skipped via the content hash.
"""
from __future__ import annotations

import argparse
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

from .config import SOURCE, get_settings
from .db import apply_migrations, connect, try_lock
from .fetch import fetch
from .freshness import check_freshness, compute_freshness, save_freshness
from .load import run_load
from .report import build_report, write_report
from .stage import stage_tables
from .validate import validate

log = logging.getLogger("pipeline")


def _start_run(conn: psycopg.Connection) -> int:
    run_id = conn.execute(
        "INSERT INTO ingestion_runs (source, status) VALUES (%s, 'running') RETURNING run_id",
        (SOURCE,),
    ).fetchone()[0]
    conn.commit()
    return run_id


def _finish_run(conn, run_id, status, rows=None, notes=None, snapshot_id=None) -> None:
    conn.execute(
        "UPDATE ingestion_runs SET finished_at = now(), status = %s, rows_loaded = %s, "
        "notes = %s, snapshot_id = %s WHERE run_id = %s",
        (status, rows, notes, snapshot_id, run_id),
    )
    conn.commit()


def _last_loaded(conn) -> tuple[str | None, dict | None]:
    row = conn.execute(
        "SELECT version_hash, row_counts FROM dataset_snapshots "
        "WHERE source = %s AND status = 'loaded' ORDER BY snapshot_id DESC LIMIT 1",
        (SOURCE,),
    ).fetchone()
    conn.commit()
    return (row[0], row[1]) if row else (None, None)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--from-dir", type=Path, help="use CSVs from this folder instead of Kaggle")
    ap.add_argument("--force", action="store_true", help="reload even if data is unchanged")
    ap.add_argument("--relaxed", action="store_true", help="skip minimum-size checks (small test data)")
    ap.add_argument("--skip-report", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    settings = get_settings()

    with connect(settings.database_url) as conn:
        if not try_lock(conn):
            log.error("Another refresh is already running; exiting.")
            return 2
        apply_migrations(conn, settings.sql_dir)
        run_id = _start_run(conn)
        snapshot_id = None
        try:
            snap = fetch(settings.kaggle_dataset, settings.data_dir, args.from_dir)
            prev_hash, prev_counts = _last_loaded(conn)
            if prev_hash == snap.version_hash and not args.force:
                log.info("Data unchanged since last load (%s); nothing to do.", snap.version_hash[:12])
                _finish_run(conn, run_id, "skipped", notes="unchanged")
                return 0

            snapshot_id = conn.execute(
                "INSERT INTO dataset_snapshots (source, version_hash, status) "
                "VALUES (%s, %s, 'fetched') RETURNING snapshot_id",
                (SOURCE, snap.version_hash),
            ).fetchone()[0]
            conn.commit()

            counts = stage_tables(conn, snap.files)
            conn.execute(
                "UPDATE dataset_snapshots SET row_counts = %s WHERE snapshot_id = %s",
                (Jsonb(counts), snapshot_id),
            )
            conn.commit()

            issues = validate(conn, counts, prev_counts, relaxed=args.relaxed)
            if not any(i.level == "error" for i in issues):
                # Only once the columns are known to exist (a missing column is reported above, cleanly).
                fresh = compute_freshness(conn)
                save_freshness(conn, snapshot_id, fresh)
                issues += check_freshness(fresh)
                log.info("Stats through %s; market values through %s",
                         fresh.matches_through, fresh.values_through)
            conn.commit()
            for i in issues:
                (log.error if i.level == "error" else log.warning)("validation %s: %s", i.level, i.message)
            errors = [i.message for i in issues if i.level == "error"]
            if errors:
                conn.execute("UPDATE dataset_snapshots SET status = 'rejected' WHERE snapshot_id = %s", (snapshot_id,))
                conn.commit()
                _finish_run(conn, run_id, "failed", notes="; ".join(errors)[:2000], snapshot_id=snapshot_id)
                log.error("Snapshot rejected; core tables untouched.")
                return 1

            results = run_load(conn, datetime.now(timezone.utc).date())
            conn.execute("UPDATE dataset_snapshots SET status = 'loaded' WHERE snapshot_id = %s", (snapshot_id,))
            conn.commit()
            _finish_run(conn, run_id, "success", rows=sum(results.values()), snapshot_id=snapshot_id)

            if not args.skip_report:
                text = build_report(conn, snap.version_hash, [i.message for i in issues])
                conn.commit()
                log.info("Wrote %s", write_report(text, settings.report_dir))
            return 0
        except Exception as exc:  # record the failure, then surface it
            conn.rollback()
            _finish_run(conn, run_id, "failed", notes=str(exc)[:2000], snapshot_id=snapshot_id)
            log.exception("Refresh failed")
            return 1


if __name__ == "__main__":
    sys.exit(main())
