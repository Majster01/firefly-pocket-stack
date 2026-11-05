"""Run `suggest` on request, for the importer's "import now".

A manual import (started from Pico) is followed by suggestions for the time
frame it imported. The importer cannot start a container, so this small server
does it: POST /suggest {"since": "YYYY-MM-DD", "until": "YYYY-MM-DD"} with the
shared token, answered when the run is over.

GET /stats?days=30 (same token) answers with the run history and what became of
the suggestions, read from the same SQLite file; the importer passes it on to
the status page in Pico, so Pico needs no token of its own for this service.

It listens on the compose network only (no published port, no Caddy route) and
refuses to start without a token, so nothing outside the stack can drive the
model spend. It runs the very same `python -m suggester suggest` as the nightly
job, as a subprocess, so the two cannot differ; the run lock in cli.py keeps
them from overlapping.
"""

from __future__ import annotations

import datetime as dt
import hmac
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from .config import DEFAULT_DB_PATH
from .store import Store

MIN_TOKEN_LENGTH = 32
DEFAULT_STATS_DAYS = 30
MAX_STATS_DAYS = 365
# One model call per group of transactions; a long time frame is a few minutes.
RUN_TIMEOUT_SECONDS = 1800
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_day(value: object) -> dt.date | None:
    if not isinstance(value, str) or not DAY.match(value):
        return None
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return None


def run_suggest(since: dt.date, until: dt.date) -> tuple[int, dict, str]:
    """Run the suggester; returns (exit status, its report, the reason when it failed)."""
    with tempfile.TemporaryDirectory() as tmp:
        report_path = Path(tmp) / "report.json"
        try:
            done = subprocess.run(
                [sys.executable, "-m", "suggester", "suggest", "--source", "manual", "--since", since.isoformat(), "--until", until.isoformat(), "--report", str(report_path)],
                capture_output=True,
                text=True,
                timeout=RUN_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            return 124, {}, "the suggester ran out of time"
        report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}
    fatal = next((line for line in reversed(done.stderr.splitlines()) if line.startswith("FATAL:")), "")
    return done.returncode, report, fatal.removeprefix("FATAL:").strip() or f"the suggester failed (exit status {done.returncode})"


def read_stats(db_path: str, days: int) -> dict:
    """Run history and suggestion outcomes; a read-only look, so it never creates or changes the database."""
    store = Store.open(db_path, readonly=True)
    try:
        return store.stats(days)
    finally:
        store.conn.close()


def parse_days(query: str) -> int | None:
    """?days=N, 1 to 365 (default 30); None when it is not a number in range."""
    raw = parse_qs(query).get("days", [str(DEFAULT_STATS_DAYS)])[0]
    return int(raw) if raw.isdigit() and 1 <= int(raw) <= MAX_STATS_DAYS else None


def make_handler(token: str, runner=run_suggest, db_path: str = DEFAULT_DB_PATH):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, status: int, body: dict) -> None:
            payload = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:  # noqa: N802 (http.server's name)
            url = urlsplit(self.path)
            supplied = self.headers.get("Authorization", "").removeprefix("Bearer ")
            if url.path != "/stats" or not hmac.compare_digest(supplied, token):
                self._send(401 if url.path == "/stats" else 404, {"error": "unauthorized" if url.path == "/stats" else "not found"})
                return
            days = parse_days(url.query)
            if days is None:
                self._send(422, {"error": f"days must be a number from 1 to {MAX_STATS_DAYS}"})
                return
            try:
                self._send(200, read_stats(db_path, days))
            except sqlite3.Error as exc:
                self._send(503, {"error": f"cannot read the run history: {exc}"})

        def do_POST(self) -> None:  # noqa: N802 (http.server's name)
            supplied = self.headers.get("Authorization", "").removeprefix("Bearer ")
            if self.path != "/suggest" or not hmac.compare_digest(supplied, token):
                self._send(401 if self.path == "/suggest" else 404, {"error": "unauthorized" if self.path == "/suggest" else "not found"})
                return
            try:
                body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 4096)) or b"{}")
            except (ValueError, json.JSONDecodeError):
                body = None
            since = parse_day(body.get("since")) if isinstance(body, dict) else None
            until = parse_day(body.get("until")) if isinstance(body, dict) else None
            if since is None or until is None or since > until:
                self._send(422, {"error": "since and until must be dates (YYYY-MM-DD), since not after until"})
                return
            status, report, reason = runner(since, until)
            if status != 0:
                self._send(502, {"error": reason})
                return
            self._send(200, {"written": int(report.get("written", 0))})

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            print(f"{self.address_string()} {format % args}", file=sys.stderr, flush=True)

    return Handler


def serve(port: int) -> int:
    token = os.environ.get("SUGGESTER_TRIGGER_TOKEN", "")
    if len(token) < MIN_TOKEN_LENGTH:
        print(f"FATAL: SUGGESTER_TRIGGER_TOKEN must be at least {MIN_TOKEN_LENGTH} characters", file=sys.stderr)
        return 1
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(token, db_path=os.environ.get("SUGGESTER_DB") or DEFAULT_DB_PATH))
    print(f"listening on :{port}", file=sys.stderr, flush=True)
    server.serve_forever()
    return 0
