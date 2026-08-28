"""SQLite-backed report history with an explicit overall-metrics JSON seed.

``overall_history`` is intentionally retained as the compatibility layer used by
the original deterministic pipeline.  New successful report commits also store a
complete canonical snapshot so richer, cross-week comparisons never have to
reconstruct detail rows from aggregate history.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import date
from pathlib import Path
from typing import Any, Dict, Iterable, Optional

from .models import CanonicalReport, HistoryRecord, OverallMetrics


_OVERALL_FIELDS = tuple(OverallMetrics.model_fields)


class HistoryError(ValueError):
    """Raised when history cannot safely be read or written."""


class HistoryStore:
    def __init__(self, database_path: str | Path, seed_path: str | Path | None = None):
        self.database_path = Path(database_path)
        self.seed_path = Path(seed_path) if seed_path else None
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(str(self.database_path))
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS overall_history (
                    market TEXT NOT NULL,
                    period_start TEXT NOT NULL,
                    period_end TEXT NOT NULL,
                    amount_spent REAL NOT NULL,
                    purchase_value REAL NOT NULL,
                    purchase_roas REAL NOT NULL,
                    purchases INTEGER NOT NULL,
                    adds_to_cart INTEGER NOT NULL,
                    cost_per_purchase REAL NOT NULL,
                    cost_per_add_to_cart REAL NOT NULL,
                    link_clicks INTEGER NOT NULL,
                    ctr REAL NOT NULL,
                    add_to_cart_rate REAL NOT NULL,
                    source_bundle_sha256 TEXT,
                    template_version TEXT,
                    PRIMARY KEY (market, period_start, period_end)
                )
                """
            )
            # Additive migration: databases created by releases before 0.4 only
            # contain ``overall_history``.  Creating this table leaves those rows
            # and the explicit seed-file fallback untouched.
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS canonical_report_snapshots (
                    market TEXT NOT NULL,
                    period_start TEXT NOT NULL,
                    period_end TEXT NOT NULL,
                    report_json TEXT NOT NULL,
                    source_bundle_sha256 TEXT,
                    template_version TEXT,
                    PRIMARY KEY (market, period_start, period_end)
                )
                """
            )

    @staticmethod
    def _record_from_mapping(
        payload: Dict[str, Any], *, source_kind: str, source_file: str
    ) -> HistoryRecord:
        values = {field: payload[field] for field in _OVERALL_FIELDS if field in payload}
        missing = sorted(set(_OVERALL_FIELDS) - set(values))
        if missing:
            raise HistoryError(f"history record is missing fields: {missing}")
        return HistoryRecord(
            overall=OverallMetrics.model_validate(values),
            source_kind=source_kind,
            source_file=source_file,
        )

    def _seed_records(self) -> Iterable[HistoryRecord]:
        if self.seed_path is None or not self.seed_path.exists():
            return []
        try:
            payload = json.loads(self.seed_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise HistoryError(f"cannot read history seed {self.seed_path}: {exc}") from exc
        if not isinstance(payload, list):
            raise HistoryError("history seed root must be a JSON array")
        return [
            self._record_from_mapping(
                item,
                source_kind="history_seed",
                source_file=str(self.seed_path.resolve()),
            )
            for item in payload
        ]

    def get_previous_record(self, market: str, before: date) -> Optional[HistoryRecord]:
        """Return the latest record ending before ``before`` from DB or seed."""

        candidates = [
            record
            for record in self._seed_records()
            if record.overall.market == market and record.overall.period_end < before
        ]
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT market, period_start, period_end, amount_spent, purchase_value,
                       purchase_roas, purchases, adds_to_cart, cost_per_purchase,
                       cost_per_add_to_cart, link_clicks, ctr, add_to_cart_rate
                FROM overall_history
                WHERE market = ? AND period_end < ?
                ORDER BY period_end DESC, period_start DESC
                LIMIT 1
                """,
                (market, before.isoformat()),
            ).fetchone()
        if row is not None:
            candidates.append(
                self._record_from_mapping(
                    dict(row),
                    source_kind="history_db",
                    source_file=str(self.database_path.resolve()),
                )
            )
        if not candidates:
            return None
        return max(
            candidates,
            key=lambda record: (
                record.overall.period_end,
                record.overall.period_start,
                record.source_kind == "history_db",
            ),
        )

    def get_previous(self, market: str, before: date) -> Optional[OverallMetrics]:
        record = self.get_previous_record(market, before)
        return record.overall if record else None

    def get_previous_report(
        self, market: str, before: date
    ) -> Optional[CanonicalReport]:
        """Return the latest complete canonical snapshot ending before ``before``.

        Overall-only database rows and JSON seed rows deliberately do not qualify:
        they remain available through :meth:`get_previous`, while detailed
        cross-week diagnostics report that a snapshot is unavailable.
        """

        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT market, period_start, period_end, report_json
                FROM canonical_report_snapshots
                WHERE market = ? AND period_end < ?
                ORDER BY period_end DESC, period_start DESC
                LIMIT 1
                """,
                (market, before.isoformat()),
            ).fetchone()
        if row is None:
            return None
        try:
            report = CanonicalReport.model_validate_json(row["report_json"])
        except (ValueError, TypeError) as exc:
            raise HistoryError(
                "stored canonical report snapshot is invalid for "
                f"{row['market']} {row['period_start']}..{row['period_end']}: {exc}"
            ) from exc
        if (
            report.market != row["market"]
            or report.period_start.isoformat() != row["period_start"]
            or report.period_end.isoformat() != row["period_end"]
        ):
            raise HistoryError(
                "stored canonical report snapshot identity does not match its row"
            )
        return report

    def upsert(self, report: CanonicalReport) -> None:
        _assert_history_writable(report)
        overall = report.current_overall
        # Serialize and validate before opening the write transaction.  If this
        # ever fails, neither the compatibility aggregate nor the snapshot moves.
        report_json = json.dumps(
            report.model_dump(mode="json"),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        )
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO overall_history (
                    market, period_start, period_end, amount_spent, purchase_value,
                    purchase_roas, purchases, adds_to_cart, cost_per_purchase,
                    cost_per_add_to_cart, link_clicks, ctr, add_to_cart_rate,
                    source_bundle_sha256, template_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(market, period_start, period_end) DO UPDATE SET
                    amount_spent=excluded.amount_spent,
                    purchase_value=excluded.purchase_value,
                    purchase_roas=excluded.purchase_roas,
                    purchases=excluded.purchases,
                    adds_to_cart=excluded.adds_to_cart,
                    cost_per_purchase=excluded.cost_per_purchase,
                    cost_per_add_to_cart=excluded.cost_per_add_to_cart,
                    link_clicks=excluded.link_clicks,
                    ctr=excluded.ctr,
                    add_to_cart_rate=excluded.add_to_cart_rate,
                    source_bundle_sha256=excluded.source_bundle_sha256,
                    template_version=excluded.template_version
                """,
                (
                    overall.market,
                    overall.period_start.isoformat(),
                    overall.period_end.isoformat(),
                    overall.amount_spent,
                    overall.purchase_value,
                    overall.purchase_roas,
                    overall.purchases,
                    overall.adds_to_cart,
                    overall.cost_per_purchase,
                    overall.cost_per_add_to_cart,
                    overall.link_clicks,
                    overall.ctr,
                    overall.add_to_cart_rate,
                    report.source_bundle_sha256,
                    report.template_version,
                ),
            )
            connection.execute(
                """
                INSERT INTO canonical_report_snapshots (
                    market, period_start, period_end, report_json,
                    source_bundle_sha256, template_version
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(market, period_start, period_end) DO UPDATE SET
                    report_json=excluded.report_json,
                    source_bundle_sha256=excluded.source_bundle_sha256,
                    template_version=excluded.template_version
                """,
                (
                    report.market,
                    report.period_start.isoformat(),
                    report.period_end.isoformat(),
                    report_json,
                    report.source_bundle_sha256,
                    report.template_version,
                ),
            )


def _assert_history_writable(report: CanonicalReport) -> None:
    overall = report.current_overall
    if overall.market != report.market:
        raise HistoryError("current overall market does not match report market")
    if (overall.period_start, overall.period_end) != (report.period_start, report.period_end):
        raise HistoryError("current overall period does not match report period")
    if report.period_end < report.period_start:
        raise HistoryError("report period is inverted")
    numeric_values = (
        overall.amount_spent,
        overall.purchase_value,
        overall.purchase_roas,
        overall.purchases,
        overall.adds_to_cart,
        overall.cost_per_purchase,
        overall.cost_per_add_to_cart,
        overall.link_clicks,
        overall.ctr,
        overall.add_to_cart_rate,
    )
    if any(value < 0 for value in numeric_values):
        raise HistoryError("history metrics cannot be negative")


def commit_report_history(report: CanonicalReport, history_db_path: str | Path) -> None:
    """Upsert aggregate history and the full snapshot after a successful build."""

    HistoryStore(history_db_path).upsert(report)
