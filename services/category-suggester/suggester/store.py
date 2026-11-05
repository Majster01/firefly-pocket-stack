"""SQLite memory: which suggestions this suggester wrote, and which were rejected.

Firefly is the source of truth for what is pending; this only remembers what it
cannot tell us any more once a suggestion is deleted — whether the user said no.
"""

from __future__ import annotations

import datetime as dt
import json
import sqlite3
from dataclasses import dataclass, field, fields
from pathlib import Path

from .contract import Suggestion
from .firefly import Firefly, FireflyError
from .normalize import normalize_description

SCHEMA = """
CREATE TABLE IF NOT EXISTS suggestions (
    rule_id      INTEGER PRIMARY KEY,           -- Firefly rule id in `Suggestions`
    created      TEXT NOT NULL,
    category     TEXT NOT NULL,
    transactions TEXT NOT NULL,                 -- JSON [[transaction_id, journal_id], ...]
    triggers     TEXT NOT NULL,                 -- JSON [[type, value], ...]
    status       TEXT NOT NULL DEFAULT 'pending', -- pending | resolved | rejected
    closed       TEXT
);
CREATE TABLE IF NOT EXISTS rejected_triggers (
    trigger_type TEXT NOT NULL,
    value        TEXT NOT NULL,                 -- normalised, see trigger_key()
    category     TEXT NOT NULL,
    rule_id      INTEGER NOT NULL,
    PRIMARY KEY (trigger_type, value, category)
);
CREATE TABLE IF NOT EXISTS rejected_journals (
    journal_id INTEGER PRIMARY KEY,
    category   TEXT NOT NULL,
    rule_id    INTEGER NOT NULL
);
-- One row per real `suggest` run (dry runs change nothing, so they leave no row).
-- History starts the day this table was created; nothing is backfilled.
CREATE TABLE IF NOT EXISTS runs (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    started        TEXT NOT NULL,
    finished       TEXT NOT NULL,
    source         TEXT NOT NULL,               -- nightly | manual
    window_since   TEXT,
    window_until   TEXT,
    model          TEXT NOT NULL,
    min_confidence REAL NOT NULL,               -- the threshold in force for this run
    status         TEXT NOT NULL,               -- ok | failed
    error          TEXT,
    transactions   INTEGER NOT NULL DEFAULT 0,  -- uncategorized withdrawals considered
    groups_sent    INTEGER NOT NULL DEFAULT 0,  -- groups handed to the model
    deferred       INTEGER NOT NULL DEFAULT 0,  -- groups left for the next run (max per run)
    calls          INTEGER NOT NULL DEFAULT 0,  -- model API requests (>= groups: web-search continuations)
    input_tokens   INTEGER NOT NULL DEFAULT 0,
    output_tokens  INTEGER NOT NULL DEFAULT 0,
    searches       INTEGER NOT NULL DEFAULT 0,
    suggestions    INTEGER NOT NULL DEFAULT 0,
    low_confidence INTEGER NOT NULL DEFAULT 0,  -- of those, below min_confidence
    written        INTEGER NOT NULL DEFAULT 0,
    group_errors   INTEGER NOT NULL DEFAULT 0,
    write_errors   INTEGER NOT NULL DEFAULT 0,
    error_details  TEXT                         -- JSON list: what the first few group / write errors said
);
"""

# Columns added after the table first shipped; `CREATE TABLE IF NOT EXISTS` leaves an existing table as it was.
LATER_RUN_COLUMNS = {"error_details": "TEXT"}
MAX_ERROR_DETAILS = 5
ERROR_DETAIL_LENGTH = 200

SUGGESTION_STATUSES = ("pending", "resolved", "rejected")
# What stats() adds up per window; every one is a column of `runs`.
RUN_TOTALS = (
    "transactions",
    "groups_sent",
    "deferred",
    "calls",
    "input_tokens",
    "output_tokens",
    "searches",
    "suggestions",
    "low_confidence",
    "written",
    "group_errors",
    "write_errors",
)


