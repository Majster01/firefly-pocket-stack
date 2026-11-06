#!/usr/bin/env python3
"""Firefly Pocket Console: setup in the browser, on admin.<domain>.

Setup UI step 4. Until Firefly III has its account, every other host sends the
browser here (the Caddyfile's setup gate), and this asks for the setup code
that `scripts/firefly-pocket setup web` printed on the server. Its first page
sets the domain, your email, your name and the timezone, and shows whether each
name points at this server and has its certificate. The rest of setup runs over
SSH for now, until the console takes those steps over too.

It is built so that taking it over gains little:

- It never touches Docker or the settings. Save turns into a request file in
  /inbox, a directory it can add files to but not list; the host agent checks
  each request as `firefly-pocket config set` would, and applies it
  (scripts/console.sh). What it shows comes from /status, which the agent
  writes and which holds no secret.
- The setup code works only until setup is finished: FIREFLY_POCKET_SETUP is
  "done" once the importer has its Firefly III token. After that the console
  only says where things are, and the agent refuses its requests too.
- It shares a network with Caddy only, not with the apps or Postgres.

Standard library only: compose runs it on the stock python image, with this
directory mounted read-only, as an unprivileged user on a read-only root.
"""

from __future__ import annotations

import hmac
import html
import json
import os
import re
import secrets
import signal
import socket
import ssl
import sys
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
LETS_ENCRYPT = "https://acme-v02.api.letsencrypt.org/directory"
# __Host-: the browser keeps it to this host, over HTTPS, for every path.
COOKIE = "__Host-console"
SESSION_SECONDS = 8 * 3600
MAX_BODY = 16 * 1024
# Wrong codes: each costs a second, and more than this many a minute stop all
# tries for the rest of that minute. A code has 80 bits, so this only keeps
# the log quiet.
FAILURES_PER_MINUTE = 10


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- checks ---
# The checks scripts/config.sh makes, so a typo shows before Save. The agent
# checks again with config.sh itself, and that is the one that counts.
DOMAIN_RE = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+")
TIMEZONE_RE = re.compile(r"[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*")
ZONEINFO = Path("/usr/share/zoneinfo")


def check(kind: str, value: str, zoneinfo: Path = ZONEINFO) -> str | None:
    """None when the value passes, else what it should look like."""
    if kind == "domain":
        if len(value) <= 253 and DOMAIN_RE.fullmatch(value):
            return None
        return "a host name in lower case, such as example.com"
    if kind == "email":
        return None if EMAIL_RE.fullmatch(value) else "an email address, such as you@example.com"
    if kind == "text":
        if (
            len(value) > 200
            or any(c in '$\\#"' for c in value)
            or value[:1].isspace()
            or value[:1] == "'"
            or value[-1:].isspace()
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
        ):
            return 'plain text up to 200 characters, without $, \\, # or ", and no space at either end'
        return None
    if kind == "timezone":
        if TIMEZONE_RE.fullmatch(value) and (not zoneinfo.is_dir() or (zoneinfo / value).is_file()):
            return None
        return "an IANA timezone, such as Europe/Ljubljana"
    raise ValueError(f"no check called {kind}")


@dataclass(frozen=True)
class Field:
    key: str  # the setting
    name: str  # the form field
    label: str
    kind: str
    required: bool
    help: str


# Step 1, as `firefly-pocket setup` asks it in its domain and you steps.
SERVER_FIELDS = (
    Field(
        "DOMAIN", "domain", "Domain", "domain", True,
        "Firefly Pocket answers on five names under it. A subdomain of yours works too, "
        "such as money.example.com.",
    ),
    Field(
        "SITE_OWNER", "email", "Your email", "email", True,
        "Your Firefly III account's, Let's Encrypt's for certificate notices, the push "
        "services' contact, and the legal pages'.",
    ),
    Field(
        "LEGAL_OWNER_NAME", "name", "Your name", "text", False,
        "The operator the privacy policy and terms name; Enable Banking's reviewers read "
        "them. Empty: “the operator of this server”.",
    ),
    Field(
        "TZ", "timezone", "Timezone", "timezone", True,
        "The nightly jobs run in it: the backup at 02:00, the import at 03:00.",
    ),
)

