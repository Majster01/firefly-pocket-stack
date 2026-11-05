#!/usr/bin/env bash
#
# One-time setup of the deploy agent (README "Deploying"). Runs ON THE SERVER
# as the admin user, and uses sudo for systemd. From the laptop:
#
#     ssh <server> 'bash -s' < scripts/install-deploy-agent.sh
#
# 1. A read-only deploy key for this repository, ~/.ssh/fireflyx_deploy. The
#    first run creates it, prints it and stops: add it to the repository under
#    Settings -> Deploy keys, without write access, then run this again.
# 2. /opt/fireflyx becomes a git checkout of master. A copy made by the old
#    rsync deploys keeps every file git does not track (compose/.env,
#    compose/secrets/, config/importers/), and its tracked files are reset to
#    the revision it was last deployed at, so nothing changes yet.
# 3. fireflyx-deploy.timer: scripts/deploy.sh every two minutes. Its first run
#    deploys master. Skipped while compose/.env does not exist (a new server
#    in the middle of the README setup); run this again at the end of it.
#
# Safe to run again.

set -euo pipefail

REPO_URL="${REPO_URL:-git@github.com:Majster01/firefly-pocket-stack.git}"
REPO_DIR=/opt/fireflyx
KEY="$HOME/.ssh/fireflyx_deploy"
# GitHub's published ED25519 host key fingerprint (docs.github.com, "GitHub's
# SSH key fingerprints"), so the first connection is not trust-on-first-use.
GITHUB_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

# ------------------------------------------------------------ deploy key ---
install -d -m 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "fireflyx-deploy@$(hostname -s)" -f "$KEY" </dev/null
  cat <<EOF
Created a deploy key. Add it to GitHub: ${REPO_URL#git@github.com:} -> Settings ->
Deploy keys -> Add deploy key. Any title; leave "Allow write access" OFF.

$(cat "$KEY.pub")

Then run this script again.
EOF
  exit 0
fi

if ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
  scanned="$(ssh-keyscan -t ed25519 github.com 2>/dev/null)"
  fp="$(printf '%s\n' "$scanned" | ssh-keygen -lf - | awk '{print $2}')"
  if [ "$fp" != "$GITHUB_FP" ]; then
    echo "FATAL: github.com offered host key ${fp:-none}, expected $GITHUB_FP." >&2
    exit 1
  fi
  printf '%s\n' "$scanned" >> "$HOME/.ssh/known_hosts"
fi

# --------------------------------------------------------- git checkout ---
cd "$REPO_DIR"
[ -d .git ] || git init -q -b master
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REPO_URL"
git config core.sshCommand "ssh -i $KEY -o IdentitiesOnly=yes"
# </dev/null: under `bash -s` the script itself is stdin, and ssh would eat it.
git fetch -q origin master </dev/null

if ! git rev-parse -q --verify HEAD >/dev/null; then
  # Start where the rsync deploys left off, so the agent's first run deploys
  # master the usual way. A new server starts at master.
  start="$(cat .deployed-rev 2>/dev/null || true)"
  git cat-file -e "${start:-none}^{commit}" 2>/dev/null || start="$(git rev-parse FETCH_HEAD)"
  git reset -q --hard "$start"
  echo "==> $REPO_DIR is a git checkout at $(git log --oneline -1)"
  stale="$(git status --porcelain --untracked-files=all | sed -n 's/^?? //p')"
  if [ -n "$stale" ]; then
    echo "    Files here that git does not track and does not ignore, probably deleted"
    echo "    from the repository since they were synced. Check them, and delete the stale ones:"
    printf '%s\n' "$stale" | sed 's/^/      /'
  fi
fi

# ----------------------------------------------------------------- timer ---
if [ ! -f compose/.env ]; then
  echo "==> no compose/.env yet: finish the README setup, then run this again to start the timer."
  exit 0
fi

sudo tee /etc/systemd/system/fireflyx-deploy.service >/dev/null <<EOF
[Unit]
Description=firefly-pocket-stack: deploy origin/master if it moved (scripts/deploy.sh)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
User=$(id -un)
WorkingDirectory=$REPO_DIR
ExecStart=$REPO_DIR/scripts/deploy.sh
TimeoutStartSec=2h
EOF

sudo tee /etc/systemd/system/fireflyx-deploy.timer >/dev/null <<EOF
[Unit]
Description=firefly-pocket-stack: check for a new master every two minutes

[Timer]
OnBootSec=2min
OnUnitInactiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now fireflyx-deploy.timer
echo "==> fireflyx-deploy.timer is on. Its log: journalctl -u fireflyx-deploy -f"
systemctl list-timers fireflyx-deploy.timer --no-pager
