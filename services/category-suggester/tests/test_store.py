import datetime as dt
import os
import sqlite3
import tempfile
import unittest

from suggester.contract import Suggestion
from suggester.store import SCHEMA, Run, Store, reconcile, trigger_key
from tests.helpers import txn


def suggestion(category, triggers, *journal_ids):
    return Suggestion(
        category=category,
        confidence=0.8,
        low_confidence=False,
        company=None,
        reason="test",
        transactions=[txn("x", journal_id=j) for j in journal_ids],
        triggers=triggers,
        model="test",
    )


class Reconcile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "data", "suggester.sqlite3")
        self.store = Store.open(self.path)
        self.store.record(101, suggestion("Shopping", [("description_contains", "HOMEDECO")], 1, 2), "2026-10-29")
        self.store.record(102, suggestion("Bills", [("destination_account_id", "16")], 3), "2026-10-29")
        self.store.record(103, suggestion("Food & Drink", [("description_contains", "SP FROSTFOX")], 4), "2026-10-29")
        self.store.record(104, suggestion("Other", [("description_contains", "GONE AWAY")], 5), "2026-10-29")

    def tearDown(self):
        self.store.conn.close()
        self.dir.cleanup()

    def test_resolved_rejected_and_still_pending(self):
        categories = {1: None, 2: "Shopping", 3: "Bills", 4: None}  # journal 5 was deleted

        decisions = reconcile(self.store, {102}, lambda txns: {j: categories[j] for _, j in txns if j in categories})
        status = {d.pending.rule_id: d.status for d in decisions}
        # 101: one of its journals got a category -> resolved (approve or set by hand)
        # 102: still in Suggestions -> not decided at all
        # 103: gone, still uncategorized -> rejected
        # 104: gone, its transaction deleted -> resolved, nothing to remember
        self.assertEqual(status, {101: "resolved", 103: "rejected", 104: "resolved"})

        self.store.apply(decisions)
        self.assertEqual([p.rule_id for p in self.store.pending()], [102])
        self.assertEqual(self.store.rejected_journals(), {4})
        self.assertEqual(self.store.rejected_triggers(), {trigger_key("description_contains", "SP FROSTFOX", "Food & Drink")})

    def test_memory_survives_reopening(self):
        decisions = reconcile(self.store, set(), lambda txns: {j: None for _, j in txns})
        self.store.apply(decisions)
        self.store.conn.close()
        reopened = Store.open(self.path)
        self.assertEqual(reopened.rejected_journals(), {1, 2, 3, 4, 5})
        self.assertIn(trigger_key("destination_account_id", "16", "Bills"), reopened.rejected_triggers())
        self.assertEqual(reopened.pending(), [])
        self.store = reopened

    def test_readonly_never_creates_or_changes_a_database(self):
        missing = os.path.join(self.dir.name, "nope", "db.sqlite3")
        ro = Store.open(missing, readonly=True)
        self.assertEqual(ro.pending(), [])
        self.assertFalse(os.path.exists(missing))

        ro = Store.open(self.path, readonly=True)
        self.assertEqual(len(ro.pending()), 4)
        with self.assertRaises(Exception):
            ro.apply(reconcile(ro, set(), lambda txns: {}))


def run(**changes):
    values = dict(started="2026-10-29T03:00:05", finished="2026-10-29T03:01:10", source="nightly", model="claude-haiku-5-5", min_confidence=0.6)
    return Run(**{**values, **changes})


