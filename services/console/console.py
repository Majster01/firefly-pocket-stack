#!/usr/bin/env python3
"""Firefly Pocket Console: setup in the browser, on admin.<domain>.

Setup UI steps 4 to 7. Until Firefly III has its account, every other host
sends the browser here (the Caddyfile's setup gate), and this asks for the
setup code that `scripts/firefly-pocket setup web` printed on the server. Its
first page sets the domain, your email, your name and the timezone, and shows
whether each name points at this server and has its certificate. Its second
asks for your Firefly III account's password; the server then makes the
account and a token for each app inside Firefly III, and starts everything,
which opens the gate. Its third connects the bank: the server makes a key for
an Enable Banking application, this hands out its certificate, and the server
keeps the application's ID once Enable Banking takes a request signed with the
key for it. Then the AI key for suggestions, which the server keeps once the
provider has the model for it, and the alerts: an ntfy topic, kept once a test
alert gets through, and healthchecks.io's two checks, made with an API key the
server does not keep. Then the offsite backup: a restic repository, made with
a password this shows you once to keep, or one restic uses already. Then
updates: the deploy agent, which keeps the server on master and runs the
nightly jobs. Saved keys are write-only: this shows their last four
characters. Finish lists what each step left, and ends the setup code.

After setup (Setup UI step 8) it signs you in with Firefly III instead: an
authorization code with PKCE, for the public client the server registers in
Firefly III, so Firefly III's password and its two-factor authentication
apply. Only the account the server was set up for, SITE_OWNER, gets in. Then
it shows what the server has; changing a step here comes next.

It is built so that taking it over gains little:

- It never touches Docker or the settings. Save turns into a request file in
  /inbox, a directory it can add files to but not list; the host agent checks
  each request as `firefly-pocket config set` would, and applies it
  (scripts/console.sh). Each carries the setup code, which the agent checks
  too. What it shows comes from /status, which the agent writes and which
  holds no secret. The password goes into its request and nowhere else, and
  the bank's private key never leaves the server. A new repository's password
  is made here and kept in memory only until the server has made the
  repository with it.
- The setup code works only until setup is finished, when the server removes
  it and starts this again without it. After that only a sign-in with Firefly
  III opens it, and the agent refuses its requests. It holds no client secret:
  the client is public, and PKCE stands in for one. Firefly III's token stays
  in memory for the session, which lasts 8 hours, and in no file.
- It shares a network with Caddy only, not with the apps or Postgres.
- It is also the importer's lock: Caddy asks /auth/importer before it lets a
  request through to the importer's own pages under /importer/ (Hostnames and
  routing step 7), and only this console's sign-in passes.

Standard library only: compose runs it on the stock python image, with this
directory mounted read-only, as an unprivileged user on a read-only root.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import html
import http.client
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
from urllib.parse import parse_qs, urlencode, urlsplit

HERE = Path(__file__).resolve().parent
LETS_ENCRYPT = "https://acme-v02.api.letsencrypt.org/directory"
# __Host-: the browser keeps it to this host, over HTTPS, for every path.
COOKIE = "__Host-console"
# The sign-in with Firefly III under way in this browser: its state, for 10 minutes.
SIGNIN_COOKIE = "__Host-console-signin"
SIGNIN_SECONDS = 600
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

# The setup's steps, as the CLI wizard has them, and the page of each that is
# here so far.
STEPS = (
    ("Server", "/server"),
    ("Firefly III account", "/account"),
    ("Bank connection", "/bank"),
    ("Suggestions", "/suggestions"),
    ("Alerts", "/alerts"),
    ("Backups", "/backups"),
    ("Updates", "/updates"),
    ("Finish", "/finish"),
)
SERVER, ACCOUNT, BANK, SUGGESTIONS, ALERTS, BACKUPS, UPDATES, FINISH = range(8)

# Firefly III's minimum, which the agent checks again.
MIN_PASSWORD = 16
# A request the agent has said nothing about for this long is not running any
# more: firefly-pocket-console.service stops it after 30 minutes.
STALE_SECONDS = 40 * 60

# What a request's outcome is called: done, not done, and while the server works on it.
OUTCOME = {
    "server": ("Saved", "Not saved", "Saving"),
    "account": ("Done", "Not done", "Making your account"),
    "bank_key": ("Made", "Not made", "Making the key"),
    "bank": ("Saved", "Not saved", "Checking with Enable Banking"),
    "suggestions": ("Saved", "Not saved", "Checking the key"),
    "ntfy": ("Saved", "Not saved", "Sending a test alert"),
    "ntfy_test": ("Sent", "Not sent", "Sending a test alert"),
    "healthchecks": ("Made", "Not made", "Making the checks"),
    "backups": ("Saved", "Not saved", "Opening the repository"),
    "updates": ("Turned on", "Not turned on", "Turning on the deploy agent"),
    "finish": ("Setup is finished", "Not finished", "Finishing"),
}
# The page each request goes back to, and the step after it once it is done.
BACK = {"server": "/server", "account": "/account", "bank_key": "/bank", "bank": "/bank", "suggestions": "/suggestions",
        "ntfy": "/alerts", "ntfy_test": "/alerts", "healthchecks": "/alerts", "backups": "/backups", "updates": "/updates",
        "finish": "/finish"}
NEXT = {"server": ("/account", "Firefly III account"), "account": ("/bank", "Bank connection"),
        "bank": ("/suggestions", "Suggestions"), "suggestions": ("/alerts", "Alerts"), "ntfy": ("/backups", "Backups"),
        "ntfy_test": ("/backups", "Backups"), "healthchecks": ("/backups", "Backups"), "backups": ("/updates", "Updates"),
        "updates": ("/finish", "Finish")}

# As scripts/config.sh checks an API key and a model, and the providers' defaults.
API_KEY_RE = re.compile(r"[A-Za-z0-9._-]{16,}")
MODEL_RE = re.compile(r"(claude|gemini)-[a-z0-9.-]+")
DEFAULT_MODEL = "claude-haiku-5-5"
PROVIDERS = {"anthropic": "Anthropic", "gemini": "Gemini"}
URL_RE = re.compile(r"https?://[^\s$\\]+")
# A restic repository as scripts/config.sh checks it (one word), and a new one's
# password, as gen-secrets.sh makes RESTIC_PASSWORD.
REPOSITORY_RE = re.compile(r"[^\s\x00-\x1f\x7f…]+")
REPOSITORY_EXAMPLE = "s3:https://s3.eu-central-003.backblazeb2.com/your-bucket/firefly-pocket"
RESTIC_PASSWORD_LENGTH = 32

# As scripts/config.sh checks ENABLE_BANKING_APP_ID.
APP_ID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
APP_ID_EXAMPLE = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"

NOT_FOUND = '<section class="narrow"><h1>Not found</h1><p><a href="/server">Back to setup</a></p></section>'

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


class _ThroughCaddy(http.client.HTTPSConnection):
    """HTTPS to a name Caddy serves, on the network the two share: connected to
    Caddy, and the TLS handshake for the name."""

    def __init__(self, host: str, caddy: tuple[str, int], context: ssl.SSLContext, timeout: float):
        super().__init__(host, caddy[1], context=context, timeout=timeout)
        self.caddy = caddy

    def connect(self) -> None:
        sock = socket.create_connection(self.caddy, timeout=self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def firefly_call(caddy: tuple[str, int], method: str, host: str, path: str, form: dict | None = None,
                 token: str = "", timeout: float = 20.0) -> tuple[int, dict]:
    """Firefly III, through Caddy: its HTTP status and its JSON answer, or 0 and
    {} when it did not answer. Its certificate is checked as a browser would,
    except on *.localhost, whose certificates are Caddy's own."""
    context = ssl.create_default_context()
    if is_localhost(host):
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    headers = {"Accept": "application/vnd.api+json" if token else "application/json"}
    body = None
    if form is not None:
        body = urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    conn = _ThroughCaddy(host, caddy, context, timeout)
    try:
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        status, data = resp.status, resp.read(256 * 1024)
    except (OSError, ssl.SSLError, http.client.HTTPException):
        return 0, {}
    finally:
        conn.close()
    try:
        answer = json.loads(data)
    except ValueError:
        answer = {}
    return status, answer if isinstance(answer, dict) else {}


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
def write_request(inbox: Path, action: str, auth: dict[str, str], fields: dict) -> str:
    """Hand a request to the host agent: written beside, then renamed into
    place, so the agent never reads half of one (it takes *.json only). What
    lets it in goes with it, for the agent to check: {"code": the setup code}
    during setup, {"token": Firefly III's} after."""
    rid = secrets.token_hex(16)
    data = json.dumps(
        {"version": 1, "id": rid, "action": action, **auth, **fields, "at": now_iso()}
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


def part(state: dict, key: str) -> dict:
    value = state.get(key)
    return value if isinstance(value, dict) else {}


def hosts_of(state: dict) -> dict[str, str]:
    return {str(n.get("role")): str(n.get("host")) for n in state.get("names") or []
            if isinstance(n, dict) and n.get("host")}


def account_made(state: dict) -> bool:
    """Firefly III has its account: the agent says so. Its status from before
    the bank step said setup_done for the same thing."""
    if "account" in state:
        return state.get("account") is True
    return state.get("setup_done") is True


def server_saved(state: dict) -> bool:
    """The account needs the Server step's email, and the timezone saved with
    it; the agent checks this too."""
    settings = part(state, "settings")
    return bool(settings.get("SITE_OWNER")) and bool(settings.get("TZ"))


def latest(state: dict, action: str = "") -> dict:
    """The last request the agent has a word on, of that action if one is named."""
    requests = part(state, "requests")
    mine = [r for r in requests.values() if isinstance(r, dict) and (not action or r.get("action") == action)]
    return max(mine, key=lambda r: str(r.get("at") or ""), default={})


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
        code: str,
        inbox: Path,
        status_file: Path,
        acme_ca: str = LETS_ENCRYPT,
        caddy: tuple[str, int] = ("caddy", 443),
        timezones: list[str] | None = None,
        clock=time.time,
        fail_delay: float = 1.0,
        check_names=None,
        firefly=None,
    ):
        self.code = normalize_code(code)
        self.inbox = inbox
        self.status_file = status_file
        self.acme_ca = acme_ca or LETS_ENCRYPT
        self.caddy = caddy
        self.timezones = timezones if timezones is not None else _timezones()
        self.clock = clock
        self.fail_delay = fail_delay
        self.check_names = check_names or self._check_names
        # firefly(method, host, path, form=None, token=None) -> (status, JSON object)
        self.firefly = firefly or (lambda *a, **k: firefly_call(self.caddy, *a, **k))
        self.css = (HERE / "console.css").read_bytes()
        self.lock = threading.Lock()
        self.sessions: dict[str, float] = {}
        # After setup: a session signed in with Firefly III, and its token, for
        # the agent to check (part 2). In memory only.
        self.owner_sessions: dict[str, str] = {}
        # A sign-in under way: state -> (PKCE verifier, until).
        self.signins: dict[str, tuple[str, float]] = {}
        self.failures: deque[float] = deque()
        # request id: (when, its action, the host the console moves to)
        self.pending: dict[str, tuple[float, str, str]] = {}
        # The password a new restic repository gets, the same each time the
        # backups page shows it, and the request that makes a repository with it.
        self.restic_password = ""
        self.password_request = ""

    @classmethod
    def from_env(cls, env=os.environ) -> Console:
        return cls(
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
        if path == "/auth/importer" and req.method in ("GET", "HEAD"):
            return self.importer_auth(req)
        if req.method not in ("GET", "HEAD", "POST"):
            return Response(405, b"", headers=[("Allow", "GET, HEAD, POST")])
        if req.method == "POST" and not same_origin(req):
            return self.page(403, "Refused", '<section class="narrow"><h1>Refused</h1>'
                             "<p>That form was not sent from this page.</p></section>")
        state = read_status(self.status_file)
        # Finished: the server removed the code, and starts this again without
        # it; until then the agent refuses what this would send.
        if not self.code or (state.get("setup_done") is True and "account" in state):
            if account_made(state):
                return self.after_setup(req, state)
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
        post = req.method == "POST"
        if path == "/":
            return redirect(next_step(state))
        if path == "/server":
            return self.save_server(req) if post else self.server_page(req)
        if path == "/account":
            return self.save_account(req) if post else self.account_page(req)
        if path == "/bank":
            return self.save_bank(req) if post else self.bank_page(req)
        if path == "/bank/key" and post:
            return self.make_key(req)
        if path == "/bank/certificate" and not post:
            return self.certificate()
        if path == "/suggestions":
            return self.save_suggestions(req) if post else self.suggestions_page(req)
        if path == "/alerts" and not post:
            return self.alerts_page(req)
        if path in ("/alerts/ntfy", "/alerts/test", "/alerts/healthchecks") and post:
            return self.save_alerts(req, path.rsplit("/", 1)[1])
        if path == "/backups":
            return self.save_backups(req) if post else self.backups_page(req)
        if path == "/updates":
            return self.save_updates(req) if post else self.updates_page(req)
        if path == "/finish":
            return self.save_finish(req) if post else self.finish_page(req)
        match = re.fullmatch(r"/requests/([0-9a-f]{32})", path)
        if match and req.method != "POST":
            return self.request_page(req, match.group(1))
        return self.page(404, "Not found", NOT_FOUND, signed_in=True)

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
        cookie = f"{COOKIE}={token}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age={SESSION_SECONDS}"
        return redirect(next_step(read_status(self.status_file)), [("Set-Cookie", cookie)])

    def logout(self, req: Request) -> Response:
        with self.lock:
            self.sessions.pop(req.cookie(COOKIE), None)
            token = self.owner_sessions.pop(req.cookie(COOKIE), None)
        if token:
            # Firefly III revokes it: no one gets far with it from here on.
            try:
                write_request(self.inbox, "signout", {"token": token}, {})
            except OSError:
                pass  # it lasts eight hours at most: the agent revokes it then
        return redirect("/", [("Set-Cookie", f"{COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0")])

    def login_page(self, status: int = 200, error: str = "") -> Response:
        body = f"""
<section class="narrow">
  <h1>Setup</h1>
  <p>This server is being set up, and until that is finished this console asks for its setup code.</p>
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
        if account_made(state):
            # Every service runs with these now: the wizard changes them, and starts everything again.
            rows = "".join(
                f'<tr><th scope="row">{esc(f.label)}</th><td>{esc(settings.get(f.key) or "")}</td></tr>'
                for f in SERVER_FIELDS
            )
            form = f"""
    <p>Firefly III has its account, so these stay as they are here. To change one, on the server:
    <code>scripts/firefly-pocket setup domain</code>, or <code>setup you</code>.</p>
    <table class="settings"><tbody>{rows}</tbody></table>"""
            after = '<p><a class="button" href="/bank">Next: Bank connection</a></p>'
        else:
            form = f"""
    <p>Your domain, your email and the timezone. Save sends them to the server, which checks each one again
    before it keeps it.</p>
    <form method="post" action="/server" novalidate>
      {fields}
      <datalist id="timezones">{datalist}</datalist>
      <button type="submit">Save</button>
    </form>"""
            after = """
    <p>Once these are saved: your Firefly III account. The names need not be ready for it.</p>
    <p><a class="button" href="/account">Firefly III account</a></p>"""
        body = f"""
<section class="panel">
    <h1>Server</h1>
    {note}
    {form}
    <h2>Names</h2>
    {names_html}
    <h2>Next</h2>
    {after}
  </section>"""
        return self.page(status, "Server", body, signed_in=True, nav=stepper(SERVER, state))

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
            rows = ""
            for name in (domain, f"*.{domain}"):
                rows += f"<tr><td><code>{esc(name)}</code></td><td>A</td><td><code>{esc(v4 or 'this server’s IPv4 address')}</code></td></tr>"
                if v6:
                    rows += f"<tr><td><code>{esc(name)}</code></td><td>AAAA</td><td><code>{esc(v6)}</code> (optional)</td></tr>"
            records = f"""
    <p>Point the domain itself, which is Firefly Pocket, and a wildcard record at this server: the wildcard does not cover the domain. Let's Encrypt gives each name its certificate once it does.</p>
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
        if account_made(read_status(self.status_file)):
            return self.server_page(req, 409)
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
            rid = write_request(self.inbox, "server", {"code": self.code}, {"settings": values})
        except OSError:
            return self.server_page(req, 503, values, note=NO_INBOX)
        with self.lock:
            self.pending[rid] = (self.clock(), "server", moves_to if moves_to != here else "")
        return redirect(f"/requests/{rid}")

    # ------------------------------------------------------------ account ---
    def account_running(self) -> str:
        """The account request the server is still working on, if any: a second
        one would only be refused."""
        requests = read_status(self.status_file).get("requests")
        requests = requests if isinstance(requests, dict) else {}
        with self.lock:
            mine = [rid for rid, (_, action, _) in self.pending.items() if action == "account"]
        for rid in mine:
            result = requests.get(rid)
            if not isinstance(result, dict) or (result.get("state") == "running" and not self.stale(result)):
                return rid
        return ""

    def stale(self, result: dict) -> bool:
        """A request still running long after systemd would have stopped the
        agent (its unit allows it 30 minutes): the agent died on the way."""
        try:
            at = datetime.strptime(str(result.get("at")), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            return False
        return self.clock() - at.timestamp() > STALE_SECONDS

    def account_page(self, req: Request, status: int = 200, errors=None, note: str = "") -> Response:
        running = self.account_running()
        if running:
            return redirect(f"/requests/{running}")
        state = read_status(self.status_file)
        settings = part(state, "settings")
        hosts = hosts_of(state)
        email = str(settings.get("SITE_OWNER") or "")
        firefly = str(hosts.get("firefly") or "")
        where = f" at <code>https://{esc(firefly)}</code>" if firefly else ""  # none before a domain
        if account_made(state):
            last = latest(state, "account")
            problem = ""
            if last.get("state") == "failed":  # the account is made, but not everything started
                problem = f'<p class="error">The server\'s last try did not finish: {esc(last.get("message") or "")}</p>'
            body = f"""
<section class="panel">
    <h1>Firefly III account</h1>
    <p class="good">Done: you sign in{where} as {esc(email)}, and each app has its token.</p>
    {problem}
    <p>Turn on two-factor authentication there: Options, Profile.</p>
    <h2>Next</h2>
    <p><a class="button" href="/bank">Next: Bank connection</a></p>
  </section>"""
            return self.page(status, "Firefly III account", body, signed_in=True, nav=stepper(ACCOUNT, state))
        if not server_saved(state):
            body = f"""
<section class="panel">
    <h1>Firefly III account</h1>
    <p>Save the Server step first: the account's email is the one it keeps.</p>
    <p><a class="button" href="/server">Server</a></p>
  </section>"""
            return self.page(status, "Firefly III account", body, signed_in=True, nav=stepper(ACCOUNT, state))
        errors = errors or {}
        body = f"""
<section class="panel">
    <h1>Firefly III account</h1>
    {note}
    <p>Your Firefly III account: you sign in{where} with your email and this password. The server makes
    it, and a token for each app (the bank importer, the suggester and Firefly Pocket's warm-up) inside
    Firefly III: nobody opens its registration page or copies a token.</p>
    <form method="post" action="/account" novalidate>
      <div class="field">
        <label for="email">Email</label>
        <input id="email" name="email" type="email" value="{esc(email)}" readonly autocomplete="username"
               aria-describedby="email-help">
        <p class="quiet" id="email-help">The one the Server step saved.</p>
      </div>
      {password_field("password", "Password", errors.get("password", ""),
                      f"At least {MIN_PASSWORD} characters, Firefly III's minimum. A password manager's is best.")}
      {password_field("password2", "Once more", errors.get("password2", ""), "")}
      <button type="submit">Make the account</button>
    </form>
    <p class="quiet">It takes a few minutes: the server downloads every service, starts Firefly III, which
    sets up its database the first time, makes the account and the tokens, then starts everything else.
    Then every name opens.</p>
  </section>"""
        return self.page(status, "Firefly III account", body, signed_in=True, nav=stepper(ACCOUNT, state))

    def save_account(self, req: Request) -> Response:
        running = self.account_running()
        if running:
            return redirect(f"/requests/{running}")
        state = read_status(self.status_file)
        if account_made(state) or not server_saved(state):
            return self.account_page(req, 409)
        form = req.form()
        password, again = form.get("password", ""), form.get("password2", "")
        errors: dict[str, str] = {}
        if any(ord(c) < 32 or ord(c) == 127 for c in password):
            errors["password"] = "No control characters"
        elif len(password) < MIN_PASSWORD:
            errors["password"] = f"At least {MIN_PASSWORD} characters"
        elif again != password:
            errors["password2"] = "The two differ"
        if errors:
            return self.account_page(req, 400, errors)
        return self.hand_over(req, "account", {"password": password}, self.account_page)

    # --------------------------------------------------------------- bank ---
    def bank_page(self, req: Request, status: int = 200, value: str | None = None, error: str = "",
                  note: str = "") -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            body = f"""
<section class="panel">
    <h1>Bank connection</h1>
    <p>Make the Firefly III account first: the bank importer needs its token.</p>
    <p><a class="button" href="/account">Firefly III account</a></p>
  </section>"""
            return self.page(status, "Bank connection", body, signed_in=True, nav=stepper(BANK, state))
        bank = part(state, "bank")
        hosts = hosts_of(state)
        app_id = str(bank.get("app_id") or "")
        cert = str(bank.get("certificate") or "")
        urls = "".join(f"<li><code>{esc(u)}</code></li>" for u in bank.get("redirect_urls") or [] if isinstance(u, str))
        legal = hosts.get("legal", "")
        if not bank.get("key"):
            steps = """
    <h2>1. A key for your application</h2>
    <p>The server makes a key and a certificate for it. You upload the certificate when you register the
    application with Enable Banking; the private key never leaves the server.</p>
    <form method="post" action="/bank/key"><button type="submit">Make the key</button></form>"""
        else:
            if cert:
                register = f"""
    <h2>1. Register the application</h2>
    <p>In Enable Banking's control panel, register a new application:</p>
    <ol class="todo">
      <li>Environment: <strong>production</strong>. A sandbox application only ever sees a mock bank.</li>
      <li>Its certificate: upload this one, made on this server for it.
        <p><a class="button" href="/bank/certificate" download>Download the certificate</a></p>
        <details><summary>Or copy it</summary><pre>{esc(cert)}</pre></details></li>
      <li>Redirect URLs, both:<ul>{urls}</ul></li>
      <li>Privacy policy <code>https://{esc(legal)}/privacy</code>, terms <code>https://{esc(legal)}/terms</code></li>
      <li>Then activate it by linking your own accounts: restricted mode, free for personal use.</li>
    </ol>"""
            else:
                register = f"""
    <h2>1. The application</h2>
    <p>This server's key was set by hand (<code>scripts/set-eb-key.sh</code>), for an application of its own,
    so there is no certificate to hand out here. The application needs these redirect URLs:</p>
    <ul>{urls}</ul>"""
            shown = app_id if value is None else value
            invalid = ' aria-invalid="true"' if error else ""
            steps = f"""{register}
    <h2>2. Its application ID</h2>
    <form method="post" action="/bank" novalidate>
      <div class="field">
        <label for="app_id">Application ID</label>
        <input id="app_id" name="app_id" value="{esc(shown)}" placeholder="{APP_ID_EXAMPLE}"{invalid}
               autocomplete="off" spellcheck="false" aria-describedby="app_id-help{' app_id-error' if error else ''}">
        {f'<p class="error" id="app_id-error">{esc(error)}</p>' if error else ''}
        <p class="quiet" id="app_id-help">Enable Banking's control panel shows it with the application. The
        server keeps it once Enable Banking takes a request signed with this server's key for it.</p>
      </div>
      <button type="submit">Check and save</button>
    </form>
    <details class="new-key"><summary>A new key</summary>
      <p>Only for a new application: the one registered with {'this certificate' if cert else 'the key set by hand'}
      stops working on this server, and its ID is removed here.</p>
      <form method="post" action="/bank/key"><button type="submit">Make a new key</button></form>
    </details>"""
        saved = f'<p class="good">This server uses the application <code>{esc(app_id)}</code>.</p>' if app_id else ""
        if app_id:
            after = '<p><a class="button" href="/suggestions">Next: Suggestions</a></p>'
        else:
            after = """<p>Firefly Pocket links no bank until this is done. <a href="/suggestions">Skip it for now</a>: on the
    server, <code>scripts/firefly-pocket setup bank</code> does it later.</p>"""
        body = f"""
<section class="panel">
    <h1>Bank connection</h1>
    {note}
    <p>Firefly Pocket imports from your bank through Enable Banking
    (<a href="https://enablebanking.com/" rel="noreferrer">enablebanking.com</a>), free for your own accounts.
    Check first that it covers your bank.</p>
    {saved}
    {steps}
    <h2>Next</h2>
    {after}
  </section>"""
        return self.page(status, "Bank connection", body, signed_in=True, nav=stepper(BANK, state))

    def make_key(self, req: Request) -> Response:
        if not account_made(read_status(self.status_file)):
            return self.bank_page(req, 409)
        return self.hand_over(req, "bank_key", {}, self.bank_page)

    def save_bank(self, req: Request) -> Response:
        state = read_status(self.status_file)
        if not account_made(state) or not part(state, "bank").get("key"):
            return self.bank_page(req, 409)
        value = req.form().get("app_id", "").strip()
        if not APP_ID_RE.fullmatch(value):
            return self.bank_page(req, 400, value, f"An application ID, such as {APP_ID_EXAMPLE}")
        return self.hand_over(req, "bank", {"app_id": value}, self.bank_page)

    def certificate(self) -> Response:
        """The certificate the server made for the application: public, it is
        what Enable Banking checks the key's signatures with."""
        cert = str(part(read_status(self.status_file), "bank").get("certificate") or "")
        if not cert.startswith("-----BEGIN CERTIFICATE-----"):
            return self.page(404, "Not found", '<section class="narrow"><h1>Not found</h1>'
                             '<p>No certificate yet. <a href="/bank">Bank connection</a></p></section>',
                             signed_in=True)
        return Response(200, cert.encode(), "application/x-pem-file",
                        [("Content-Disposition", 'attachment; filename="firefly-pocket-enable-banking.crt"')])

    def hand_over(self, req: Request, action: str, fields: dict, page) -> Response:
        """A request to the agent, then its page; on no inbox, the form again.
        After setup it carries the owner's Firefly III token, not the code."""
        with self.lock:
            token = self.owner_sessions.get(req.cookie(COOKIE), "")
        try:
            rid = write_request(self.inbox, action, {"token": token} if token else {"code": self.code}, fields)
        except OSError:
            return page(req, 503, note=NO_INBOX)
        with self.lock:
            self.pending[rid] = (self.clock(), action, "")
            if action == "backups" and fields.get("mode") == "new":
                self.password_request = rid
        return redirect(f"/requests/{rid}")

    # -------------------------------------------------------- suggestions ---
    def needs_account(self, current: int, title: str, status: int) -> Response:
        state = read_status(self.status_file)
        body = f"""
<section class="panel">
    <h1>{esc(title)}</h1>
    <p>Make the Firefly III account first.</p>
    <p><a class="button" href="/account">Firefly III account</a></p>
  </section>"""
        return self.page(status, title, body, signed_in=True, nav=stepper(current, state))

    def suggestions_page(self, req: Request, status: int = 200, values=None, errors=None, note: str = "") -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.needs_account(SUGGESTIONS, "Category suggestions", status)
        kept = part(state, "suggestions")
        model = str(kept.get("model") or DEFAULT_MODEL)
        saved = [(name, str(kept.get(key))) for key, name in PROVIDERS.items() if kept.get(key)]
        values = values or {"provider": "gemini" if model.startswith("gemini-") else "anthropic", "model": model}
        errors = errors or {}
        saved_html = ""
        if saved:
            keys = " and ".join(f"{esc(name)}'s, <code>{esc(last)}</code>" for name, last in saved)
            saved_html = f'<p class="good">This server has a key: {keys}, for <code>{esc(model)}</code>.</p>'
        radios = "".join(
            f'<label class="choice"><input type="radio" name="provider" value="{key}"'
            f'{" checked" if values.get("provider") == key else ""}> {esc(name)}</label>'
            for key, name in PROVIDERS.items()
        )
        model_error = errors.get("model", "")
        after = ('<p><a class="button" href="/alerts">Next: Alerts</a></p>' if saved else
                 """<p>Firefly Pocket makes no suggestions until this is done. <a href="/alerts">Skip it for now</a>: on the
    server, <code>scripts/firefly-pocket setup suggestions</code> does it later.</p>""")
        body = f"""
<section class="panel">
    <h1>Category suggestions</h1>
    {note}
    <p>Each night an AI model suggests a category for each new transaction, as a rule you approve in Firefly
    Pocket. It needs an API key: Anthropic's (<a href="https://console.anthropic.com/" rel="noreferrer">console.anthropic.com</a>,
    an account with credit) or Google's for Gemini (a paid project: the free tier allows 20 requests a day).</p>
    {saved_html}
    <form method="post" action="/suggestions" novalidate>
      <fieldset class="field"><legend>Provider</legend>{radios}
        {f'<p class="error">{esc(errors["provider"])}</p>' if errors.get("provider") else ''}</fieldset>
      {secret_field("key", "API key", errors.get("key", ""),
                    "Kept on the server only: this page shows its last four characters, never the key.")}
      <div class="field">
        <label for="model">Model</label>
        <input id="model" name="model" value="{esc(values.get("model", ""))}" autocomplete="off" spellcheck="false"
               aria-describedby="model-help{' model-error' if model_error else ''}"{' aria-invalid="true"' if model_error else ''}>
        {f'<p class="error" id="model-error">{esc(model_error)}</p>' if model_error else ''}
        <p class="quiet" id="model-help">Anthropic: {DEFAULT_MODEL} unless you choose another. Gemini: a gemini-* model,
        as Google names it.</p>
      </div>
      <button type="submit">Check and save</button>
    </form>
    <p class="quiet">The server asks the provider for the model with this key before it keeps it.</p>
    <h2>Next</h2>
    {after}
  </section>"""
        return self.page(status, "Category suggestions", body, signed_in=True, nav=stepper(SUGGESTIONS, state))

    def save_suggestions(self, req: Request) -> Response:
        if not account_made(read_status(self.status_file)):
            return self.suggestions_page(req, 409)
        form = req.form()
        provider = form.get("provider", "")
        key = form.get("key", "").strip()
        model = form.get("model", "").strip()
        errors: dict[str, str] = {}
        if provider not in PROVIDERS:
            errors["provider"] = "Anthropic or Gemini"
        elif key.startswith("sk-ant-") and provider != "anthropic":
            errors["key"] = "That is an Anthropic key"
        elif key.startswith("AIza") and provider != "gemini":
            errors["key"] = "That is a Gemini key"
        if "key" not in errors and not API_KEY_RE.fullmatch(key):
            errors["key"] = "An API key: at least 16 letters, digits, dots, dashes and underscores"
        if provider == "anthropic":
            model = model if model.startswith("claude-") else DEFAULT_MODEL
        elif provider == "gemini" and not model.startswith("gemini-"):
            errors["model"] = "A gemini-* model, as Google names it"
        if "model" not in errors and not MODEL_RE.fullmatch(model):
            errors["model"] = "A claude-* or gemini-* model name"
        if errors:
            return self.suggestions_page(req, 400, {"provider": provider, "model": model}, errors)
        return self.hand_over(req, "suggestions", {"provider": provider, "key": key, "model": model},
                              self.suggestions_page)

    # ------------------------------------------------------------- alerts ---
    def alerts_page(self, req: Request, status: int = 200, errors=None, note: str = "", topic: str = "") -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.needs_account(ALERTS, "Alerts", status)
        kept = part(state, "alerts")
        errors = errors or {}
        ntfy = str(kept.get("ntfy") or "")
        topic = topic or f"https://ntfy.sh/firefly-pocket-{new_topic()}"
        url_error = errors.get("url", "")
        topic_form = f"""
    <form method="post" action="/alerts/ntfy" novalidate>
      <div class="field">
        <label for="url">Topic URL</label>
        <input id="url" name="url" value="{esc(topic)}" autocomplete="off" spellcheck="false"
               aria-describedby="url-help{' url-error' if url_error else ''}"{' aria-invalid="true"' if url_error else ''}>
        {f'<p class="error" id="url-error">{esc(url_error)}</p>' if url_error else ''}
        <p class="quiet" id="url-help">Made for this server. Anyone who knows its name can read what goes to it, so the
        name is long and random: keep it to yourself. Subscribe to it first, in the ntfy app (Android, iOS): Subscribe
        to topic, the name after <code>ntfy.sh/</code>. Then Save sends it a test alert, and the server keeps it once
        ntfy takes that.</p>
      </div>
      <button type="submit">Save and send a test</button>
    </form>"""
        if ntfy:
            ntfy_html = f"""
    <p class="good">This server sends alerts to its topic, <code>{esc(ntfy)}</code>.</p>
    <form method="post" action="/alerts/test"><button type="submit">Send a test alert</button></form>
    <details><summary>Another topic</summary>{topic_form}
      <form method="post" action="/alerts/ntfy"><input type="hidden" name="url" value="">
        <button type="submit" class="link">Send no alerts to ntfy</button></form>
    </details>"""
        else:
            ntfy_html = topic_form
        key_error = errors.get("key", "")
        checks_form = f"""
    <form method="post" action="/alerts/healthchecks" novalidate>
      {secret_field("key", "healthchecks.io API key", key_error,
                    "Your project's Settings, API Access: the read-write key. The server uses it once, to make the two "
                    "checks, and does not keep it.")}
      <button type="submit">Make the checks</button>
    </form>"""
        if kept.get("healthchecks"):
            checks_html = f"""
    <p class="good">Both checks are made: healthchecks.io mails you when the nightly import or the backup does not
    report in on time.</p>
    <details><summary>Make them again</summary>{checks_form}</details>"""
        else:
            checks_html = checks_form
        body = f"""
<section class="panel">
    <h1>Alerts</h1>
    {note}
    <p>When something fails (an import, a backup, a bank consent about to end), an alert goes to the Firefly Pocket
    app on your phone, and to <a href="https://ntfy.sh/" rel="noreferrer">ntfy</a>, which works even when Firefly
    Pocket does not.</p>
    <h2>ntfy</h2>
    {ntfy_html}
    <h2>A dead man's switch</h2>
    <p>Every alert above is sent from this server, so when it is down nothing alerts at all.
    <a href="https://healthchecks.io/" rel="noreferrer">healthchecks.io</a> (free) mails you when the nightly import or
    the backup does not report in on time. Its API key makes both checks, with their schedules in this server's
    timezone.</p>
    {checks_html}
    <h2>Next</h2>
    <p><a class="button" href="/backups">Next: Backups</a></p>
  </section>"""
        return self.page(status, "Alerts", body, signed_in=True, nav=stepper(ALERTS, state))

    def save_alerts(self, req: Request, what: str) -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.alerts_page(req, 409)
        form = req.form()
        if what == "test":
            if not part(state, "alerts").get("ntfy"):
                return self.alerts_page(req, 409)
            return self.hand_over(req, "ntfy_test", {}, self.alerts_page)
        if what == "ntfy":
            url = form.get("url", "").strip()
            if url and not URL_RE.fullmatch(url):
                return self.alerts_page(req, 400, {"url": "An http:// or https:// URL, without spaces"}, topic=url)
            return self.hand_over(req, "ntfy", {"url": url}, self.alerts_page)
        key = form.get("key", "").strip()
        if not API_KEY_RE.fullmatch(key):
            return self.alerts_page(req, 400, {"key": "An API key: at least 16 letters and digits"})
        return self.hand_over(req, "healthchecks", {"key": key}, self.alerts_page)

    # ------------------------------------------------------------ backups ---
    def new_repository_password(self, state: dict) -> str:
        """The password a new repository gets: made here, and the same on every
        view, so the one you kept is the one sent, until the server has made a
        repository with it. Then it is forgotten."""
        requests = part(state, "requests")
        with self.lock:
            result = requests.get(self.password_request) if self.password_request else None
            if isinstance(result, dict) and result.get("state") == "applied":
                self.restic_password, self.password_request = "", ""
            elif isinstance(result, dict) and result.get("state") in ("refused", "failed"):
                self.password_request = ""
            if not self.restic_password:
                self.restic_password = new_password()
            return self.restic_password

    def backups_page(self, req: Request, status: int = 200, values=None, errors=None, note: str = "") -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.needs_account(BACKUPS, "Backups", status)
        kept = part(state, "backups")
        repository = str(kept.get("repository") or "")
        key_id, secret_key = str(kept.get("access_key_id") or ""), str(kept.get("secret_access_key") or "")
        password = self.new_repository_password(state)
        values = values or {"repository": repository if "…" not in repository else "",
                            "mode": "existing" if repository else "new"}
        errors = errors or {}
        no_restic = ""
        if kept.get("restic") is False:
            no_restic = ('<p class="error">restic is not installed on this server. On the server: '
                         "<code>sudo apt-get install -y restic</code>, then save this.</p>")

        def text_field(name: str, label: str, help_text: str, value: str = "", placeholder: str = "") -> str:
            error = errors.get(name, "")
            described = f"{name}-help" + (f" {name}-error" if error else "")
            return f"""
      <div class="field">
        <label for="{name}">{esc(label)}</label>
        <input id="{name}" name="{name}" value="{esc(value)}" autocomplete="off" spellcheck="false"
               {f'placeholder="{esc(placeholder)}" ' if placeholder else ''}aria-describedby="{described}"{' aria-invalid="true"' if error else ''}>
        {f'<p class="error" id="{name}-error">{esc(error)}</p>' if error else ''}
        <p class="quiet" id="{name}-help">{help_text}</p>
      </div>"""

        keeps = " Empty keeps this server's, <code>{}</code>."
        mode = values.get("mode", "new")
        mode_error = errors.get("mode", "")
        form = f"""
    <form method="post" action="/backups" novalidate>
      {text_field("repository", "Repository",
                  "S3 storage (Backblaze B2, Hetzner Object Storage, AWS) as <code>s3:https://&lt;endpoint&gt;/&lt;bucket&gt;/"
                  "&lt;folder&gt;</code>; restic's other kinds (<code>sftp:</code>, <code>rest:</code>, a path) work too.",
                  values.get("repository", ""), REPOSITORY_EXAMPLE)}
      {text_field("access_key_id", "S3 access key ID",
                  "For S3 only." + (keeps.format(esc(key_id)) if key_id else ""))}
      {secret_field("secret_access_key", "S3 secret access key", errors.get("secret_access_key", ""),
                    "For S3 only. Kept on the server: this page shows its last four characters, never the key."
                    + (f" Empty keeps this server's, {secret_key}." if secret_key else ""), required=False)}
      <fieldset class="field"><legend>Its password</legend>
        {f'<p class="error">{esc(mode_error)}</p>' if mode_error else ''}
        <label class="choice"><input type="radio" name="mode" value="new"{" checked" if mode == "new" else ""}>
          A new repository: the server makes it, with this password</label>
        <div class="indent">
          <p class="password"><code>{esc(password)}</code></p>
          <input type="hidden" name="new_password" value="{esc(password)}">
          <p class="quiet">Keep it off this server, in your password manager: without it nobody can read the copy,
          you included, once this server is gone. This page shows it until the server has made the repository,
          and never again.</p>
          <label class="choice"><input type="checkbox" name="saved" value="yes"{" checked" if values.get("saved") else ""}{
            ' aria-invalid="true" aria-describedby="saved-error"' if errors.get("saved") else ''}>
            I have kept this password off this server</label>
          {f'<p class="error" id="saved-error">{esc(errors["saved"])}</p>' if errors.get("saved") else ''}
        </div>
        <label class="choice"><input type="radio" name="mode" value="existing"{" checked" if mode == "existing" else ""}>
          One restic uses already: its password</label>
        <div class="indent">
          {secret_field("password", "Password", errors.get("password", ""),
                        "As you kept it when the repository was made."
                        + (" Empty: this server's, the one it backs up with now." if repository else ""), required=False)}
        </div>
      </fieldset>
      <button type="submit">Check and save</button>
    </form>
    <p class="quiet">The server opens the repository with restic, or makes it, before it keeps any of this.</p>"""
        if repository:
            saved_html = f"""
    <p class="good">This server backs up to <code>{esc(repository)}</code> each night.</p>
    <details{" open" if errors else ""}><summary>Another repository, or new keys</summary>{form}</details>"""
            after = '<p><a class="button" href="/updates">Next: Updates</a></p>'
        else:
            saved_html = form
            after = """<p>Without one, losing this server loses everything. <a href="/updates">Skip it for now</a>: on the
    server, <code>scripts/firefly-pocket setup backups</code> does it later.</p>"""
        body = f"""
<section class="panel">
    <h1>Backups</h1>
    {note}
    <p>At 02:00 each night the databases, the attachments and the settings are backed up on this server. A
    <a href="https://restic.net/" rel="noreferrer">restic</a> repository keeps an encrypted copy off it too.</p>
    {no_restic}
    {saved_html}
    <h2>Next</h2>
    {after}
  </section>"""
        return self.page(status, "Backups", body, signed_in=True, nav=stepper(BACKUPS, state))

    def save_backups(self, req: Request) -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.backups_page(req, 409)
        kept = part(state, "backups")
        form = req.form()
        repository = form.get("repository", "").strip()
        key_id = form.get("access_key_id", "").strip()
        secret_key = form.get("secret_access_key", "").strip()
        mode = form.get("mode", "")
        values = {"repository": repository, "mode": mode, "saved": form.get("saved", "")}
        errors: dict[str, str] = {}
        if not REPOSITORY_RE.fullmatch(repository):
            errors["repository"] = "A restic repository, without spaces: such as " + REPOSITORY_EXAMPLE
        if repository.startswith("s3:"):
            if not key_id and not kept.get("access_key_id"):
                errors["access_key_id"] = "S3 needs it"
            if not secret_key and not kept.get("secret_access_key"):
                errors["secret_access_key"] = "S3 needs it"
        for name, value in (("access_key_id", key_id), ("secret_access_key", secret_key)):
            if value and not REPOSITORY_RE.fullmatch(value):
                errors[name] = "No spaces"
        fields = {"repository": repository, "access_key_id": key_id, "secret_access_key": secret_key, "mode": mode}
        if mode == "new":
            password = form.get("new_password", "")
            if len(password) < 16 or not password.isalnum() or not password.isascii():
                errors["mode"] = "Choose again: that password is not one this page made"
            elif form.get("saved") != "yes":
                errors["saved"] = "Keep it first: without it nobody can read the copy"
            else:
                # The one shown again, if the server refuses the repository.
                with self.lock:
                    self.restic_password = password
            fields["password"] = password
        elif mode == "existing":
            password = form.get("password", "")
            if any(ord(c) < 32 or ord(c) == 127 for c in password):
                errors["password"] = "No control characters"
            elif not password and not kept.get("repository"):
                errors["password"] = "Its password"
            fields["password"] = password
        else:
            errors["mode"] = "A new repository, or one restic uses already"
        if errors:
            return self.backups_page(req, 400, values, errors)
        return self.hand_over(req, "backups", fields, self.backups_page)

    # ------------------------------------------------------------ updates ---
    def updates_page(self, req: Request, status: int = 200, note: str = "") -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.needs_account(UPDATES, "Updates", status)
        kept = part(state, "updates")
        origin = str(kept.get("origin") or "")
        finish, finish_name = ("/", "Your server") if state.get("setup_done") is True else ("/finish", "Finish")
        repository = f"<code>{esc(origin)}</code>" if origin else "the repository this server was installed from"
        if kept.get("agent") is True:
            now = f"""
    <p class="good">The deploy agent is on: this server follows master of {repository}.</p>
    <p class="quiet">To turn it off, on the server: <code>sudo systemctl disable --now fireflyx-deploy.timer</code>. Then
    nothing runs on a schedule.</p>"""
            after = f'<p><a class="button" href="{finish}">Next: {finish_name}</a></p>'
        else:
            now = """
    <p><span class="bad">Off:</span> nothing runs on a schedule, so no nightly import and no backup.</p>
    <form method="post" action="/updates"><button type="submit">Turn on the deploy agent</button></form>
    <p class="quiet">Its timer is a systemd unit, so the server's user needs sudo without a password, as a server made
    from <code>terraform/cloud-init.yaml</code> has. Without it, on the server: <code>scripts/firefly-pocket setup
    updates</code>, which asks for the password.</p>"""
            after = f"""<p><a href="{finish}">Skip it for now</a>: on the server, <code>scripts/firefly-pocket setup updates</code>
    does it later.</p>"""
        body = f"""
<section class="panel">
    <h1>Updates</h1>
    {note}
    <p>The deploy agent keeps this server up to date. Every two minutes it looks at master of {repository}, and when it
    has moved, deploys it: every image pulled first, and a backup that is shown to restore before Firefly III,
    Postgres or the importer changes, as they migrate their databases. A failure alerts you.</p>
    <p>It also runs the nightly jobs: the backup at 02:00, the bank import at 03:00, and on Sundays the restore tests,
    from this server's copy and from the offsite one.</p>
    {now}
    <p class="quiet">Following a release channel (stable or latest) instead of master comes later.</p>
    <h2>Next</h2>
    {after}
  </section>"""
        return self.page(status, "Updates", body, signed_in=True, nav=stepper(UPDATES, state))

    def save_updates(self, req: Request) -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            return self.updates_page(req, 409)
        return self.hand_over(req, "updates", {}, self.updates_page)

    # ------------------------------------------------------------- finish ---
    def finish_page(self, req: Request, status: int = 200, note: str = "") -> Response:
        state = read_status(self.status_file)
        if not account_made(state):
            body = f"""
<section class="panel">
    <h1>Finish</h1>
    <p>Make the Firefly III account first: finishing before it would leave this server showing only this
    console, with no code to open it.</p>
    <p><a class="button" href="/account">Firefly III account</a></p>
  </section>"""
            return self.page(status, "Finish", body, signed_in=True, nav=stepper(FINISH, state))
        body = f"""
<section class="panel">
    <h1>Finish</h1>
    {note}
    {summary(state)}
    <p class="quiet">Each step was applied as you saved it. To change one, open its page; after Finish, on the server:
    <code>scripts/firefly-pocket setup &lt;step&gt;</code>.</p>
    <h2>Finish setup</h2>
    <p>Then the setup code works no more, and this console opens only to you, signed in with Firefly III.</p>
    <form method="post" action="/finish"><button type="submit">Finish setup</button></form>
  </section>"""
        return self.page(status, "Finish", body, signed_in=True, nav=stepper(FINISH, state))

    def save_finish(self, req: Request) -> Response:
        if not account_made(read_status(self.status_file)):
            return self.finish_page(req, 409)
        return self.hand_over(req, "finish", {}, self.finish_page)

    def request_page(self, req: Request, rid: str) -> Response:
        state = read_status(self.status_file)
        requests = state.get("requests") if isinstance(state.get("requests"), dict) else {}
        result = requests.get(rid)
        with self.lock:
            started, action, moves_to = self.pending.get(rid, (0.0, "", ""))
        if isinstance(result, dict):
            action = str(result.get("action") or action)
        done, not_done, working = OUTCOME.get(action, OUTCOME["server"])
        back = BACK.get(action, "/server")
        # Where the nav leads is where the request belongs; not once Finish is applied (the console restarts) and not
        # for a domain change (this host goes away): their links would lead nowhere.
        finished = action == "finish" and isinstance(result, dict) and result.get("state") == "applied"
        nav = "" if finished or moves_to else stepper(step_of(back), state)
        after = state.get("setup_done") is True
        back_label = "Back" if after else "Back to setup"
        if isinstance(result, dict) and result.get("state") in ("applied", "refused", "failed"):
            message = esc(result.get("message") or "")
            if result.get("state") != "applied":
                return self.page(200, not_done, f'<section class="narrow"><h1>{not_done}</h1><p class="error">{message}</p>'
                                 f'<p><a class="button" href="{back}">{back_label}</a></p></section>', signed_in=True, nav=nav)
            if action == "bank_key":  # nothing to read: the bank page shows the certificate
                return redirect("/bank")
            if action == "backups":  # a new repository's password is not shown again
                self.new_repository_password(state)
            links = f'<a class="button" href="{back}">{back_label}</a>'
            if after:
                links = f'<a class="button" href="/">Your server</a> <a href="{back}">Back</a>'
            elif action in NEXT:
                path, name = NEXT[action]
                links = f'<a class="button" href="{path}">Next: {esc(name)}</a> <a href="{back}">Back</a>'
            elif action == "finish":
                links = 'This console starts again without the code: <a href="/">open it again</a> in a moment.'
            return self.page(200, done, f'<section class="narrow"><h1>{done}</h1><p>{message}</p><p>{links}</p></section>',
                             signed_in=True, nav=nav)
        takes = {"account": "This takes a few minutes.", "backups": "This can take a minute.",
                 "updates": "This can take a minute."}.get(
            action, "This takes a few seconds.")
        if isinstance(result, dict):  # running: the server says how far it got
            if self.stale(result):
                body = f"""<section class="narrow"><h1>{not_done}</h1>
  <p>The server stopped working on it, after: {esc(result.get("message") or "")}</p>
  <p class="error">On the server, <code>journalctl -u firefly-pocket-console</code> says why.</p>
  <p><a class="button" href="{back}">{back_label}</a></p></section>"""
                return self.page(200, not_done, body, signed_in=True, nav=nav)
            body = f"""<section class="narrow"><h1>{working}</h1>
  <p>{esc(result.get("message") or "")}</p>
  <p class="quiet">{takes} This page looks again every few seconds; reload it if it shows an
  error while Caddy starts again.</p></section>"""
            return self.page(202, working, body, refresh=3, signed_in=True, nav=nav)
        if not started:
            return self.page(404, "Not found", NOT_FOUND, signed_in=True)
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
        body = f"""<section class="narrow"><h1>{working}</h1>
  <p>The server checks what you sent and applies it. {takes} This page looks again every few seconds; reload it
  if it shows an error while Caddy starts again.</p>{hint}</section>"""
        return self.page(202, working, body, refresh=3, signed_in=True, nav=nav)

    # -------------------------------------------------------- after setup ---
    def after_setup(self, req: Request, state: dict) -> Response:
        """Setup is finished: only Firefly III's account owner, signed in with
        Firefly III, gets further than where things are."""
        path = req.path
        if path == "/signin" and req.method != "POST":
            return self.start_signin(state)
        if path == "/oauth/callback" and req.method != "POST":
            return self.signin_callback(req, state)
        if path == "/logout" and req.method == "POST":
            return self.logout(req)
        if not self.owner_signed_in(req):
            return self.finished(state)
        post = req.method == "POST"
        if path == "/":
            return self.overview(state)
        if path == "/bank":
            return self.save_bank(req) if post else self.bank_page(req)
        if path == "/bank/key" and post:
            return self.make_key(req)
        if path == "/bank/certificate" and not post:
            return self.certificate()
        if path == "/suggestions":
            return self.save_suggestions(req) if post else self.suggestions_page(req)
        if path == "/alerts" and not post:
            return self.alerts_page(req)
        if path in ("/alerts/ntfy", "/alerts/test", "/alerts/healthchecks") and post:
            return self.save_alerts(req, path.rsplit("/", 1)[1])
        if path == "/backups":
            return self.save_backups(req) if post else self.backups_page(req)
        if path == "/updates":
            return self.save_updates(req) if post else self.updates_page(req)
        match = re.fullmatch(r"/requests/([0-9a-f]{32})", path)
        if match and not post:
            return self.request_page(req, match.group(1))
        # The Server step, the account and Finish are done: the overview.
        return redirect("/")

    def importer_auth(self, req: Request) -> Response:
        """Caddy's forward_auth for the importer's own pages, under /importer/ on
        this host (Hostnames and routing step 7): 204 lets the request through,
        anything else is what the browser gets instead. The same sign-in as the
        console's: the setup code during setup, Firefly III's owner after it."""
        state = read_status(self.status_file)
        if not self.code or (state.get("setup_done") is True and "account" in state):
            allowed = self.owner_signed_in(req)
        else:
            allowed = self.signed_in(req)
        if allowed:
            return Response(204, b"", "text/plain; charset=utf-8", [("Cache-Control", "no-store")])
        return redirect("/", [("Cache-Control", "no-store")])

    def owner_signed_in(self, req: Request) -> bool:
        token = req.cookie(COOKIE)
        with self.lock:
            return token in self.owner_sessions and self.sessions.get(token, 0) > self.clock()

    def start_signin(self, state: dict) -> Response:
        client_id = str(part(state, "signin").get("client_id") or "")
        hosts = hosts_of(state)
        if not client_id or not hosts.get("firefly") or not hosts.get("admin"):
            return self.finished(state, 503)
        now = self.clock()
        signin = secrets.token_urlsafe(24)
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        with self.lock:
            self.signins = {k: v for k, v in self.signins.items() if v[1] > now}
            self.signins[signin] = (verifier, now + SIGNIN_SECONDS)
        query = urlencode({"client_id": client_id, "redirect_uri": f"https://{hosts['admin']}/oauth/callback",
                           "response_type": "code", "scope": "", "state": signin,
                           "code_challenge": challenge, "code_challenge_method": "S256"})
        # Lax: the browser comes back here from Firefly III, another host.
        cookie = f"{SIGNIN_COOKIE}={signin}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age={SIGNIN_SECONDS}"
        return redirect(f"https://{hosts['firefly']}/oauth/authorize?{query}", [("Set-Cookie", cookie)])

    def signin_callback(self, req: Request, state: dict) -> Response:
        query = {k: v[0] for k, v in parse_qs(urlsplit(req.target).query, max_num_fields=10).items()}
        given = query.get("state", "")
        with self.lock:
            pending = self.signins.pop(given, None) if given else None
        clear = [("Set-Cookie", f"{SIGNIN_COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0")]
        if not pending or pending[1] <= self.clock() or not hmac.compare_digest(given, req.cookie(SIGNIN_COOKIE)):
            return self.not_signed_in(400, "That sign-in did not start here, or took longer than ten minutes.", clear)
        if query.get("error"):
            said = query.get("error_description") or query.get("error")
            return self.not_signed_in(403, f"Firefly III said: {said}", clear)
        client_id = str(part(state, "signin").get("client_id") or "")
        hosts = hosts_of(state)
        firefly = hosts.get("firefly", "")
        status, answer = self.firefly("POST", firefly, "/oauth/token", form={
            "grant_type": "authorization_code", "client_id": client_id,
            "redirect_uri": f"https://{hosts.get('admin', '')}/oauth/callback",
            "code": query.get("code", ""), "code_verifier": pending[0]})
        access = answer.get("access_token") if status == 200 else None
        if not isinstance(access, str) or not access:
            return self.not_signed_in(502, f"Firefly III did not give this console a token (HTTP {status or 'no answer'}).",
                                      clear)
        status, about = self.firefly("GET", firefly, "/api/v1/about/user", token=access)
        email = str(part(part(about, "data"), "attributes").get("email") or "") if status == 200 else ""
        owner = str(part(state, "settings").get("SITE_OWNER") or "")
        if not email:
            return self.not_signed_in(502, f"Firefly III did not say who signed in (HTTP {status or 'no answer'}).", clear)
        if not owner or email.casefold() != owner.casefold():
            return self.not_signed_in(403, f"You signed in to Firefly III as {email}, and this console is only for "
                                           f"{owner or 'the account the server was set up for'}.", clear)
        now = self.clock()
        session = secrets.token_urlsafe(32)
        with self.lock:
            self.sessions = {t: until for t, until in self.sessions.items() if until > now}
            self.owner_sessions = {t: a for t, a in self.owner_sessions.items() if t in self.sessions}
            self.sessions[session] = now + SESSION_SECONDS
            self.owner_sessions[session] = access
        cookie = f"{COOKIE}={session}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age={SESSION_SECONDS}"
        return redirect("/", clear + [("Set-Cookie", cookie)])

    def not_signed_in(self, status: int, why: str, headers: list[tuple[str, str]]) -> Response:
        body = f"""<section class="narrow"><h1>Not signed in</h1><p class="error">{esc(why)}</p>
  <p><a class="button" href="/signin">Sign in with Firefly III</a></p></section>"""
        resp = self.page(status, "Not signed in", body)
        resp.headers.extend(headers)
        return resp

    def overview(self, state: dict) -> Response:
        owner = str(part(state, "settings").get("SITE_OWNER") or "")
        body = f"""<section class="narrow">
  <h1>Your server</h1>
  <p>Signed in with Firefly III as {esc(owner)}.</p>
  {summary(state)}
  <p class="quiet">Open a step to change it: the server checks each change with Firefly III, as you, before it applies
  it. The domain and your details change on the server: <code>scripts/firefly-pocket setup domain</code>, or
  <code>setup you</code>.</p>
  <p>The importer's own pages, for an import by hand or a look at its settings, are behind this sign-in too:
  <a href="/importer/">open the importer</a>.</p>
  <p class="quiet">This sign-in lasts eight hours; then Firefly III takes the console's token no more. Sign out when
  you are done.</p>
</section>"""
        return self.page(200, "Your server", body, signed_in=True, nav=stepper(None, state))

    def finished(self, state: dict, status: int = 200) -> Response:
        hosts = hosts_of(state)
        links = ""
        for role in ("firefly", "app"):
            if hosts.get(role):
                links += f'<li>{esc(ROLES[role])}: <a href="https://{esc(hosts[role])}/">https://{esc(hosts[role])}/</a></li>'
        # A step can fail after the account is made: starting the rest, say.
        last = latest(state)
        problem = ""
        if last.get("state") == "failed":
            problem = f'<p class="error">The server\'s last step did not finish: {esc(last.get("message") or "")}</p>'
        if part(state, "signin").get("client_id"):
            signin = """<h2>This console</h2>
  <p>It shows what the server has, and changes it, for you only: <a class="button" href="/signin">Sign in with Firefly III</a></p>
  <p class="quiet">Firefly III asks for your password, and its two-factor code once you have turned that on. The
  first time it also asks whether to let the console in.</p>"""
        else:
            signin = """<h2>This console</h2>
  <p class="quiet">Signing in here with Firefly III comes with the server's next deploy, which registers the console
  in Firefly III. On the server, <code>scripts/firefly-pocket console client</code> does it now.</p>"""
        body = f"""<section class="narrow">
  <h1>Setup is finished</h1>
  <p>Firefly III has its account, every name is open, and the setup code works no more.</p>
  {problem}
  {f'<ul>{links}</ul>' if links else ''}
  <p>Sign in to Firefly III with your email and password, and turn on two-factor authentication there:
  Options, Profile. Firefly Pocket asks for a token: in Firefly III, Options, Profile, OAuth, Personal Access
  Tokens, Create one named after the phone.</p>
  {signin}
  <h2>Changing a step</h2>
  <p>Signed in here, open the step: bank, suggestions, alerts, backups, updates. Or on the server,
  <code>scripts/firefly-pocket setup &lt;step&gt;</code>.</p>
</section>"""
        return self.page(status, "Setup is finished", body)

    # -------------------------------------------------------------- pages ---
    def page(self, status: int, title: str, main: str, refresh: int | None = None, signed_in: bool = False,
             nav: str = "") -> Response:
        """A page in the console's shell. With a nav (`stepper()`), the step navigation sits beside it (above it on a
        phone) and stays in view; without one the page stands alone: sign-in, results that move the console, errors."""
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
<div class="app{' has-nav' if nav else ''}">
<div class="rail">
<header><span class="brand"><strong>Firefly Pocket</strong> Console</span>{logout}</header>
{nav}
</div>
<main>{main}</main>
</div>
</body>
</html>
"""
        return Response(status, doc.encode("utf-8"))


def summary(state: dict) -> str:
    """What each step left, one row each, with a link to each page that can
    change it: Finish's, and the signed-in overview's after setup."""
    settings = part(state, "settings")
    hosts = hosts_of(state)
    app_id = str(part(state, "bank").get("app_id") or "")
    firefly = hosts.get("firefly", "")
    bank = (f"the application <code>{esc(app_id)}</code>" if app_id else
            '<span class="bad">not yet: Firefly Pocket links no bank until it is.</span> On the server, '
            "<code>scripts/firefly-pocket setup bank</code> does it later.")
    kept = part(state, "suggestions")
    keys = [f"{name}'s key, <code>{esc(kept.get(key))}</code>" for key, name in PROVIDERS.items() if kept.get(key)]
    suggestions = (f"{' and '.join(keys)}, for <code>{esc(kept.get('model') or DEFAULT_MODEL)}</code>" if keys else
                   '<span class="bad">not yet: no suggestions until it is.</span> '
                   "<code>scripts/firefly-pocket setup suggestions</code> does it later.")
    alerts_kept = part(state, "alerts")
    alerts = [f"ntfy, <code>{esc(alerts_kept.get('ntfy'))}</code>"] if alerts_kept.get("ntfy") else []
    if alerts_kept.get("healthchecks"):
        alerts.append("healthchecks.io's two checks")
    alerts_html = (", and ".join(alerts) if alerts else
                   '<span class="bad">only the Firefly Pocket app:</span> no ntfy, and nothing tells you when this '
                   "server is down. <code>scripts/firefly-pocket setup alerts</code> does it later.")
    repository = str(part(state, "backups").get("repository") or "")
    backups_html = (f"each night to <code>{esc(repository)}</code>" if repository else
                    '<span class="bad">on this server only:</span> losing it loses everything. '
                    "<code>scripts/firefly-pocket setup backups</code> does it later.")
    updates_html = ("the deploy agent is on: this server follows master, and the nightly jobs run"
                    if part(state, "updates").get("agent") is True else
                    '<span class="bad">off: nothing runs on a schedule,</span> so no nightly import and no backup. '
                    "<code>scripts/firefly-pocket setup updates</code> does it later.")
    rows = (("Server", "/server", f"{esc(settings.get('DOMAIN') or '')}, {esc(settings.get('SITE_OWNER') or '')}, "
                                  f"{esc(settings.get('TZ') or '')}"),
            ("Firefly III account", "/account", f"made: you sign in at <code>https://{esc(firefly)}</code>"),
            ("Bank connection", "/bank", bank), ("Suggestions", "/suggestions", suggestions),
            ("Alerts", "/alerts", alerts_html), ("Backups", "/backups", backups_html), ("Updates", "/updates", updates_html))
    body = ""
    for name, path, value in rows:
        changes = path not in ("/server", "/account") or state.get("setup_done") is not True
        head = f'<a href="{path}">{name}</a>' if changes else name
        body += f'<tr><th scope="row">{head}</th><td>{value}</td></tr>'
    return f'<table class="settings"><tbody>{body}</tbody></table>'


def next_step(state: dict) -> str:
    """The first page with something left to do."""
    if not account_made(state):
        return "/account" if server_saved(state) else "/server"
    done = steps_done(state)
    for step, path in ((BANK, "/bank"), (SUGGESTIONS, "/suggestions"), (ALERTS, "/alerts"), (BACKUPS, "/backups"),
                       (UPDATES, "/updates")):
        if step not in done:
            return path
    return "/finish"


def steps_done(state: dict) -> set[int]:
    done = {SERVER} if server_saved(state) else set()
    if account_made(state):
        done.add(ACCOUNT)
    if part(state, "bank").get("app_id"):
        done.add(BANK)
    suggestions = part(state, "suggestions")
    if any(suggestions.get(key) for key in PROVIDERS):
        done.add(SUGGESTIONS)
    alerts = part(state, "alerts")
    if alerts.get("ntfy") or alerts.get("healthchecks"):
        done.add(ALERTS)
    if part(state, "backups").get("repository"):
        done.add(BACKUPS)
    if part(state, "updates").get("agent") is True:
        done.add(UPDATES)
    return done


def new_topic() -> str:
    """24 lower-case letters and digits, as the wizard makes an ntfy topic's name."""
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(24))


def new_password() -> str:
    """A new repository's password: as gen-secrets.sh makes RESTIC_PASSWORD."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(RESTIC_PASSWORD_LENGTH))


def step_of(path: str) -> int:
    """The step whose page is `path`."""
    return next(i for i, (_, page) in enumerate(STEPS) if page == path)


def stepper(current: int | None, state: dict) -> str:
    """The step navigation: before setup the eight steps; after it the overview (current None, after setup only)
    and the steps that change from here. `where` is the phone bar's fixed label, since CSS cannot scroll the
    current pill into view."""
    done = steps_done(state)
    if state.get("setup_done") is True:
        if current is not None and not BANK <= current <= UPDATES:  # an old Server, Account or Finish request page
            current = None
        overview = current is None
        kind = "now" if overview else "done"
        aria = ' aria-current="page"' if overview else ""
        label = "Your server" if overview else '<a href="/">Your server</a>'
        items = f'<li class="{kind}"{aria}>{label}</li>'
        where = "Your server" if overview else STEPS[current][0]
        for i, (name, path) in enumerate(STEPS):
            if BANK <= i <= UPDATES:
                kind = "now" if i == current else ("done" if i in done else "later")
                aria = ' aria-current="page"' if i == current else ""
                label = f'<a href="{path}">{esc(name)}</a>' if i != current else esc(name)
                items += f'<li class="{kind}"{aria}>{label}</li>'
        return (f'<nav class="steps" aria-label="Your server"><p class="where">{esc(where)}</p>'
                f'<ol class="after">{items}</ol></nav>')
    items = ""
    for i, (name, path) in enumerate(STEPS):
        kind = "now" if i == current else ("done" if i in done else "later")
        aria = ' aria-current="step"' if i == current else ""
        label = f'<a href="{path}">{esc(name)}</a>' if path and i != current else esc(name)
        items += f'<li class="{kind}"{aria}>{label}</li>'
    where = f"Step {current + 1} of {len(STEPS)} · {STEPS[current][0]}"
    return f'<nav class="steps" aria-label="Setup steps"><p class="where">{esc(where)}</p><ol>{items}</ol></nav>'


def password_field(name: str, label: str, error: str, help_text: str) -> str:
    """A new password: never filled in again, after an error either."""
    described = " ".join(x for x in (f"{name}-help" if help_text else "", f"{name}-error" if error else "") if x)
    return f"""
      <div class="field">
        <label for="{name}">{esc(label)}</label>
        <input id="{name}" name="{name}" type="password" autocomplete="new-password" minlength="{MIN_PASSWORD}"
               required{' aria-invalid="true"' if error else ''}{f' aria-describedby="{described}"' if described else ''}>
        {f'<p class="error" id="{name}-error">{esc(error)}</p>' if error else ''}
        {f'<p class="quiet" id="{name}-help">{esc(help_text)}</p>' if help_text else ''}
      </div>"""


def secret_field(name: str, label: str, error: str, help_text: str, required: bool = True) -> str:
    """A key to send to the server: never shown again, after an error either."""
    described = " ".join(x for x in (f"{name}-help", f"{name}-error" if error else "") if x)
    return f"""
      <div class="field">
        <label for="{name}">{esc(label)}</label>
        <input id="{name}" name="{name}" type="password" autocomplete="off" spellcheck="false"
               {'required' if required else ''}{' aria-invalid="true"' if error else ''} aria-describedby="{described}">
        {f'<p class="error" id="{name}-error">{esc(error)}</p>' if error else ''}
        <p class="quiet" id="{name}-help">{esc(help_text)}</p>
      </div>"""


NO_INBOX = (
    '<p class="error">The console could not hand this to the server: it cannot write to '
    "compose/console/inbox. On the server: <code>scripts/firefly-pocket console status</code> "
    "makes it as it should be.</p>"
)


def redirect(location: str, headers: list[tuple[str, str]] | None = None) -> Response:
    return Response(303, b"", "text/plain; charset=utf-8", [("Location", location), *(headers or [])])


def same_origin(req: Request) -> bool:
    """A POST must come from a page of this console: its Origin is this host,
    as the browser saw it through Caddy. With this, and the cookie's SameSite=Lax
    (which a browser leaves off a POST from another site), no other site can make
    a signed-in browser save anything. Lax, not Strict: a bank sends the browser
    back to the importer behind this console (/auth/importer) from its own site,
    and a Strict cookie stays off that whole chain of redirects.

    A browser sends Origin "null" where a referrer policy hides it (no-referrer
    does, even for a form on the same page): then Sec-Fetch-Site decides, which
    no page can set, and which says cross-site for a sandboxed frame elsewhere."""
    host = req.headers.get("host", "")
    proto = req.headers.get("x-forwarded-proto", "https")
    origin = req.headers.get("origin")
    if origin is not None and origin != "null":
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
    # same-origin, not no-referrer: no-referrer makes a browser send Origin
    # "null" with this console's own forms.
    ("Referrer-Policy", "same-origin"),
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
    state = "waiting for the setup code" if console.code else "no setup code: setup is finished, or not begun"
    print(f"Firefly Pocket Console on :{port}, {state}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
