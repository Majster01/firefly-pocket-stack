#!/usr/bin/env bash
#
# The server agent (the "Server agent" plan): it will deploy from the release
# bundle instead of the git checkout. For now it runs in shadow mode (step 1):
# beside each git deploy it fetches the bundle latest names, compares it with
# the checkout the deploy ran, and deploys nothing.
#
#     scripts/agent.sh shadow                       # deploy.sh runs it when there is nothing to deploy
#     scripts/agent.sh resolve [<tag>]              # the digest a tag names now; default latest
#     scripts/agent.sh fetch <tag|sha256:…> <dir>   # extract a bundle into an empty directory
#     scripts/agent.sh compare <bundle-dir>         # its files against this checkout
#
# shadow, once for each revision the server deployed:
#   1. resolve latest to a digest: GHCR's registry API, anonymously, as the
#      bundle is public. No docker login and no token on the server
#   2. fetch that bundle: its manifest and layer, each checked against its
#      digest, extracted into a temporary directory
#   3. if it is another revision's bundle, wait: master moved and its deploy or
#      its Publish bundle run is not done yet. A later tick looks again, once
#      latest or the deployed revision has moved
#   4. compare, below
#   5. record it: a line in .shadow.log, the commit status agent/shadow on
#      GitHub (with DEPLOY_STATUS_TOKEN, like deploy/server), and on a
#      difference an alert to ntfy
#
# What "no difference" means:
#   - the bundle holds the same files as the checkout tracks under BUNDLE_PATHS
#     (scripts/lib.sh), with the same contents and executable bits
#   - in compose/docker-compose.yml only the image lines differ: the bundle pins
#     each of the checkout's image:tag to a digest
#   - each of those digests is the image the server pulled for that tag.
#     shadow only: compare checks files, for CI, which has not pulled them
# The bundle's release.json has nothing to compare with.
#
# Needs curl, jq and tar; shadow also docker and the server's compose/.env.

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-ghcr.io/majster01/firefly-pocket-stack}"
REGISTRY="${IMAGE%%/*}"
REPOSITORY="${IMAGE#*/}"
# A bundle is one image manifest: FROM scratch, holding no binaries, so one
# platform fits all. An index is refused.
MANIFEST_TYPES="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

SHADOW_REV="$REPO_ROOT/.shadow-rev"     # the deployed revision compared last
SHADOW_WAIT="$REPO_ROOT/.shadow-wait"   # "<deployed> <digest>": latest named another revision
SHADOW_LOG="$REPO_ROOT/.shadow.log"     # a line for each comparison

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 143' TERM   # deploy.sh's timeout: clean up all the same

die() { echo "agent: $*" >&2; exit 1; }
usage() { sed -n '8,11s/^#     //p' "${BASH_SOURCE[0]}" >&2; exit 2; }
sha256_of() { echo "sha256:$(sha256sum "$1" | cut -d' ' -f1)"; }
short_digest() { echo "${1:0:19}"; }   # sha256: and 12 hex digits
indent() { sed 's/^/    /'; }

# ------------------------------------------------------------- registry ---
# resolve <tag|digest>: the bundle's manifest into $TMP/manifest.json, its
# digest into DIGEST and a pull token into TOKEN. The digest is worked out from
# the manifest's bytes, not taken from the registry's word for it.
resolve() {
  local ref="$1" at=":" type
  [[ "$ref" == sha256:* ]] && at="@"
  TOKEN="$(curl -fsS --max-time 30 "https://$REGISTRY/token?scope=repository:$REPOSITORY:pull" | jq -er .token)" \
    || die "no pull token from $REGISTRY"
  curl -fsS --max-time 60 --max-filesize 1048576 -o "$TMP/manifest.json" \
      -H "Authorization: Bearer $TOKEN" -H "Accept: $MANIFEST_TYPES" \
      "https://$REGISTRY/v2/$REPOSITORY/manifests/$ref" \
    || die "no manifest for $IMAGE$at$ref"
  DIGEST="$(sha256_of "$TMP/manifest.json")"
  if [ "$at" = "@" ] && [ "$DIGEST" != "$ref" ]; then
    die "$REGISTRY sent a manifest for $ref whose digest is $DIGEST"
  fi
  type="$(jq -r '.mediaType // "manifest without a mediaType"' "$TMP/manifest.json")"
  case "$type" in
    application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json) ;;
    *) die "$IMAGE$at$ref is a $type, not an image manifest" ;;
  esac
}