@dataclass
class Run:
    """What one real `suggest` run did; filled in by cmd_suggest, saved by Store.record_run."""

    started: str
    source: str
    model: str
    min_confidence: float
    window_since: str | None = None
    window_until: str | None = None
    status: str = "ok"
    error: str | None = None
    finished: str = ""
    transactions: int = 0
    groups_sent: int = 0
    deferred: int = 0
    calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0
    suggestions: int = 0
    low_confidence: int = 0
    written: int = 0
    group_errors: int = 0
    write_errors: int = 0
    error_details: list[str] = field(default_factory=list)

    def add_error(self, message: str) -> None:
        """Remember what an error said, for the status page: a few distinct, bounded lines, never more."""
        message = " ".join(message.split())[:ERROR_DETAIL_LENGTH]
        if message and message not in self.error_details and len(self.error_details) < MAX_ERROR_DETAILS:
            self.error_details.append(message)


RUN_COLUMNS = [f.name for f in fields(Run)]


def trigger_key(trigger_type: str, value: str, category: str) -> tuple[str, str, str]:
    """What "the same suggestion again" means for rejection memory.

    Description values are normalised, so rejecting "NAKUP X 1,40 EUR" also
    covers next month's "NAKUP X 2,10 EUR" for the same category.
    """
    if trigger_type == "description_contains":
        value = normalize_description(value)
    return (trigger_type, value.strip().lower(), category)


@dataclass(frozen=True)
class Pending:
    rule_id: int
    category: str
    transactions: list[tuple[int, int]]
    triggers: list[tuple[str, str]]


@dataclass(frozen=True)
class Decision:
    pending: Pending
    status: str  # resolved | rejected


