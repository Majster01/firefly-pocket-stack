#!/usr/bin/env bash
#
# A new server's first boot, without SSH. cloud-init clones this repository
# into /opt/fireflyx and runs, as root:
#
#     scripts/first-boot.sh install   the host: Docker, the files under host/
#                                     (SSH, fail2ban, updates), and
#                                     fireflyx-first-boot.service
#     scripts/first-boot.sh configure the answers into the settings store and
#                                     `setup web`, as the admin user (the boot
#                                     test runs it; `run` ends with it)
#
# The service runs `run` once /etc/fireflyx/first-boot.json exists. The
# firefly-pocket.com/help/hetzner page writes it into the cloud-init it
# generates:
#
#     { "domain": "...", "email": "...", "timezone": "Europe/Ljubljana",
#       "setup_code": "XXXX-XXXX-XXXX-XXXX" }
#
# `run` waits until the five names under the domain point at this server, so
# Caddy never asks Let's Encrypt for names that do not resolve yet, puts the
# answers into the settings store and runs `setup web`: the same Caddy and
# console as over SSH, which asks for the setup code at https://admin.<domain>.
# It then deletes the file. A server made by Terraform has no such file; the
# service then does nothing and the README's setup over SSH applies.
#
# Progress goes to the journal (journalctl -u fireflyx-first-boot) and to the
# login banner of Hetzner's web Console (/etc/issue.d). Safe to run again.

set -euo pipefail
set -o errtrace
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_USER="${ADMIN_USER:-fireflyx}"
INPUTS="${FIRST_BOOT_INPUTS:-/etc/fireflyx/first-boot.json}"
BANNER="${FIRST_BOOT_BANNER:-/etc/issue.d/50-fireflyx.issue}"
WAIT_SECONDS="${FIRST_BOOT_WAIT_SECONDS:-30}"
# A fresh cloud image often holds the dpkg lock for a while after its first boot.
APT=(apt-get -o DPkg::Lock::Timeout=600)
# Exit status of an answer that will never work: the unit does not retry it
# (RestartPreventExitStatus), the person starts again with a new server.
REFUSED=65
# shellcheck source=host.sh
source "$REPO_ROOT/scripts/host.sh"

log() { printf '[first-boot] %s\n' "$*"; }

# What the web Console's login screen says: with no SSH, it is the one place to look.
banner() {
  install -d -m 0755 "$(dirname "$BANNER")"
  printf 'Firefly Pocket setup: %s\n\n' "$*" > "$BANNER"
  agetty --reload 2>/dev/null || true
}

# ------------------------------------------------------------- install ---
install_host_files() {
  local file dest
  while IFS= read -r -d '' file; do
    dest="/${file#"$REPO_ROOT/host/"}"
    install -D -m 0644 "$file" "$dest"
    log "installed $dest"
  done < <(find "$REPO_ROOT/host/etc" -type f -print0)
}

install_docker() {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091  # the host's own os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  "${APT[@]}" update
  DEBIAN_FRONTEND=noninteractive "${APT[@]}" install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "$ADMIN_USER"
  systemctl enable --now docker
}

# Type=simple: a oneshot that waits for DNS would hold up multi-user.target,
# at every boot until DNS is set.
install_service() {
  cat > /etc/systemd/system/fireflyx-first-boot.service <<UNIT
[Unit]
Description=Firefly Pocket first boot: wait for DNS, then start the console (scripts/first-boot.sh)
ConditionPathExists=$INPUTS
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=simple
Environment=ADMIN_USER=$ADMIN_USER
ExecStart=$REPO_ROOT/scripts/first-boot.sh run
Restart=on-failure
RestartSec=60
RestartPreventExitStatus=$REFUSED

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable fireflyx-first-boot.service
  systemctl start --no-block fireflyx-first-boot.service
}

cmd_install() {
  [ "$(id -u)" = 0 ] || { log "install runs as root"; exit 1; }
  trap 'banner "installing the host failed: see /var/log/cloud-init-output.log"' ERR
  log "installing the host"
  "${APT[@]}" update
  DEBIAN_FRONTEND=noninteractive "${APT[@]}" install -y \
    ca-certificates curl git jq restic fail2ban unattended-upgrades apt-listchanges tzdata-legacy
  # Before Docker starts, so daemon.json applies to it.
  install_host_files
  install_docker
  install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" /var/backups/fireflyx
  chown -R "$ADMIN_USER:$ADMIN_USER" "$REPO_ROOT"
  # The service first: a hardening step that fails must not leave the server with no setup.
  install_service
  # sshd's own check wants its privilege-separation directory, which a socket-activated ssh has not made yet.
  install -d -m 0755 /run/sshd
  sshd -t
  systemctl enable --now fail2ban
  systemctl restart ssh
  log "the host is ready"
}

# ----------------------------------------------------------------- run ---
input() { jq -r --arg key "$1" '.[$key] // empty' "$INPUTS"; }

