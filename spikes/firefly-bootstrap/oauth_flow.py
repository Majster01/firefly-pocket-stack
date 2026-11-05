"""Spike: 'Sign in with Firefly III' end to end with an authorization-code client and PKCE."""
import base64, hashlib, html, http.cookiejar, json, os, re, secrets, sys, urllib.parse, urllib.request

BASE = "http://127.0.0.1:8080"
REDIRECT = "http://127.0.0.1:9999/callback"
EMAIL = os.environ.get("FX_EMAIL", "owner@example.com")
PASSWORD = os.environ.get("FX_PASSWORD", "Spike-Passw0rd-2026!")
client = json.load(open(os.environ.get("FX_CLIENT_JSON", "client.json")))  # {"id": ..., "secret": ...} from bootstrap.php

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar), NoRedirect)

def call(method, path, data=None, headers=None):
    url = path if path.startswith("http") else BASE + path
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        r = opener.open(req)
        return r.status, r.headers, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode()

def csrf(page):
    return re.search(r'name="_token" value="([^"]+)"', page).group(1)

# 1-2. Log in to Firefly III's own web UI (in the console, the person does this in their browser).
_, _, page = call("GET", "/login")
s, h, _ = call("POST", "/login", {"_token": csrf(page), "email": EMAIL, "password": PASSWORD})
print("login:", s, h.get("Location"))

def authorize():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    q = urllib.parse.urlencode({"client_id": client["id"], "redirect_uri": REDIRECT, "response_type": "code",
                                "scope": "", "state": "st-123", "code_challenge": challenge, "code_challenge_method": "S256"})
    s, h, page = call("GET", "/oauth/authorize?" + q)
    if s == 200:
        print("authorize: approval page shown")
        approve = page.split("</form>")[0]  # the first form approves, the second (DELETE) denies
        form = {n: v for n, v in (
            (re.search(r'name="([^"]+)"', i).group(1), re.search(r'value="([^"]*)"', i).group(1))
            for i in re.findall(r"<input[^>]*>", approve))}
        s, h, _ = call("POST", "/oauth/authorize", {k: html.unescape(v) for k, v in form.items()})
    else:
        print("authorize: no approval page, status", s)
    loc = h.get("Location")
    params = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
    print("redirected to callback:", loc.split("?")[0], "state ok:", params.get("state") == ["st-123"])
    return params["code"][0], verifier

code, verifier = authorize()
s, _, body = call("POST", "/oauth/token", {"grant_type": "authorization_code", "client_id": client["id"],
                  "client_secret": client["secret"], "redirect_uri": REDIRECT, "code": code, "code_verifier": verifier})
tok = json.loads(body)
print("token:", s, tok.get("token_type"), "expires_in", tok.get("expires_in"), "refresh:", bool(tok.get("refresh_token")))
s, _, body = call("GET", "/api/v1/about/user", headers={"Authorization": "Bearer " + tok["access_token"], "Accept": "application/vnd.api+json"})
d = json.loads(body)["data"]
print("about/user:", s, d["attributes"]["email"], d["attributes"]["role"])

print("--- second sign-in")
authorize()

s, _, body = call("POST", "/oauth/token", {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
                  "client_id": client["id"], "client_secret": client["secret"], "scope": ""})
print("refresh:", s, "new access token:", bool(json.loads(body).get("access_token")))