class Store:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self.conn = conn

    @classmethod
    def open(cls, path: str, readonly: bool = False) -> "Store":
        """readonly (dry runs): read an existing database, never create or change one."""
        if readonly:
            if Path(path).is_file():
                conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            else:
                conn = sqlite3.connect(":memory:")
                conn.executescript(SCHEMA)
            return cls(conn)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)
        existing = {row[1] for row in conn.execute("PRAGMA table_info(runs)")}
        for column, definition in LATER_RUN_COLUMNS.items():
            if column not in existing:
                conn.execute(f"ALTER TABLE runs ADD COLUMN {column} {definition}")
        conn.commit()
        return cls(conn)

    # --- reads -----------------------------------------------------------

    def pending(self) -> list[Pending]:
        rows = self.conn.execute(
            "SELECT rule_id, category, transactions, triggers FROM suggestions WHERE status = 'pending'"
        ).fetchall()
        return [
            Pending(
                rule_id=row[0],
                category=row[1],
                transactions=[tuple(t) for t in json.loads(row[2])],
                triggers=[tuple(t) for t in json.loads(row[3])],
            )
            for row in rows
        ]

    def rejected_triggers(self) -> set[tuple[str, str, str]]:
        return set(self.conn.execute("SELECT trigger_type, value, category FROM rejected_triggers").fetchall())

    def rejected_journals(self) -> set[int]:
        return {row[0] for row in self.conn.execute("SELECT journal_id FROM rejected_journals")}

    def stats(self, days: int = 30, recent: int = 20) -> dict:
        """Run history and suggestion outcomes, for the status page in Pico.

        `suggestions` counts every suggestion this suggester ever wrote by where
        it ended up (all time); `totals` add up the runs of the last `days`.
        """
        outcomes = dict(self.conn.execute("SELECT status, COUNT(*) FROM suggestions GROUP BY status"))
        result: dict = {
            "window_days": days,
            "tracking_since": None,
            "suggestions": {status: outcomes.get(status, 0) for status in SUGGESTION_STATUSES},
            "totals": {"runs": 0, "failed_runs": 0, **{column: 0 for column in RUN_TOTALS}},
            "last_run": None,
            "recent": [],
        }
        # A read-only handle on a database from before `runs` existed has no such table.
        if not self.conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'runs'").fetchone():
            return result

        result["tracking_since"] = self.conn.execute("SELECT MIN(started) FROM runs").fetchone()[0]
        cutoff = (dt.datetime.now() - dt.timedelta(days=days)).isoformat(timespec="seconds")
        sums = ", ".join(f"COALESCE(SUM({column}), 0)" for column in RUN_TOTALS)
        row = self.conn.execute(
            f"SELECT COUNT(*), COALESCE(SUM(status = 'failed'), 0), {sums} FROM runs WHERE started >= ?", (cutoff,)
        ).fetchone()
        result["totals"] = dict(zip(["runs", "failed_runs", *RUN_TOTALS], row))

        cursor = self.conn.execute("SELECT * FROM runs ORDER BY id DESC LIMIT ?", (recent,))
        names = [column[0] for column in cursor.description]
        result["recent"] = [dict(zip(names, row)) for row in cursor.fetchall()]
        for run in result["recent"]:  # a row from before the column existed has none
            run["error_details"] = json.loads(run.get("error_details") or "[]")
        result["last_run"] = result["recent"][0] if result["recent"] else None
        return result

    # --- writes ----------------------------------------------------------

    def record_run(self, run: Run) -> None:
        with self.conn:
            self.conn.execute(
                f"INSERT INTO runs ({', '.join(RUN_COLUMNS)}) VALUES ({', '.join('?' * len(RUN_COLUMNS))})",
                [json.dumps(run.error_details, ensure_ascii=False) if column == "error_details" else getattr(run, column) for column in RUN_COLUMNS],
            )

    def record(self, rule_id: int, suggestion: Suggestion, created: str) -> None:
        with self.conn:
            self.conn.execute(
                "INSERT OR REPLACE INTO suggestions (rule_id, created, category, transactions, triggers) VALUES (?, ?, ?, ?, ?)",
                (
                    rule_id,
                    created,
                    suggestion.category,
                    json.dumps([[t.transaction_id, t.journal_id] for t in suggestion.transactions]),
                    json.dumps([list(t) for t in suggestion.triggers], ensure_ascii=False),
                ),
            )

    def apply(self, decisions: list[Decision]) -> None:
        now = dt.datetime.now().isoformat(timespec="seconds")
        with self.conn:
            for d in decisions:
                p = d.pending
                self.conn.execute(
                    "UPDATE suggestions SET status = ?, closed = ? WHERE rule_id = ?", (d.status, now, p.rule_id)
                )
                if d.status != "rejected":
                    continue
                for trigger_type, value in p.triggers:
                    self.conn.execute(
                        "INSERT OR IGNORE INTO rejected_triggers VALUES (?, ?, ?, ?)",
                        (*trigger_key(trigger_type, value, p.category), p.rule_id),
                    )
                for _, journal_id in p.transactions:
                    self.conn.execute(
                        "INSERT OR IGNORE INTO rejected_journals VALUES (?, ?, ?)", (journal_id, p.category, p.rule_id)
                    )


def journal_categories(ff: Firefly, transactions: list[tuple[int, int]]) -> dict[int, str | None]:
    """Current category per journal; journals that no longer exist are left out."""
    found: dict[int, str | None] = {}
    for transaction_id in sorted({tid for tid, _ in transactions}):
        try:
            group = ff.get(f"/transactions/{transaction_id}")["data"]
        except FireflyError:  # deleted since (404)
            continue
        for split in group["attributes"]["transactions"]:
            found[int(split["transaction_journal_id"])] = split.get("category_name")
    return found


def reconcile(store: Store, suggestion_rule_ids: set[int], lookup) -> list[Decision]:
    """Decide what happened to every suggestion we wrote that is gone from `Suggestions`.

    Per the contract: any of its transactions now has a category -> resolved
    (approved, or set by hand); otherwise -> rejected. A suggestion whose
    transactions were all deleted counts as resolved — there is nothing left to
    remember a "no" about. `lookup` is journal_categories bound to a client;
    injected so tests need no server.
    """
    decisions = []
    for p in store.pending():
        if p.rule_id in suggestion_rule_ids:
            continue
        categories = lookup(p.transactions)
        wanted = [jid for _, jid in p.transactions]
        existing = [jid for jid in wanted if jid in categories]
        if not existing or any(categories[jid] for jid in existing):
            decisions.append(Decision(p, "resolved"))
        else:
            decisions.append(Decision(p, "rejected"))
    return decisions
