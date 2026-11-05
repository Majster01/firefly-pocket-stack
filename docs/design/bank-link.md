# Design: bank connections managed from Pico, through an importer fork

Status: **phases 0–3 implemented** (see §13 and §14); "Import now" is implemented too (§15). Researched 2026-10-29 against data-importer `v2.3.4` (currently pinned) and `v2.3.5` (latest; `main` @ `9228bb7`). Tried locally: the overlay image (§4.3), the Caddy callback split (§7.2), and the base + connection merge against the live NLB config (§5.1).

## Summary

- **The fork owns the logic.** All bank-connection logic lives in an **additive fork of the Data Importer** (`Majster01/data-importer`, branch `fireflyx`). **Pico (`firefly-pocket-archive`) is its only UI** and calls the fork's token-guarded JSON API.
- **One shared import config.** Every connection uses the same committed `config/importer-base.json`. A connection holds only what really differs: its Enable Banking session and its bank-account → Firefly-account mapping (plus the bank it belongs to).
- **Connections live in Postgres, not files.** `/autoimport` can only read a directory, so the fork writes `/import/<name>.json` (base + connection + date window) from the database at the start of every nightly run, then the unchanged `/autoimport` call imports them. A connection saved in Pico is therefore imported at the next 03:00 run. A post-import check alerts if any active connection was *not* imported.
- **The fork is small.**
  - New code lives in `app/FireflyX/`, `routes/fireflyx.php`, `config/fireflyx.php` and `database/migrations/fireflyx/`.
  - The only upstream file changed is `config/app.php`, by one line.
  - The image is `FROM fireflyiii/data-importer:version-X` plus `COPY`, with no build step.
- **The one registered Enable Banking redirect URL** (`https://import.<domain>/eb-callback`) is shared. Caddy sends callbacks whose `state` starts with `fx-` to the fork's handler and everything else to the upstream importer, as today.

## 1. Goals

1. **Connections page.** Pico has a page listing every importer connection with its status, `expires_at`, bank, and for each bank account the Firefly account it imports into (as a link). Each connection has **Remove** and **Re-authenticate**.
2. **Re-authenticate.** Sends the user straight to the bank's consent page and then back to that Pico page.
3. **New connection.** A new import connection can be set up entirely from Pico (Enable Banking only). It uses the shared import config, and **it imports automatically at the next nightly run**.

Non-goals: other importer flows; per-connection import settings; replacing the importer's own UI, which stays as a fallback.

## 2. Constraints