class RunHistory(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "suggester.sqlite3")
        self.store = Store.open(self.path)

    def tearDown(self):
        self.store.conn.close()
        self.dir.cleanup()

    def test_totals_cover_the_window_and_last_run_is_the_newest(self):
        now = dt.datetime.now()
        old = (now - dt.timedelta(days=40)).isoformat(timespec="seconds")
        recent = (now - dt.timedelta(days=1)).isoformat(timespec="seconds")
        self.store.record_run(run(started=old, groups_sent=9, calls=9, suggestions=9, low_confidence=9))
        self.store.record_run(run(started=recent, groups_sent=4, calls=5, input_tokens=1200, output_tokens=300, searches=2, suggestions=3, low_confidence=1, written=3))
        self.store.record_run(run(started=recent, status="failed", error="ModelUnreachable: billing", source="manual"))

        stats = self.store.stats(days=30)

        self.assertEqual(2, stats["totals"]["runs"])
        self.assertEqual(1, stats["totals"]["failed_runs"])
        self.assertEqual((4, 5, 1200, 300, 2, 3, 1, 3), tuple(stats["totals"][k] for k in ("groups_sent", "calls", "input_tokens", "output_tokens", "searches", "suggestions", "low_confidence", "written")))
        self.assertEqual("failed", stats["last_run"]["status"])
        self.assertEqual("manual", stats["last_run"]["source"])
        self.assertEqual(3, len(stats["recent"]))  # the list is not limited to the window
        self.assertEqual(old, stats["tracking_since"])
        self.assertEqual(0.6, stats["last_run"]["min_confidence"])

    def test_outcomes_count_every_suggestion_ever_written(self):
        self.store.record(101, suggestion("Shopping", [("description_contains", "A")], 1), "2026-10-29")
        self.store.record(102, suggestion("Bills", [("description_contains", "B")], 2), "2026-10-29")
        self.store.record(103, suggestion("Other", [("description_contains", "C")], 3), "2026-10-29")
        self.store.apply(reconcile(self.store, {101}, lambda txns: {j: ("Bills" if j == 2 else None) for _, j in txns}))

        self.assertEqual({"pending": 1, "resolved": 1, "rejected": 1}, self.store.stats()["suggestions"])

    def test_no_history_yet_is_zeros_not_an_error(self):
        stats = self.store.stats()

        self.assertEqual((0, 0), (stats["totals"]["runs"], stats["totals"]["calls"]))
        self.assertIsNone(stats["last_run"])
        self.assertIsNone(stats["tracking_since"])
        self.assertEqual([], stats["recent"])

    def test_a_database_from_before_runs_existed_can_still_be_read(self):
        old = os.path.join(self.dir.name, "old.sqlite3")
        conn = sqlite3.connect(old)
        conn.executescript(SCHEMA.split("-- One row per real")[0])  # the three original tables only
        conn.close()

        stats = Store.open(old, readonly=True).stats()

        self.assertEqual(0, stats["totals"]["runs"])
        self.assertEqual({"pending": 0, "resolved": 0, "rejected": 0}, stats["suggestions"])
        self.assertFalse(Store.open(old, readonly=True).conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'runs'").fetchone())

    def test_error_details_are_kept_bounded_and_distinct(self):
        r = run()
        for message in ["model: ValueError: model refused", "model: ValueError: model refused", "x\n\n  y " + "z" * 500] + [f"e{i}" for i in range(10)]:
            r.add_error(message)
        self.store.record_run(r)

        details = self.store.stats()["last_run"]["error_details"]

        self.assertEqual(5, len(details))
        self.assertEqual("model: ValueError: model refused", details[0])
        self.assertTrue(details[1].startswith("x y zzz"))
        self.assertLessEqual(len(details[1]), 200)
        self.assertEqual("e0", details[2])

    def test_a_table_from_before_error_details_gets_the_column(self):
        old = os.path.join(self.dir.name, "old.sqlite3")
        conn = sqlite3.connect(old)
        conn.executescript(SCHEMA.replace(",\n    error_details  TEXT                         -- JSON list: what the first few group / write errors said", ""))
        conn.execute("INSERT INTO runs (started, finished, source, model, min_confidence, status) VALUES ('2026-10-20T03:00:00', '2026-10-20T03:01:00', 'nightly', 'm', 0.6, 'ok')")
        conn.commit()
        conn.close()

        Store.open(old).record_run(run(started="2026-10-21T03:00:00"))
        recent = Store.open(old, readonly=True).stats(days=3650)["recent"]

        self.assertEqual([[], []], [r["error_details"] for r in recent])

    def test_opening_for_writing_adds_the_table_to_an_old_database(self):
        old = os.path.join(self.dir.name, "old.sqlite3")
        conn = sqlite3.connect(old)
        conn.executescript(SCHEMA.split("-- One row per real")[0])
        conn.close()

        Store.open(old).record_run(run())

        self.assertEqual(1, Store.open(old, readonly=True).stats()["totals"]["runs"])


class TriggerKey(unittest.TestCase):
    def test_description_values_are_normalised(self):
        self.assertEqual(
            trigger_key("description_contains", "NAKUP HETZNER ONLINE GMBH 8,65 EUR", "Business"),
            trigger_key("description_contains", "nakup hetzner online gmbh 0,17 EUR", "Business"),
        )

    def test_category_is_part_of_the_key(self):
        self.assertNotEqual(
            trigger_key("description_contains", "HOMEDECO", "Shopping"), trigger_key("description_contains", "HOMEDECO", "Bills")
        )


if __name__ == "__main__":
    unittest.main()
