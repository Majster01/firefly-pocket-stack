# shellcheck shell=bash
# What the server agent decides about a release, and nothing that touches the
# server: functions over what deploy.sh read, so scripts/channels-test.sh tests
# every decision without a registry, a clock or Docker. Sourced; it sets
# nothing but the window's hours, and changes nothing.
#
# A server follows one channel, the CHANNEL setting:
#   latest   every merge into master, within minutes (the canary: your server)
#   stable   the newest release, in the morning window; a new major waits for
#            scripts/firefly-pocket updates approve
#   X.Y.Z    that release and nothing else, in the morning window
# and never moves backwards: a downgrade is a restore, not a deploy.

# The window in which stable and a pinned release are applied, in the host's
# hours: after the 02:00 backup, the 03:00 import, the Sunday 04:00 and 04:30
# restore tests and the 05:30 unattended-upgrades reboot (crontab, host/).
WINDOW_FROM=6
WINDOW_TO=8

# channel_valid <value>: exit 0 for latest, stable or X.Y.Z.
channel_valid() {
  [[ "$1" == latest || "$1" == stable ]] || is_release "$1"
}

# is_release <tag>: exit 0 for a release tag, X.Y.Z.
is_release() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

# releases_newest_first: the release tags among the tags on stdin, the newest
# first, by number (1.10.0 after 1.9.0).
releases_newest_first() {
  local tag
  while IFS= read -r tag; do
    if is_release "$tag"; then printf '%s\n' "$tag"; fi
  done | sort -t. -k1,1nr -k2,2nr -k3,3nr
}

# next_page <registry> <headers file>: the URL of the next page of a tag list,
# from its Link header (absolute, or a path on the registry); nothing on the
# last page.
next_page() {
  local next
  next="$(tr -d '\r' < "$2" | sed -nE 's/^[Ll]ink: *<([^>]+)>; *rel="next".*/\1/p' | head -n 1)"
  case "$next" in
    "") ;;
    /*) echo "https://$1$next" ;;
    *) echo "$next" ;;
  esac
}

# major_of <version>: 1 of 1.4.2 and of 1.5.0-dev.37; nothing for anything else.
major_of() {
  [[ "$1" =~ ^([0-9]+)\. ]] && echo "${BASH_REMATCH[1]}"
  return 0
}

# settled <digest> <deployed> <held> <failed>: exit 0 when a tick has nothing
# to do with the digest the channel names: it runs, it is held on purpose, or it
# failed (each until the channel moves, or --force).
settled() {
  [ "$1" = "$2" ] || [ "$1" = "$3" ] || [ "$1" = "$4" ]
}

# bundle_version <git dir> <commit>: the version make-bundle.sh gives a build
# of master. After v1.4.2 it is 1.5.0-dev.<n>, <n> counting the commits on
# master since v1.4.0, the line's first release: a patch release does not start
# the count again, so a line's builds only go up. Before any release,
# 1.0.0-dev.<n>. Reads git, changes nothing.
bundle_version() {
  local dir="$1" commit="$2" last major minor base
  last="$(git -C "$dir" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$commit" 2>/dev/null || true)"
  if [ -z "$last" ]; then
    echo "1.0.0-dev.$(git -C "$dir" rev-list --count --first-parent "$commit")"
    return 0
  fi
  IFS=. read -r major minor _ <<<"${last#v}"
  # release.sh releases only commits of master, so vX.Y.0 is an ancestor of
  # every vX.Y.Z.
  base="v$major.$minor.0"
  git -C "$dir" rev-parse -q --verify "refs/tags/$base" >/dev/null || base="$last"
  echo "$major.$((minor + 1)).0-dev.$(git -C "$dir" rev-list --count --first-parent "$base..$commit")"
}

# backwards <running build> <target build>: exit 0 when the target is older
# than what runs. A running build that is not known (a server switched over
# from a shallow clone) is never backwards; deploy.sh never takes a target
# without one, a bundle from before the server agent.
backwards() {
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 1
  [ "$2" -lt "$1" ]
}

# in_window <hour>: exit 0 when the hour (0-23) is in the morning window.
in_window() {
  local hour=$((10#$1))
  [ "$hour" -ge "$WINDOW_FROM" ] && [ "$hour" -lt "$WINDOW_TO" ]
}

# verdict <channel> <target version> <running version> <approved major> <hour> <channel changed: 1|''> <force: 1|''>
#
# Prints what to do with a release that is newer than what runs:
#   apply            now
#   hold-major <N>   it is major N, which nobody approved yet (stable only)
#   wait-window      outside the morning window (stable and a pin)
# An approval is for a major, so 2.0.1 needs none after 2.0.0, and 3.0.0 does.
# A changed channel and --force skip the window, never a major: a major can
# need a value only a person can give.
verdict() {
  local channel="$1" target="$2" running="$3" approved="$4" hour="$5" changed="$6" force="$7" to from
  if [ "$channel" = latest ]; then
    echo apply
    return 0
  fi
  if [ "$channel" = stable ]; then
    to="$(major_of "$target")"
    from="$(major_of "$running")"
    if [ -n "$to" ] && [ -n "$from" ] && [ "$to" -gt "$from" ] && [ "$to" != "$approved" ]; then
      echo "hold-major $to"
      return 0
    fi
  fi
  if [ -z "$changed" ] && [ -z "$force" ] && ! in_window "$hour"; then
    echo wait-window
    return 0
  fi
  echo apply
}

# prune_candidates <keep> <current> <previous>: the release directories on
# stdin (names, oldest first) that may go, keeping the newest <keep> and never
# the current or the previous one.
prune_candidates() {
  local keep="$1" current="$2" previous="$3" all=() name i
  while IFS= read -r name; do
    [ -n "$name" ] && all+=("$name")
  done
  for ((i = 0; i < ${#all[@]} - keep; i++)); do
    name="${all[$i]}"
    [ "$name" = "$current" ] || [ "$name" = "$previous" ] || printf '%s\n' "$name"
  done
}
