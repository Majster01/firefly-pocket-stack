# shellcheck shell=bash
# The offsite backup's restic repository: whether it opens with a password, and
# making one. For the setup wizard's backups step (setup.sh) and the console's
# (console.sh), so both check it the same way. Sourced; uses restic and jq.
#
# Every function takes the repository, its password and, for S3, the access key
# ID and the secret access key, and hands them to restic in its environment
# alone: never on a command line, and nothing a caller exported instead.

# restic_with <repository> <password> <key ID> <secret key> <seconds> <restic args...>
restic_with() {
  RESTIC_REPOSITORY="$1" RESTIC_PASSWORD="$2" AWS_ACCESS_KEY_ID="$3" AWS_SECRET_ACCESS_KEY="$4" \
    RESTIC_PASSWORD_FILE="" RESTIC_PASSWORD_COMMAND="" timeout "$5" restic --no-cache "${@:6}"
}

# restic_said <output>: restic's reason, its first "Fatal: " line, in one line.
restic_said() {
  local said
  said="$(sed -n 's/^Fatal: //p' <<<"$1" | head -n 1)"
  [ -n "$said" ] || said="$(grep -v '^[[:space:]]*$' <<<"$1" | tail -n 1)"
  said="${said:-no answer within two minutes}"
  printf '%s' "${said:0:300}"
}

# restic_open <repository> <password> <key ID> <secret key>: RESTIC_STATE says
# what is there:
#   open            a repository, and the password opens it; RESTIC_SNAPSHOTS counts them
#   wrong_password  a repository, with another password
#   missing         nothing yet: restic init makes one
#   error           restic cannot tell: the storage did not answer, or refused the keys
# and RESTIC_PROBLEM is restic's reason, for the last two.
# shellcheck disable=SC2034  # for the sourcing script
restic_open() {
  local out
  RESTIC_STATE="" RESTIC_PROBLEM="" RESTIC_SNAPSHOTS=""
  command -v restic >/dev/null 2>&1 || {
    RESTIC_STATE=error RESTIC_PROBLEM="restic is not installed on this server: sudo apt-get install -y restic"
    return 0
  }
  if out="$(restic_with "$1" "$2" "$3" "$4" 120 cat config 2>&1)"; then
    RESTIC_STATE=open
    RESTIC_SNAPSHOTS="$(restic_with "$1" "$2" "$3" "$4" 120 snapshots --json 2>/dev/null | jq length 2>/dev/null || echo "?")"
  elif grep -qiE 'wrong password|no key found' <<<"$out"; then
    RESTIC_STATE=wrong_password
  # Only an answer that nothing is there: S3 that does not answer says "Is
  # there a repository" too.
  elif grep -qiE 'does not exist|no such file or directory|NoSuchKey|NoSuchBucket' <<<"$out"; then
    RESTIC_STATE=missing
  else
    RESTIC_STATE=error
    RESTIC_PROBLEM="$(restic_said "$out")"
  fi
}

# restic_make <repository> <password> <key ID> <secret key>: 0 once restic
# init made it; else RESTIC_PROBLEM says why.
# shellcheck disable=SC2034  # for the sourcing script
restic_make() {
  local out
  RESTIC_PROBLEM=""
  out="$(restic_with "$1" "$2" "$3" "$4" 300 init 2>&1)" && return 0
  RESTIC_PROBLEM="$(restic_said "$out")"
  return 1
}

# restic_shown <repository>: as the console may show it: a password in it, as
# in rest:https://user:password@host/, is not.
restic_shown() {
  sed -E 's#(://[^/@:]*:)[^/@]*@#\1…@#' <<<"$1"
}
