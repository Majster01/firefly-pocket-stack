# shellcheck shell=bash
# What this machine says about itself, for the setup wizard (setup.sh) and the
# console's status (console.sh). Sourced, not executed. Unlike lib.sh it needs
# no compose/.env, so a new server can ask it before it has one.

# my_address 4|6: this server's address on its default route: the public one,
# unless the server sits behind NAT. Nothing when it has none.
my_address() {
  local target=1.1.1.1
  [ "$1" = 4 ] || target=2606:4700:4700::1111
  command -v ip >/dev/null 2>&1 || return 0
  # Without a route (a server with no IPv6) ip fails: no address, not an error.
  { ip "-$1" route get "$target" 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F.:]*\).*/\1/p' | head -n 1; } || true
}

# dns_problems <v4> <v6> <host>: one line for each reason <host> does not point
# only at this server, and nothing when it does. Let's Encrypt tries every address
# a name has, IPv6 first. An empty <v4>, or a private one (a server behind NAT),
# checks only that the name resolves.
dns_problems() {
  local v4="$1" v6="$2" host="$3" a aaaa addr nat=""
  if [ -z "$v4" ] || private_v4 "$v4"; then nat=1; fi
  a="$(getent ahostsv4 "$host" 2>/dev/null | awk '{ print $1 }' | sort -u || true)"
  aaaa="$(getent ahostsv6 "$host" 2>/dev/null | awk '$1 !~ /^::ffff:/ { print $1 }' | sort -u || true)"
  if [ -z "$a$aaaa" ]; then
    echo "$host does not resolve yet"
    return 0
  fi
  for addr in $a; do
    if [ -z "$nat" ] && [ "$addr" != "$v4" ]; then
      echo "$host points to $addr, but this server is $v4"
    fi
  done
  for addr in $aaaa; do
    if [ -z "$v6" ]; then
      echo "$host has the IPv6 address $addr, but this server has none: remove that AAAA record"
    elif [ "$addr" != "$v6" ]; then
      echo "$host points to $addr, but this server's IPv6 address is $v6"
    fi
  done
}

private_v4() { [[ "$1" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

host_timezone() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$tz" ] || tz="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p' || true)"
  printf '%s' "${tz:-Etc/UTC}"
}

# agent_on: whether the deploy agent runs this server (install-deploy-agent.sh).
agent_on() { systemctl is-enabled --quiet fireflyx-deploy.timer 2>/dev/null; }
