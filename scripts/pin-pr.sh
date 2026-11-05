#!/usr/bin/env bash
#
# Pin a service through a PR that merges itself: what .github/workflows/pin.yml
# runs (Release pipeline step 3). master takes no direct pushes, so the pin is
# a commit on a branch, the PR runs CI like any other, and auto-merge merges it
# once the checks are green. Merging deploys (README "Deploying").
#
#     scripts/pin-pr.sh <next|importer|suggester> <tag>
#
# Needs gh logged in (GH_TOKEN) as an identity whose PRs start workflows: the
# pin app's token, not GITHUB_TOKEN. Pushes and commits as whatever git is
# configured with.
#
# One branch per service, pin/<service>. A newer pin of a service replaces the
# one still waiting for CI, and a pin of the tag master already runs closes it:
# the newest pin wins.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
component="${1:-}"
tag="${2:-}"
if [ -z "$component" ] || [ -z "$tag" ]; then
  echo "usage: $0 next|importer|suggester <tag>" >&2
  exit 2
fi
branch="pin/$component"
cd "$REPO_ROOT"

git fetch -q origin master
git switch -q -C "$branch" FETCH_HEAD
before="$(git rev-parse HEAD)"
scripts/pin.sh "$component" "$tag"

open="$(gh pr list --base master --head "$branch" --state open --json number --jq '.[0].number // empty')"

if [ "$(git rev-parse HEAD)" = "$before" ]; then
  if [ -n "$open" ]; then
    gh pr close "$open" --delete-branch \
      --comment "master already runs $tag, so this pin is not wanted any more."
    echo "==> closed #$open: master already runs $tag"
  fi
  exit 0
fi

title="$(git log -1 --format=%s)"
body="$(git log -1 --format=%b)

Opened by *Pin fork image*. It merges itself once CI is green, and merging deploys it. A newer pin of $component replaces this one."

git push -q --force origin "HEAD:refs/heads/$branch"
if [ -n "$open" ]; then
  gh pr edit "$open" --title "$title" --body "$body" >/dev/null
else
  gh pr create --base master --head "$branch" --title "$title" --body "$body" >/dev/null
fi
gh pr merge "$branch" --auto --squash
echo "==> $title: $(gh pr view "$branch" --json url --jq .url), merges itself once CI is green"
