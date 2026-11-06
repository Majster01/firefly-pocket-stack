# AGENTS.md

firefly-pocket-stack is the deployment repository of a live personal-finance server with real bank data. README.md is the manual; read the part you touch.

## Deploying: master is production

- **Merging into `master` (or pushing to it) deploys** to the server within about two minutes (README "Deploying"). Merge or push to `master` only when the user asked, in this session, to deploy that change. Otherwise work on a branch and open a PR.
- The same holds for the apps this repository deploys: `main` of [firefly-pocket](https://github.com/Majster01/firefly-pocket) and `fireflyx` of [data-importer](https://github.com/Majster01/data-importer). Each has a DEPLOYING.md.
- `master` takes no direct pushes; every change is a PR that passes CI. `.github/workflows/pin.yml` opens one for each new image tag of the forks and the suggester (`pin/<service>`, by the pin app), which merges itself once CI is green, and Renovate opens PRs for upstream images. Rebase onto `master` before pushing; never rewrite its history.
- The server is a git checkout of `master`, reset on every deploy. Never change tracked files on the server: the deploy refuses to run over them. `compose/.env` lives only on the server and is never committed.
- A change that needs a new `.env` value or secret must say so in its PR: the value has to be on the server before the merge, or the deploy stops at `docker compose`.
- Releases (`.github/workflows/release.yml`, `scripts/release.sh`) are made by hand, only when the user asks for one; a dry run is always fine.
- Image tags stay pinned. Don't move Firefly III's or Postgres' image in passing: they migrate databases on start, and the deploy backs up and runs a restore test before it does.

## Checks

CI (`.github/workflows/ci.yml`) runs these on every PR into `master`, as the checks `shellcheck`, `compose`, `suggester`, `boot`, `bundle`, `upgrade (stable)` and `upgrade (latest)`. Run the ones your change touches before pushing:

- `git ls-files -z '*.sh' | xargs -0 shellcheck -x -P scripts` for scripts. CI runs shellcheck 0.11.0.
- `docker compose --project-directory compose config -q` with a `compose/.env` for compose changes (the `:?` variables must be set; dummy values are fine locally, or `cp compose/.env.example compose/.env && scripts/gen-secrets.sh` as CI does).
- `python -m unittest` in `services/category-suggester` for the suggester, with `requirements.txt` installed. CI runs them inside the suggester's image.
- `scripts/make-bundle.sh <empty-dir>` assembles the release bundle that `.github/workflows/publish.yml` pushes on every merge: it reads every image's digest from its registry, so it needs network access to them.
- `FROM=latest scripts/upgrade-test.sh` boots a published bundle and upgrades it to the checkout; same rules as `boot-test.sh`.
- `scripts/boot-test.sh` boots the whole stack with throwaway values and runs the deploy's smoke test (`KEEP=1` leaves it running). It needs Docker, refuses to run where `compose/.env` exists, and is never for the server: its containers use the server's names.
