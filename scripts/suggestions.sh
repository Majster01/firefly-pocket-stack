# shellcheck shell=bash
# The category suggester's AI key: which provider a key is for, and the check
# that the provider has the model for it. For the setup wizard's suggestions
# step (setup.sh) and the console's (console.sh), so both check it the same
# way. Sourced; uses curl and jq.

# shellcheck disable=SC2034  # the sourcing script's
SUGGESTER_DEFAULT_MODEL=claude-haiku-5-5
# Where the check asks. Others only in the boot test, which answers it itself.
ANTHROPIC_API="${ANTHROPIC_API:-https://api.anthropic.com}"
GEMINI_API="${GEMINI_API:-https://generativelanguage.googleapis.com}"

# key_provider <key>: anthropic or gemini, by how the key starts; nothing when
# it does not tell.
key_provider() {
  case "$1" in
    sk-ant-*) echo anthropic ;;
    AIza*) echo gemini ;;
  esac
}

# model_check <anthropic|gemini> <key> <model>: 0 when the provider has the
# model for the key; else MODEL_PROBLEM says why, in a sentence. The key goes
# to curl on stdin, never on its command line.
model_check() {
  local body code said
  body="$(mktemp)"
  if [ "$1" = anthropic ]; then
    code="$(printf 'header = "x-api-key: %s"\n' "$2" | curl -sS --max-time 30 --config - \
      -H 'anthropic-version: 2026-10-21' -o "$body" -w '%{http_code}' "$ANTHROPIC_API/v1/models/$3" 2>/dev/null || true)"
  else
    code="$(printf 'header = "x-goog-api-key: %s"\n' "$2" | curl -sS --max-time 30 --config - \
      -o "$body" -w '%{http_code}' "$GEMINI_API/v1beta/models/$3" 2>/dev/null || true)"
  fi
  code="${code:-000}"
  said="$(jq -r '.error.message // .error // empty | tostring' "$body" 2>/dev/null | tr -d '\000-\037\177' | cut -c1-300 || true)"
  rm -f "$body"
  # shellcheck disable=SC2034  # MODEL_PROBLEM is the caller's
  case "$code" in
    200) return 0 ;;
    000) MODEL_PROBLEM="$1 did not answer. Try again in a minute." ;;
    401 | 403) MODEL_PROBLEM="$1 does not take this key (HTTP $code${said:+: $said})." ;;
    404) MODEL_PROBLEM="$1 has no model $3 for this key${said:+ ($said)}." ;;
    *) MODEL_PROBLEM="$1 answered HTTP $code${said:+: $said}." ;;
  esac
  return 1
}