- **One redirect URL.** Enable Banking accepts only registered redirect URLs (`REDIRECT_URI_NOT_ALLOWED`), and the user cannot add one. The registered URL is the importer's `GET /eb-callback` ([routes/web.php:54](https://github.com/firefly-iii/data-importer/blob/v2.3.4/routes/web.php#L54)).
- **`state` comes back unchanged.** Enable Banking returns it "unchanged in query parameter". The upstream callback only accepts a `state` that is the UUID of one of its own import jobs ([ImportJobRepository.php:74-91](https://github.com/firefly-iii/data-importer/blob/v2.3.4/app/Repository/ImportJob/ImportJobRepository.php#L74-L91)).
- **The importer host is public behind basic auth**, because the OAuth redirect must reach it over HTTPS.

## 3. Research: what upstream gives us and what is missing

### 3.1 No API for any of the goals

- **External entry points:** only `POST /autoimport` (secret + **directory**) and `POST /autoupload` ([AutoImportController.php:45-89](https://github.com/firefly-iii/data-importer/blob/v2.3.4/app/Http/Controllers/AutoImportController.php#L45-L89)). The existing `/api/*` routes are read-only helpers for the importer's own UI and **have no authentication** ([routes/api.php](https://github.com/firefly-iii/data-importer/blob/v2.3.5/routes/api.php)).
- **The EB link flow is web pages only.** It ends in a *download* of a JSON config ([LinkController.php:54-185](https://github.com/firefly-iii/data-importer/blob/v2.3.4/app/Http/Controllers/Import/EnableBanking/LinkController.php#L54)). The importer never stores a config itself.
- **Expiry is parsed and ignored.** `access.valid_until` is parsed ([SessionResponse.php:53-60](https://github.com/firefly-iii/data-importer/blob/v2.3.4/app/Services/EnableBanking/Response/SessionResponse.php#L53-L60)), but nothing reads it.
- **The consent length is fixed:** `+90 days` (2.3.4) or 89 days (2.3.5) ([PostAuthRequest.php:90](https://github.com/firefly-iii/data-importer/blob/v2.3.5/app/Services/EnableBanking/Request/PostAuthRequest.php#L90)), even though the bank's `maximum_consent_validity` is parsed ([Bank.php:50](https://github.com/firefly-iii/data-importer/blob/v2.3.4/app/Services/EnableBanking/Model/Bank.php#L50)). 2.3.4 also hits [#12553](https://github.com/firefly-iii/firefly-iii/issues/12553) across DST changes.

### 3.2 What one nightly import of an EB config does

1. **Discovery.** `AutoImports::getFiles()` does a flat `scandir()` of the directory and treats every `*.json` with no CSV/XML companion as one job ([AutoImports.php:59-116](https://github.com/firefly-iii/data-importer/blob/v2.3.5/app/Console/AutoImports.php#L59-L116)). Each job runs inside its own `try/catch` ([L175-L196](https://github.com/firefly-iii/data-importer/blob/v2.3.5/app/Console/AutoImports.php#L175-L196)), so one failing config does not stop the others.
2. **Session check.** `parseImportJob` → `case 'eb'` → `NewJobDataCollector::collectAccounts()` ([ImportJobRepository.php:215-222](https://github.com/firefly-iii/data-importer/blob/v2.3.5/app/Repository/ImportJob/ImportJobRepository.php#L215-L222)) calls **`GET /sessions/{id}`** for each session in `enable_banking_sessions`. With no session, it fails with `missing_sessions`.
3. **Download.** `TransactionProcessor::download()` calls `GET /accounts/{uid}/transactions` for each **key of `accounts`** ([TransactionProcessor.php:85-127](https://github.com/firefly-iii/data-importer/blob/v2.3.4/app/Services/EnableBanking/Conversion/Routine/TransactionProcessor.php#L85-L127)), from `date_not_before`.
4. **Report.** `event(new ImportedTransactions(basename($jsonFile), $messages, $warnings, $errors, …))` fires once per config ([AutoImports.php:337](https://github.com/firefly-iii/data-importer/blob/v2.3.5/app/Console/AutoImports.php#L337), and on each failure path at L248, L257, L266).

So **the session ID and the account UIDs must be replaced together.** UIDs are session-scoped: Enable Banking says they are "valid only until the session to which the account belongs is in the AUTHORIZED status", and upstream confirmed this in [#12093](https://github.com/firefly-iii/firefly-iii/issues/12093). The stable key across sessions is `identification_hash`.

### 3.3 Reusable upstream pieces

| Need | Upstream class |
|---|---|
| EB JWT, headers, base URL | `EnableBanking\Request\Request` (`getClient()`, `getHeaders()` are `protected`), `JWTManager` |
| Banks | `GetASPSPsRequest` → `Bank` (incl. `maximumConsentValidity`) |
| Consent | `PostAuthRequest` (`setValidUntil()`), `PostSessionRequest` → `SessionResponse` |
| Account details | `GetAccountDetailsRequest` → `Account` (IBAN, name, currency, `identification_hash`) |
| Valid config shape | `Configuration::make()`, `fromArray()`, `toArray()` |
| Firefly asset accounts | `Support\Http\CollectsAccounts` |
| Per-config import result | `App\Events\ImportedTransactions` (`configurationFile`, `messages`, `warnings`, `errors`) |

**Missing upstream, so the fork adds it:** `GetSessionRequest` (status, `valid_until`, `accounts_data`) and `DeleteSessionRequest` (`Request` has no DELETE).

### 3.4 Image build and extension points

- **The official image is a tarball on `firefly-iii/base-image`** (`serversideup/php:8.5-fpm-nginx`, `www-data`). Its entrypoint runs `composer dump-autoload` and `config:cache` on every start, with **no route cache**. An overlay that `COPY`s new PHP files, routes and config therefore works with no build step. This was tried locally on `version-2.3.5`: a token-guarded route returned `401` without the token and `200` with it, `Configuration::make()->toArray()` built a 52-key config, and upstream routes kept working.
- **The importer has no database**, but the image has `pdo_pgsql`, and Laravel's `config/database.php` reads `DB_*` from the env. Cache and session default to `file` and the queue to `sync`, so setting `DB_*` does not change upstream behaviour.
- **Migrations can run automatically.** The base image ships `/etc/entrypoint.d/50-laravel-automations.sh`, which runs `php artisan migrate --force` on start when `AUTORUN_ENABLED=true`. It waits for the database first. Its other automations (`optimize`, route/view/event cache) must be switched off (§4.3).
- **The importer has no `APP_KEY` today**: there's no `.env` in the image and none in compose. The fork needs one for encrypted columns.
- **`vendor/bin/phpunit` is in the image**, so fork tests run against the real base.

### 3.5 Upstream direction

There is no issue or PR about EB expiry or re-auth. For GoCardless the maintainer says "There is no simpler process yet… It is on my list" ([discussion #10690](https://github.com/orgs/firefly-iii/discussions/10690)). A fork is the only near-term path. Keeping it additive keeps rebases trivial.

## 4. The fork

### 4.1 Repository and branches

- **The fork:** `github.com/Majster01/data-importer`, branch `fireflyx` = upstream release tag + our commits.
- **Release bump:**
  ```bash
  git fetch upstream --tags
  git rebase --onto v2.3.6 v2.3.5 fireflyx
  ```
  Then bump `IMPORTER_VERSION`, run the tests, push, and pin the SHA in this repository. The only possible conflict is the one line in `config/app.php`.

### 4.2 Layout

```
app/FireflyX/
  FireflyXServiceProvider.php     # routes, migrations, commands, ImportedTransactions listener
  Http/RequireToken.php           # Bearer FIREFLYX_API_TOKEN (hash_equals, ≥32 chars)
  Http/ConnectionController.php   # list / show / refresh / delete
  Http/LinkController.php         # create + reauth (POST /auth) and the callback
  Http/AccountsController.php     # account mapping
  Http/BankController.php         # GET /banks
  EnableBanking/GetSessionRequest.php, DeleteSessionRequest.php, SessionDetails.php
  Models/Connection.php, ConnectionAccount.php, PendingAuth.php       # Eloquent
  Import/BaseConfig.php           # loads + validates the shared base (§5.1)
  Import/ConfigComposer.php       # base ⊕ connection ⊕ window → Configuration → array
  Import/AccountRemapper.php      # old → new uid via identification_hash, IBAN fallback
  Listeners/RecordImportResult.php  # ImportedTransactions → connections.last_import_*
  Console/RefreshConnections.php  # fireflyx:connections:refresh [--json]
  Console/RenderImports.php       # fireflyx:render [--dry-run]
  Console/ReportImports.php       # fireflyx:connections:report --since=… [--json]
  Console/AdoptConfig.php         # fireflyx:connections:adopt <file> (one-off migration)
routes/fireflyx.php
config/fireflyx.php
database/migrations/fireflyx/…
config/app.php                    # + App\FireflyX\FireflyXServiceProvider::class (only upstream edit)
Dockerfile.fireflyx
tests/FireflyX/…
```

### 4.3 Image and compose

```dockerfile
ARG IMPORTER_VERSION=2.3.5
FROM fireflyiii/data-importer:version-${IMPORTER_VERSION}
COPY --chown=www-data:www-data app/FireflyX                /var/www/html/app/FireflyX
COPY --chown=www-data:www-data routes/fireflyx.php         /var/www/html/routes/fireflyx.php
COPY --chown=www-data:www-data database/migrations/fireflyx /var/www/html/database/migrations/fireflyx
COPY --chown=www-data:www-data config/fireflyx.php config/app.php /var/www/html/config/
# Guard: our config/app.php must come from the same release as the base image.
COPY config/importer.php /tmp/fork-importer.php
RUN grep "'version'" /tmp/fork-importer.php > /tmp/a && grep "'version'" /var/www/html/config/importer.php > /tmp/b && cmp /tmp/a /tmp/b
```

```yaml
importer:
  build:
    context: https://github.com/Majster01/data-importer.git#<sha>
    dockerfile: Dockerfile.fireflyx
    args: { IMPORTER_VERSION: "2.3.5" }
  image: fireflyx/data-importer:2.3.5-<shortsha>
  depends_on:
    db: { condition: service_healthy }
    app: { condition: service_started }
  volumes:
    - importer_render:/import                     # written only by fireflyx:render; was ./importer
    - ../config/importer-base.json:/fireflyx/base.json:ro
    - ./secrets/eb:/secrets/eb:ro
  environment:
    # … all existing variables …
    APP_KEY: ${IMPORTER_APP_KEY:?run scripts/gen-secrets.sh}
    DB_CONNECTION: pgsql
    DB_HOST: db
    DB_PORT: "5432"
    DB_DATABASE: fireflyx_importer
    DB_USERNAME: importer
    DB_PASSWORD: ${IMPORTER_DB_PASSWORD}
    # Run our migrations on start; leave every other serversideup automation off,
    # so upstream's own boot sequence is unchanged.
    AUTORUN_ENABLED: "true"
    AUTORUN_LARAVEL_MIGRATION: "true"
    AUTORUN_LARAVEL_OPTIMIZE: "false"
    AUTORUN_LARAVEL_CONFIG_CACHE: "false"
    AUTORUN_LARAVEL_ROUTE_CACHE: "false"
    AUTORUN_LARAVEL_VIEW_CACHE: "false"
    AUTORUN_LARAVEL_EVENT_CACHE: "false"
    AUTORUN_LARAVEL_STORAGE_LINK: "false"
    FIREFLYX_API_TOKEN: ${FIREFLYX_API_TOKEN:?run scripts/gen-secrets.sh}
    FIREFLYX_PICO_URL: https://${PICO_HOSTNAME}
    FIREFLYX_CALLBACK_URL: https://${IMPORT_HOSTNAME}/eb-callback
    FIREFLYX_LOOKBACK_DAYS: ${IMPORT_LOOKBACK_DAYS:-5}
```

`/import` becomes a named volume that only the container writes. The host no longer reads or writes any importer file, so there are no uid or permission issues. The AUTORUN migration path and the version guard have **not been run yet** (§11).

## 5. Configuration model

### 5.1 One shared base, one row per connection

The rendered config for a connection is:

```
/import/<name>.json  =  base  ⊕  connection keys  ⊕  window
```

| Part | Keys | Source |
|---|---|---|
| **base** | everything else (41 keys today: `flow: eb`, `duplicate_detection_method: cell`, `unique_column_type: external-id`, `pseudo_identifier`, `rules`, `webhooks`, `ignore_duplicate_transactions`, `pending_transactions`, `version`, …) | `config/importer-base.json`, **committed** (it holds no secrets; every token field is empty), mounted read-only |
| **connection** | `enable_banking_country`, `enable_banking_bank`, `enable_banking_sessions` (`[session_id]`), `enable_banking_auth_id`, `accounts` (`{uid: firefly_account_id}`), `created_at` | Postgres (§5.2) |
| **window** | `date_not_before`, `date_not_after: ""`, `date_range: partial`, `date_range_number`, `date_range_unit: d` | computed by `fireflyx:render` (§6.1) |

**Tried on the live NLB config:** splitting today's `config/importers/nlb.json` into a 41-key base and the 6 connection keys, merging them back and applying the window gives a file **identical** to what `render-importer-config.sh` produces today. That covers every key and value, once `created_at` is counted as a connection key. In other words, the split changes nothing about how NLB imports.

Rules the fork enforces:
- **The base must not contain any connection or window key.** `BaseConfig` refuses to render otherwise. This matters because a deep merge of a stray `accounts: {}` in the base would union old UIDs into every connection.
- **The base must pass `Configuration::fromArray()` and have `flow: eb`** and `cell`/`external-id` duplicate detection.
- **Changing the base is a commit plus `deploy-cron.sh`** (it is a tracked file). It applies to every connection at the next nightly render.
- **Per-connection overrides are deliberately not supported.** If one is ever needed, it would be an explicit allow-list column, not a free-form JSON patch.

### 5.2 Database (`fireflyx_importer`, in the existing Postgres)

```
fireflyx_connections
  id, name (unique slug, [a-z0-9-]), status,
  bank_name, bank_country, bank_logo, psu_type, max_consent_days,
  session_id   (encrypted),  auth_id (encrypted),
  eb_status, valid_until, checked_at,
  import_since (date, nullable),           -- first-run backfill, see §6.2
  last_import_at, last_import_ok (bool), last_import_summary (json: messages/warnings/errors counts),
  last_error, created_at, updated_at, relinked_at, deleted_at (soft delete)

fireflyx_connection_accounts
  id, connection_id → connections, identification_hash, uid, iban, name, currency,
  firefly_account_id (int, nullable)       -- null = don't import, 0 = importer creates the account
  unique (connection_id, identification_hash)

fireflyx_pending_auths
  state (pk, "fx-" + 32 hex), kind (create|reauth), connection_id (nullable for create),
  payload (json: country, bank, psu_type), return_path, expires_at (+15 min), used_at
```

`session_id` and `auth_id` use Laravel's `encrypted` cast with the importer's new `APP_KEY`. Writes happen in transactions, so a re-link that swaps the session and every UID is atomic, and the nightly render reads a consistent snapshot. No file locks are needed.

**Why not files, as an answer to "does it need to live in a file?":** the files are only an interface. `/autoimport` accepts nothing but a directory (§3.2), so files must exist **at import time**, and `fireflyx:render` writes them seconds before the import. Everything else is better in the database:
- **Atomic swaps:** session and UIDs change together in one transaction.
- **Pico can query it:** status, expiry and last import come from a query, not a directory listing.
- **Backups:** add one name to the `pg_dump` loop in `backup.sh`.
- **No host file handling:** no host bind mount, no uid alignment, no laptop-vs-server copy to keep in sync.

`config/importers/*.json` and `scripts/deploy-importers.sh` are retired after migration.

### 5.3 Status shown in Pico

| Status | When | Rendered for import? |
|---|---|---|
| `active` | EB `AUTHORIZED`, more than 14 days left | yes |
| `expiring` | `AUTHORIZED`, 14 days or fewer left | yes |
| `expired` | EB `EXPIRED`, `REVOKED`, `CLOSED` or `INVALID` | no (ntfy alert instead of a failed import) |
| `needs_mapping` | session exists but no account is mapped, or a re-link could not remap every account | no |
| `pending` | consent started, callback not received | no |
| `error` | the last refresh failed (`last_error`) | yes (the import will report the real error) |

## 6. Nightly run: from saved connection to imported transactions

### 6.1 New `nightly.sh` order

| # | Step | Command | Fails when |
|---|---|---|---|
| 1 | Consent check | `docker compose exec -T importer php artisan fireflyx:connections:refresh --json` | any connection is `expired` or `expiring`: ntfy at 14, 7 and 3 days. Not fatal |
| 2 | Render | `… php artisan fireflyx:render` | the base is invalid (fatal, nothing rendered), or a connection can't be rendered (that one is skipped, the others proceed, alert) |
| 3 | Import | `internal_http http://importer:8080/autoimport?secret=…&directory=/import` (**unchanged**) | as today |
| 4 | Log check | `check_importer_errors` (**unchanged**) | as today |
| 5 | Import report | `… php artisan fireflyx:connections:report --since="$IMPORT_STARTED" --json` | **an `active`/`expiring` connection has no import result since step 3 started** (it was not imported), or its result has errors |
| 6–7 | Suggestions, Firefly cron | unchanged | |

**`fireflyx:render`:**
1. Loads and validates the base.
2. Computes one `date_not_before = today − FIREFLYX_LOOKBACK_DAYS` for all connections.
3. For every connection in `active`, `expiring` or `error` that has at least one mapped account, composes the config through `Configuration::fromArray(...)->toArray()`, so the importer's own model normalises it. It writes `/import/.<name>.json.<rand>` and renames it to `/import/<name>.json`. The temporary name has no `.json` extension, so the importer's `scandir` never picks it up.
4. Deletes every `/import/*.json` that has no matching connection, which covers removed and expired ones.
5. Prints one line per connection: `nlb → 2 accounts, since 2026-10-24`.

`--dry-run` prints the merged JSON with session IDs masked.

### 6.2 Why a newly saved connection imports at the next run

A connection created in Pico becomes importable the moment `PUT /connections/{name}/accounts` commits: status `active`, at least one mapped account, session `AUTHORIZED`. From there:
1. **03:00 step 2:** `fireflyx:render` selects it from the database and writes `/import/<name>.json`. No deploy, restart or file copy is involved, because the render reads the database every night.
2. **Step 3:** upstream `getFiles()` finds every `*.json` in `/import`, the new one included, and imports it in its own `try/catch`.
3. **Step 5:** the fork's `RecordImportResult` listener has stored `last_import_at` and `last_import_ok` for that connection from the `ImportedTransactions` event (`configurationFile` = `<name>.json`). If it is missing or failed, the nightly run alerts. Pico shows "Last import: today 03:00 ✓".

**First-run history.** The rolling window only reaches back `LOOKBACK_DAYS` (5). The setup page asks "Import history since" (default: 30 days ago, max: what the bank allows, normally 90 days). The date is stored as `import_since`. While `last_import_ok` has never been true, render uses `min(import_since, rolling date)` for that connection only. A failed first night therefore retries the full history the next night. Overlap is harmless, because duplicates are matched by `external_id`.

**Optional "Import now"** (phase 3): Pico can trigger an immediate import of just this connection. That reuses the same composer into a one-file directory and the upstream `importer:import {config}` command. The nightly run stays the guaranteed path.

## 7. API and callback

### 7.1 Fork API (`/api/fireflyx/v1`, `Authorization: Bearer $FIREFLYX_API_TOKEN`, internal network only)

| Method | Path | Body | Returns |
|---|---|---|---|
| `GET` | `/connections` | – | `[Connection]`; entries older than 1 h are refreshed from EB |
| `GET` | `/connections/{name}` | – | `Connection` |
| `POST` | `/connections/{name}/refresh` | – | `Connection` (live `GET /sessions/{id}`) |
| `DELETE` | `/connections/{name}` | – | `204`. `DELETE /sessions/{id}` at EB (best effort), soft-delete the row, remove `/import/<name>.json` now |
| `GET` | `/banks?country=SI` | – | `[{name, country, logo, max_consent_days, psu_types}]` |
| `POST` | `/connections` | `{country, bank, psu_type, return_path}` | `{name, auth_url}`, row `pending` |
| `POST` | `/connections/{name}/reauth` | `{return_path}` | `{auth_url}` |
| `PUT` | `/connections/{name}/accounts` | `{accounts: [{identification_hash, firefly_account_id}], import_since}` | `Connection` (now `active`; included in the next render) |
| `GET` | `/firefly/asset-accounts` | – | `[{id, name, iban, currency}]` via `CollectsAccounts`, for pre-selecting by IBAN |

`Connection` = `{name, status, bank: {name, country, logo}, psu_type, expires_at, days_left, checked_at, accounts: [{identification_hash, iban_masked, name, currency, firefly_account_id}], last_import: {at, ok, summary}, last_error}`.

### 7.2 Callback (public, only through Caddy)

`GET /fireflyx/eb-callback?state&code|error` does the following:
1. Looks up `fireflyx_pending_auths` (unused, not expired) and marks it used.
2. Calls `POST /sessions {code}` and fetches account details.
3. Branches on the kind of flow:
   - **create:** stores the accounts and sets `needs_mapping`.
   - **reauth:** runs `AccountRemapper`. If every mapped account is matched, it swaps the session and UIDs in one transaction and then `DELETE`s the old session. Otherwise it keeps the old data and sets `needs_mapping`.
4. Returns `302` to `FIREFLYX_PICO_URL + return_path + ?connection=<name>&result=<ok|needs_mapping|error>&reason=<code>`.

`return_path` must start with `/bank-connections`, so the callback can't be an open redirect.

The Caddy split was tried locally with `caddy:2.11.4-alpine` (`caddy validate` passes):
- `state=fx-…` is rewritten to the fork, in either parameter order.
- A UUID `state`, a malformed `state` and a duplicated `state` all fall through to basic auth.
- `/fireflyx/*` and `/api/fireflyx/*` return 404 from outside.

```caddyfile
{$IMPORT_HOSTNAME} {
	import security_headers
	@fx_callback {
		path /eb-callback
		vars_regexp {http.request.uri.query.state} ^fx-[0-9a-f]+$
	}
	@fx_internal path /api/fireflyx/* /fireflyx/*
	route {
		handle @fx_callback {
			rewrite * /fireflyx/eb-callback{?query}
			reverse_proxy importer:8080
		}
		handle @fx_internal {
			respond 404
		}
		handle {
			basic_auth {
				{$IMPORT_AUTH_USER} {$IMPORT_AUTH_HASH}
			}
			reverse_proxy importer:8080
		}
	}
}
```

## 8. Flows from Pico

- **List (goal 1):** `GET /connections`. Pico resolves `firefly_account_id` to names with its own Firefly client and links each to `/accounts/<id>`.
- **Re-authenticate (goal 2):** `POST /connections/{name}/reauth` → `window.location = auth_url` (Enable Banking's redirector, with `aspsp` and `psu_type` preset so no bank choice is shown) → bank → `/eb-callback` → Caddy → fork → `302` to `/bank-connections?connection=…&result=ok`. The next nightly run imports with the new session automatically, because render reads it from the database.
- **New connection (goal 3):** country → bank → personal/business → consent → `/bank-connections/<name>/setup`: each bank account gets a Firefly asset account (pre-selected by IBAN), "Create new" or "Don't import", plus "Import history since". **Save** makes it `active`, and it imports at 03:00 (§6.2).
- **Remove:** confirm → `DELETE` → stops importing immediately.

## 9. Pico (`firefly-pocket-archive` fork)

Follow the rule-suggestions feature (controller, service, repository, `pages/rule-suggestions/`, `profileStore.ruleSuggestionsEnabled`, an `extras.vue` entry with a badge).

**Backend:**
- `BankConnectionService`: `Http::withToken(config('app.importer_api_token'))->baseUrl(config('app.importer_api_url'))`.
- `BankConnectionController`: `checkUser()` first in every action.
- `BankConnectionValidation`.
- Routes:
  ```
  GET    bank-connections
  GET    bank-connections/banks
  POST   bank-connections
  GET    bank-connections/{name}
  POST   bank-connections/{name}/refresh
  POST   bank-connections/{name}/reauth
  PUT    bank-connections/{name}/accounts
  DELETE bank-connections/{name}
  ```
- New env vars: `IMPORTER_API_URL=http://importer:8080/api/fireflyx/v1` and `IMPORTER_API_TOKEN`.

**Frontend:**
- **`pages/bank-connections/list.vue`:** cards with logo, status tag, `expires_at`/days left and last import; bank account → Firefly account links; Re-authenticate, Remove (confirm) and pull-to-refresh; a floating "Add connection" button; a toast from `?result`.
- **`pages/bank-connections/new.vue`:** country, searchable bank list, personal/business → redirect.
- **`pages/bank-connections/[name]/setup.vue`:** the account mapping and "Import history since".
- **Wiring:** `BankConnectionRepository.js`, route constants, the extras entry with a badge (`expiring` + `expired`), a dashboard notice for `expired`, and `en` i18n strings.

**Returning to Pico:** the redirect target is an ordinary SPA route with the token in local storage. On an iOS home-screen PWA, the return may land in Safari. That is harmless: everything happened server-side.

## 10. Changes in this repo

- **`compose/docker-compose.yml`:** the importer is built from the fork (§4.3); `importer_render` volume; Pico gets `IMPORTER_API_URL` and `IMPORTER_API_TOKEN`.
- **`compose/initdb/01-create-databases.sh`:** `CREATE ROLE importer …; CREATE DATABASE fireflyx_importer OWNER importer;`. initdb only runs on an empty volume, so on the existing server this has to be run once by hand (README).
- **`scripts/gen-secrets.sh` and `.env.example`:** `IMPORTER_APP_KEY` (`base64:` + 32 random bytes), `IMPORTER_DB_PASSWORD`, `FIREFLYX_API_TOKEN`.
- **`scripts/backup.sh`:** add `fireflyx_importer` to the `pg_dump` loop (`for db in firefly firefly_pico fireflyx_importer`). Add `restore-test.sh` coverage. Separately, the current copy of `config/importer-config.json` points at a path that no longer exists, so **`config/importers/` is not backed up today**. That gap disappears once connections are in the database.
- **`scripts/nightly.sh`:** the steps in §6.1.
- **`config/importer-base.json`:** new and committed, generated once from today's `nlb.json` (§5.1). It replaces `config/importer_config.example.json`.
- **Retired after migration:** `scripts/render-importer-config.sh`, `scripts/deploy-importers.sh`, `config/importers/`, and the `./importer` bind mount.
- **`compose/Caddyfile`:** §7.2.
- **`deploy-firefly.sh`:** `build` instead of `pull` for the importer.
- **README:** "Connect your bank", "Adding another bank account" and "Re-authorising the bank" now point at Pico. New: "Changing import settings" (edit `config/importer-base.json`, run `deploy-cron.sh`).

## 11. Plan

**Phase 0: groundwork (this repo only, before any fork work)**
- Back up `config/importers/` until it's retired.
- Bump to upstream `v2.3.5` (fixes the DST bug).
- Commit `config/importer-base.json` from today's NLB config.

**Phase 1: fork skeleton, database, render, status**
- **Fork:** provider, token middleware, migrations, `BaseConfig` + `ConfigComposer`, `fireflyx:render`, `RecordImportResult` + `fireflyx:connections:report`, `GetSessionRequest` + refresh, `GET /connections`, `fireflyx:connections:adopt`, `Dockerfile.fireflyx`.
- **Tests:** a golden test that base + NLB fixture renders exactly today's config; base validation; the remapper.
- **This repo:** database + secrets, compose build, AUTORUN migration (verify on a staging start), the new nightly steps, the backup loop.
- **Migrate:** `fireflyx:connections:adopt /…/nlb.json`. Then compare `fireflyx:render --dry-run` with the old rendered file: expect no difference except the date. Then let one nightly run use the new path, and only then retire `render-importer-config.sh`.
- **Pico:** the read-only list.

**Phase 2: re-authenticate and remove**
- **Fork:** `PendingAuth`, reauth, the callback, the remapper and delete.
- **This repo:** the Caddy split.
- **Pico:** the actions and return handling.
- **Test:** one real NLB re-link; the next nightly report shows NLB `ok` with the new UIDs.

**Phase 3: new connections**
- **Fork:** `GET /banks`, `POST /connections`, `PUT /accounts` with `import_since`.
- **Pico:** the new and setup pages.
- **Test:** add a connection in the evening; the next morning's report shows it imported, with history since the chosen date.
- **Optional:** "Import now".

## 12. Open questions and risks

1. **Is NLB's `identification_hash` stable?** It should be, by the API's contract. Phase 1 stores it, and the first phase 2 re-link proves it. The fallback is an IBAN match.
2. **NLB's `maximum_consent_validity`:** if it is 180 days, re-links halve.
3. **How far back can a 03:00 import go?** Some banks only return history beyond 90 days right after consent. `import_since` is therefore capped at 90 days, and "Import now" covers deeper backfill.
4. **Enable Banking interstitial:** whether one appears before NLB's login.
5. **AUTORUN migration** on this image, with only the migration enabled: verify on first start. The fallback is an `entrypoint.d/60-fireflyx-migrate.sh` in the overlay.
6. **Rebase cost:** low while the fork stays additive. Upstream renaming the EB request classes or `ImportedTransactions` breaks the build tests rather than the 03:00 run.
7. **Upstream PR:** using `maximum_consent_validity` in `LinkController::build` is small and useful for everyone (keep it short and human-written).

## 13. Implementation notes (phases 0–2)

Where the build differs from the design above, and why. Code: fork [`Majster01/data-importer@fireflyx`](https://github.com/Majster01/data-importer/tree/fireflyx) (`3e5f500f`), this repo's branches `bank-link-phase1`/`bank-link-phase2` (in its private predecessor), firefly-pocket-archive branch `bank-connections`.

- **Upstream re-hashes `identification_hash`.** `Account::fromArray()` stores `sha256` of Enable Banking's value, and when the bank sends none it invents one from the whole account, uid included, which changes with every session. The fork therefore never reads the hash through upstream's `Account`: `BankAccount` keeps Enable Banking's raw value, the same one `GET /sessions/{id}` returns in `accounts_data`. Mixing the two would have made every re-link fall back to the IBAN, or fail.
- **Enable Banking behind one interface.** Every call goes through `EnableBankingGateway` (`UpstreamGateway` wraps upstream's request classes; `GetSessionRequest`, `DeleteSessionRequest` and `GetAccountDetailsRawRequest` are the fork's own). Tests bind a fake, so the whole re-link flow is tested without the network.
- **Consent length in seconds.** `valid_until = now + maximum_consent_validity − 86 400 s`. Counting calendar days would cross a DST change an hour long, which is how upstream's fixed 90 days broke (#12553).
- **A re-link that cannot find every imported account changes nothing.** The working connection is kept (its old consent may still be valid), the new consent is closed, and Pico is told `result=needs_mapping&reason=unmatched_accounts`. Mapping in Pico is phase 3; until then such a bank is re-linked in the importer UI.
- **Migration and interim re-links: `fireflyx:connections:adopt`.** Reads an exported config (from stdin with `-`, so the host passes its mode-600 file without mounts or root), refuses one whose shared settings differ from the base, and with `--replace` swaps session and account uids of an existing connection in one transaction.
- **The base config is mounted as the `config/` directory**, not the file: deploys replace the file by rename, and a single-file bind mount keeps showing the old inode.
- **`/import` is a named volume owned by `www-data`**, created in the image; the host no longer touches rendered configs. `fireflyx:render --dry-run` shows them.
- **Remove is a soft delete.** The consent is closed at the bank (best effort) and the rendered config deleted at once; the row keeps its name and import history.
- **Build guards.** `Dockerfile.fireflyx` fails when the branch and the base image are different importer versions (it copies `config/app.php`), and runs `php -l` over the fork's files: a syntax error would otherwise only show as an importer that does not boot.
- **Pico.** The page is `/bank-connections/list` (Extras → Bank connections, with a badge for expiring/expired/failing consents). Pico's backend exposes `GET api/bank-connections`, `POST api/bank-connections/{name}/reauthenticate` and `DELETE api/bank-connections/{name}`, and always passes `return_path=/bank-connections/list`; the fork accepts only paths under `/bank-connections`. Firefly account names are resolved from Pico's own account store.
- **Not yet verified against real services:** the upgrade on the server, a real NLB re-link (does NLB send a stable `identification_hash`; is the registered redirect URL exactly `https://import.<domain>/eb-callback`), and the Pico page on a phone.


## 14. Implementation notes (phase 3: new connections)

Code: fork [`Majster01/data-importer`](https://github.com/Majster01/data-importer) branch `phase3-new-connections` (`5eb2c708`), firefly-pocket-archive branch `bank-connections-new` (`f435f73`). Tested with fake Enable Banking and Firefly clients (fork: `NewConnectionTest`; Pico: `BankConnectionTest`) and the Pico pages against a mock backend. **Not yet tried against real services:** a real consent for a new bank, and the setup page on a phone.

Where it differs from §7–§9:

- **Accounts are addressed by row `id`, not `identification_hash`.** A bank may send no hash, and then two accounts could not be told apart. `Connection.accounts[]` now carries `id`, and `PUT /connections/{name}/accounts` takes `{accounts: [{id, firefly_account_id}], import_since}`. `firefly_account_id` is a positive integer or `null` (not imported); at least one account must be mapped, and `import_since` must be a date within the last 90 days.
- **No `GET /firefly/asset-accounts` in the fork.** Pico already holds the asset accounts and matches them to the bank accounts by IBAN. The fork exposes only the first and last four characters (`SI56…3438`), so Pico compares the same masking. It is a pre-selection: a mismatch just means the user chooses.
- **"New account" is created by Pico**, through its own accounts endpoint, when Save is pressed (once per bank account, even if the save is retried), and the fork only ever receives an ID. The importer is never asked to create accounts (`0` in the config is unused).
- **The callback sends a new connection to `/bank-connections/setup?connection=<name>&result=ok`**, a fixed path, because the name does not exist when Pico starts the flow. `return_path` is where *failures* go. A bank that refuses, or a failed session exchange, **deletes the pending row** (hard delete), so nothing half-made is left; a consent nobody comes back from is removed by the next `POST /connections`.
- **`pending` connections are not listed** (`GET /connections`); `needs_mapping` ones are, and count towards the Extras badge.
- **Names** are the bank's slug (`nlb`), then `nlb-2`, … A soft-deleted connection keeps its name, so a removed bank's history is never mixed into a new connection.
- **The bank list comes from the same Enable Banking call that gives the consent limit**, so creating a connection costs one call instead of two. `GET /banks` returns `max_consent_days` as whole days.
- **Deploying:** bump the importer pin (SHA in `build.context` and in the image tag) after the fork branch is merged, and run `scripts/deploy-pico.sh` for Pico. No new environment variables, secrets or Caddy rules.

### 14.1 Fixes after the first real use

- **A consent can share no accounts.** OTP banka accepted the consent but returned `accounts: []` (and `accounts_data: []`) for the session, the usual result of no account being ticked on the bank's own screen. The fork stored an empty `needs_mapping` connection that Pico could not map. The callback now closes such a session and returns `reason=no_accounts`: a new connection is not kept, a re-linked one keeps its old session. Re-authenticating a connection that was never mapped continues on the setup page instead of becoming `active`. An existing empty connection is repaired from Pico: setup page → Re-authenticate.
- **The bank may redirect to a browser, not the installed app.** The redirect target is a plain URL, so on a phone it can open in Safari or an in-app browser, which has its own storage and no Pico login. Pico now shows a "consent done, open Pico" page there (`/bank-connections/done`, no login needed), and while a consent is open the new-connection page polls the importer and continues to the setup page by itself. A connection waiting for its mapping is always reachable from Extras → Bank connections. The importer cannot do more: it never sees the user's device, and putting a Pico token in the redirect URL is not an option.

## 15. Implementation notes: Import now

Code: fork branch `manual-import` (on top of `fix-empty-consent`), firefly-pocket-archive branch `manual-import` (on top of `fix-bank-return`), and this repo. Tested with a fake importer and a faked suggester call (fork: `ManualImportTest`; Pico: `BankConnectionTest`; suggester: `test_serve.py`) and the Pico card against a mock backend. **Not yet tried against real services:** a real import over a chosen range, and the suggester trigger on the server.

What it is: the optional "Import now" of §6.2, with two changes. The user picks the **time frame** (the connection's saved configuration is otherwise unchanged and not editable), and the import is followed by **the category suggester over the same time frame**.

- **API.** `POST /connections/{name}/imports {date_from, date_to}` → `202` with the run; `GET /connections[/{name}]` carries the latest one as `manual_import: {id, status, date_from, date_to, started_at, finished_at, summary, error, suggestions, suggest_error}`. Pico: `POST api/bank-connections/{name}/import`. `status` is `queued → importing → suggesting → done`, or `failed`. Both days are included; `date_to` is today at the latest; the connection must be `active`, `expiring` or `error` with a mapped account (the same test the nightly render uses); only one manual import runs at a time, for all connections (`409`).
- **Same config, different window.** `ConfigComposer::composeRange()` builds the config exactly as `compose()` does, and only the window keys differ (`date_range: range` with `date_not_before` and `date_not_after`). A test compares it with the rendered nightly config.
- **Detached, in a row.** The request only inserts a `fireflyx_manual_imports` row and starts `php artisan fireflyx:manual-import <id>` with `nohup … &`, so neither the web worker nor Pico waits for it (an import takes minutes). That command writes the config to `/import/manual/<name>.manual-<id>.json`: a subdirectory, so the nightly `/autoimport` (a flat `scandir`) and the render's prune never see it, and a name that is not a connection's, so `RecordImportResult` ignores it. A manual import therefore never counts as the night's import, never clears `import_since` and never feeds the nightly report. It then runs upstream's own `importer:import`, which is allowed because `IMPORT_DIR_ALLOWLIST=/import` soft-matches subdirectories. A run that stops without finishing (its process died) is shown as `failed` after 90 minutes and stops blocking new ones.
- **Errors stop the chain.** If the import reports any error, the run is `failed` with the first error and the suggester is not called. A suggester failure leaves the run `done` with `suggest_error`: the transactions are in either way.
- **Suggester trigger.** The importer cannot start a container, and the suggester was a one-shot job with no port. A second compose service, `suggester-trigger` (same image, `suggester serve`), accepts `POST /suggest {since, until}` with a bearer token, runs `python -m suggester suggest --since … --until …` as a subprocess and answers when it ends. It has no published port and no Caddy route, and refuses to start without `SUGGESTER_TRIGGER_TOKEN` (≥ 32 characters), which only it and the importer hold. This weakens "the suggester has no port" to "its port is internal and token-guarded"; the alternative that keeps it literally portless (a request file in a shared volume that a polling worker picks up) was not worth its extra moving parts here.
- **Suggester changes.** `suggest --until`, and exact date filtering on both ends (the search takes a day of margin, so it does not matter whether Firefly's `date_after`/`date_before` include their own date). `suggest` takes an `flock` on `<db>.lock` while it writes, so the trigger and the nightly job never write suggestions at once (the second waits). `--report` now includes `written`.
- **Pico.** An **Import** button on connections the nightly import would also use (disabled while any manual import runs), a popup with two dates (default: the last 30 days), and a "Manual import" row on the card: a spinner and the stage while it runs (polled every 4 s), then the result and a link to the suggestions when Pico has them enabled.
- **Bank limits.** PSD2 lets a bank refuse unattended requests beyond about four a day per account. The nightly run uses one. The popup says to use this sparingly; nothing enforces it.
- **Deploying.** Merge and push the fork branch and the Pico branch, then bump the importer pin (SHA and image tag) and run `scripts/deploy-pico.sh`; run `./scripts/gen-secrets.sh` on the server for `SUGGESTER_TRIGGER_TOKEN`; `scripts/deploy-cron.sh` starts `suggester-trigger`; `scripts/deploy-firefly.sh` rebuilds the importer (its migration creates `fireflyx_manual_imports` on start).
