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

private_v4() { [[ "$1" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

host_timezone() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$tz" ] || tz="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p' || true)"
  printf '%s' "${tz:-Etc/UTC}"
}
