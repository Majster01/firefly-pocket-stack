#!/usr/bin/env bash
#
# The server agent's registry side: the release bundles of
# ghcr.io/majster01/firefly-pocket-stack, read anonymously (the bundle is
# public), with no docker login and no token on the server. scripts/deploy.sh
# uses it to follow the server's channel; CI and scripts/upgrade-test.sh to
# fetch and compare bundles.
#
#     scripts/agent.sh resolve [<tag>]              # the digest a tag names now; default latest
#     scripts/agent.sh release-of <sha256:…>        # the release X.Y.Z that names that digest
#     scripts/agent.sh fetch <tag|sha256:…> <dir>   # extract a bundle into an empty directory
#     scripts/agent.sh compare <bundle-dir>         # its files against this checkout
#
# resolve exits 3 when the registry has no such tag (stable before the first
# release), and 1 on any other failure. release-of prints nothing when no
# release names the digest yet (a release half pushed).
#
# A bundle is the same as a checkout when:
#   - it holds the same files as the checkout tracks under BUNDLE_PATHS
#     (scripts/lib.sh), with the same contents and executable bits
#   - in compose/docker-compose.yml only the image lines differ: the bundle pins
#     each of the checkout's image:tag to a digest
# The bundle's release.json has nothing to compare with.
#
# LOCAL_BUNDLES=<dir> stands in for the registry, for the tests: <dir>/tags/<tag>
# holds a digest, and <dir>/<digest>/ the bundle's files.
#
# Needs curl, jq and tar.

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=channels.sh
source "$REPO_ROOT/scripts/channels.sh"
IMAGE="${IMAGE:-ghcr.io/majster01/firefly-pocket-stack}"
REGISTRY="${IMAGE%%/*}"
REPOSITORY="${IMAGE#*/}"
# A bundle is one image manifest: FROM scratch, holding no binaries, so one
# platform fits all. An index is refused.
MANIFEST_TYPES="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 143' TERM   # deploy.sh's timeout: clean up all the same

die() { echo "agent: $*" >&2; exit 1; }
usage() { sed -n '9,12s/^#     //p' "${BASH_SOURCE[0]}" >&2; exit 2; }
sha256_of() { echo "sha256:$(sha256sum "$1" | cut -d' ' -f1)"; }
indent() { sed 's/^/    /'; }

# ------------------------------------------------------------- registry ---
# token: a pull token into TOKEN, once.
token() {
  [ -z "${TOKEN:-}" ] || return 0
  TOKEN="$(curl -fsS --max-time 30 "https://$REGISTRY/token?scope=repository:$REPOSITORY:pull" | jq -er .token)" \
    || die "no pull token from $REGISTRY"
}

# resolve <tag|digest>: the bundle's manifest into $TMP/manifest.json, its
# digest into DIGEST and a pull token into TOKEN. The digest is worked out from
# the manifest's bytes, not taken from the registry's word for it. A tag the
# registry does not have exits 3.
resolve() {
  local ref="$1" at=":" type code
  [[ "$ref" == sha256:* ]] && at="@"
  if [ -n "${LOCAL_BUNDLES:-}" ]; then
    resolve_local "$ref"
    return 0
  fi
  token
  code="$(curl -sS --max-time 60 --max-filesize 1048576 -o "$TMP/manifest.json" -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" -H "Accept: $MANIFEST_TYPES" \
      "https://$REGISTRY/v2/$REPOSITORY/manifests/$ref")" \
    || die "no answer from $REGISTRY for $IMAGE$at$ref"
  case "$code" in
    200) ;;
    404) echo "agent: $IMAGE has no $ref" >&2; exit 3 ;;
    *) die "$REGISTRY answered $code for $IMAGE$at$ref" ;;
  esac
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

# resolve_local <tag|digest>: resolve, from LOCAL_BUNDLES.
resolve_local() {
  if [[ "$1" == sha256:* ]]; then
    DIGEST="$1"
  elif [ -f "$LOCAL_BUNDLES/tags/$1" ]; then
    DIGEST="$(cat "$LOCAL_BUNDLES/tags/$1")"
  else
    echo "agent: $LOCAL_BUNDLES has no $1" >&2
    exit 3
  fi
  [ -d "$LOCAL_BUNDLES/$DIGEST" ] || die "$LOCAL_BUNDLES has no bundle $DIGEST"
}

# tags: every tag of the bundle, a page at a time (GHCR pages the list, and a
# sha- tag per merge fills pages quickly), following the Link header.
tags() {
  local url="https://$REGISTRY/v2/$REPOSITORY/tags/list?n=1000" pages=0
  if [ -n "${LOCAL_BUNDLES:-}" ]; then
    ls "$LOCAL_BUNDLES/tags"
    return 0
  fi
  token
  while [ -n "$url" ]; do
    pages=$((pages + 1))
    [ "$pages" -le 100 ] || die "more than 100 pages of tags"
    curl -fsS --max-time 60 -D "$TMP/headers" -o "$TMP/tags.json" \
        -H "Authorization: Bearer $TOKEN" "$url" \
      || die "could not list the tags of $IMAGE"
    jq -r '.tags[]?' "$TMP/tags.json"
    url="$(next_page "$REGISTRY" "$TMP/headers")"
  done
}

# release_of <digest>: the newest release tag, X.Y.Z, that names the digest;
# nothing when none does. Newest first, so stable's is the first one tried.
release_of() {
  local want="$1" tag
  # First, not in the loop's process substitution: a failed listing stops here.
  tags > "$TMP/tags"
  while IFS= read -r tag; do
    resolve "$tag"
    if [ "$DIGEST" = "$want" ]; then
      echo "$tag"
      return 0
    fi
  done < <(releases_newest_first < "$TMP/tags")
}

# extract <dir>: the layers of the manifest resolve fetched, each checked
# against its digest, into <dir>. Files and directories only: a bundle has no
# links, and a layer that deletes files (a whiteout) is not one of ours.
extract() {
  local dir="$1" digest type odd
  if [ -n "${LOCAL_BUNDLES:-}" ]; then
    cp -a "$LOCAL_BUNDLES/$DIGEST/." "$dir/"
    [ -f "$dir/release.json" ] || die "no release.json in $LOCAL_BUNDLES/$DIGEST"
    return 0
  fi
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

# ----------------------------------------------------------------- main ---
case "${1:-}" in
  resolve)
    [ "$#" -le 2 ] || usage
    resolve "${2:-latest}"
    echo "$DIGEST"
    ;;
  release-of)
    [ "$#" -eq 2 ] && [[ "$2" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
    release_of "$2"
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