# The setup's steps, as the CLI wizard has them. Only the first is here so far.
STEPS = (
    "Server",
    "Firefly III account",
    "Bank connection",
    "Suggestions",
    "Alerts",
    "Backups",
    "Updates",
)

ROLES = {
    "admin": "this console",
    "firefly": "Firefly III",
    "app": "Firefly Pocket",
    "import": "the bank importer",
    "legal": "the privacy policy and terms",
}


def normalize(f: Field, value: str) -> str:
    value = value.strip()
    if f.kind == "domain":
        value = value.lower().rstrip(".")
    return value


def normalize_code(text: str) -> str:
    """The code as typed, in any case, with or without its dashes; O, I and L
    read as 0, 1 and 1, as Crockford's base32 has it."""
    text = text.upper().translate(str.maketrans("OIL", "011"))
    return re.sub(r"[\s-]+", "", text)


# ------------------------------------------------------- names and certs ---
PRIVATE_V4 = re.compile(
    r"(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)"
)


def is_localhost(host: str) -> bool:
    return host == "localhost" or host.endswith(".localhost")


def resolve(host: str) -> tuple[list[str], list[str]]:
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except (socket.gaierror, UnicodeError):
        return [], []
    v4 = sorted({i[4][0] for i in infos if i[0] == socket.AF_INET})
    v6 = sorted({i[4][0] for i in infos if i[0] == socket.AF_INET6 and not i[4][0].startswith("::ffff:")})
    return v4, v6


def dns_verdict(host: str, v4s: list[str], v6s: list[str], mine_v4: str, mine_v6: str) -> tuple[bool, str]:
    """Each name resolves, and only to this server: Let's Encrypt tries every
    address a name has, IPv6 first. Behind NAT it can only be seen to resolve."""
    if is_localhost(host):
        return True, "this machine"
    if not v4s and not v6s:
        return False, "does not resolve yet"
    nat = not mine_v4 or bool(PRIVATE_V4.match(mine_v4))
    problems = []
    for addr in v4s:
        if not nat and addr != mine_v4:
            problems.append(f"points to {addr}, but this server is {mine_v4}")
    for addr in v6s:
        if not mine_v6:
            problems.append(f"has the IPv6 address {addr}, but this server has none: remove that AAAA record")
        elif addr != mine_v6:
            problems.append(f"points to {addr}, but this server's IPv6 address is {mine_v6}")
    if problems:
        return False, "; ".join(problems)
    if nat:
        return True, f"resolves to {', '.join(v4s + v6s)}; this server is behind NAT, so its certificate is the check"
    return True, "points here"


def certificate(host: str, caddy: tuple[str, int], timeout: float = 5.0) -> tuple[bool, str]:
    """Whether Caddy has a trusted certificate for the name: asked directly, on
    the network the two share, and checked against the image's CA bundle."""
    context = ssl.create_default_context()
    try:
        with socket.create_connection(caddy, timeout=timeout) as sock:
            with context.wrap_socket(sock, server_hostname=host) as tls:
                not_after = tls.getpeercert().get("notAfter")
    except ssl.SSLCertVerificationError:
        return False, "none that a browser trusts yet"
    except (OSError, ssl.SSLError):
        return False, "none yet"
    if not not_after:
        return True, "has one"
    until = datetime.fromtimestamp(ssl.cert_time_to_seconds(not_after), timezone.utc)
    return True, f"valid until {until:%Y-%m-%d}"


@dataclass
class NameCheck:
    role: str
    host: str
    dns_ok: bool
    dns: str
    cert_ok: bool | None  # None: not checked
    cert: str


# ------------------------------------------------------------- requests ---
def write_request(inbox: Path, action: str, settings: dict[str, str]) -> str:
    """Hand a request to the host agent: written beside, then renamed into
    place, so the agent never reads half of one (it takes *.json only)."""
    rid = secrets.token_hex(16)
    data = json.dumps(
        {"version": 1, "id": rid, "action": action, "settings": settings, "at": now_iso()}
    ).encode()
    tmp = inbox / f".{rid}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        # The agent runs as another user: it reads this as "others".
        os.fchmod(fd, 0o644)
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, inbox / f"{rid}.json")
    return rid