# extract <dir>: the layers of the manifest resolve fetched, each checked
# against its digest, into <dir>. Files and directories only: a bundle has no
# links, and a layer that deletes files (a whiteout) is not one of ours.
extract() {
  local dir="$1" digest type odd
  while read -r digest type; do
    case "$type" in
      application/vnd.oci.image.layer.v1.tar+gzip|application/vnd.docker.image.rootfs.diff.tar.gzip) ;;
      *) die "layer $digest is a $type, not a gzipped tar" ;;
    esac
    curl -fsSL --max-time 300 --max-filesize $((64 << 20)) -o "$TMP/layer" \
        -H "Authorization: Bearer $TOKEN" "https://$REGISTRY/v2/$REPOSITORY/blobs/$digest" \
      || die "could not download layer $digest"
    [ "$(sha256_of "$TMP/layer")" = "$digest" ] || die "layer $digest does not match its digest"
    odd="$(tar -tvzf "$TMP/layer" | awk '($1 !~ /^[-d]/ || $NF ~ /(^|\/)\.wh\./) && n++ < 3')"
    [ -z "$odd" ] || die "layer $digest holds more than files and directories:"$'\n'"$odd"
    tar -xzf "$TMP/layer" -C "$dir" --no-same-owner
    rm -f "$TMP/layer"
  done < <(jq -r '.layers[] | "\(.digest) \(.mediaType)"' "$TMP/manifest.json")
  [ -f "$dir/release.json" ] || die "no release.json in $IMAGE@$DIGEST"
}

# ------------------------------------------------------------ comparing ---
# Each prints one line per difference, and nothing when there is none.

# unpin: a compose file with each image line as the checkout writes it,
# image:tag without the @sha256 that make-bundle.sh added.
unpin() { sed -E 's/^([[:space:]]+image:[[:space:]]+[^[:space:]#@]+)@sha256:[0-9a-f]{64}/\1/'; }

# bundle_images <bundle-dir>: every image its compose file names, as written.
bundle_images() {
  sed -nE 's/^[[:space:]]+image:[[:space:]]+([^[:space:]#]+).*/\1/p' "$1/compose/docker-compose.yml" | sort -u
}

executable() { if [ -x "$1" ]; then echo yes; else echo no; fi; }

