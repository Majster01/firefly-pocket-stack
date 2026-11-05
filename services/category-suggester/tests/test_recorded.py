import argparse
import datetime as dt
import os
import tempfile
import unittest
from unittest import mock

from suggester import cli
from suggester.config import Settings
from suggester.llm import ModelUnreachable
from suggester.store import Store


def settings(db_path):
    return Settings(
        firefly_url="http://firefly",
        firefly_token="t",
        anthropic_api_key="k",
        gemini_api_key="",
        model="claude-haiku-5-5",
        min_confidence=0.6,
        max_per_run=50,
        db_path=db_path,
        ntfy_url="",
        pico_url="",
    )


def args(**changes):
    values = dict(source="nightly", all=False, since=None, until=None)
    return argparse.Namespace(**{**values, **changes})


class RecordedRuns(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.db = os.path.join(self.dir.name, "suggester.sqlite3")

    def last_run(self):
        return Store.open(self.db, readonly=True).stats()["last_run"]

    def test_a_finished_run_is_saved_with_what_it_counted(self):
        def fake(args, settings, run):
            run.groups_sent, run.calls, run.suggestions, run.low_confidence, run.written = 4, 5, 3, 1, 3
            return cli.EXIT_OK

        with mock.patch.object(cli, "cmd_suggest", fake):
            status = cli.cmd_suggest_recorded(args(source="manual", until=dt.date(2026, 10, 1)), settings(self.db))

        saved = self.last_run()
        self.assertEqual(cli.EXIT_OK, status)
        self.assertEqual(("ok", "manual", 4, 5, 1, "2026-10-01"), tuple(saved[k] for k in ("status", "source", "groups_sent", "calls", "low_confidence", "window_until")))
        self.assertEqual(0.6, saved["min_confidence"])

    def test_an_unreachable_model_is_saved_as_failed_and_still_raised(self):
        def fake(args, settings, run):
            run.groups_sent = 2
            raise ModelUnreachable("billing: no credit")

        with mock.patch.object(cli, "cmd_suggest", fake), self.assertRaises(ModelUnreachable):
            cli.cmd_suggest_recorded(args(), settings(self.db))

        saved = self.last_run()
        self.assertEqual(("failed", 2), (saved["status"], saved["groups_sent"]))
        self.assertIn("billing: no credit", saved["error"])

    def test_a_setup_failure_keeps_its_reason(self):
        def fake(args, settings, run):
            run.error = "rule group(s) not found by title: Suggestions"
            return cli.EXIT_SETUP

        with mock.patch.object(cli, "cmd_suggest", fake):
            self.assertEqual(cli.EXIT_SETUP, cli.cmd_suggest_recorded(args(), settings(self.db)))

        self.assertEqual(("failed", "rule group(s) not found by title: Suggestions"), (self.last_run()["status"], self.last_run()["error"]))

    def test_all_means_no_window_start(self):
        with mock.patch.object(cli, "cmd_suggest", lambda *_: cli.EXIT_OK):
            cli.cmd_suggest_recorded(args(all=True), settings(self.db))

        self.assertIsNone(self.last_run()["window_since"])

    def test_a_history_that_cannot_be_saved_does_not_fail_the_run(self):
        with mock.patch.object(cli, "cmd_suggest", lambda *_: cli.EXIT_OK), mock.patch.object(cli.Store, "open", side_effect=cli.sqlite3.OperationalError("disk full")):
            self.assertEqual(cli.EXIT_OK, cli.cmd_suggest_recorded(args(), settings(self.db)))


if __name__ == "__main__":
    unittest.main()
