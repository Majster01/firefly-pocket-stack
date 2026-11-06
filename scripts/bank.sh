# shellcheck shell=bash
# Enable Banking: the key this server makes for your application, its
# certificate, and the check that Enable Banking takes a request signed with the
# key. For the setup wizard's bank step (setup.sh), the console's (console.sh)
# and scripts/set-eb-key.sh, so each does it the same way. Sourced by a script
# that sets REPO_ROOT; make_eb_key also needs FP, and lib.sh before it.

EB_CERT="$REPO_ROOT/compose/secrets/eb/application.crt"
# Where the check asks. Another only in the boot test, which answers it itself.
EB_API="${EB_API:-https://api.enablebanking.com}"

# eb_redirect_urls: where a bank sends the browser back, which the application
# must list: a link started from Firefly Pocket comes back to its host, one from
# the importer's UI to the importer's. After lib.sh.
eb_redirect_urls() { printf 'https://%s/eb-callback\n' "$NEXT_HOSTNAME" "$IMPORT_HOSTNAME"; }

# eb_pem <base64>: the key as the importer rebuilds it from the store, on stdout.
eb_pem() {
  echo "-----BEGIN PRIVATE KEY-----"
  fold -w64 <<<"$1"
  echo "-----END PRIVATE KEY-----"
}

# make_eb_key <dir>: a new key, into the store, and its certificate (public)
# into EB_CERT. The application ID goes: it was the old key's. <dir> must be
# private (mktemp -d), as the key passes through it. The caller renders. On a
# failure, EB_PROBLEM says why; the key and the ID are changed only once the
# certificate is in place beside the old one.
# shellcheck disable=SC2034  # EB_PROBLEM is the caller's
make_eb_key() {
  local dir="$1" certs b64
  certs="$(dirname "$EB_CERT")"
  mkdir -p "$certs" 2>/dev/null || true
  if [ ! -w "$certs" ]; then
    EB_PROBLEM="$certs is not writable by $(id -un): Docker made it, as root, before setup did. On the server: sudo chown $(id -un) $certs"
    return 1
  fi
  EB_PROBLEM="openssl could not make the key and its certificate"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$dir/eb.pem" 2>/dev/null || return 1
  openssl req -new -x509 -key "$dir/eb.pem" -days 3650 -subj "/CN=$NEXT_HOSTNAME" -out "$dir/eb.crt" 2>/dev/null \
    || { rm -f "$dir/eb.pem"; return 1; }
  b64="$(grep -v -- '-----' "$dir/eb.pem" | tr -d '\n\r')"
  rm -f "$dir/eb.pem"
  EB_PROBLEM="the certificate could not be written to $certs"
  install -m 644 "$dir/eb.crt" "$EB_CERT.new" || return 1
  EB_PROBLEM="the settings store did not take the new key"
  "$FP" config set --no-render ENABLE_BANKING_PRIVATE_KEY - <<<"$b64" >/dev/null || { rm -f "$EB_CERT.new"; return 1; }
  if "$FP" config has ENABLE_BANKING_APP_ID; then
    "$FP" config unset ENABLE_BANKING_APP_ID >/dev/null || return 1
  fi
  mv -f "$EB_CERT.new" "$EB_CERT"
  EB_PROBLEM=""
}

# eb_cert_matches <base64>: EB_CERT is this key's certificate. A key set by hand
# (scripts/set-eb-key.sh) has none here, or an old one that is another key's.
eb_cert_matches() {
  local cert key
  [ -n "$1" ] && [ -f "$EB_CERT" ] || return 1
  cert="$(openssl x509 -in "$EB_CERT" -noout -pubkey 2>/dev/null)" || return 1
  key="$(eb_pem "$1" | openssl pkey -pubout 2>/dev/null)" || return 1
  [ -n "$cert" ] && [ "$cert" = "$key" ]
}

eb_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# eb_check <base64 key> <application ID>: asks Enable Banking about the
# application, in a request signed with the key as the importer signs its own.
# EB_STATUS is the HTTP status ("000": no answer), EB_ANSWER the body. The token
# goes to curl on stdin, and the key to openssl through a pipe: neither is on a
# command line or in a file.
eb_check() {
  local now header payload signature out
  now="$(date +%s)"
  header="$(printf '{"typ":"JWT","alg":"RS256","kid":"%s"}' "$2" | eb_b64url)"
  payload="$(printf '{"iss":"enablebanking.com","aud":"api.enablebanking.com","iat":%s,"exp":%s}' "$now" "$((now + 3600))" | eb_b64url)"
  signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign <(eb_pem "$1") -binary 2>/dev/null | eb_b64url)"
  if [ -z "$signature" ]; then
    EB_STATUS=000
    EB_ANSWER='{"message":"this server could not sign with its key"}'
    return 1
  fi
  # With no answer at all curl writes 000 itself, and fails.
  out="$(printf 'header = "Authorization: Bearer %s.%s.%s"\n' "$header" "$payload" "$signature" \
    | curl -sS --max-time 25 --config - -w '\n%{http_code}' "$EB_API/application" 2>/dev/null || true)"
  EB_STATUS="${out##*$'\n'}"
  EB_STATUS="${EB_STATUS:-000}"
  EB_ANSWER="${out%$'\n'*}"
  [ "$out" != "$EB_STATUS" ] || EB_ANSWER=""
  [ "$EB_STATUS" = 200 ]
}

# What Enable Banking said, on one line, at most 300 characters.
eb_said() {
  local said
  said="$(jq -r '.message // .detail // .error // .code // empty | tostring' <<<"$EB_ANSWER" 2>/dev/null || true)"
  [ -n "$said" ] || said="$EB_ANSWER"
  printf '%s' "$said" | tr -d '\000-\037\177' | cut -c1-300
}

# eb_refusal: after a failed eb_check, why, in a sentence or two.
eb_refusal() {
  local said
  said="$(eb_said)"
  case "$EB_STATUS" in
    000) echo "Enable Banking did not answer (${EB_API#https://}${said:+: $said}). Try again in a minute." ;;
    401 | 403 | 404)
      echo "Enable Banking refused a request signed with this server's key for this ID (HTTP $EB_STATUS${said:+: $said})." \
           "The ID must be that of the application registered with this server's certificate." ;;
    5??) echo "Enable Banking answered HTTP $EB_STATUS${said:+: $said}. Try again later." ;;
    *) echo "Enable Banking answered HTTP $EB_STATUS${said:+: $said}." ;;
  esac
}

# eb_about: after a passed eb_check: the application's name and environment.
eb_about() {
  jq -r '"“\(.name // "unnamed" | tostring)”, a \(.environment // "unknown" | tostring | ascii_downcase) application"' \
    <<<"$EB_ANSWER" 2>/dev/null | tr -d '\000-\037\177' | cut -c1-200
}

# eb_notes: after a passed eb_check, what to change in Enable Banking's control
# panel, a sentence a line; nothing when all is well. After lib.sh.
eb_notes() {
  local url
  if [ "$(jq -r '.environment // empty' <<<"$EB_ANSWER" 2>/dev/null)" = SANDBOX ]; then
    echo "It is a sandbox application, which only ever sees Enable Banking's mock bank: for your own accounts, register a production one with this certificate, and use its ID."
  fi
  while IFS= read -r url; do
    jq -e --arg u "$url" '(.redirect_urls // []) | index($u)' <<<"$EB_ANSWER" >/dev/null 2>&1 \
      || echo "Add $url to its redirect URLs in Enable Banking's control panel: a bank sends the browser back there."
  done < <(eb_redirect_urls)
}
