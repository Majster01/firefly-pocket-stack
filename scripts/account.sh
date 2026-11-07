# shellcheck shell=bash
# Firefly III's account and the apps' tokens, made inside Firefly III by
# scripts/firefly-bootstrap.php. For the setup wizard's account step (setup.sh)
# and the console's (console.sh), so both make them the same way. Sourced, after
# lib.sh, by a script that defines die, ok, compose, FP and REPO_ROOT.

# The apps' Firefly III tokens: the setting, and the token's name in Firefly III
# (Options -> Profile -> OAuth), where each can be revoked alone.
TOKENS=(
  "IMPORTER_FIREFLY_TOKEN:Firefly Pocket importer"
  "SUGGESTER_FIREFLY_TOKEN:Firefly Pocket suggester"
  "NEXT_WARMUP_FIREFLY_TOKEN:Firefly Pocket warm-up"
)

# bootstrap: scripts/firefly-bootstrap.php inside the app container, its JSON
# input on stdin. Its answer, the JSON after the marker, on stdout.
bootstrap() {
  local code out answer
  code="$(sed '1{/^<?php/d;}' "$REPO_ROOT/scripts/firefly-bootstrap.php")"
  out="$(compose exec -T app php -r "$code" 2>&1)" || true
  answer="$(sed -n 's/^FIREFLY_POCKET_BOOTSTRAP //p' <<<"$out" | tail -n 1)"
  if [ -z "$answer" ]; then
    printf '%s\n' "$out" | tail -n 15 >&2
    die "scripts/firefly-bootstrap.php gave no answer (its output is above)"
  fi
  if jq -e 'has("error")' <<<"$answer" >/dev/null; then
    die "scripts/firefly-bootstrap.php: $(jq -r .error <<<"$answer")"
  fi
  printf '%s' "$answer"
}

# A token is good when Firefly III's API accepts it.
token_works() {
  [ -n "$1" ] || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$1" \
    | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" -fsS --max-time 30 --config - \
        -H 'Accept: application/vnd.api+json' -o /dev/null http://app:8080/api/v1/about/user 2>/dev/null
}

# registration open|closed: what Firefly III's /register shows. It answers 200
# either way, so the page is read: open, it has the form with its confirmation field.
registration() {
  local page
  page="$(internal_http http://app:8080/register 60)" || return 1
  if grep -q 'name="password_confirmation"' <<<"$page"; then [ "$1" = open ]; else [ "$1" = closed ]; fi
}

wait_for() {
  local url="$1" what="$2" _
  for _ in $(seq 60); do
    internal_http "$url" 10 >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "$what did not answer within five minutes: docker compose --project-directory compose logs $3"
}

# firefly_up: Postgres and Firefly III, and nothing else: Caddy, which makes
# them public, starts only once the account exists, so no one else can claim it.
# Then USERS is how many accounts Firefly III has.
firefly_up() {
  local info
  compose up -d --no-build --quiet-pull db app
  wait_for http://app:8080/health "Firefly III" app
  info="$(bootstrap <<<'{}')"
  USERS="$(jq -r .users <<<"$info")"
  if [ "$USERS" = 0 ]; then
    registration open || die "Firefly III's /register shows no registration form, so checking that it closed would prove nothing. This Firefly III needs a newer firefly-pocket-stack."
  fi
}

