"""Tests of the Firefly Pocket Console (services/console/console.py).

CI runs them in the image compose runs the console on, the way compose runs it:

    python -I -B test_console.py

-I leaves this directory off sys.path, so it is put there below.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import stat
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import console  # noqa: E402
from console import Console, NameCheck, Request, check, dns_verdict, normalize_code  # noqa: E402

CODE = "7K2M-Q9TB-0XH4-PVRA"
HOST = "admin.fx.example.com"


class Clock:
    def __init__(self, now: float = 1_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


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
            setup_done=False, code=CODE, inbox=self.inbox, status_file=self.status,
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

    def test_asks_for_the_code(self):
        resp = self.call("GET", "/")
        self.assertEqual(resp.status, 200)
        self.assertIn(b'name="code"', resp.body)
        # Every other page too, until signed in.
        self.assertIn(b'name="code"', self.call("GET", "/server").body)

    def test_right_code_in_any_spelling(self):
        resp = self.call("POST", "/login", "code=7k2m+q9tb+oxh4+pvra")
        self.assertEqual(resp.status, 303)
        cookie = dict(resp.headers)["Set-Cookie"]
        self.assertTrue(cookie.startswith("__Host-console="))
        for attribute in ("Path=/", "Secure", "HttpOnly", "SameSite=Strict"):
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

    def test_a_refused_request(self):
        self.write_status(requests={"ab" * 16: {"state": "refused", "message": "TZ: an IANA timezone",
                                                "at": "2026-11-06T12:00:00Z"}})
        resp = self.call("GET", f"/requests/{'ab' * 16}", cookie=self.sign_in())
        self.assertIn(b"Not saved", resp.body)
        self.assertIn(b"TZ: an IANA timezone", resp.body)

    def test_a_new_domain_moves_the_console(self):
        self.write_status()
        cookie = self.sign_in()
        resp = self.call("POST", "/server", "domain=pocket.example.org&email=you%40example.com&name=&timezone=Etc%2FUTC",
                         cookie=cookie)
        page = self.call("GET", dict(resp.headers)["Location"], cookie=cookie)
        self.assertEqual(page.status, 202)
        self.assertIn(b"https://admin.pocket.example.org/", page.body)
        self.assertNotIn(b'http-equiv="refresh"', page.body)

    def test_unknown_request(self):
        self.assertEqual(self.call("GET", f"/requests/{'0' * 32}", cookie=self.sign_in()).status, 404)

    def test_inbox_not_writable(self):
        self.inbox.rmdir()
        resp = self.call("POST", "/server", "domain=fx.example.com&email=you%40example.com&name=&timezone=Etc%2FUTC",
                         cookie=self.sign_in())
        self.assertEqual(resp.status, 503)
        self.assertIn(b"compose/console/inbox", resp.body)

    def test_finished_refuses_the_code(self):
        self.write_status()
        app = self.make(setup_done=True)
        resp = self.call("GET", "/", app=app)
        self.assertEqual(resp.status, 200)
        self.assertIn(b"Setup is finished", resp.body)
        self.assertIn(b"https://firefly.fx.example.com/", resp.body)
        resp = self.call("POST", "/login", f"code={CODE}", app=app)
        self.assertIn(b"Setup is finished", resp.body)
        self.assertFalse(any(name == "Set-Cookie" for name, _ in resp.headers))
        resp = self.call("POST", "/server", "domain=evil.example", app=app)
        self.assertEqual(self.requests(), [])

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
        app = Console(setup_done=False, code=CODE, inbox=Path(self.tmp.name), status_file=Path(self.tmp.name) / "s.json",
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
