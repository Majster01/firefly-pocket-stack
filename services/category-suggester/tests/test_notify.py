import argparse
import contextlib
import io
import json
import os
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

from suggester import cli
from suggester.config import Settings

NEXT_URL = "http://next:80/api/internal/notify"
TOKEN = "t" * 48
NTFY = "https://ntfy.example/topic"


def settings(**changes):
    values = dict(
        firefly_url="http://firefly",
        firefly_token="t",
        anthropic_api_key="k",
        gemini_api_key="",
        model="claude-haiku-5-5",
        min_confidence=0.6,
        max_per_run=50,
        db_path="/unused",
        ntfy_url="",
        pico_url="https://pico.example",
        next_notify_url="",
        next_notify_token="",
    )
    return Settings(**{**values, **changes})


def both(**changes):
    return settings(ntfy_url=NTFY, next_notify_url=NEXT_URL, next_notify_token=TOKEN, **changes)


class FakeFirefly:
    def __init__(self, count):
        self.count = count

    def __call__(self, *_):
        return self

    def rule_group_id(self, _title):
        return 1

    def rules(self, _group):
        return list(range(self.count))


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, *_):
        return self.body


def http_error(code):
    return urllib.error.HTTPError(NEXT_URL, code, "x", {}, io.BytesIO(b"{}"))


class Network:
    """Stands in for urlopen: records every request, answers by URL."""

    def __init__(self, ntfy=None, push=None):
        self.requests = []
        self.answers = {NTFY: ntfy, NEXT_URL: push}

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        answer = self.answers[req.full_url]
        if isinstance(answer, BaseException):
            raise answer
        return answer if answer is not None else Response(b"")

    def to(self, url):
        return [r for r in self.requests if r.full_url == url]