# make_tokens [<password>]: after firefly_up. The account $SITE_OWNER with that
# password, when Firefly III has none; then a new token for each app whose
# token Firefly III does not accept, kept in the store, and compose/.env written
# again. Fails unless every token works and /register shows no form.
make_tokens() {
  local pw="${1:-}" entry key name mint=() request answer token
  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    name="${entry#*:}"
    if [ "$USERS" != 0 ] && token_works "${!key:-}"; then
      ok "$key works"
    else
      mint+=("$name")
    fi
  done
  [ "$USERS" = 0 ] || pw=""
  if [ "${#mint[@]}" -gt 0 ] || [ -n "$pw" ]; then
    # The password goes to jq on stdin, and from there on stdin into the container.
    request="$(printf '%s' "$pw" | jq -Rsc --arg email "$SITE_OWNER" '$ARGS.positional as $t
      | {email: $email, password: ., tokens: $t}' --args "${mint[@]}")"
    pw=""
    answer="$(bootstrap <<<"$request")"
    request=""
    [ "$(jq -r .user <<<"$answer")" != created ] || ok "the account $SITE_OWNER is made"
    for entry in "${TOKENS[@]}"; do
      key="${entry%%:*}"
      name="${entry#*:}"
      token="$(jq -r --arg n "$name" '.tokens[$n].token // empty' <<<"$answer")"
      [ -n "$token" ] || continue
      "$FP" config set --no-render "$key" - <<<"$token" >/dev/null 2>&1 \
        || die "Firefly III made a token for $name that $key does not take"
      ok "$key: a new token, \"$name\" in Firefly III, valid until $(jq -r --arg n "$name" '.tokens[$n].expires_at' <<<"$answer" | cut -c1-10)"
    done
    "$FP" config render >/dev/null
    # shellcheck source=lib.sh
    source "$REPO_ROOT/scripts/lib.sh"
  fi
  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    token_works "${!key:-}" || die "Firefly III does not accept the new $key"
  done
  registration closed || die "Firefly III's /register still shows its form"
  ok "/register is closed: no one else can make an account"
  console_client
}

# console_client: the console's "Sign in with Firefly III" client, registered
# inside Firefly III, or moved to this domain's redirect URL, and its ID kept
# as CONSOLE_CLIENT_ID. Public: the console holds no secret (firefly-bootstrap.php).
CONSOLE_CLIENT_NAME="Firefly Pocket Console"
console_client() {
  local answer id
  answer="$(jq -nc --arg name "$CONSOLE_CLIENT_NAME" --arg redirect "https://$ADMIN_HOSTNAME/oauth/callback" \
    '{client: {name: $name, redirect: $redirect}}' | bootstrap)"
  id="$(jq -r '.client.id // empty' <<<"$answer")"
  [ -n "$id" ] || die "Firefly III registered no client for the console"
  if [ "$id" != "${CONSOLE_CLIENT_ID:-}" ]; then
    "$FP" config set --no-render CONSOLE_CLIENT_ID - <<<"$id" >/dev/null || die "CONSOLE_CLIENT_ID does not take $id"
    "$FP" config render >/dev/null
    # shellcheck source=lib.sh
    source "$REPO_ROOT/scripts/lib.sh"
  fi
  ok "the console signs in with Firefly III: its client, $id, is $(jq -r '.client.client' <<<"$answer")"
}

# How long the console's sign-in lasts: its session, and its token in Firefly
# III, which revokes it after that (console_tokens, and console.sh expire).
CONSOLE_SESSION_SECONDS=28800

# token_user <token>: the email of the account a token is for, as Firefly III's
# API says; 1 when the API refuses the token, 2 when it does not answer. The
# token goes to curl on stdin, in no command line.
token_user() {
  local out code
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$1" \
    | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" -sS --max-time 30 --config - \
        -H 'Accept: application/vnd.api+json' -w '\n%{http_code}' http://app:8080/api/v1/about/user 2>/dev/null)" || return 2
  code="${out##*$'\n'}"
  case "$code" in
    200) jq -r '.data.attributes.email // empty' <<<"${out%$'\n'*}" 2>/dev/null ;;
    401 | 403) return 1 ;;
    *) return 2 ;;
  esac
}

# console_tokens [token] [end]: the console client's tokens older than its
# session revoked; with a token, what it is (firefly-bootstrap.php), or, with
# end, that one revoked too. The token goes on stdin. Prints the answer.
console_tokens() {
  jq -Rc --arg client "${CONSOLE_CLIENT_ID:-}" --argjson age "$CONSOLE_SESSION_SECONDS" --argjson end "${2:-false}" \
    '{console_tokens: ({client: $client, max_age: $age, end: $end} + (if . == "" then {} else {token: .} end))}' \
    <<<"${1:-}" | bootstrap
}
