"""Tests of the Firefly Pocket Console (services/console/console.py).

CI runs them in the image compose runs the console on, the way compose runs it:

    python -I -B test_console.py

-I leaves this directory off sys.path, so it is put there below.
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import re
import stat
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlencode, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

import console  # noqa: E402
from console import Console, NameCheck, Request, check, dns_verdict, normalize_code  # noqa: E402

CODE = "7K2M-Q9TB-0XH4-PVRA"
HOST = "admin.fx.example.com"
CLIENT_ID = "9f2b6c1e-5a7d-4c3b-8e21-0d4f6a8b9c10"
APP_ID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
ORIGIN = "https://github.com/Majster01/firefly-pocket-stack.git"
CERT = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----\n"


class Clock:
    def __init__(self, now: float = 1_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


class FakeFirefly:
    """Firefly III's OAuth token endpoint and /api/v1/about/user, as far as the
    console can tell: a code is good for the verifier of the challenge it was
    asked for, once."""

    def __init__(self, email: str = "you@example.com"):
        self.email = email
        self.challenge = ""
        self.code = "the-code"
        self.calls = []

    def __call__(self, method, host, path, form=None, token=""):
        self.calls.append((method, host, path, dict(form or {}), token))
        if path == "/oauth/token":
            verifier = (form or {}).get("code_verifier", "")
            made = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
            if form.get("code") != self.code or made != self.challenge or form.get("client_id") != CLIENT_ID \
                    or form.get("redirect_uri") != f"https://{HOST}/oauth/callback" or form.get("client_secret"):
                return 400, {"error": "invalid_grant"}
            self.code = ""
            return 200, {"token_type": "Bearer", "access_token": "ff-access", "expires_in": 31536000}
        if path == "/api/v1/about/user":
            if token != "ff-access":
                return 401, {}
            return 200, {"data": {"type": "users", "attributes": {"email": self.email, "role": "owner"}}}
        return 404, {}


class ChecksTest(unittest.TestCase):
    def test_domain(self):
        for good in ("example.com", "money.example.com", "localhost", "a-b.c0"):
            self.assertIsNone(check("domain", good), good)
        for bad in ("Example.com", "-a.com", "a..com", "a_b.com", "", "a.com/x", "a" * 254):
            self.assertIsNotNone(check("domain", bad), bad)

    def test_email(self):
        self.assertIsNone(check("email", "you+fp@example.com"))
        for bad in ("you", "you@", "@example.com", "you@example", "you@ex ample.com"):
            self.assertIsNotNone(check("email", bad), bad)

    def test_text(self):
        self.assertIsNone(check("text", "Ana Novak"))
        for bad in (" Ana", "Ana ", "'Ana", "A$na", "A#na", 'A"na', "A\\na", "A\nna", "x" * 201):
            self.assertIsNotNone(check("text", bad), repr(bad))

    def test_timezone(self):
        with tempfile.TemporaryDirectory() as tmp:
            zones = Path(tmp)
            (zones / "Europe").mkdir()
            (zones / "Europe" / "Ljubljana").write_bytes(b"TZif")
            self.assertIsNone(check("timezone", "Europe/Ljubljana", zones))
            self.assertIsNotNone(check("timezone", "Mars/Base", zones))
            self.assertIsNotNone(check("timezone", "Europe", zones))  # a directory, not a zone
            self.assertIsNotNone(check("timezone", "../etc/passwd", zones))

    def test_code(self):
        self.assertEqual(normalize_code(" 7k2m-q9tb-oxh4-pvra "), "7K2MQ9TB0XH4PVRA")
        self.assertEqual(normalize_code("7K2M Q9TB 0XH4 PVRA"), "7K2MQ9TB0XH4PVRA")
        self.assertEqual(normalize_code("ILl"), "111")


class DnsTest(unittest.TestCase):
    def test_points_here(self):
        self.assertEqual(dns_verdict("app.x.com", ["203.0.113.5"], [], "203.0.113.5", ""), (True, "points here"))

    def test_elsewhere(self):
        ok, text = dns_verdict("app.x.com", ["198.51.100.1"], [], "203.0.113.5", "")
        self.assertFalse(ok)
        self.assertIn("points to 198.51.100.1, but this server is 203.0.113.5", text)

    def test_aaaa_without_ipv6(self):
        ok, text = dns_verdict("app.x.com", ["203.0.113.5"], ["2001:db8::1"], "203.0.113.5", "")
        self.assertFalse(ok)
        self.assertIn("remove that AAAA record", text)

    def test_unresolved(self):
        self.assertEqual(dns_verdict("app.x.com", [], [], "203.0.113.5", ""), (False, "does not resolve yet"))

    def test_nat(self):
        ok, text = dns_verdict("app.x.com", ["198.51.100.1"], [], "10.0.0.4", "")
        self.assertTrue(ok)
        self.assertIn("behind NAT", text)

    def test_localhost(self):
        self.assertEqual(dns_verdict("admin.localhost", [], [], "", ""), (True, "this machine"))


class ConsoleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.inbox = base / "inbox"
        self.inbox.mkdir()
        self.status = base / "status.json"
        self.clock = Clock()
        self.checked = []
        self.app = self.make()

    def tearDown(self):
        self.tmp.cleanup()

    def make(self, **kw) -> Console:
        def check_names(names, v4, v6):
            self.checked.append((names, v4, v6))
            return [NameCheck(n["role"], n["host"], True, "points here", True, "valid until 2027-02-01") for n in names]

        args = dict(
            code=CODE, inbox=self.inbox, status_file=self.status,
            timezones=["Europe/Ljubljana", "Etc/UTC"], clock=self.clock, fail_delay=0, check_names=check_names,
        )
        args.update(kw)
        return Console(**args)

    def write_status(self, **extra):
        state = {
            "settings": {"DOMAIN": "fx.example.com", "SITE_OWNER": "you@example.com", "LEGAL_OWNER_NAME": "",
                         "TZ": "", "ADMIN_HOSTNAME": ""},
            "host_timezone": "Europe/Ljubljana",
            "addresses": {"v4": "203.0.113.5", "v6": ""},
            "names": [{"role": "admin", "host": HOST}, {"role": "firefly", "host": "firefly.fx.example.com"},
                      {"role": "app", "host": "app.fx.example.com"}],
            "requests": {},
        }
        state.update(extra)
        self.status.write_text(json.dumps(state))

    def call(self, method, target, body="", cookie="", origin=f"https://{HOST}", app=None):
        headers = {"host": HOST, "x-forwarded-proto": "https"}
        if origin is not None:
            headers["origin"] = origin
        if cookie:
            headers["cookie"] = cookie
        return (app or self.app).handle(Request(method, target, headers, body.encode()))

    def sign_in(self) -> str:
        resp = self.call("POST", "/login", f"code={CODE}")
        self.assertEqual(resp.status, 303)
        cookie = dict(resp.headers)["Set-Cookie"]
        return cookie.split(";")[0]

    def requests(self) -> list[Path]:
        return sorted(self.inbox.glob("*.json"))

    # ---------------------------------------------------------------- tests ---
    def test_health_and_css_need_nothing(self):
        self.assertEqual(self.call("GET", "/health").status, 200)
        resp = self.call("GET", "/console.css")
        self.assertEqual(resp.status, 200)
        self.assertIn("text/css", resp.content_type)
        # The page's policy allows this file and nothing else: no url() or @import in it.
        css = resp.body.decode()
        self.assertNotIn("url(", css)
        self.assertNotIn("@import", css)

    def test_asks_for_the_code(self):
        resp = self.call("GET", "/")
        self.assertEqual(resp.status, 200)
        self.assertIn(b'name="code"', resp.body)
        # Every other page too, until signed in.
        self.assertIn(b'name="code"', self.call("GET", "/server").body)
        self.assertNotIn(b"<nav", resp.body)

    def test_right_code_in_any_spelling(self):
        resp = self.call("POST", "/login", "code=7k2m+q9tb+oxh4+pvra")
        self.assertEqual(resp.status, 303)
        cookie = dict(resp.headers)["Set-Cookie"]
        self.assertTrue(cookie.startswith("__Host-console="))
        for attribute in ("Path=/", "Secure", "HttpOnly", "SameSite=Lax"):
            self.assertIn(attribute, cookie)

    def test_wrong_code(self):
        resp = self.call("POST", "/login", "code=0000-0000-0000-0000")
        self.assertEqual(resp.status, 401)
        self.assertIn(b"That is not the code", resp.body)
        self.assertFalse(any(name == "Set-Cookie" for name, _ in resp.headers))

    def test_too_many_wrong_codes(self):
        for _ in range(console.FAILURES_PER_MINUTE):
            self.assertEqual(self.call("POST", "/login", "code=nope").status, 401)
        self.assertEqual(self.call("POST", "/login", f"code={CODE}").status, 429)
        self.clock.now += 61
        self.assertEqual(self.call("POST", "/login", f"code={CODE}").status, 303)

    def test_post_from_elsewhere_is_refused(self):
        self.assertEqual(self.call("POST", "/login", f"code={CODE}", origin="https://evil.example").status, 403)
        self.assertEqual(self.call("POST", "/login", f"code={CODE}", origin=None).status, 403)
        cookie = self.sign_in()
        resp = self.call("POST", "/server", "domain=fx.example.com", cookie=cookie, origin="https://evil.example")
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.requests(), [])

    def test_origin_null_from_this_page(self):
        # What a browser sends where a referrer policy hides the origin: only
        # Sec-Fetch-Site tells this page's own form from another site's.
        def login(fetch_site):
            headers = {"host": HOST, "x-forwarded-proto": "https", "origin": "null"}
            if fetch_site:
                headers["sec-fetch-site"] = fetch_site
            return self.app.handle(Request("POST", "/login", headers, f"code={CODE}".encode())).status
        self.assertEqual(login("same-origin"), 303)
        self.assertEqual(login("cross-site"), 403)
        self.assertEqual(login(""), 403)

    def test_session_ends(self):
        cookie = self.sign_in()
        self.assertEqual(self.call("GET", "/server", cookie=cookie).status, 200)
        self.clock.now += console.SESSION_SECONDS + 1
        self.assertIn(b'name="code"', self.call("GET", "/server", cookie=cookie).body)

    def test_sign_out(self):
        cookie = self.sign_in()
        self.assertEqual(self.call("POST", "/logout", cookie=cookie).status, 303)
        self.assertIn(b'name="code"', self.call("GET", "/server", cookie=cookie).body)

    def test_server_page_shows_the_settings_and_the_names(self):
        self.write_status()
        resp = self.call("GET", "/server", cookie=self.sign_in())
        page = resp.body.decode()
        self.assertEqual(resp.status, 200)
        self.assertIn('value="fx.example.com"', page)
        self.assertIn('value="you@example.com"', page)
        self.assertIn('value="Europe/Ljubljana"', page)  # no TZ stored: the host's
        self.assertIn("*.fx.example.com", page)
        self.assertIn("<code>fx.example.com</code></td><td>A</td>", page)  # the bare domain is Pocket's
        self.assertIn("203.0.113.5", page)
        self.assertIn(HOST, page)
        self.assertIn("valid until 2027-02-01", page)
        self.assertEqual(self.checked[-1][1:], ("203.0.113.5", ""))

    def test_server_page_without_status(self):
        resp = self.call("GET", "/server", cookie=self.sign_in())
        self.assertEqual(resp.status, 200)
        self.assertIn(b"console status", resp.body)

    def test_save_refuses_a_bad_value(self):
        cookie = self.sign_in()
        resp = self.call("POST", "/server", "domain=fx.example.com&email=you%40example.com&name=&timezone=Mars%2FBase",
                         cookie=cookie)
        self.assertEqual(resp.status, 400)
        self.assertIn(b"an IANA timezone", resp.body)
        self.assertIn(b'value="Mars/Base"', resp.body)
        resp = self.call("POST", "/server", "domain=&email=you%40example.com&name=&timezone=Etc%2FUTC", cookie=cookie)
        self.assertEqual(resp.status, 400)
        self.assertIn(b"Domain is needed", resp.body)
        self.assertEqual(self.requests(), [])

    def test_save_hands_a_request_to_the_agent(self):
        self.write_status()
        cookie = self.sign_in()
        resp = self.call("POST", "/server",
                         "domain=FX.Example.com.&email=you%40example.com&name=Ana+Novak&timezone=Europe%2FLjubljana",
                         cookie=cookie)
        self.assertEqual(resp.status, 303)
        location = dict(resp.headers)["Location"]
        rid = re.fullmatch(r"/requests/([0-9a-f]{32})", location).group(1)
        files = self.requests()
        self.assertEqual([f.name for f in files], [f"{rid}.json"])
        self.assertEqual(list(self.inbox.glob(".*")), [])
        self.assertEqual(stat.S_IMODE(files[0].stat().st_mode), 0o644)
        request = json.loads(files[0].read_text())
        self.assertEqual(request["action"], "server")
        self.assertEqual(request["code"], "7K2MQ9TB0XH4PVRA")  # the agent checks it too
        self.assertEqual(request["settings"], {"DOMAIN": "fx.example.com", "SITE_OWNER": "you@example.com",
                                               "LEGAL_OWNER_NAME": "Ana Novak", "TZ": "Europe/Ljubljana"})

        waiting = self.call("GET", location, cookie=cookie)
        self.assertEqual(waiting.status, 202)
        self.assertIn(b'http-equiv="refresh"', waiting.body)
        self.clock.now += 31
        self.assertIn(b"console apply", self.call("GET", location, cookie=cookie).body)

        self.write_status(requests={rid: {"state": "applied", "message": "Saved: your name and the timezone.",
                                          "at": "2026-11-06T12:00:00Z"}})
        done = self.call("GET", location, cookie=cookie)
        self.assertEqual(done.status, 200)
        self.assertIn(b"Saved: your name and the timezone.", done.body)
        self.assertIn(b'href="/account"', done.body)
        # The step navigation stays in view while it works and after: on Server, the step the request belongs to.
        for page in (waiting, done):
            self.assertIn(b'<nav class="steps" aria-label="Setup steps">', page.body)
        self.assertIn(b'<li class="now" aria-current="step">Server</li>', done.body)
        self.assertIn(b"Step 1 of 8", done.body)

    def test_every_step_page_has_its_nav(self):
        # Each step's page, in every state it renders (account made or not), has the navigation on that step.
        cookie = self.sign_in()
        for state in ({}, {"account": True}):
            self.write_status(**state)
            for i, (name, path) in enumerate(console.STEPS):
                resp = self.call("GET", path, cookie=cookie)
                self.assertIn(resp.status, (200, 409), path)
                self.assertIn(f'<li class="now" aria-current="step">{name}</li>'.encode(), resp.body, (path, state))
                self.assertIn(f"Step {i + 1} of 8".encode(), resp.body)

    def test_a_request_page_shows_the_step_it_belongs_to(self):
        # Alerts has three requests; the navigation is on Alerts for each, and Bank's key is on Bank.
        for action, state, step in (("ntfy", "applied", "Alerts"), ("ntfy_test", "applied", "Alerts"),
                                    ("healthchecks", "applied", "Alerts"), ("suggestions", "applied", "Suggestions"),
                                    ("bank_key", "refused", "Bank connection"), ("backups", "failed", "Backups")):
            self.write_status(requests={"ab" * 16: {"state": state, "action": action, "message": "ok",
                                                    "at": "2026-11-06T12:00:00Z"}})
            page = self.call("GET", f"/requests/{'ab' * 16}", cookie=self.sign_in()).body.decode()
            self.assertIn(f'<li class="now" aria-current="step">{step}</li>', page, action)

    def test_a_running_request_that_stopped_keeps_its_nav(self):
        self.write_status(requests={"ab" * 16: {"state": "running", "action": "ntfy",
                                                "message": "Sending", "at": "2026-11-06T12:00:00Z"}})
        self.clock.now = datetime(2026, 11, 6, 12, tzinfo=timezone.utc).timestamp() + console.STALE_SECONDS + 60
        page = self.call("GET", f"/requests/{'ab' * 16}", cookie=self.sign_in()).body.decode()
        self.assertIn("stopped working on it", page)
        self.assertIn('<li class="now" aria-current="step">Alerts</li>', page)

    def test_a_refused_finish_keeps_its_nav(self):
        # Only an applied Finish restarts the console: after a refusal the steps' links still work.
        self.write_status(requests={"ab" * 16: {"state": "refused", "action": "finish", "message": "No.",
                                                "at": "2026-11-06T12:00:00Z"}})
        page = self.call("GET", f"/requests/{'ab' * 16}", cookie=self.sign_in()).body.decode()
        self.assertIn("Not finished", page)
        self.assertIn('<li class="now" aria-current="step">Finish</li>', page)

    def test_finishing_has_no_step_navigation(self):
        # The console starts again without the code: the steps' links would lead nowhere.
        self.write_status(requests={"ab" * 16: {"state": "applied", "action": "finish", "message": "Done.",
                                                "at": "2026-11-06T12:00:00Z"}})
        page = self.call("GET", f"/requests/{'ab' * 16}", cookie=self.sign_in()).body
        self.assertIn(b"open it again", page)
        self.assertNotIn(b"<nav", page)

    def test_a_refused_request(self):
        self.write_status(requests={"ab" * 16: {"state": "refused", "message": "TZ: an IANA timezone",
                                                "at": "2026-11-06T12:00:00Z"}})
        resp = self.call("GET", f"/requests/{'ab' * 16}", cookie=self.sign_in())
        self.assertIn(b"Not saved", resp.body)
        self.assertIn(b"TZ: an IANA timezone", resp.body)
        self.assertIn(b'<li class="now" aria-current="step">Server</li>', resp.body)

    def test_a_new_domain_moves_the_console(self):
        self.write_status()
        cookie = self.sign_in()
        resp = self.call("POST", "/server", "domain=pocket.example.org&email=you%40example.com&name=&timezone=Etc%2FUTC",
                         cookie=cookie)
        page = self.call("GET", dict(resp.headers)["Location"], cookie=cookie)
        self.assertEqual(page.status, 202)
        self.assertIn(b"https://admin.pocket.example.org/", page.body)
        self.assertNotIn(b'http-equiv="refresh"', page.body)
        self.assertNotIn(b"<nav", page.body)  # this host goes away: the steps' links would fail

    def test_unknown_request(self):
        resp = self.call("GET", f"/requests/{'0' * 32}", cookie=self.sign_in())
        self.assertEqual(resp.status, 404)
        self.assertNotIn(b"<nav", resp.body)

    def test_inbox_not_writable(self):
        self.inbox.rmdir()
        resp = self.call("POST", "/server", "domain=fx.example.com&email=you%40example.com&name=&timezone=Etc%2FUTC",
                         cookie=self.sign_in())
        self.assertEqual(resp.status, 503)
        self.assertIn(b"compose/console/inbox", resp.body)

    def test_finished_refuses_the_code(self):
        # Finish removed the code, and the console started again without it.
        self.write_status(account=True, setup_done=True)
        app = self.make(code="")
        resp = self.call("GET", "/", app=app)
        self.assertEqual(resp.status, 200)
        self.assertIn(b"Setup is finished", resp.body)
        self.assertIn(b"https://firefly.fx.example.com/", resp.body)
        self.assertNotIn(b"did not finish", resp.body)
        resp = self.call("POST", "/login", f"code={CODE}", app=app)
        self.assertIn(b"Setup is finished", resp.body)
        self.assertFalse(any(name == "Set-Cookie" for name, _ in resp.headers))
        for path, body in (("/server", "domain=evil.example"), ("/account", "password=x" * 20),
                           ("/bank", "app_id=" + APP_ID), ("/bank/key", ""), ("/finish", "")):
            self.call("POST", path, body, app=app)
        self.assertEqual(self.requests(), [])

    def test_finished_before_the_console_starts_again(self):
        # The agent removed the code, and says so; this console still has it until it starts again.
        self.write_status(account=True, setup_done=True)
        resp = self.call("POST", "/login", f"code={CODE}")
        self.assertIn(b"Setup is finished", resp.body)
        self.assertFalse(any(name == "Set-Cookie" for name, _ in resp.headers))

    def test_a_server_set_up_before_this_version(self):
        # Its status said setup_done for the account, and it never had a code.
        self.write_status(setup_done=True)
        self.assertIn(b"Setup is finished", self.call("GET", "/", app=self.make(code="")).body)

    def test_finished_says_when_the_last_step_failed(self):
        # The account is made, so the gate opened, but not everything started.
        self.write_status(account=True, setup_done=True, requests={
            "ab" * 16: {"state": "applied", "message": "Saved: the timezone.", "action": "server", "at": "2026-11-06T12:00:00Z"},
            "cd" * 16: {"state": "failed", "message": "not running: importer.", "action": "account", "at": "2026-11-06T12:09:00Z"},
        })
        page = self.call("GET", "/", app=self.make(code="")).body
        self.assertIn(b"did not finish: not running: importer.", page)

    # ------------------------------------------------------------ account ---
    def account_status(self, **extra):
        self.write_status(settings={"DOMAIN": "fx.example.com", "SITE_OWNER": "you@example.com", "LEGAL_OWNER_NAME": "",
                                    "TZ": "Europe/Ljubljana", "ADMIN_HOSTNAME": ""}, **extra)

    def test_account_waits_for_the_server_step(self):
        self.write_status()  # no TZ saved yet
        cookie = self.sign_in()
        page = self.call("GET", "/account", cookie=cookie).body
        self.assertIn(b"Save the Server step first", page)
        self.assertNotIn(b'name="password"', page)
        password = "correct+horse+battery+staple"
        resp = self.call("POST", "/account", f"password={password}&password2={password}", cookie=cookie)
        self.assertEqual(resp.status, 409)
        self.assertEqual(self.requests(), [])

    def test_account_page(self):
        self.account_status()
        resp = self.call("GET", "/account", cookie=self.sign_in())
        page = resp.body.decode()
        self.assertEqual(resp.status, 200)
        self.assertIn('value="you@example.com"', page)
        self.assertIn('autocomplete="username"', page)
        self.assertEqual(page.count('type="password" autocomplete="new-password"'), 2)
        self.assertIn("https://firefly.fx.example.com", page)
        self.assertIn('href="/server"', page)  # the stepper goes back
        self.assertIn('aria-current="step">Firefly III account', page)

    def test_account_refuses_a_bad_password(self):
        self.account_status()
        cookie = self.sign_in()
        for body, status, text in (
            ("password=short&password2=short", 400, b"At least 16 characters"),
            ("password=correct+horse+battery&password2=correct+horse+batterz", 400, b"The two differ"),
            ("password=correct%07horse+battery&password2=correct%07horse+battery", 400, b"No control characters"),
        ):
            resp = self.call("POST", "/account", body, cookie=cookie)
            self.assertEqual(resp.status, status, body)
            self.assertIn(text, resp.body)
            self.assertNotIn(b"horse", resp.body)  # never written back into the page
        self.assertEqual(self.requests(), [])

    def test_account_hands_the_password_to_the_agent(self):
        self.account_status()
        cookie = self.sign_in()
        password = "correct horse battery staple ✓"
        form = f"password={quote(password)}&password2={quote(password)}&email=other%40example.com"
        resp = self.call("POST", "/account", form, cookie=cookie)
        self.assertEqual(resp.status, 303)
        location = dict(resp.headers)["Location"]
        rid = re.fullmatch(r"/requests/([0-9a-f]{32})", location).group(1)
        files = self.requests()
        self.assertEqual([f.name for f in files], [f"{rid}.json"])
        request = json.loads(files[0].read_text())
        # Only the password: the email is the one the server keeps, whatever the form says.
        self.assertEqual({k: request[k] for k in ("action", "code", "password")},
                         {"action": "account", "code": "7K2MQ9TB0XH4PVRA", "password": password})
        self.assertNotIn("settings", request)

        waiting = self.call("GET", location, cookie=cookie)
        self.assertEqual(waiting.status, 202)
        self.assertIn(b"Making your account", waiting.body)
        # A second try while the first runs only goes back to the first.
        for method, body in (("GET", ""), ("POST", form)):
            again = self.call(method, "/account", body, cookie=cookie)
            self.assertEqual((again.status, dict(again.headers).get("Location")), (303, location))
        self.assertEqual(len(self.requests()), 1)

        self.account_status(requests={rid: {"state": "running", "action": "account", "at": "2026-11-06T12:00:00Z",
                                            "message": "Starting Firefly III, and nothing that makes it public."}})
        running = self.call("GET", location, cookie=cookie)
        self.assertEqual(running.status, 202)
        self.assertIn(b'http-equiv="refresh"', running.body)
        self.assertIn(b"Starting Firefly III", running.body)

        self.account_status(requests={rid: {"state": "failed", "action": "account", "at": "2026-11-06T12:04:00Z",
                                            "message": "Firefly III did not answer within five minutes."}})
        failed = self.call("GET", location, cookie=cookie)
        self.assertIn(b"Not done", failed.body)
        self.assertIn(b"did not answer within five minutes", failed.body)
        # Then it can be tried again.
        self.assertEqual(self.call("GET", "/account", cookie=cookie).status, 200)

    def test_a_stale_account_request(self):
        rid = "ef" * 16
        self.account_status(requests={rid: {"state": "running", "action": "account", "at": "2026-11-06T12:00:00Z",
                                            "message": "Downloading every service."}})
        at = datetime(2026, 11, 6, 12, tzinfo=timezone.utc).timestamp()
        self.clock.now = at + console.STALE_SECONDS - 60
        self.assertIn(b"Downloading every service.", self.call("GET", f"/requests/{rid}", cookie=self.sign_in()).body)
        self.clock.now = at + console.STALE_SECONDS + 60
        page = self.call("GET", f"/requests/{rid}", cookie=self.sign_in()).body
        self.assertIn(b"stopped working on it", page)
        self.assertNotIn(b'http-equiv="refresh"', page)

    # ------------------------------------------------- the steps in order ---
    def bank_status(self, requests=None, suggestions=None, alerts=None, backups=None, updates=None, **bank):
        state = {"key": False, "certificate": "", "app_id": "",
                 "redirect_urls": ["https://app.fx.example.com/eb-callback", "https://import.fx.example.com/eb-callback"]}
        state.update(bank)
        self.account_status(account=True, setup_done=False, bank=state, requests=requests or {},
                            suggestions=suggestions or {"anthropic": "", "gemini": "", "model": "claude-haiku-5-5"},
                            alerts=alerts or {"ntfy": "", "healthchecks": False},
                            backups=backups or {"repository": "", "access_key_id": "", "secret_access_key": "",
                                                "restic": True},
                            updates=updates or {"agent": False, "origin": ORIGIN},
                            names=[{"role": "admin", "host": HOST}, {"role": "firefly", "host": "firefly.fx.example.com"},
                                   {"role": "app", "host": "app.fx.example.com"},
                                   {"role": "legal", "host": "legal.fx.example.com"}])

    def request_of(self, resp) -> tuple[str, dict]:
        self.assertEqual(resp.status, 303, resp.body[:300])
        location = dict(resp.headers)["Location"]
        rid = re.fullmatch(r"/requests/([0-9a-f]{32})", location).group(1)
        return location, json.loads((self.inbox / f"{rid}.json").read_text())

    def test_each_step_in_turn(self):
        for status, where in ((self.write_status, "/server"), (self.account_status, "/account"),
                              (self.bank_status, "/bank")):
            status()
            resp = self.call("POST", "/login", f"code={CODE}")
            self.assertEqual(dict(resp.headers)["Location"], where)
            cookie = dict(resp.headers)["Set-Cookie"].split(";")[0]
            self.assertEqual(dict(self.call("GET", "/", cookie=cookie).headers)["Location"], where)

    def test_after_the_account_the_server_step_stays(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/server", cookie=cookie).body.decode()
        self.assertNotIn('<form method="post" action="/server"', page)
        self.assertIn("scripts/firefly-pocket setup domain", page)
        self.assertIn("Europe/Ljubljana", page)
        self.assertIn('href="/bank"', page)
        resp = self.call("POST", "/server", "domain=fx.example.com&email=you%40example.com&name=&timezone=Etc%2FUTC",
                         cookie=cookie)
        self.assertEqual(resp.status, 409)
        self.assertEqual(self.requests(), [])

    def test_after_the_account_its_page_says_done(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/account", cookie=cookie).body.decode()
        self.assertIn("Done: you sign in at <code>https://firefly.fx.example.com</code> as you@example.com", page)
        self.assertNotIn('type="password"', page)
        self.assertIn("Next: Bank connection", page)
        password = "correct+horse+battery+staple"
        resp = self.call("POST", "/account", f"password={password}&password2={password}", cookie=cookie)
        self.assertEqual(resp.status, 409)
        self.assertEqual(self.requests(), [])

    def test_bank_and_finish_wait_for_the_account(self):
        self.account_status()
        cookie = self.sign_in()
        for path in ("/bank", "/finish"):
            self.assertIn(b"Make the Firefly III account first", self.call("GET", path, cookie=cookie).body)
        for path, body in (("/bank/key", ""), ("/bank", f"app_id={APP_ID}"), ("/finish", "")):
            self.assertEqual(self.call("POST", path, body, cookie=cookie).status, 409, path)
        self.assertEqual(self.requests(), [])

    def test_bank_asks_the_server_for_a_key(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/bank", cookie=cookie).body.decode()
        self.assertIn('action="/bank/key"', page)
        self.assertIn("Make the key", page)
        self.assertNotIn('name="app_id"', page)
        self.assertIn("Skip it for now", page)
        self.assertEqual(self.call("POST", "/bank", f"app_id={APP_ID}", cookie=cookie).status, 409)  # no key yet
        location, request = self.request_of(self.call("POST", "/bank/key", "", cookie=cookie))
        self.assertEqual({k: request[k] for k in ("action", "code")}, {"action": "bank_key", "code": "7K2MQ9TB0XH4PVRA"})
        waiting = self.call("GET", location, cookie=cookie)
        self.assertEqual(waiting.status, 202)
        self.assertIn(b"Making the key", waiting.body)
        self.assertIn(b"a few seconds", waiting.body)
        # Made: straight back to the bank page, which has the certificate now.
        rid = location.rsplit("/", 1)[1]
        self.bank_status(key=True, certificate=CERT, requests={rid: {
            "state": "applied", "action": "bank_key", "at": "2026-11-06T12:00:00Z", "message": "A new key."}})
        done = self.call("GET", location, cookie=cookie)
        self.assertEqual((done.status, dict(done.headers)["Location"]), (303, "/bank"))

    def test_bank_hands_out_the_certificate(self):
        self.bank_status(key=True, certificate=CERT)
        cookie = self.sign_in()
        page = self.call("GET", "/bank", cookie=cookie).body.decode()
        for want in ('href="/bank/certificate" download', "-----BEGIN CERTIFICATE-----",
                     "<code>https://app.fx.example.com/eb-callback</code>", "<code>https://import.fx.example.com/eb-callback</code>",
                     "https://legal.fx.example.com/privacy", "https://legal.fx.example.com/terms", "production",
                     'name="app_id" value=""', "Make a new key", "Skip it for now"):
            self.assertIn(want, page)
        resp = self.call("GET", "/bank/certificate", cookie=cookie)
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.body, CERT.encode())
        self.assertEqual(resp.content_type, "application/x-pem-file")
        self.assertIn("attachment", dict(resp.headers)["Content-Disposition"])
        # Only signed in.
        self.assertNotEqual(self.call("GET", "/bank/certificate").body, CERT.encode())

    def test_bank_with_a_key_set_by_hand(self):
        self.bank_status(key=True)
        cookie = self.sign_in()
        page = self.call("GET", "/bank", cookie=cookie).body.decode()
        self.assertIn("set by hand", page)
        self.assertNotIn("/bank/certificate", page)
        self.assertIn('name="app_id"', page)
        self.assertEqual(self.call("GET", "/bank/certificate", cookie=cookie).status, 404)

    def test_bank_refuses_a_bad_id(self):
        self.bank_status(key=True, certificate=CERT)
        cookie = self.sign_in()
        for value in ("", "not-an-id", APP_ID + "0", APP_ID[:-1] + "%0A"):
            resp = self.call("POST", "/bank", f"app_id={value}", cookie=cookie)
            self.assertEqual(resp.status, 400, value)
            self.assertIn(b"An application ID, such as", resp.body)
        resp = self.call("POST", "/bank", "app_id=%22%3E%3Cb%3E", cookie=cookie)
        self.assertNotIn(b'"><b>', resp.body)
        self.assertEqual(self.requests(), [])

    def test_bank_hands_the_id_to_the_agent(self):
        self.bank_status(key=True, certificate=CERT)
        cookie = self.sign_in()
        location, request = self.request_of(self.call("POST", "/bank", f"app_id=+{APP_ID}+", cookie=cookie))
        self.assertEqual({k: request[k] for k in ("action", "code", "app_id")},
                         {"action": "bank", "code": "7K2MQ9TB0XH4PVRA", "app_id": APP_ID})
        self.assertIn(b"Checking with Enable Banking", self.call("GET", location, cookie=cookie).body)
        rid = location.rsplit("/", 1)[1]
        self.bank_status(key=True, certificate=CERT, requests={rid: {
            "state": "refused", "action": "bank", "at": "2026-11-06T12:00:00Z",
            "message": "Enable Banking refused a request signed with this server's key for this ID (HTTP 401)."}})
        page = self.call("GET", location, cookie=cookie).body
        self.assertIn(b"Not saved", page)
        self.assertIn(b"HTTP 401", page)
        self.assertIn(b'href="/bank"', page)
        self.bank_status(key=True, certificate=CERT, app_id=APP_ID, requests={rid: {
            "state": "applied", "action": "bank", "at": "2026-11-06T12:00:00Z", "message": "Saved: it works."}})
        page = self.call("GET", location, cookie=cookie).body
        self.assertIn(b"Saved: it works.", page)
        self.assertIn(b'href="/suggestions">Next: Suggestions', page)
        page = self.call("GET", "/bank", cookie=cookie).body.decode()
        self.assertIn(f"This server uses the application <code>{APP_ID}</code>", page)
        self.assertIn(f'value="{APP_ID}"', page)
        self.assertIn('<li class="done"><a href="/bank">', self.call("GET", "/finish", cookie=cookie).body.decode())

    def test_finish(self):
        self.bank_status(key=True, certificate=CERT, app_id=APP_ID)
        cookie = self.sign_in()
        page = self.call("GET", "/finish", cookie=cookie).body.decode()
        for want in (f"the application <code>{APP_ID}</code>", "fx.example.com", "https://firefly.fx.example.com",
                     "setup updates</code>", "nothing runs on a schedule", 'action="/finish"'):
            self.assertIn(want, page)
        location, request = self.request_of(self.call("POST", "/finish", "", cookie=cookie))
        self.assertEqual({k: request[k] for k in ("action", "code")}, {"action": "finish", "code": "7K2MQ9TB0XH4PVRA"})
        rid = location.rsplit("/", 1)[1]
        self.bank_status(key=True, certificate=CERT, app_id=APP_ID, requests={rid: {
            "state": "applied", "action": "finish", "at": "2026-11-06T12:00:00Z",
            "message": "Setup is finished: the setup code works no more."}})
        page = self.call("GET", location, cookie=cookie).body
        self.assertIn(b"<h1>Setup is finished</h1>", page)
        self.assertIn(b"open it again", page)

    def test_finish_without_the_bank(self):
        self.bank_status()
        page = self.call("GET", "/finish", cookie=self.sign_in()).body.decode()
        self.assertIn("Firefly Pocket links no bank until it is", page)
        self.assertIn("scripts/firefly-pocket setup bank", page)

    # -------------------------------------------- suggestions and alerts ---
    def test_the_first_step_left(self):
        for extra, where in (({}, "/bank"), ({"app_id": APP_ID}, "/suggestions"),
                             ({"app_id": APP_ID, "suggestions": {"anthropic": "…wxyz", "model": "claude-haiku-5-5"}}, "/alerts"),
                             ({"app_id": APP_ID, "suggestions": {"anthropic": "…wxyz", "model": "claude-haiku-5-5"},
                               "alerts": {"ntfy": "…abcd", "healthchecks": False}}, "/backups"),
                             ({"app_id": APP_ID, "suggestions": {"anthropic": "…wxyz", "model": "claude-haiku-5-5"},
                               "alerts": {"ntfy": "…abcd", "healthchecks": False},
                               "backups": {"repository": "/srv/restic", "restic": True}}, "/updates"),
                             ({"app_id": APP_ID, "suggestions": {"anthropic": "…wxyz", "model": "claude-haiku-5-5"},
                               "alerts": {"ntfy": "…abcd", "healthchecks": False},
                               "backups": {"repository": "/srv/restic", "restic": True},
                               "updates": {"agent": True, "origin": ORIGIN}}, "/finish")):
            self.bank_status(**extra)
            self.assertEqual(dict(self.call("POST", "/login", f"code={CODE}").headers)["Location"], where, extra)

    def test_suggestions_page(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/suggestions", cookie=cookie).body.decode()
        for want in ('name="provider" value="anthropic" checked', 'name="key" type="password"', 'value="claude-haiku-5-5"',
                     "Skip it for now", 'aria-current="step">Suggestions'):
            self.assertIn(want, page)
        self.bank_status(suggestions={"anthropic": "", "gemini": "…Q9xz", "model": "gemini-2.5-flash"})
        page = self.call("GET", "/suggestions", cookie=cookie).body.decode()
        self.assertIn("Gemini's, <code>…Q9xz</code>, for <code>gemini-2.5-flash</code>", page)
        self.assertIn('name="provider" value="gemini" checked', page)
        self.assertIn("Next: Alerts", page)

    def test_suggestions_refuses_what_cannot_be_right(self):
        self.bank_status()
        cookie = self.sign_in()
        key = "sk-ant-api03-" + "x" * 40
        for form, text in ((f"provider=gemini&key={key}&model=gemini-2.5-flash", b"That is an Anthropic key"),
                           ("provider=anthropic&key=AIzaSyA" + "x" * 30 + "&model=", b"That is a Gemini key"),
                           ("provider=anthropic&key=short&model=", b"at least 16"),
                           ("provider=gemini&key=" + "y" * 39 + "&model=", b"A gemini-* model"),
                           (f"provider=openai&key={key}&model=", b"Anthropic or Gemini")):
            resp = self.call("POST", "/suggestions", form, cookie=cookie)
            self.assertEqual(resp.status, 400, form)
            self.assertIn(text, resp.body)
            self.assertNotIn(b"x" * 30, resp.body)  # the key is never written back
        self.assertEqual(self.requests(), [])

    def test_suggestions_hands_the_key_to_the_agent(self):
        self.bank_status()
        cookie = self.sign_in()
        key = "sk-ant-api03-" + "k" * 40
        location, request = self.request_of(
            self.call("POST", "/suggestions", f"provider=anthropic&key={key}&model=gemini-2.5-flash", cookie=cookie))
        # A gemini model with an Anthropic key: the default Anthropic one instead.
        self.assertEqual({k: request[k] for k in ("action", "code", "provider", "key", "model")},
                         {"action": "suggestions", "code": "7K2MQ9TB0XH4PVRA", "provider": "anthropic", "key": key,
                          "model": "claude-haiku-5-5"})
        self.assertIn(b"Checking the key", self.call("GET", location, cookie=cookie).body)
        rid = location.rsplit("/", 1)[1]
        self.bank_status(requests={rid: {"state": "applied", "action": "suggestions", "at": "2026-11-06T12:00:00Z",
                                         "message": "Saved: anthropic has claude-haiku-5-5 for this key."}})
        page = self.call("GET", location, cookie=cookie).body
        self.assertIn(b'href="/alerts">Next: Alerts', page)
        self.assertNotIn(key.encode(), page)

    def test_alerts_page(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/alerts", cookie=cookie).body.decode()
        topic = re.search(r'name="url" value="(https://ntfy\.sh/firefly-pocket-([a-z0-9]{24}))"', page)
        self.assertIsNotNone(topic)
        self.assertNotEqual(topic.group(1), re.search(r'name="url" value="([^"]+)"',
                                                       self.call("GET", "/alerts", cookie=cookie).body.decode()).group(1))
        self.assertIn('action="/alerts/healthchecks"', page)
        self.assertNotIn('action="/alerts/test"', page)  # no topic kept yet
        self.assertEqual(self.call("POST", "/alerts/test", "", cookie=cookie).status, 409)
        self.bank_status(alerts={"ntfy": "…3xq1", "healthchecks": True})
        page = self.call("GET", "/alerts", cookie=cookie).body.decode()
        for want in ("<code>…3xq1</code>", 'action="/alerts/test"', "Send no alerts to ntfy", "Both checks are made",
                     "Make them again"):
            self.assertIn(want, page)
        self.assertEqual(self.requests(), [])

    def test_alerts_hands_requests_to_the_agent(self):
        self.bank_status(alerts={"ntfy": "…3xq1", "healthchecks": False})
        cookie = self.sign_in()
        resp = self.call("POST", "/alerts/ntfy", "url=ntfy.sh%2Fno+scheme", cookie=cookie)
        self.assertEqual(resp.status, 400)
        resp = self.call("POST", "/alerts/healthchecks", "key=short", cookie=cookie)
        self.assertEqual(resp.status, 400)
        self.assertEqual(self.requests(), [])
        topic = "https://ntfy.sh/firefly-pocket-" + "a" * 24
        for path, form, want in (("/alerts/ntfy", f"url={quote(topic)}", {"action": "ntfy", "url": topic}),
                                 ("/alerts/ntfy", "url=", {"action": "ntfy", "url": ""}),
                                 ("/alerts/test", "", {"action": "ntfy_test"}),
                                 ("/alerts/healthchecks", "key=" + "h" * 32, {"action": "healthchecks", "key": "h" * 32})):
            location, request = self.request_of(self.call("POST", path, form, cookie=cookie))
            self.assertEqual({k: request[k] for k in want}, want)
            self.assertEqual(request["code"], "7K2MQ9TB0XH4PVRA")
            rid = location.rsplit("/", 1)[1]
            self.bank_status(alerts={"ntfy": "…3xq1", "healthchecks": False}, requests={rid: {
                "state": "applied", "action": want["action"], "at": "2026-11-06T12:00:00Z", "message": "Done."}})
            self.assertIn(b'href="/alerts">Back', self.call("GET", location, cookie=cookie).body)

    def test_finish_lists_suggestions_and_alerts(self):
        self.bank_status(app_id=APP_ID, suggestions={"anthropic": "…wxyz", "gemini": "", "model": "claude-haiku-5-5"},
                         alerts={"ntfy": "…3xq1", "healthchecks": True})
        page = self.call("GET", "/finish", cookie=self.sign_in()).body.decode()
        self.assertIn("Anthropic's key, <code>…wxyz</code>, for <code>claude-haiku-5-5</code>", page)
        self.assertIn("ntfy, <code>…3xq1</code>, and healthchecks.io's two checks", page)
        self.assertNotIn("<code>suggestions</code>:", page)
        self.assertIn("scripts/firefly-pocket setup backups", page)
        self.assertIn('<a href="/backups">Backups</a>', page)
        for name in ("Server", "Firefly III account", "Bank connection", "Suggestions", "Alerts"):
            self.assertIn(f'<li class="done"><a href=', page)
            self.assertRegex(page, rf'<li class="done"><a href="/[a-z]+">{name}</a>')

    # ------------------------------------------------------------ backups ---
    def shown_password(self, page: str) -> str:
        match = re.search(r'<p class="password"><code>([A-Za-z0-9]+)</code></p>', page)
        self.assertIsNotNone(match, page[:2000])
        self.assertIn(f'name="new_password" value="{match.group(1)}"', page)
        return match.group(1)

    def test_backups_page(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/backups", cookie=cookie).body.decode()
        for want in ('aria-current="step">Backups', 'name="mode" value="new" checked', 'name="saved" value="yes"',
                     "Skip it for now", "setup backups", 'name="secret_access_key" type="password"'):
            self.assertIn(want, page)
        self.assertNotIn("not installed", page)
        self.assertNotRegex(page, r'name="secret_access_key"[^>]*required')  # for S3 only
        self.assertRegex(page, r'name="repository"[^>]*placeholder="s3:https://')
        password = self.shown_password(page)
        self.assertEqual(len(password), 32)
        # The same until the server has made a repository with it.
        self.assertEqual(self.shown_password(self.call("GET", "/backups", cookie=cookie).body.decode()), password)
        self.bank_status(backups={"repository": "s3:https://s3.example.com/bucket/fp", "access_key_id": "…KEY1",
                                  "secret_access_key": "…cret", "restic": True})
        page = self.call("GET", "/backups", cookie=cookie).body.decode()
        for want in ("backs up to <code>s3:https://s3.example.com/bucket/fp</code>", "Another repository, or new keys",
                     'value="s3:https://s3.example.com/bucket/fp"', 'name="mode" value="existing" checked',
                     "Empty keeps this server&#x27;s, …cret.", "<code>…KEY1</code>", "Next: Updates"):
            self.assertIn(want, page)
        self.assertNotIn("Skip it for now", page)
        self.bank_status(backups={"repository": "rest:https://me:…@backup.example.com/", "restic": False})
        page = self.call("GET", "/backups", cookie=cookie).body.decode()
        self.assertIn("restic is not installed on this server", page)
        self.assertNotIn('value="rest:https://me:…@backup.example.com/"', page)  # not sent back with the … in it

    def test_backups_refuses_what_cannot_be_right(self):
        self.bank_status()
        cookie = self.sign_in()
        password = self.shown_password(self.call("GET", "/backups", cookie=cookie).body.decode())
        s3 = "repository=s3%3Ahttps%3A%2F%2Fs3.example.com%2Fb%2Ffp"
        for form, text in (("repository=&mode=existing&password=x", "A restic repository, without spaces"),
                           ("repository=a+b&mode=existing&password=x", "A restic repository, without spaces"),
                           (f"{s3}&mode=existing&password=x", "S3 needs it"),
                           (f"{s3}&access_key_id=a+b&secret_access_key=c&mode=existing&password=x", "No spaces"),
                           (f"repository=%2Fsrv%2Frestic&mode=new&new_password={password}", "Keep it first"),
                           ("repository=%2Fsrv%2Frestic&mode=new&new_password=short&saved=yes", "not one this page made"),
                           ("repository=%2Fsrv%2Frestic&mode=existing&password=", "Its password"),
                           ("repository=%2Fsrv%2Frestic&mode=existing&password=a%01b", "No control characters"),
                           ("repository=%2Fsrv%2Frestic&mode=both", "A new repository, or one restic uses already")):
            resp = self.call("POST", "/backups", form, cookie=cookie)
            self.assertEqual(resp.status, 400, form)
            self.assertIn(text, resp.body.decode(), form)
        self.assertEqual(self.requests(), [])
        # The page after an error shows the password it showed before.
        self.assertIn(f"<code>{password}</code>", resp.body.decode())

    def test_backups_hands_requests_to_the_agent(self):
        self.bank_status()
        cookie = self.sign_in()
        password = self.shown_password(self.call("GET", "/backups", cookie=cookie).body.decode())
        location, request = self.request_of(self.call(
            "POST", "/backups", f"repository=%2Fsrv%2Frestic&mode=new&new_password={password}&saved=yes", cookie=cookie))
        self.assertEqual({k: request[k] for k in ("action", "repository", "mode", "password", "access_key_id",
                                                   "secret_access_key")},
                         {"action": "backups", "repository": "/srv/restic", "mode": "new", "password": password,
                          "access_key_id": "", "secret_access_key": ""})
        rid = location.rsplit("/", 1)[1]
        # Refused: the same password, to keep, next time too.
        self.bank_status(requests={rid: {"state": "refused", "action": "backups", "at": "2026-11-06T12:00:00Z",
                                         "message": "restic could not make it: permission denied"}})
        page = self.call("GET", location, cookie=cookie).body.decode()
        self.assertIn("permission denied", page)
        self.assertIn('href="/backups"', page)
        self.assertEqual(self.shown_password(self.call("GET", "/backups", cookie=cookie).body.decode()), password)
        location, _ = self.request_of(self.call(
            "POST", "/backups", f"repository=%2Fsrv%2Frestic&mode=new&new_password={password}&saved=yes", cookie=cookie))
        rid = location.rsplit("/", 1)[1]
        # Made: the password is not shown again.
        self.bank_status(requests={rid: {"state": "applied", "action": "backups", "at": "2026-11-06T12:01:00Z",
                                         "message": "Saved: restic made the repository, with the password you kept."}},
                         backups={"repository": "/srv/restic", "restic": True})
        page = self.call("GET", location, cookie=cookie).body.decode()
        self.assertIn("Next: Updates", page)
        self.assertNotIn(password, page)
        self.assertNotIn(password, self.call("GET", "/backups", cookie=cookie).body.decode())
        # One restic uses already, S3 with the server's keys: an empty password is this server's.
        self.bank_status(backups={"repository": "s3:https://s3.example.com/b/fp", "access_key_id": "…KEY1",
                                  "secret_access_key": "…cret", "restic": True})
        _, request = self.request_of(self.call(
            "POST", "/backups", "repository=s3%3Ahttps%3A%2F%2Fs3.example.com%2Fb%2Fother&mode=existing&password=",
            cookie=cookie))
        self.assertEqual({k: request[k] for k in ("repository", "mode", "password", "access_key_id", "secret_access_key")},
                         {"repository": "s3:https://s3.example.com/b/other", "mode": "existing", "password": "",
                          "access_key_id": "", "secret_access_key": ""})

    def test_finish_lists_backups(self):
        self.bank_status(backups={"repository": "s3:https://s3.example.com/b/fp", "restic": True})
        page = self.call("GET", "/finish", cookie=self.sign_in()).body.decode()
        self.assertIn("each night to <code>s3:https://s3.example.com/b/fp</code>", page)
        self.assertNotIn("setup backups", page)
        self.assertRegex(page, r'<li class="done"><a href="/backups">Backups</a>')

    # ------------------------------------------------------------ updates ---
    def test_updates_page(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/updates", cookie=cookie).body.decode()
        for want in ('aria-current="step">Updates', f"from <code>{ORIGIN}</code>", "<code>stable</code>", "nothing runs on a schedule",
                     'action="/updates"', "Turn on the deploy agent", "sudo without a password", "Skip it for now",
                     "setup updates"):
            self.assertIn(want, page)
        self.assertNotIn("over SSH for now", page)
        self.bank_status(updates={"agent": True, "origin": ORIGIN, "channel": "stable", "version": "1.2.0"})
        page = self.call("GET", "/updates", cookie=cookie).body.decode()
        self.assertIn(f"The deploy agent is on: this server follows <code>stable</code> of <code>{ORIGIN}</code>, and runs <code>1.2.0</code>.", page)
        self.bank_status(updates={"agent": True, "origin": ORIGIN})
        page = self.call("GET", "/updates", cookie=cookie).body.decode()
        self.assertIn(f"this server follows <code>latest</code> of <code>{ORIGIN}</code>.", page)
        self.assertIn("Next: Finish", page)
        self.assertNotIn('action="/updates"', page)

    def test_updates_hands_the_request_to_the_agent(self):
        self.bank_status()
        cookie = self.sign_in()
        location, request = self.request_of(self.call("POST", "/updates", "", cookie=cookie))
        self.assertEqual({k: request[k] for k in ("action", "code")}, {"action": "updates", "code": "7K2MQ9TB0XH4PVRA"})
        rid = location.rsplit("/", 1)[1]
        self.assertIn(b"Turning on the deploy agent", self.call("GET", location, cookie=cookie).body)
        self.bank_status(requests={rid: {"state": "refused", "action": "updates", "at": "2026-11-06T12:00:00Z",
                                         "message": "this server's user has no sudo without a password"}})
        page = self.call("GET", location, cookie=cookie).body.decode()
        self.assertIn("<h1>Not turned on</h1>", page)
        self.assertIn('href="/updates"', page)
        self.bank_status(requests={rid: {"state": "applied", "action": "updates", "at": "2026-11-06T12:00:00Z",
                                         "message": "The deploy agent is on."}}, updates={"agent": True, "origin": ORIGIN})
        page = self.call("GET", location, cookie=cookie).body.decode()
        self.assertIn("<h1>Turned on</h1>", page)
        self.assertIn("Next: Finish", page)

    def test_updates_page_shows_the_channel(self):
        self.bank_status()
        cookie = self.sign_in()
        page = self.call("GET", "/updates", cookie=cookie).body.decode()
        self.assertIn('action="/updates/channel"', page)
        self.assertIn('value="stable" checked', page)  # what turning the agent on here sets
        self.bank_status(updates={"agent": True, "origin": ORIGIN})
        page = self.call("GET", "/updates", cookie=cookie).body.decode()
        self.assertIn('value="latest" checked', page)  # an agent from before channels follows master
        self.bank_status(updates={"agent": True, "origin": ORIGIN, "channel": "1.4.2"})
        page = self.call("GET", "/updates", cookie=cookie).body.decode()
        self.assertIn('value="version" checked', page)
        self.assertIn('name="release" value="1.4.2"', page)

    def test_channel_hands_the_request_to_the_agent(self):
        self.bank_status()
        cookie = self.sign_in()
        for form, want in (("channel=latest", "latest"), ("channel=stable&release=9.9.9", "stable"),
                           ("channel=version&release=1.4.2", "1.4.2"), ("channel=version&release=v2.0.0", "2.0.0")):
            location, request = self.request_of(self.call("POST", "/updates/channel", form, cookie=cookie))
            self.assertEqual({k: request[k] for k in ("action", "channel")}, {"action": "channel", "channel": want})
        self.assertIn(b"Saving the channel", self.call("GET", location, cookie=cookie).body)

    def test_channel_refuses_what_is_no_channel(self):
        self.bank_status()
        cookie = self.sign_in()
        for form, error in (("channel=master", "Stable, latest or one release"), ("", "Stable, latest or one release"),
                            ("channel=version&release=1.4", "A release such as 1.4.2"),
                            ("channel=version&release=01.4.2", "A release such as 1.4.2"),
                            ("channel=version", "A release such as 1.4.2")):
            response = self.call("POST", "/updates/channel", form, cookie=cookie)
            self.assertEqual(response.status, 400, form)
            self.assertIn(error, response.body.decode())
        self.assertEqual(os.listdir(self.inbox), [])

    def test_finish_lists_every_step(self):
        self.bank_status(app_id=APP_ID, suggestions={"anthropic": "…wxyz", "gemini": "", "model": "claude-haiku-5-5"},
                         alerts={"ntfy": "…3xq1", "healthchecks": True},
                         backups={"repository": "/srv/restic", "restic": True}, updates={"agent": True, "origin": ORIGIN})
        page = self.call("GET", "/finish", cookie=self.sign_in()).body.decode()
        self.assertIn("the deploy agent is on", page)
        self.assertNotIn("Left for the server", page)
        self.assertNotIn('class="bad"', page)
        for name in ("Server", "Firefly III account", "Bank connection", "Suggestions", "Alerts", "Backups", "Updates"):
            self.assertRegex(page, rf'<li class="done"><a href="/[a-z]+">{name}</a>')

    # ------------------------------------------------------ after setup ---
    def finished_status(self, client_id=CLIENT_ID, **extra):
        self.bank_status(**extra)
        state = json.loads(self.status.read_text())
        state.update(setup_done=True, signin={"client_id": client_id})
        self.status.write_text(json.dumps(state))

    def start_signin(self, app) -> tuple[dict, str]:
        resp = self.call("GET", "/signin", app=app)
        self.assertEqual(resp.status, 303, resp.body[:300])
        url = urlsplit(dict(resp.headers)["Location"])
        self.assertEqual((url.scheme, url.netloc, url.path), ("https", "firefly.fx.example.com", "/oauth/authorize"))
        cookie = dict(resp.headers)["Set-Cookie"]
        self.assertIn("SameSite=Lax", cookie)
        return {k: v[0] for k, v in parse_qs(url.query).items()}, cookie.split(";")[0]

    def signed_in_owner(self, fake: FakeFirefly) -> str:
        app = self.make(code="", firefly=fake)
        query, signin = self.start_signin(app)
        fake.challenge = query["code_challenge"]
        resp = self.call("GET", "/oauth/callback?" + urlencode({"code": "the-code", "state": query["state"]}),
                         cookie=signin, app=app)
        self.assertEqual(resp.status, 303, resp.body[:600])
        self.assertEqual(dict(resp.headers)["Location"], "/")
        cookies = [v for k, v in resp.headers if k == "Set-Cookie"]
        self.assertTrue(any(c.startswith("__Host-console-signin=;") for c in cookies), cookies)
        session = [c for c in cookies if c.startswith("__Host-console=")][0]
        self.assertIn("SameSite=Lax", session)
        self.app = app
        return session.split(";")[0]

    def test_after_setup_it_offers_the_sign_in(self):
        self.finished_status()
        page = self.call("GET", "/", app=self.make(code="")).body.decode()
        self.assertIn("Setup is finished", page)
        self.assertIn('href="/signin"', page)
        self.assertNotIn("<nav", page)
        self.finished_status(client_id="")
        page = self.call("GET", "/", app=self.make(code="")).body.decode()
        self.assertIn("console client", page)
        self.assertNotIn('href="/signin"', page)
        self.assertEqual(self.call("GET", "/signin", app=self.make(code="")).status, 503)

    def test_sign_in_with_firefly_iii(self):
        self.finished_status()
        fake = FakeFirefly()
        app = self.make(code="", firefly=fake)
        query, _ = self.start_signin(app)
        self.assertEqual({k: query[k] for k in ("client_id", "redirect_uri", "response_type", "code_challenge_method")},
                         {"client_id": CLIENT_ID, "redirect_uri": f"https://{HOST}/oauth/callback",
                          "response_type": "code", "code_challenge_method": "S256"})
        self.assertGreaterEqual(len(query["state"]), 24)
        session = self.signed_in_owner(fake)
        page = self.call("GET", "/", cookie=session).body.decode()
        for want in ("<h1>Your server</h1>", "Signed in with Firefly III as you@example.com", 'action="/logout"',
                     '<a href="/bank">Bank connection</a>', '<a href="/updates">Updates</a>', "eight hours"):
            self.assertIn(want, page)
        self.assertIn('<li class="now" aria-current="page">Your server</li>', page)
        # The Server step and the account are done: no page to change them.
        self.assertNotIn('<a href="/server">', page)
        self.assertNotIn('<a href="/account">', page)
        # The token was asked for with no secret, and checked against the account.
        self.assertEqual([c[2] for c in fake.calls], ["/oauth/token", "/api/v1/about/user"])
        self.assertNotIn("client_secret", fake.calls[0][3])
        self.assertEqual(fake.calls[1][4], "ff-access")
        # Signed out: where things are, and the sign-in again; Firefly III is
        # asked to revoke the token.
        self.assertEqual(self.call("POST", "/logout", cookie=session).status, 303)
        self.assertIn("Setup is finished", self.call("GET", "/", cookie=session).body.decode())
        [request] = [json.loads(f.read_text()) for f in self.requests()]
        self.assertEqual({k: request.get(k) for k in ("action", "token", "code")},
                         {"action": "signout", "token": "ff-access", "code": None})

    def test_after_setup_the_owner_changes_steps(self):
        self.finished_status(key=True, certificate=CERT, app_id=APP_ID)
        session = self.signed_in_owner(FakeFirefly())
        page = self.call("GET", "/bank", cookie=session).body.decode()
        self.assertIn('action="/bank/key"', page)
        self.assertIn('<nav class="steps" aria-label="Your server">', page)
        self.assertIn('<a href="/">Your server</a>', page)
        self.assertNotIn('href="/server"', page)
        self.assertNotIn('href="/finish"', page)
        self.assertEqual(self.call("GET", "/bank/certificate", cookie=session).body.decode(), CERT)
        # A new key: the request carries the owner's Firefly III token, for the
        # agent to check with Firefly III, and not the setup code.
        location, request = self.request_of(self.call("POST", "/bank/key", "", cookie=session))
        self.assertEqual(request["action"], "bank_key")
        self.assertEqual(request["token"], "ff-access")
        self.assertNotIn("code", request)
        rid = location.rsplit("/", 1)[1]
        self.assertIn(b"Making the key", self.call("GET", location, cookie=session).body)
        self.finished_status(key=True, certificate=CERT, requests={rid: {
            "state": "refused", "action": "bank_key", "at": "2026-11-06T12:00:00Z",
            "message": "That sign-in is more than eight hours old"}})
        page = self.call("GET", location, cookie=session).body.decode()
        self.assertIn("more than eight hours old", page)
        self.assertIn('<nav class="steps" aria-label="Your server">', page)
        self.assertIn('<li class="now" aria-current="page">Bank connection</li>', page)
        # An old Server request, opened after setup: the overview is the current item.
        self.finished_status(requests={rid: {"state": "applied", "action": "server", "message": "Saved.",
                                             "at": "2026-11-06T12:00:00Z"}})
        page = self.call("GET", location, cookie=session).body.decode()
        self.assertIn('<li class="now" aria-current="page">Your server</li>', page)
        self.assertNotIn("Back to setup", page)
        # The other steps' pages, and their requests, the same way.
        for path in ("/suggestions", "/alerts", "/backups", "/updates"):
            self.assertEqual(self.call("GET", path, cookie=session).status, 200, path)
        location, request = self.request_of(self.call("POST", "/updates", "", cookie=session))
        self.assertEqual((request["action"], request["token"]), ("updates", "ff-access"))
        rid = location.rsplit("/", 1)[1]
        self.finished_status(updates={"agent": True, "origin": ORIGIN}, requests={rid: {
            "state": "applied", "action": "updates", "at": "2026-11-06T12:00:00Z", "message": "The deploy agent is on."}})
        page = self.call("GET", location, cookie=session).body.decode()
        self.assertIn('<a class="button" href="/">Your server</a>', page)
        self.assertNotIn("Next:", page)
        self.assertIn("Next: Your server", self.call("GET", "/updates", cookie=session).body.decode())
        # What is done stays done: the overview.
        for path in ("/server", "/account", "/finish", "/elsewhere"):
            self.assertEqual(dict(self.call("GET", path, cookie=session).headers)["Location"], "/", path)
        self.assertEqual(dict(self.call("POST", "/finish", "", cookie=session).headers)["Location"], "/")
        self.assertEqual(len(self.requests()), 2)

    def test_after_setup_nothing_changes_without_the_sign_in(self):
        self.bank_status()
        cookie = self.sign_in()
        self.finished_status()
        for path, body in (("/bank/key", ""), ("/updates", ""), ("/suggestions", "provider=anthropic&key=x")):
            resp = self.call("POST", path, body, cookie=cookie)
            self.assertIn("Setup is finished", resp.body.decode(), path)
        self.assertIn("Setup is finished", self.call("GET", "/bank", cookie=cookie).body.decode())
        self.assertEqual(self.requests(), [])
        # Nor from another site, signed in.
        session = self.signed_in_owner(FakeFirefly())
        resp = self.call("POST", "/bank/key", "", cookie=session, origin="https://evil.example")
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.requests(), [])

    def test_importer_is_behind_the_console_sign_in(self):
        # During setup, the setup code's session lets Caddy through to the importer.
        self.bank_status()
        resp = self.call("GET", "/auth/importer", origin=None)
        self.assertEqual((resp.status, dict(resp.headers)["Location"]), (303, "/"))
        cookie = self.sign_in()
        self.assertEqual(self.call("GET", "/auth/importer", cookie=cookie, origin=None).status, 204)
        # Only GET: forward_auth asks with it.
        self.assertNotEqual(self.call("POST", "/auth/importer", cookie=cookie).status, 204)
        # After setup that session does no more; Firefly III's owner does, for eight hours.
        self.finished_status()
        resp = self.call("GET", "/auth/importer", cookie=cookie, origin=None)
        self.assertEqual((resp.status, dict(resp.headers)["Location"]), (303, "/"))
        session = self.signed_in_owner(FakeFirefly())
        self.assertEqual(self.call("GET", "/auth/importer", cookie=session, origin=None).status, 204)
        self.assertIn('href="/importer/"', self.call("GET", "/", cookie=session).body.decode())
        self.clock.now += console.SESSION_SECONDS + 1
        self.assertEqual(self.call("GET", "/auth/importer", cookie=session, origin=None).status, 303)

    def test_owner_session_ends_after_eight_hours(self):
        self.finished_status()
        session = self.signed_in_owner(FakeFirefly())
        self.assertEqual(self.call("GET", "/bank", cookie=session).status, 200)
        self.clock.now += console.SESSION_SECONDS + 1
        self.assertIn("Setup is finished", self.call("GET", "/bank", cookie=session).body.decode())

    def test_sign_in_is_for_the_owner_only(self):
        self.finished_status()
        fake = FakeFirefly(email="someone@example.com")
        app = self.make(code="", firefly=fake)
        query, signin = self.start_signin(app)
        fake.challenge = query["code_challenge"]
        resp = self.call("GET", "/oauth/callback?" + urlencode({"code": "the-code", "state": query["state"]}),
                         cookie=signin, app=app)
        self.assertEqual(resp.status, 403)
        self.assertIn("someone@example.com", resp.body.decode())
        self.assertIn("you@example.com", resp.body.decode())
        self.assertFalse([v for k, v in resp.headers if k == "Set-Cookie" and v.startswith("__Host-console=")])

    def test_sign_in_needs_its_own_state(self):
        self.finished_status()
        fake = FakeFirefly()
        app = self.make(code="", firefly=fake)
        query, signin = self.start_signin(app)
        fake.challenge = query["code_challenge"]
        callback = "/oauth/callback?" + urlencode({"code": "the-code", "state": query["state"]})
        # Another browser's, or none.
        self.assertEqual(self.call("GET", callback, cookie="__Host-console-signin=other", app=app).status, 400)
        query, signin = self.start_signin(app)
        fake.challenge = query["code_challenge"]
        self.assertEqual(self.call("GET", "/oauth/callback?code=the-code&state=made-up", cookie=signin, app=app).status,
                         400)
        # Ten minutes: then it starts again.
        self.clock.now += 601
        callback = "/oauth/callback?" + urlencode({"code": "the-code", "state": query["state"]})
        self.assertEqual(self.call("GET", callback, cookie=signin, app=app).status, 400)
        self.assertEqual(fake.calls, [])  # Firefly III was never asked

    def test_sign_in_when_firefly_iii_says_no(self):
        self.finished_status()
        fake = FakeFirefly()
        app = self.make(code="", firefly=fake)
        query, signin = self.start_signin(app)
        resp = self.call("GET", "/oauth/callback?" + urlencode({"error": "access_denied", "state": query["state"],
                                                                "error_description": "The user denied the request."}),
                         cookie=signin, app=app)
        self.assertEqual(resp.status, 403)
        self.assertIn("The user denied the request.", resp.body.decode())
        query, signin = self.start_signin(app)
        fake.challenge = "not-this-one"
        resp = self.call("GET", "/oauth/callback?" + urlencode({"code": "the-code", "state": query["state"]}),
                         cookie=signin, app=app)
        self.assertEqual(resp.status, 502)
        self.assertIn("HTTP 400", resp.body.decode())

    def test_the_setup_code_opens_nothing_after_setup(self):
        self.bank_status()
        cookie = self.sign_in()
        self.finished_status()
        page = self.call("GET", "/", cookie=cookie).body.decode()
        self.assertIn("Setup is finished", page)
        self.assertNotIn("Your server", page)

    def test_no_code(self):
        resp = self.call("GET", "/", app=self.make(code=""))
        self.assertEqual(resp.status, 503)
        self.assertIn(b"setup web", resp.body)
        # An empty code never signs anyone in.
        self.assertEqual(self.call("POST", "/login", "code=", app=self.make(code="")).status, 503)

    def test_values_are_escaped(self):
        self.write_status(settings={"DOMAIN": "fx.example.com", "SITE_OWNER": '"><script>x</script>',
                                    "LEGAL_OWNER_NAME": "", "TZ": "", "ADMIN_HOSTNAME": ""})
        page = self.call("GET", "/server", cookie=self.sign_in()).body
        self.assertNotIn(b"<script>", page)
        self.assertIn(b"&lt;script&gt;", page)


class ServerTest(unittest.TestCase):
    """The HTTP side: what a browser gets through Caddy."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        app = Console(code=CODE, inbox=Path(self.tmp.name), status_file=Path(self.tmp.name) / "s.json",
                      timezones=[], fail_delay=0, check_names=lambda names, v4, v6: [])

        class Handler(console.Handler):
            pass

        Handler.console = app
        Handler.log_message = lambda *a: None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        try:
            conn.request(method, path, body=body, headers={"Host": HOST, **(headers or {})})
            resp = conn.getresponse()
            return resp.status, dict(resp.getheaders()), resp.read()
        finally:
            conn.close()

    def test_headers(self):
        status, headers, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Referrer-Policy"], "same-origin")  # no-referrer would null the forms' Origin
        self.assertEqual(int(headers["Content-Length"]), len(body))
        self.assertNotIn("Python", headers.get("Server", ""))

    def test_login_over_http(self):
        status, headers, _ = self.request(
            "POST", "/login", f"code={CODE}",
            {"Content-Type": "application/x-www-form-urlencoded", "Origin": f"https://{HOST}"})
        self.assertEqual(status, 303)
        self.assertTrue(headers["Set-Cookie"].startswith("__Host-console="))

    def test_too_large(self):
        status, _, _ = self.request("POST", "/login", "x" * (console.MAX_BODY + 1), {"Origin": f"https://{HOST}"})
        self.assertEqual(status, 413)

    def test_head(self):
        status, headers, body = self.request("HEAD", "/health")
        self.assertEqual((status, body), (200, b""))
        self.assertEqual(headers["Content-Length"], "3")


if __name__ == "__main__":
    unittest.main(verbosity=2)