class NotifyTest(unittest.TestCase):
    def run_notify(self, cfg, pending=3, dry_run=False, network=None, metas=None):
        network = network or Network(push=Response(b'{"sent":1,"failed":0,"removed":0}'))
        metas = [{"low_confidence": False}] * pending if metas is None else metas
        err = io.StringIO()
        with mock.patch.object(cli, "Firefly", FakeFirefly(pending)), \
             mock.patch.object(cli, "suggestion_metas", lambda _rules: metas), \
             mock.patch.object(cli.urllib.request, "urlopen", network), \
             contextlib.redirect_stderr(err):
            status = cli.cmd_notify(argparse.Namespace(dry_run=dry_run), cfg)
        return status, network, err.getvalue()

    def pushed(self, network):
        (req,) = network.to(NEXT_URL)
        return req, json.loads(req.data)

    def test_pushes_to_next_with_badge_path_and_tag(self):
        status, network, _ = self.run_notify(settings(next_notify_url=NEXT_URL, next_notify_token=TOKEN), pending=3)

        self.assertEqual(cli.EXIT_OK, status)
        req, body = self.pushed(network)
        self.assertEqual("POST", req.get_method())
        self.assertEqual(f"Bearer {TOKEN}", req.get_header("Authorization"))
        self.assertEqual("application/json", req.get_header("Content-type"))
        self.assertEqual(
            {
                "event": "suggestions.digest",
                "title": "Firefly Pocket: category suggestions",
                "body": "3 category suggestions waiting for review.",
                "path": cli.SUGGESTIONS_PATH,
                "badge": 3,
                "tag": "suggestions",
            },
            body,
        )
        self.assertEqual([], network.to(NTFY))

    def test_the_badge_counts_every_pending_suggestion(self):
        metas = [{"low_confidence": True}, {"low_confidence": False}]
        _, network, _ = self.run_notify(both(), metas=metas)

        _, body = self.pushed(network)
        self.assertEqual(2, body["badge"])
        self.assertEqual("2 category suggestions waiting for review (1 low-confidence).", body["body"])

    def test_ntfy_gets_no_digest(self):
        status, network, err = self.run_notify(settings(ntfy_url=NTFY))

        self.assertEqual(cli.EXIT_OK, status)
        self.assertEqual([], network.requests)
        self.assertIn("would send: 3 category suggestions", err)

    def test_the_digest_goes_to_next_only(self):
        status, network, _ = self.run_notify(both())

        self.assertEqual(cli.EXIT_OK, status)
        self.assertEqual([], network.to(NTFY))
        self.assertEqual(1, len(network.to(NEXT_URL)))

    def test_neither_configured_sends_nothing(self):
        status, network, err = self.run_notify(settings())

        self.assertEqual(cli.EXIT_OK, status)
        self.assertEqual([], network.requests)
        self.assertIn("would send: 3 category suggestions", err)

    def test_nothing_pending_sends_nothing_not_even_a_clearing_push(self):
        status, network, err = self.run_notify(both(), pending=0)

        self.assertEqual(cli.EXIT_OK, status)
        self.assertEqual([], network.requests)
        self.assertIn("nothing sent", err)

    def test_dry_run_sends_nothing_and_says_what_it_would(self):
        status, network, err = self.run_notify(both(), dry_run=True)

        self.assertEqual(cli.EXIT_OK, status)
        self.assertEqual([], network.requests)
        self.assertIn("would send: 3 category suggestions", err)
        self.assertIn("would push to Firefly Pocket", err)
        self.assertIn('"event": "suggestions.digest"', err)
        self.assertIn('"badge": 3', err)
        self.assertIn('"tag": "suggestions"', err)
        self.assertNotIn(TOKEN, err)

    def test_dry_run_without_next_does_not_mention_it(self):
        _, network, err = self.run_notify(settings(ntfy_url=NTFY), dry_run=True)

        self.assertEqual([], network.requests)
        self.assertNotIn("Firefly Pocket", err)

    def test_next_rejections_are_warnings(self):
        for code in (401, 422, 503):
            with self.subTest(code=code):
                network = Network(push=http_error(code))
                status, network, err = self.run_notify(both(), network=network)

                self.assertEqual(cli.EXIT_OK, status)
                self.assertIn(f"WARN: Firefly Pocket push notification failed: HTTP {code}", err)

    def test_next_unreachable_is_a_warning(self):
        failures = (urllib.error.URLError("connection refused"), TimeoutError("timed out"), ConnectionResetError("reset"))
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                status, network, err = self.run_notify(both(), network=Network(push=failure))

                self.assertEqual(cli.EXIT_OK, status)
                self.assertIn("WARN: Firefly Pocket push notification failed", err)

    def test_a_garbled_answer_is_not_fatal(self):
        status, _, err = self.run_notify(both(), network=Network(push=Response(b"<html>")))

        self.assertEqual(cli.EXIT_OK, status)
        self.assertIn("WARN: Firefly Pocket push notification failed", err)

    def test_the_answer_is_logged(self):
        network = Network(push=Response(b'{"sent":2,"failed":0,"removed":0,"skipped":1}'))
        _, _, err = self.run_notify(both(), network=network)

        self.assertIn("pushed to Firefly Pocket: 2 sent, 0 failed", err)

    def test_nobody_subscribed_is_not_an_error(self):
        network = Network(push=Response(b'{"sent":0,"failed":0,"removed":0}'))
        status, _, err = self.run_notify(both(), network=network)

        self.assertEqual(cli.EXIT_OK, status)
        self.assertNotIn("WARN", err)

    def test_half_configured_next_is_skipped_with_a_warning(self):
        for cfg in (settings(ntfy_url=NTFY, next_notify_url=NEXT_URL), settings(ntfy_url=NTFY, next_notify_token=TOKEN)):
            status, network, err = self.run_notify(cfg)

            self.assertEqual(cli.EXIT_OK, status)
            self.assertEqual([], network.requests)
            self.assertIn("must both be set", err)


class NotifyConfigTest(unittest.TestCase):
    ENV = {"FIREFLY_URL": "http://firefly", "SUGGESTER_FIREFLY_TOKEN": "t"}

    def load(self, environ, env_file=None):
        with mock.patch.dict(os.environ, environ, clear=True):
            return Settings.load(env_file, need_model=False)

    def test_off_by_default(self):
        cfg = self.load(self.ENV)

        self.assertEqual("", cfg.next_notify_url)
        self.assertEqual("", cfg.next_notify_token)

    def test_read_from_the_environment(self):
        cfg = self.load({**self.ENV, "NEXT_NOTIFY_URL": NEXT_URL, "NEXT_NOTIFY_TOKEN": TOKEN})

        self.assertEqual(NEXT_URL, cfg.next_notify_url)
        self.assertEqual(TOKEN, cfg.next_notify_token)

    def test_an_empty_variable_counts_as_unset(self):
        cfg = self.load({**self.ENV, "NEXT_NOTIFY_URL": "", "NEXT_NOTIFY_TOKEN": ""})

        self.assertEqual("", cfg.next_notify_token)

    def test_read_from_an_env_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text(f"NEXT_NOTIFY_URL={NEXT_URL}\nNEXT_NOTIFY_TOKEN={TOKEN}\n")

            cfg = self.load(self.ENV, path)

        self.assertEqual(NEXT_URL, cfg.next_notify_url)
        self.assertEqual(TOKEN, cfg.next_notify_token)


if __name__ == "__main__":
    unittest.main()