def read_status(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


# ------------------------------------------------------------- the app ---
@dataclass
class Request:
    method: str
    target: str
    headers: dict[str, str]  # names in lower case
    body: bytes = b""

    @property
    def path(self) -> str:
        return urlsplit(self.target).path

    def form(self) -> dict[str, str]:
        try:
            fields = parse_qs(self.body.decode("utf-8"), keep_blank_values=True, max_num_fields=20)
        except (UnicodeDecodeError, ValueError):
            return {}
        return {k: v[0] for k, v in fields.items()}

    def cookie(self, name: str) -> str:
        # By hand: http.cookies gives up on a whole header for one odd cookie.
        for part in self.headers.get("cookie", "").split(";"):
            key, _, value = part.strip().partition("=")
            if key == name:
                return value
        return ""


@dataclass
class Response:
    status: int
    body: bytes = b""
    content_type: str = "text/html; charset=utf-8"
    headers: list[tuple[str, str]] = field(default_factory=list)


class Console:
    def __init__(
        self,
        *,
        setup_done: bool,
        code: str,
        inbox: Path,
        status_file: Path,
        acme_ca: str = LETS_ENCRYPT,
        caddy: tuple[str, int] = ("caddy", 443),
        timezones: list[str] | None = None,
        clock=time.time,
        fail_delay: float = 1.0,
        check_names=None,
    ):
        self.setup_done = setup_done
        self.code = normalize_code(code)
        self.inbox = inbox
        self.status_file = status_file
        self.acme_ca = acme_ca or LETS_ENCRYPT
        self.caddy = caddy
        self.timezones = timezones if timezones is not None else _timezones()
        self.clock = clock
        self.fail_delay = fail_delay
        self.check_names = check_names or self._check_names
        self.css = (HERE / "console.css").read_bytes()
        self.lock = threading.Lock()
        self.sessions: dict[str, float] = {}
        self.failures: deque[float] = deque()
        self.pending: dict[str, tuple[float, str]] = {}  # request id: (when, the host it moves to)

    @classmethod
    def from_env(cls, env=os.environ) -> Console:
        return cls(
            setup_done=env.get("FIREFLY_POCKET_SETUP") == "done",
            code=env.get("SETUP_CODE", ""),
            inbox=Path(env.get("CONSOLE_INBOX", "/inbox")),
            status_file=Path(env.get("CONSOLE_STATUS", "/status/status.json")),
            acme_ca=env.get("ACME_CA", ""),
        )

    # ------------------------------------------------------------ routing ---
    def handle(self, req: Request) -> Response:
        path = req.path
        if path == "/health":
            return Response(200, b"ok\n", "text/plain; charset=utf-8")
        if path == "/console.css":
            return Response(200, self.css, "text/css; charset=utf-8", [("Cache-Control", "max-age=300")])
        if req.method not in ("GET", "HEAD", "POST"):
            return Response(405, b"", headers=[("Allow", "GET, HEAD, POST")])
        if req.method == "POST" and not same_origin(req):
            return self.page(403, "Refused", "<h1>Refused</h1><p>That form was not sent from this page.</p>")
        if self.setup_done:
            return self.finished()
        if not self.code:
            return self.page(
                503, "Not set up",
                "<h1>This server is not set up yet</h1><p>It has no setup code either. On the server:</p>"
                "<pre>scripts/firefly-pocket setup web</pre>",
            )
        if path == "/login" and req.method == "POST":
            return self.login(req)
        if not self.signed_in(req):
            return self.login_page()
        if path == "/logout" and req.method == "POST":
            return self.logout(req)
        if path == "/":
            return redirect("/server")
        if path == "/server":
            return self.save_server(req) if req.method == "POST" else self.server_page(req)
        match = re.fullmatch(r"/requests/([0-9a-f]{32})", path)
        if match and req.method != "POST":
            return self.request_page(req, match.group(1))
        return self.page(404, "Not found", "<h1>Not found</h1><p><a href=\"/server\">Back to setup</a></p>", signed_in=True)

    # ------------------------------------------------------------ sign in ---
    def signed_in(self, req: Request) -> bool:
        token = req.cookie(COOKIE)
        with self.lock:
            return bool(token) and self.sessions.get(token, 0) > self.clock()

    def login(self, req: Request) -> Response:
        now = self.clock()
        with self.lock:
            while self.failures and self.failures[0] < now - 60:
                self.failures.popleft()
            if len(self.failures) >= FAILURES_PER_MINUTE:
                return self.login_page(429, "Too many wrong codes. Wait a minute, then try again.")
        given = normalize_code(req.form().get("code", ""))
        if not hmac.compare_digest(given.encode(), self.code.encode()):
            with self.lock:
                self.failures.append(now)
            if self.fail_delay:
                time.sleep(self.fail_delay)
            return self.login_page(401, "That is not the code.")
        token = secrets.token_urlsafe(32)
        with self.lock:
            self.sessions = {t: until for t, until in self.sessions.items() if until > now}
            self.sessions[token] = now + SESSION_SECONDS
        cookie = f"{COOKIE}={token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age={SESSION_SECONDS}"
        return redirect("/server", [("Set-Cookie", cookie)])

    def logout(self, req: Request) -> Response:
        with self.lock:
            self.sessions.pop(req.cookie(COOKIE), None)
        return redirect("/", [("Set-Cookie", f"{COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0")])

    def login_page(self, status: int = 200, error: str = "") -> Response:
        body = f"""
<section class="narrow">
  <h1>Setup</h1>
  <p>This server is being set up. Until its Firefly III account exists, this console is all it shows.</p>
  <form method="post" action="/login">
    <label for="code">Setup code</label>
    <input id="code" name="code" required autocomplete="off" autocapitalize="characters" spellcheck="false"
           placeholder="XXXX-XXXX-XXXX-XXXX"{' aria-invalid="true" aria-describedby="code-error"' if error else ''}>
    {f'<p class="error" id="code-error">{esc(error)}</p>' if error else ''}
    <button type="submit">Continue</button>
  </form>
  <p class="quiet">The code is the one <code>scripts/firefly-pocket setup web</code> printed on the server.
  Run it again there to see it.</p>
</section>"""
        return self.page(status, "Setup", body)

    # ------------------------------------------------------------- server ---
    def server_page(self, req: Request, status: int = 200, values=None, errors=None, note: str = "") -> Response:
        state = read_status(self.status_file)
        settings = state.get("settings") if isinstance(state.get("settings"), dict) else {}
        if values is None:
            values = {f.key: str(settings.get(f.key) or "") for f in SERVER_FIELDS}
            if not values["TZ"]:
                values["TZ"] = str(state.get("host_timezone") or "Etc/UTC")
        errors = errors or {}
        fields = "".join(self.field_html(f, values.get(f.key, ""), errors.get(f.name, "")) for f in SERVER_FIELDS)
        datalist = "".join(f'<option value="{esc(tz)}">' for tz in self.timezones)
        names = [n for n in state.get("names") or [] if isinstance(n, dict) and n.get("host")]
        addresses = state.get("addresses") if isinstance(state.get("addresses"), dict) else {}
        v4, v6 = str(addresses.get("v4") or ""), str(addresses.get("v6") or "")
        domain = str(settings.get("DOMAIN") or "")
        if not state:
            names_html = (
                '<p class="error">The host agent has not written its status yet, so the names cannot be '
                "checked. On the server: <code>scripts/firefly-pocket console status</code></p>"
            )
        else:
            names_html = self.names_html(names, v4, v6, domain)
        body = f"""
<div class="setup">
  {stepper(0)}
  <section class="panel">
    <h1>Server</h1>
    {note}
    <p>Your domain, your email and the timezone. Save sends them to the server, which checks each one again
    before it keeps it.</p>
    <form method="post" action="/server" novalidate>
      {fields}
      <datalist id="timezones">{datalist}</datalist>
      <button type="submit">Save</button>
    </form>
    <h2>Names</h2>
    {names_html}
    <h2>Next</h2>
    <p>The other steps run over SSH for now. On the server, run</p>
    <pre>scripts/firefly-pocket setup</pre>
    <p>Enter keeps what you saved here. Once your Firefly III account exists, every name opens, and this
    console has nothing more to do.</p>
  </section>
</div>"""
        return self.page(status, "Server", body, signed_in=True)

    def field_html(self, f: Field, value: str, error: str) -> str:
        extra = ' list="timezones"' if f.kind == "timezone" else ""
        kind = "email" if f.kind == "email" else "text"
        invalid = f' aria-invalid="true"' if error else ""
        optional = "" if f.required else ' <span class="quiet">(optional)</span>'
        return f"""
      <div class="field">
        <label for="{f.name}">{esc(f.label)}{optional}</label>
        <input id="{f.name}" name="{f.name}" type="{kind}" value="{esc(value)}"{extra}{invalid}
               autocomplete="off" spellcheck="false" aria-describedby="{f.name}-help{' ' + f.name + '-error' if error else ''}">
        {f'<p class="error" id="{f.name}-error">{esc(error)}</p>' if error else ''}
        <p class="quiet" id="{f.name}-help">{esc(f.help)}</p>
      </div>"""

    def names_html(self, names: list[dict], v4: str, v6: str, domain: str) -> str:
        if not names:
            return "<p>No names yet: save a domain first.</p>"
        records = ""
        if domain and not is_localhost(domain):
            rows = f"<tr><td><code>*.{esc(domain)}</code></td><td>A</td><td><code>{esc(v4 or 'this server’s IPv4 address')}</code></td></tr>"
            if v6:
                rows += f"<tr><td><code>*.{esc(domain)}</code></td><td>AAAA</td><td><code>{esc(v6)}</code> (optional)</td></tr>"
            records = f"""
    <p>Point one wildcard record at this server. Let's Encrypt gives each name its certificate once it does.</p>
    <table class="records"><thead><tr><th>Name</th><th>Type</th><th>Value</th></tr></thead><tbody>{rows}</tbody></table>"""
        checks = self.check_names(names, v4, v6)
        rows = ""
        for c in checks:
            dns_class = "good" if c.dns_ok else "bad"
            cert_class = "quiet" if c.cert_ok is None else ("good" if c.cert_ok else "bad")
            rows += f"""
        <tr><td><code>{esc(c.host)}</code><br><span class="quiet">{esc(ROLES.get(c.role, c.role))}</span></td>
            <td class="{dns_class}">{esc(c.dns)}</td><td class="{cert_class}">{esc(c.cert)}</td></tr>"""
        return f"""{records}
    <table class="names"><thead><tr><th>Name</th><th>DNS</th><th>Certificate</th></tr></thead><tbody>{rows}</tbody></table>
    <p><a class="button" href="/server">Check again</a></p>"""

    def _check_names(self, names: list[dict], v4: str, v6: str) -> list[NameCheck]:
        def one(entry: dict) -> NameCheck:
            host, role = str(entry.get("host")), str(entry.get("role") or "")
            if is_localhost(host):
                return NameCheck(role, host, True, "this machine", None, "Caddy's own, which no browser trusts; not checked")
            dns_ok, dns = dns_verdict(host, *resolve(host), v4, v6)
            if self.acme_ca != LETS_ENCRYPT:
                return NameCheck(role, host, dns_ok, dns, None, f"from {self.acme_ca}; not checked")
            cert_ok, cert = certificate(host, self.caddy)
            return NameCheck(role, host, dns_ok, dns, cert_ok, cert)

        with ThreadPoolExecutor(max_workers=8) as pool:
            return list(pool.map(one, names))

    def save_server(self, req: Request) -> Response:
        form = req.form()
        values: dict[str, str] = {}
        errors: dict[str, str] = {}
        for f in SERVER_FIELDS:
            value = normalize(f, form.get(f.name, ""))
            values[f.key] = value
            if not value:
                if f.required:
                    errors[f.name] = f"{f.label} is needed"
                continue
            problem = check(f.kind, value)
            if problem:
                errors[f.name] = problem
        if errors:
            return self.server_page(req, 400, values, errors)
        state = read_status(self.status_file)
        settings = state.get("settings") if isinstance(state.get("settings"), dict) else {}
        # Where this console will answer once it is applied: a new domain moves it.
        moves_to = str(settings.get("ADMIN_HOSTNAME") or "") or f"admin.{values['DOMAIN']}"
        here = req.headers.get("host", "").split(":")[0]
        try:
            rid = write_request(self.inbox, "server", values)
        except OSError:
            note = (
                '<p class="error">The console could not hand this to the server: it cannot write to '
                "compose/console/inbox. On the server: <code>scripts/firefly-pocket console status</code> "
                "makes it as it should be.</p>"
            )
            return self.server_page(req, 503, values, note=note)
        with self.lock:
            self.pending[rid] = (self.clock(), moves_to if moves_to != here else "")
        return redirect(f"/requests/{rid}")

    def request_page(self, req: Request, rid: str) -> Response:
        state = read_status(self.status_file)
        requests = state.get("requests") if isinstance(state.get("requests"), dict) else {}
        result = requests.get(rid)
        with self.lock:
            started, moves_to = self.pending.get(rid, (0.0, ""))
        if isinstance(result, dict):
            message = esc(result.get("message") or "")
            if result.get("state") == "applied":
                return self.page(200, "Saved", f'<section class="narrow"><h1>Saved</h1><p>{message}</p>'
                                 '<p><a class="button" href="/server">Back to setup</a></p></section>', signed_in=True)
            return self.page(200, "Not saved", f'<section class="narrow"><h1>Not saved</h1><p class="error">{message}</p>'
                             '<p><a class="button" href="/server">Back to setup</a></p></section>', signed_in=True)
        if not started:
            return self.page(404, "Not found", '<h1>Not found</h1><p><a href="/server">Back to setup</a></p>', signed_in=True)
        if moves_to:
            # This host goes away once the agent applies it: no reload to an error page.
            body = f"""<section class="narrow"><h1>Saving</h1>
  <p>The domain changes, so this console moves to <a href="https://{esc(moves_to)}/">https://{esc(moves_to)}/</a>
  once the server has applied it. Open it there and enter the setup code again; the new name needs its DNS
  record first, and then a minute for its certificate.</p>
  <p><a class="button" href="/requests/{rid}">Look again here</a></p></section>"""
            return self.page(202, "Saving", body, signed_in=True)
        waited = self.clock() - started
        hint = ""
        if waited > 30:
            hint = """<p class="error">The server has not picked it up yet. On the server, see whether the unit that
  applies it runs: <code>systemctl status firefly-pocket-console.path</code>, or apply it by hand:
  <code>scripts/firefly-pocket console apply</code></p>"""
        body = f"""<section class="narrow"><h1>Saving</h1>
  <p>The server checks each value, keeps it and starts Caddy again with it. This page looks again every few
  seconds; reload it if it shows an error while Caddy restarts.</p>{hint}</section>"""
        return self.page(202, "Saving", body, refresh=3, signed_in=True)

    # ----------------------------------------------------------- finished ---
    def finished(self) -> Response:
        state = read_status(self.status_file)
        hosts = {n.get("role"): n.get("host") for n in state.get("names") or [] if isinstance(n, dict)}
        links = ""
        for role in ("firefly", "app"):
            if hosts.get(role):
                links += f'<li>{esc(ROLES[role])}: <a href="https://{esc(hosts[role])}/">https://{esc(hosts[role])}/</a></li>'
        body = f"""<section class="narrow">
  <h1>Setup is finished</h1>
  <p>Firefly III has its account, so the setup code works no more.</p>
  {f'<ul>{links}</ul>' if links else ''}
  <p>Changing settings here comes later, behind Sign in with Firefly III. Until then, on the server:
  <code>scripts/firefly-pocket setup &lt;step&gt;</code></p>
</section>"""
        return self.page(200, "Setup is finished", body)

    # -------------------------------------------------------------- pages ---
    def page(self, status: int, title: str, main: str, refresh: int | None = None, signed_in: bool = False) -> Response:
        meta = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ""
        logout = (
            '<form method="post" action="/logout" class="logout"><button type="submit" class="link">Sign out</button></form>'
            if signed_in else ""
        )
        doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
{meta}<title>{esc(title)} · Firefly Pocket Console</title>
<link rel="stylesheet" href="/console.css">
</head>
<body>
<header><span><strong>Firefly Pocket</strong> Console</span>{logout}</header>
<main>{main}</main>
</body>
</html>
"""
        return Response(status, doc.encode("utf-8"))


def stepper(current: int) -> str:
    items = ""
    for i, name in enumerate(STEPS):
        state = "now" if i == current else ("done" if i < current else "later")
        aria = ' aria-current="step"' if i == current else ""
        items += f'<li class="{state}"{aria}>{esc(name)}</li>'
    return f"""<nav class="steps" aria-label="Setup steps"><ol>{items}</ol>
    <p class="quiet">After Server, the steps run over SSH for now.</p></nav>"""


def redirect(location: str, headers: list[tuple[str, str]] | None = None) -> Response:
    return Response(303, b"", "text/plain; charset=utf-8", [("Location", location), *(headers or [])])


def same_origin(req: Request) -> bool:
    """A POST must come from a page of this console: its Origin is this host,
    as the browser saw it through Caddy. With the cookie's SameSite=Strict, no
    other site can make a signed-in browser save anything."""
    host = req.headers.get("host", "")
    proto = req.headers.get("x-forwarded-proto", "https")
    origin = req.headers.get("origin")
    if origin is not None:
        return bool(host) and origin == f"{proto}://{host}"
    return req.headers.get("sec-fetch-site") == "same-origin"


def _timezones() -> list[str]:
    try:
        import zoneinfo

        return sorted(zoneinfo.available_timezones())
    except Exception:  # no tzdata: the field still takes any name the server knows
        return []


# ---------------------------------------------------------- HTTP server ---
SECURITY_HEADERS = (
    ("Content-Security-Policy",
     "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"),
    ("Cache-Control", "no-store"),
    ("Referrer-Policy", "no-referrer"),
    ("X-Content-Type-Options", "nosniff"),
)


class Handler(BaseHTTPRequestHandler):
    console: Console
    protocol_version = "HTTP/1.1"
    server_version = "FireflyPocketConsole"
    sys_version = ""
    timeout = 30

    def serve(self, method: str) -> None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self.close_connection = True
            self.send(Response(413, b"too large\n", "text/plain; charset=utf-8"), method)
            return
        body = self.rfile.read(length) if length else b""
        headers = {k.lower(): v for k, v in self.headers.items()}
        self.send(self.console.handle(Request(method, self.path, headers, body)), method)

    def send(self, resp: Response, method: str) -> None:
        self.send_response(resp.status)
        names = {name.lower() for name, _ in resp.headers}
        for name, value in SECURITY_HEADERS:
            if name.lower() not in names:
                self.send_header(name, value)
        for name, value in resp.headers:
            self.send_header(name, value)
        self.send_header("Content-Type", resp.content_type)
        self.send_header("Content-Length", str(len(resp.body)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(resp.body)

    def do_GET(self) -> None:
        self.serve("GET")

    def do_HEAD(self) -> None:
        self.serve("HEAD")

    def do_POST(self) -> None:
        self.serve("POST")

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - the base class's name
        sys.stderr.write(f"{self.log_date_time_string()} {format % args}\n")


def main() -> None:
    console = Console.from_env()
    Handler.console = console
    port = int(os.environ.get("CONSOLE_PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True

    def stop(signum, frame):  # PID 1 in its container: no default handler would stop it
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    state = "setup finished" if console.setup_done else ("waiting for the setup code" if console.code else "no setup code")
    print(f"Firefly Pocket Console on :{port}, {state}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