# compare_files <bundle-dir>
compare_files() {
  local bundle="$1" paths f ours ref
  # Read the way make-bundle.sh reads it, as sourcing lib.sh wants a .env.
  read -ra paths <<<"$(sed -nE 's/^BUNDLE_PATHS="([^"]*)"$/\1/p' "$REPO_ROOT/scripts/lib.sh")"
  [ "${#paths[@]}" -gt 0 ] || die "no BUNDLE_PATHS line in scripts/lib.sh"
  git -C "$REPO_ROOT" -c core.quotePath=false ls-files -- "${paths[@]}" | LC_ALL=C sort > "$TMP/checkout.list"
  (cd "$bundle" && find . -type f ! -path ./release.json | sed 's#^\./##' | LC_ALL=C sort) > "$TMP/bundle.list"

  LC_ALL=C comm -23 "$TMP/checkout.list" "$TMP/bundle.list" | sed 's/^/not in the bundle: /'
  LC_ALL=C comm -13 "$TMP/checkout.list" "$TMP/bundle.list" | sed 's/^/only in the bundle: /'
  while read -r f; do
    ours="$bundle/$f"
    if [ "$f" = compose/docker-compose.yml ]; then
      unpin < "$ours" > "$TMP/compose.yml"
      ours="$TMP/compose.yml"
    fi
    if ! cmp -s "$ours" "$REPO_ROOT/$f"; then
      echo "differs: $f"
    elif [ "$(executable "$bundle/$f")" != "$(executable "$REPO_ROOT/$f")" ]; then
      echo "executable in one only: $f"
    fi
  done < <(LC_ALL=C comm -12 "$TMP/checkout.list" "$TMP/bundle.list")

  if [ -f "$bundle/compose/docker-compose.yml" ]; then
    while read -r ref; do
      [[ "$ref" =~ @sha256:[0-9a-f]{64}$ ]] || echo "not pinned by digest: $ref"
    done < <(bundle_images "$bundle")
  fi
}

# compare_images <bundle-dir>: is each image the bundle pins the one the server
# pulled for its tag? By the digests docker recorded at the pull.
compare_images() {
  local ref named digest have
  while read -r ref; do
    [[ "$ref" == *@sha256:* ]] || continue   # compare_files says so
    named="${ref%@*}"
    digest="${ref##*@}"
    if ! have="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$named" 2>/dev/null)"; then
      echo "not on the server: $named"
    elif ! grep -qF "@$digest" <<<"$have"; then
      have="$(sed -n '1s/.*@//p' <<<"$have")"
      echo "another image: the server pulled $named as $(short_digest "${have:-no digest}"), the bundle pins $(short_digest "$digest")"
    fi
  done < <(bundle_images "$1")
}

# --------------------------------------------------------------- shadow ---
shadow() {
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  local deployed short commit version diffs n
  deployed="$(cat "$REPO_ROOT/.deployed-rev" 2>/dev/null || true)"
  [ -n "$deployed" ] || return 0                                          # nothing deployed yet
  [ "$deployed" != "$(cat "$SHADOW_REV" 2>/dev/null || true)" ] || return 0   # compared already

  resolve latest
  [ "$deployed $DIGEST" != "$(cat "$SHADOW_WAIT" 2>/dev/null || true)" ] || return 0
  mkdir "$TMP/bundle"
  extract "$TMP/bundle"
  commit="$(jq -r .commit "$TMP/bundle/release.json")"
  version="$(jq -r .version "$TMP/bundle/release.json")"
  short="${deployed:0:7}"
  if [ "$commit" != "$deployed" ]; then
    echo "==> shadow: latest is the bundle of ${commit:0:7}, the server runs $short; looking again when either moves"
    echo "$deployed $DIGEST" > "$SHADOW_WAIT"
    return 0
  fi
  rm -f "$SHADOW_WAIT"

  diffs="$(compare_files "$TMP/bundle"; compare_images "$TMP/bundle")"
  if [ -z "$diffs" ]; then
    echo "$(date -Is) $short $version $DIGEST same" >> "$SHADOW_LOG"
    echo "==> shadow: the bundle of $short ($version) is the same as the checkout"
    commit_status agent/shadow "$deployed" success "bundle $version is the same as the checkout"
  else
    n="$(wc -l <<<"$diffs")"
    if [ "$n" -eq 1 ]; then n="1 difference"; else n="$n differences"; fi
    { echo "$(date -Is) $short $version $DIGEST DIFFERENT: $n"; indent <<<"$diffs"; } >> "$SHADOW_LOG"
    echo "==> shadow: the bundle of $short ($version) has $n from the checkout:"
    indent <<<"$diffs"
    commit_status agent/shadow "$deployed" failure "bundle $version: $n from the checkout, listed in .shadow.log"
    notify_ntfy "Firefly Pocket: the bundle of $short differs from the checkout" "Shadow mode, nothing was deployed from it. In /opt/fireflyx/.shadow.log:
$diffs"
  fi
  echo "$deployed" > "$SHADOW_REV"
}

# ----------------------------------------------------------------- main ---
case "${1:-}" in
  shadow)
    [ "$#" -eq 1 ] || usage
    shadow
    ;;
  resolve)
    [ "$#" -le 2 ] || usage
    resolve "${2:-latest}"
    echo "$DIGEST"
    ;;
  fetch)
    [ "$#" -eq 3 ] || usage
    if [ -e "$3" ] && [ -n "$(ls -A "$3")" ]; then die "$3 is not empty"; fi
    mkdir -p "$3"
    resolve "$2"
    extract "$3"
    echo "$IMAGE@$DIGEST: $(jq -r '"\(.version), built from \(.commit[0:7])"' "$3/release.json")"
    ;;
  compare)
    [ "$#" -eq 2 ] && [ -d "$2" ] || usage
    diffs="$(compare_files "$2")"
    if [ -n "$diffs" ]; then
      echo "the bundle in $2 differs from this checkout:"
      indent <<<"$diffs"
      exit 1
    fi
    echo "the bundle in $2 is the same as this checkout"
    ;;
  *) usage ;;
esac
