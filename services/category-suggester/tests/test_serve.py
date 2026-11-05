import datetime as dt
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from suggester.cli import date_window, parse_args
from suggester.serve import make_handler, parse_day
from suggester.store import Run, Store

TOKEN = "t" * 40


class ServeTest(unittest.TestCase):
    def start(self, runner):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(TOKEN, runner))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def post(self, base, body, token=TOKEN, path="/suggest"):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, json.load(exc)

    def test_runs_the_suggester_over_the_time_frame(self):
        calls = []

        def runner(since, until):
            calls.append((since, until))
            return 0, {"written": 4}, ""

        base = self.start(runner)

        self.assertEqual((200, {"written": 4}), self.post(base, {"since": "2026-09-01", "until": "2026-09-30"}))
        self.assertEqual([(dt.date(2026, 9, 1), dt.date(2026, 9, 30))], calls)

    def test_needs_the_token(self):
        base = self.start(lambda *_: self.fail("must not run"))

        self.assertEqual(401, self.post(base, {"since": "2026-09-01", "until": "2026-09-30"}, token="wrong")[0])
        self.assertEqual(401, self.post(base, {"since": "2026-09-01", "until": "2026-09-30"}, token=None)[0])
        self.assertEqual(404, self.post(base, {}, path="/other")[0])

    def test_refuses_a_bad_time_frame(self):
        base = self.start(lambda *_: self.fail("must not run"))

        for body in ({}, {"since": "2026-09-01"}, {"since": "2026-02-31", "until": "2026-03-01"}, {"since": "2026-09-30", "until": "2026-09-01"}, {"since": 5, "until": "x"}):
            self.assertEqual(422, self.post(base, body)[0], body)

    def test_reports_why_a_run_failed(self):
        base = self.start(lambda *_: (2, {}, "model API unreachable"))

        self.assertEqual((502, {"error": "model API unreachable"}), self.post(base, {"since": "2026-09-01", "until": "2026-09-30"}))


class StatsTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.db = os.path.join(self.dir.name, "suggester.sqlite3")

    def start(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(TOKEN, db_path=self.db))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def get(self, base, path="/stats", token=TOKEN):
        request = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"} if token else {})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, json.load(exc)

    def test_answers_with_the_run_history(self):
        store = Store.open(self.db)
        store.record_run(Run(started=dt.datetime.now().isoformat(timespec="seconds"), finished="x", source="nightly", model="m", min_confidence=0.6, calls=7, low_confidence=2))
        store.conn.close()

        status, body = self.get(self.start(), "/stats?days=7")

        self.assertEqual(200, status)
        self.assertEqual((7, 7, 7, 2), (body["window_days"], body["totals"]["calls"], body["last_run"]["calls"], body["totals"]["low_confidence"]))

    def test_an_empty_install_is_zeros_and_creates_no_file(self):
        status, body = self.get(self.start())

        self.assertEqual((200, 0), (status, body["totals"]["runs"]))
        self.assertFalse(os.path.exists(self.db))

    def test_needs_the_token(self):
        base = self.start()

        self.assertEqual(401, self.get(base, token="wrong")[0])
        self.assertEqual(401, self.get(base, token=None)[0])
        self.assertEqual(404, self.get(base, "/other")[0])

    def test_refuses_a_bad_window(self):
        base = self.start()

        for days in ("0", "366", "x", "-1"):
            self.assertEqual(422, self.get(base, f"/stats?days={days}")[0], days)


class WindowTest(unittest.TestCase):
    def test_parse_day_is_strict(self):
        self.assertEqual(dt.date(2026, 9, 1), parse_day("2026-09-01"))
        for bad in ("20260901", "2026-9-1", "2026-02-31", "", None, 5):
            self.assertIsNone(parse_day(bad))

    def test_window_searches_wider_but_tests_exactly(self):
        query, inside = date_window(dt.date(2026, 9, 1), dt.date(2026, 9, 30))

        self.assertEqual(" date_after:2026-08-31 date_before:2026-10-01", query)
        self.assertEqual([False, True, True, False], [inside(d) for d in ("2026-08-31", "2026-09-01", "2026-09-30", "2026-10-01")])

    def test_open_ended_window(self):
        query, inside = date_window(None, None)

        self.assertEqual(("", True), (query, inside("1999-01-01")))
        self.assertEqual(" date_after:2026-08-31", date_window(dt.date(2026, 9, 1), None)[0])

    def test_until_is_a_suggest_option(self):
        self.assertEqual(dt.date(2026, 9, 30), parse_args(["suggest", "--since", "2026-09-01", "--until", "2026-09-30"]).until)
        self.assertIsNone(parse_args(["suggest"]).until)
