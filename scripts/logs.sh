#!/usr/bin/env bash
#
# Open Dozzle, the log viewer. Run from your laptop.
#
#     scripts/logs.sh                 # tunnel + open the browser; Ctrl-C closes it
#     scripts/logs.sh fireflyx-importer   # land on one container (its name)
#     LOGS_PORT=9000 scripts/logs.sh  # another local port
#
# Dozzle listens on the server's loopback only (README "Logs (Dozzle)"), so
# this is the SSH tunnel from the README plus the waiting and the browser. The
# tunnel lives exactly as long as this script does.

set -euo pipefail

# user@host. Defaults to Terraform's own ssh_command output, so the address
# lives in one place; set DEPLOY_HOST to override.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${DEPLOY_HOST:-}" ]; then
  DEPLOY_HOST="$(terraform -chdir="$REPO_ROOT/terraform" output -raw ssh_command 2>/dev/null | sed 's/^ssh //' || true)"
fi
if [ -z "$DEPLOY_HOST" ]; then
  echo "FATAL: set DEPLOY_HOST=user@host (terraform output was not available)." >&2
  exit 1
fi

PORT="${LOGS_PORT:-8081}"
URL="http://localhost:$PORT"

# Dozzle shows a container at /container/<id>; its name is accepted there too.
if [ -n "${1:-}" ]; then
  URL="$URL/container/$1"
fi

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "FATAL: local port $PORT is already in use (an earlier tunnel?)." >&2
  echo "       Close it, or pick another: LOGS_PORT=9000 $0" >&2
  exit 1
fi

# ExitOnForwardFailure: a refused bind must fail loudly, not leave a tunnel
# that forwards nothing. BatchMode: never sit on a hidden password prompt.
ssh -N -L "$PORT:127.0.0.1:8081" \
  -o ExitOnForwardFailure=yes -o BatchMode=yes \
  -o ServerAliveInterval=30 "$DEPLOY_HOST" &
TUNNEL=$!
trap 'kill "$TUNNEL" 2>/dev/null || true' EXIT INT TERM

# Ready means Dozzle answers through the tunnel, not just that ssh connected.
for _ in $(seq 1 30); do
  if ! kill -0 "$TUNNEL" 2>/dev/null; then
    echo "FATAL: the SSH tunnel to $DEPLOY_HOST failed (see ssh's message above)." >&2
    exit 1
  fi
  if curl -fsS -o /dev/null --max-time 2 "http://localhost:$PORT/" 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if ! curl -fsS -o /dev/null --max-time 2 "http://localhost:$PORT/" 2>/dev/null; then
  echo "FATAL: tunnel is up but Dozzle does not answer. Is it running?" >&2
  echo "       ssh $DEPLOY_HOST 'cd $REMOTE_DIR/compose && docker compose ps dozzle'" >&2
  exit 1
fi

echo "==> Dozzle at $URL (Ctrl-C to close the tunnel)"
if command -v open >/dev/null 2>&1; then
  open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
fi

wait "$TUNNEL"
