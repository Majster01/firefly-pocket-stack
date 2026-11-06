#!/usr/bin/env bash
#
# The category suggester's tests, inside its image: the same Python, the same
# pinned packages, the same user the server runs. CI's suggester check runs it
# on every PR, and "Suggester image" (suggester.yml) before it pushes. The
# image is built and tested once per platform it is published for (Release
# pipeline step 9); on an x86 machine, linux/arm64 runs under QEMU.
#
#     scripts/suggester-test.sh                         # linux/amd64 and linux/arm64
#     PLATFORMS=linux/amd64 scripts/suggester-test.sh   # one platform
#
# Needs Docker with buildx and, for a platform other than the machine's, QEMU:
# docker run --privileged --rm tonistiigi/binfmt --install arm64. The tests are
# not in the image, so they are mounted read-only; and no network, as none of
# them needs one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$REPO_ROOT/services/category-suggester"

for platform in ${PLATFORMS:-linux/amd64 linux/arm64}; do
  tag="suggester:test-${platform//\//-}"
  echo "==> $platform"
  docker buildx build --quiet --load --platform "$platform" -t "$tag" "$SERVICE" >/dev/null
  docker run --rm --platform "$platform" --network none \
    -v "$SERVICE/tests:/app/tests:ro" \
    --entrypoint python "$tag" -m unittest -v
done
