#!/usr/bin/env bash
#
# What this server deploys, and when (README "Deploying"). Run it as
#
#     scripts/firefly-pocket updates [status]   the channel, what runs, what waits and why
#     scripts/firefly-pocket updates now        deploy now: after a failure, or before the
#                                               morning window (scripts/deploy.sh --force)
#     scripts/firefly-pocket updates approve    let the new major that waits through, and
#                                               deploy it now
#
# The channel is a setting: scripts/firefly-pocket config set CHANNEL <latest|stable|X.Y.Z>.
# The deploy follows it from its next tick, within two minutes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO_ROOT/scripts/paths.sh"

state() { cat "$STATE_DIR/$1" 2>/dev/null || true; }

status() {
  local channel held failed pending version
  channel="$(setting CHANNEL)"
  channel="${channel:-latest}"
  echo "channel   $channel"
  if [ -d "$REPO_ROOT/.git" ]; then
    echo "runs      $(git -C "$REPO_ROOT" log --oneline -1), a git checkout of master"
    echo "          (it switches to release bundles by itself, on the deploy's next quiet tick)"
  else
    version="$(state .deployed-version)"
    [ -n "$version" ] || version="$(jq -r .version "$REPO_ROOT/release.json")"
    echo "runs      $version, the release $(basename "$(cd "$REPO_ROOT" && pwd -P)")"
  fi
  held="$(state .held)"
  pending="$(state .pending)"
  failed="$(state .deploy-failed)"
  [ -z "$(state .no-release)" ] || echo "waiting   no $channel release yet"
  case "$held" in
    *" major "*) echo "held      a new major, ${held##* }.x: scripts/firefly-pocket updates approve" ;;
    *" backwards") echo "held      ${channel} is older than what runs; a server never moves backwards" ;;
    *" before-agent") echo "held      $channel names a bundle from before the server agent; it waits for a newer one" ;;
  esac
  [ -z "$pending" ] || echo "waiting   ${pending##* }, for the morning window (06:00-08:00), or: scripts/firefly-pocket updates now"
  [ -z "$failed" ] || echo "failed    ${failed:0:19}: its alert says why; scripts/firefly-pocket updates now tries again"
  return 0
}

case "${1:-status}" in
  status) status ;;
  now) exec "$REPO_ROOT/scripts/deploy.sh" --force ;;
  approve)
    held="$(state .held)"
    [[ "$held" == *" major "* ]] || { echo "No major release is waiting."; exit 0; }
    echo "${held##* }" > "$STATE_DIR/.approved-major"
    echo "==> major ${held##* } approved; deploying it now"
    exec "$REPO_ROOT/scripts/deploy.sh" --force
    ;;
  *) sed -n '5,10s/^#     //p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