# The keys that the page and this script agree on, each checked as `config set` will
# check it: a missing or refused answer stops the run at once, before a wait for DNS
# that a wrong domain would never end, instead of surfacing as an odd question later.
check_inputs() {
  local key setting
  for key in domain email timezone setup_code; do
    [ -n "$(input "$key")" ] || { log "$INPUTS has no \"$key\""; return 1; }
  done
  for setting in domain:DOMAIN email:SITE_OWNER timezone:TZ setup_code:SETUP_CODE; do
    input "${setting%%:*}" | as_admin "$REPO_ROOT/scripts/firefly-pocket" config check "${setting#*:}" - \
      || { log "$INPUTS: \"${setting%%:*}\" is refused"; return 1; }
  done
}

# The five names, as the wizard checks them (setup.sh check_dns): each resolves to this
# server and to nothing else, so `setup web` finds nothing to ask about.
wait_for_dns() {
  local domain="$1" v4 v6 prefix problems first tries=0
  v4="$(my_address 4)"
  v6="$(my_address 6)"
  [ -n "$v4" ] || { log "this server has no IPv4 address yet"; return 1; }
  while :; do
    problems=""
    for prefix in admin firefly app import legal; do
      problems="$problems$(dns_problems "$v4" "$v6" "$prefix.$domain")"$'\n'
    done
    first="$(sed -n '/./{p;q;}' <<<"$problems")"
    [ -n "$first" ] || break
    banner "waiting for DNS. Point *.$domain at $v4. $first"
    if [ $((tries % 10)) = 0 ]; then
      log "waiting: $first"
    fi
    tries=$((tries + 1))
    sleep "$WAIT_SECONDS"
  done
  log "the five names point at this server ($v4)"
}

# The admin user owns the checkout and the settings; the service runs as root, so it switches.
as_admin() {
  if [ "$(id -un)" = "$ADMIN_USER" ]; then
    "$@"
  else
    sudo -H -u "$ADMIN_USER" "$@"
  fi
}

# The value goes in on stdin, never as an argument, so it is not in `ps`.
seed() {
  # `|| return 1`: seed runs where errexit is off, so a refused value must stop it here.
  printf '%s\n' "$2" | as_admin "$REPO_ROOT/scripts/firefly-pocket" config set --no-render "$1" - >/dev/null || return 1
  log "stored $1"
}

# The answers into the settings store, then the browser setup: the part of the
# run that needs no DNS and no root, which the boot test runs as it is. Returns
# REFUSED for an answer the store refuses, which trying again will not change.
# The timezone is not stored: it sets the host's (cmd_run), and the console's Server
# step, which also asks for the name on the legal pages, starts from it.
cmd_configure() {
  local domain email
  domain="$(input domain)"
  email="$(input email)"
  cd "$REPO_ROOT"
  seed DOMAIN "$domain" || return "$REFUSED"
  seed SITE_OWNER "$email" || return "$REFUSED"
  seed SETUP_CODE "$(input setup_code)" || return "$REFUSED"

  # The wizard's questions, one line each: the domain and the email keep what is
  # stored (the email fills Let's Encrypt's and the push contact), and, as every
  # name points here, the domain has no follow-up; then Enter after the
  # importer's password is shown (boot-test.sh).
  log "setup web"
  printf '\n\n\n' | as_admin "$REPO_ROOT/scripts/firefly-pocket" setup web
}

cmd_run() {
  if [ ! -f "$INPUTS" ]; then
    log "no $INPUTS: nothing to do"
    return 0
  fi
  if ! check_inputs; then
    banner "an answer is missing or was refused: delete this server and start again at firefly-pocket.com/help/hetzner."
    return "$REFUSED"
  fi
  local domain status=0
  domain="$(input domain)"

  wait_for_dns "$domain" || { banner "this server has no IPv4 address. journalctl -u fireflyx-first-boot"; return 1; }

  banner "DNS is set. Starting Firefly Pocket's console."
  cmd_configure || status=$?
  if [ "$status" = "$REFUSED" ]; then
    banner "an answer was refused: delete this server and start again at firefly-pocket.com/help/hetzner. journalctl -u fireflyx-first-boot says which."
    return "$REFUSED"
  fi
  if [ "$status" != 0 ]; then
    banner "setup failed, it tries again in a minute. journalctl -u fireflyx-first-boot"
    return "$status"
  fi

  # The nightly jobs run in the host's zone; config set has checked it by now.
  timedatectl set-timezone "$(input timezone)" || log "could not set the host's timezone"
  rm -f "$INPUTS"
  banner "ready. Open https://admin.$domain and enter the setup code the help page showed you."
  log "done: https://admin.$domain"
}

case "${1:-}" in
  install) cmd_install ;;
  run) cmd_run ;;
  configure) check_inputs || exit 1; cmd_configure ;;
  *)
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
