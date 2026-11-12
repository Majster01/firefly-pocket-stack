# shellcheck shell=bash
# Where a server keeps what git never tracked. Sourced, after the caller has
# set REPO_ROOT; it sets variables and defines `setting`, and changes nothing.
#
# A server that deploys release bundles (the Server agent) runs from
# /opt/fireflyx -> /opt/fireflyx-releases/current -> <release>, and keeps its
# state in /opt/fireflyx-shared, which every release links to with .state.
# A git checkout (a server before scripts/adopt.sh, CI, a laptop) has no .state
# and keeps its state where it always did, in the checkout.
#
# STATE_DIR mirrors the checkout's layout: compose/.env, compose/config.json,
# compose/secrets/ and so on sit at the same paths under it. Anything that
# writes a state file by rename (scripts/config.sh) writes it under STATE_DIR,
# never through a release's link, which the rename would replace.

# shellcheck disable=SC2034  # read by the scripts that source this
if [ -L "$REPO_ROOT/.state" ]; then
  STATE_DIR="$(readlink "$REPO_ROOT/.state")"
else
  STATE_DIR="$REPO_ROOT"
fi

# The state a release links to, by path in the checkout. config/importers sits
# inside the importer's ../config mount, where the link does not resolve; the
# importer does not read it (it renders its own), only backup.sh does, on the host.
# shellcheck disable=SC2034  # read by scripts/adopt.sh and deploy.sh
STATE_PATHS="compose/.env compose/config.json compose/.env.rendered compose/.env.before-import compose/secrets compose/console config/importers"

# setting <KEY>: a setting's value as the server has it now: the settings
# store's, where it has one (a value set with --no-render is not in .env yet),
# else compose/.env's. Empty when neither has it.
setting() {
  local config="$STATE_DIR/compose/config.json"
  if [ -f "$config" ] && jq -e --arg k "$1" 'has($k)' "$config" >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k]' "$config"
  else
    sed -n "s/^$1=//p" "$STATE_DIR/compose/.env" 2>/dev/null | tail -n 1
  fi
}
