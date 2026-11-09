# firefly-pocket-stack

Self-hosted [Firefly III](https://docs.firefly-iii.org/) personal finance stack on one small EU VM, with a mobile UI, automated nightly bank imports, and AI-suggested category rules you approve.

| Service | What it is | URL |
|---|---|---|
| **Firefly III** | The finance app. Source of truth. | `https://firefly.<domain>` |
| **Firefly Pocket** | The mobile web app ([firefly-pocket](https://github.com/Majster01/firefly-pocket)): web app + API in one image, its own database. | `https://app.<domain>` |
| **Data Importer** | Pulls transactions from your bank via Enable Banking. | its own pages at `https://admin.<domain>/importer/`, behind the console's sign-in; until Hostnames step 8 also `https://import.<domain>` |
| **Category suggester** | Suggests category rules for you to approve in Firefly Pocket. Nightly one-shot job, plus a trigger only the importer can call. | *not exposed* |

Everything except Firefly III itself is an **API client** using a Personal Access Token — nothing else touches the Firefly database. That is why these compose so freely, and why adding or removing a companion app is low-risk.

---

## Design notes worth knowing

**The category suggester is never exposed.** Its nightly run is a one-shot job. The one other way to start it is the `suggester-trigger` service, which "Import now" in Firefly Pocket uses: it has no published port and no Caddy route, listens on the internal network only, and does nothing without `SUGGESTER_TRIGGER_TOKEN`, which only the importer holds. So nothing on the internet can drive its LLM spend. It only writes *inactive* rules; a category changes only when you approve a suggestion in Firefly Pocket.

**The importer *must* be public**, because the Enable Banking OAuth redirect lands in your browser over HTTPS. It has no login of its own, so Caddy guards it: its pages under `https://admin.<domain>/importer/` let through only a browser signed in to the console (the setup code during setup, Firefly III's owner after it), which Caddy asks with `forward_auth` before every request; `https://import.<domain>` still has basic auth until Hostnames and routing step 8 retires it. The bank's way back skips the lock and is protected by its single-use state instead: on `app.<domain>`, a callback with the fork's `fx-` state goes to the fork, and one with the importer's own UUID state goes on to `https://admin.<domain>/importer/eb-callback`, where the importer's session is. The console's session cookie is `SameSite=Lax`, not `Strict`, so the browser still carries it there after a bank's site. The nightly import trigger deliberately does **not** go through Caddy — cron calls the container directly on the internal network, so the lock never gets in automation's way.

**Firefly Pocket has no login of its own.** It is unlocked by a Firefly III token: one it gets when you **Sign in with Firefly III** on its setup page (Firefly III's own login, its two-factor authentication included; Setup UI step 11), or a Personal Access Token you paste into it. The browser keeps that token and sends it with every request; Firefly Pocket's server keeps no accounts and passes it on to Firefly III, which decides. Whoever holds the token has full access to Firefly III's API, which is public, and Firefly III's 2FA does not apply to tokens. So create **one token per device**, named after it, and a lost phone is revoked alone under Options → Profile → OAuth. Treat a phone with Firefly Pocket on it like one with your banking app: screen lock on, and Firefly Pocket's own passkey lock (Settings → Security) if others use the phone.

**Until Firefly III has its account, the server shows only its console.** Whoever reaches Firefly III before its first account exists can claim it. The setup wizard over SSH starts Caddy only once the account exists. Setup in the browser has to start Caddy first, so Caddy sends every name but `admin.<domain>` to the Firefly Pocket Console, which asks for a setup code printed on the server, until you finish setup there. The console holds no other secret and cannot touch Docker or the settings: it can only drop a request into a directory, which the host checks value by value and applies ([Set it up](#3-set-it-up)).

**The log viewer is never exposed.** Through the Docker socket proxy, Dozzle can read every container's environment (every secret) and files, so it has no Caddy route and listens on the host's loopback only. The way in is an SSH tunnel; see [Logs](#logs-dozzle).

**Firefly Pocket's push endpoint is internal too.** Alerts reach the Firefly Pocket app through `POST /api/internal/notify`, which this stack's own scripts and the suggester call over the compose network (`http://next:80`) with a bearer token (`NEXT_NOTIFY_TOKEN`). Caddy answers 404 for `/api/internal/*` on the public Firefly Pocket hostname, the same way it hides the importer fork's API. ntfy stays as a second, independent channel: every alert goes to both, and either one failing only logs a warning. See [Push alerts](#push-alerts-in-firefly-pocket).

**Image tags are pinned.** Firefly III runs database migrations on boot; an unattended version jump during a routine `docker compose pull` is how people lose data. Updating is a deliberate act — see [Updating Firefly III](#updating-firefly-iii).

**Merging into `master` is deploying.** The server pulls `master` every two minutes and makes itself match it; nothing logs into it to deploy, so SSH can stay locked to your own address. The forks and Firefly Pocket work the same way: a merge into their deploy branch builds an image and pins it here. See [Deploying](#deploying).

**Sessions are file-based**, per upstream. Firefly III ships no `sessions` table migration, so `SESSION_DRIVER=database` would break login. The consequence is that recreating the `app` container logs you out. That is expected, not a bug.

**Bank consent expires every 90–180 days.** That is a PSD2 regulatory limit, not a Firefly limitation, and cannot be automated away. See [Re-authorising the bank](#re-authorising-the-bank-every-90-180-days).

---

## Prerequisites

- A domain you control, with the ability to add a wildcard A record (a subdomain of it works too)
- A [Hetzner Cloud](https://console.hetzner.cloud) account and API token
- An [Enable Banking](https://enablebanking.com) account — **check your bank is in their coverage first**; if it is not, the import design needs rethinking
- An [Anthropic API key](https://console.anthropic.com/) on an account with credit
- Terraform ≥ 1.5 locally

---

## 1. Provision the server

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # token, SSH key, timezone
terraform init
terraform apply
```

Lock `ssh_source_ips` to your own address if it is static — it is the single highest-value restriction available here.

## 2. Point DNS at it

`terraform output` prints the IP. Create one wildcard A record:

```
*.<domain>   ->  <ip>
```

It covers the five names the stack answers on: `firefly.`, `app.` (Firefly Pocket), `admin.` (its console), `import.` and `legal.`. `<domain>` can be a subdomain of yours, e.g. `money.example.com` for `app.money.example.com` and the rest; it is the domain you give the setup wizard (`DOMAIN`). Caddy still gets a certificate for each name, not a wildcard one, so it needs no DNS API token. A provider without wildcard records takes the five as A records instead. Each name can also be set on its own (`FIREFLY_HOSTNAME`, `NEXT_HOSTNAME`, `ADMIN_HOSTNAME`, `IMPORT_HOSTNAME`, `LEGAL_HOSTNAME`, with `scripts/firefly-pocket config set`), e.g. to keep the one a server already uses; then its record is up to you. A server with no `DOMAIN` has no console name until `ADMIN_HOSTNAME` is set; Caddy serves it as `admin.localhost` meanwhile, which no one outside reaches by name.

Optionally add a CAA record, so no certificate authority other than Let's Encrypt may issue for the domain: `<domain>  CAA  0 issue "letsencrypt.org"`.

**The names must resolve before the stack starts** (`dig +short app.<domain>` prints the IP): Caddy requests Let's Encrypt certificates on first start, and if DNS is not live the challenge fails. The wizard's first step checks each name, and waits for you while it does not point at the server.

## 3. Set it up

The server fetches this repository over HTTPS. It is public, so the server needs no key. From your laptop, check out `master` into `/opt/fireflyx`, then run the setup wizard on the server:

```bash
ssh fireflyx@<ip> 'bash -s' < scripts/install-deploy-agent.sh   # checks out /opt/fireflyx
ssh -t fireflyx@<ip> /opt/fireflyx/scripts/firefly-pocket setup
```

It asks only for what you have to give, checks each answer as you give it, and keeps it in the settings store ([Settings](#settings)). Everything else is generated, the Firefly III tokens included, and nobody opens `compose/.env`:

| Step | It asks for | And checks |
|---|---|---|
| `domain` | the domain | each of the five names resolves to this server |
| `you` | your email (Firefly III's, Let's Encrypt's, the push services' and the legal pages'), your name for the legal pages, the timezone | the format; then every secret is generated |
| `account` | a password for your Firefly III account, at least 16 characters | the account and a token per app are made inside Firefly III, then `/register` is closed |
| `start` | nothing | every service runs, and each name gets its certificate |
| `bank` | the Enable Banking application ID, once you have registered the application with the certificate it made | a request signed with the key succeeds |
| `suggestions` | an Anthropic or Gemini API key | the provider lists the model for that key |
| `alerts` | an ntfy topic (it makes one), a healthchecks.io API key | a test alert arrives; both checks are made, with their schedules |
| `backups` | a restic repository, and its S3 keys | it opens, or is created; its password is shown to keep. Nothing is kept until it opens |
| `updates` | whether to turn on the deploy agent | it runs `install-deploy-agent.sh` |

Only the first four are needed. Skip any other with Enter and run it later with `scripts/firefly-pocket setup <step>`; the same command changes an answer, Enter keeping what is there. A step run on its own ends with `start`, which on a server with the deploy agent is `scripts/deploy.sh --force`.

Keep two things the run shows: the bank importer's password (basic auth for its own web page, printed once and not recoverable; rarely needed, since Firefly Pocket links banks), and, with backups, the restic password.

**Nothing is public before the account exists.** Until Firefly III's first account exists, anyone who reaches it can claim it. So the wizard starts only Postgres and Firefly III, makes the account and the tokens inside the `app` container with `scripts/firefly-bootstrap.php` (the account the way `/register` makes it, and one Personal Access Token per app, named `Firefly Pocket importer`, `Firefly Pocket suggester` and `Firefly Pocket warm-up` under Options → Profile → OAuth, so each can be revoked alone), checks that `/register` shows no form any more, and only then starts Caddy. There is no registration flag to set: Firefly III 6.x has no `ALLOW_REGISTRATION` option; `single_user_mode` lives in the database, defaults to true, and `allowedToRegister()` refuses as soon as one user exists. The tokens last a year, as the ones made by hand do. The nightly run makes a new one for any app whose token has 30 days or less left, or which Firefly III no longer takes, and starts that app again with it, before the import ([Rotating a secret](#rotating-a-secret)); `setup account` replaces any that stopped working too.

Then:

1. Sign in at `https://firefly.<domain>` and turn on two-factor authentication under Options → Profile. If two people share this account (Firefly III allows only one), both add the same TOTP secret to their authenticator app.
2. Make a token for each device you will use Firefly Pocket on: Options → Profile → OAuth → **Personal Access Tokens** → Create, named after the device, so a lost phone is revoked alone. Open `https://app.<domain>`, paste it, and add it to the home screen: this is the URL you use day to day.

Behind NAT the DNS check can only see that each name resolves; the certificates check the rest. The wizard reads its answers from stdin when that is not a terminal, one line each: that is how the boot test runs it (`scripts/boot-test.sh`), so CI sets up a new server on every PR, the Firefly III part included.

**Or start in the browser.** Instead of the wizard's first four steps:

```bash
ssh -t fireflyx@<ip> /opt/fireflyx/scripts/firefly-pocket setup web
```

It asks for the domain and your email, which Caddy needs for its certificates. It makes a setup code and starts Caddy and the Firefly Pocket Console, and nothing else. Until your Firefly III account exists, every name then sends the browser to `https://admin.<domain>`, which asks for that code; `setup web` prints it, and prints it again when run again. The console's first page is the domain, your email, your name and the timezone, with whether each name points at the server and has its certificate. Its second asks for your Firefly III account's password. The server then does what the wizard's `account` and `start` steps do, in a few minutes, while the page shows how far it got: it pulls every image, starts Postgres and Firefly III, makes the account and the three tokens inside Firefly III, checks `/register` is closed, and starts everything. Nobody sees a token. Then every name opens. The third page is the bank connection, the wizard's `bank` step ([Connect your bank](#4-connect-your-bank)): the server makes the key, the page hands out its certificate and the addresses to register with it, and you paste back the application ID. Then suggestions, the wizard's `suggestions` step (the AI key, kept once the provider has the model for it), and alerts, its `alerts` step (an ntfy topic made for the server, kept once a test alert reaches it, and healthchecks.io's two checks, made with an API key the server does not keep). Then backups, its `backups` step: a restic repository, either made by the server with a password the page shows you once to keep (it is never shown again once the repository exists), or one restic uses already, with its password; kept once it opens. Then updates, its `updates` step: the deploy agent turned on, which needs sudo without a password, as a server made from `terraform/cloud-init.yaml` has (without it, the page says to run `scripts/firefly-pocket setup updates`, which asks for the password). A saved key shows only by its last four characters. The last page, Finish, lists what each step left, with a link back to each, and ends the setup code. From then on the console opens only to you: **Sign in with Firefly III** takes you to Firefly III's own login (its two-factor authentication included, once you turn it on), which asks once whether to let the console in, and back. Signed in, it shows what the server has, and its bank, suggestions, alerts, backups and updates pages work as they did during setup: a key is changed, or the bank's key made anew, from the browser. The domain, your details and the account change only over SSH. The importer's own pages are behind the same sign-in, at `https://admin.<domain>/importer/`. The sign-in lasts 8 hours, and **Sign out** ends it at once. Any step can also be done or changed over SSH: `scripts/firefly-pocket setup`, Enter keeping what is set (it asks for no password, keeps the tokens, and ends the code too if it is still there; `scripts/firefly-pocket setup finish` ends it alone).

The console runs in a container that holds no secret but that code and cannot reach Docker, the settings or the apps (it shares a network with Caddy only). What it saves becomes a request in `compose/console/inbox`, a directory it can add files to but not list. Each request carries the setup code, so a file another user of the server drops there does nothing. `scripts/firefly-pocket console apply` checks each value as `config set` does and applies it; for the account, the bank, suggestions, alerts, backups and updates it runs the wizard's own code (`scripts/account.sh`, `bank.sh`, `suggestions.sh`, `alerts.sh`, `backups.sh`, `install-deploy-agent.sh`), with the account's password on stdin and in no file it keeps, and the bank's private key, every API key and the restic password only in the settings store. It takes each step in order: the Server step and the account until the account exists, then the rest and Finish. It writes what the console shows into `compose/console/status`, which holds no secret. `setup web` installs `firefly-pocket-console.path`, a systemd unit that runs `apply` as soon as a request arrives (`journalctl -u firefly-pocket-console` shows what it did). Once setup is finished, the code is gone, and a request carries instead the Firefly III token the console holds while its owner is signed in. `apply` takes it only once Firefly III's API says the token is `SITE_OWNER`'s, and Firefly III's own records (`scripts/firefly-bootstrap.php`) show it is the console client's and less than 8 hours old. Anything else is refused, another app's token for the same account included, and so are the Server step, the account and Finish. The sign-in after setup uses an OAuth client the server registers inside Firefly III (`scripts/firefly-bootstrap.php`, at the account step; on a server set up before it, the next deploy registers it, or `scripts/firefly-pocket console client`). The client is public, with PKCE, so the console still holds no secret; it reaches Firefly III through Caddy, lets in only the account the server was set up for (`SITE_OWNER`), and keeps Firefly III's token in memory for its 8-hour session only. Firefly Pocket gets a client of its own the same way, "Firefly Pocket" (`POCKET_CLIENT_ID`, which compose hands to it as `FIREFLY_CLIENT_ID`, with Firefly III's public address as `FIREFLY_PUBLIC_URL`): public too, with PKCE, redirecting to `https://app.<domain>/oauth/callback`. Pocket's server swaps the code for the token at Firefly III on the internal network, since Firefly III answers `/oauth/token` only to its own origin; the device keeps the token, which lasts a year, as a pasted one does, and is revoked under Options → Profile → OAuth → Authorized applications. `scripts/firefly-pocket console client` registers both clients, and the next deploy does it once on a server set up before them, starting Firefly Pocket again with its own. Firefly III would take that token for a year, so the server revokes it sooner: at **Sign out** (the console's last request, `signout`), and every hour any of the client's tokens older than 8 hours (`scripts/firefly-pocket console expire`, from the crontab). While you are signed in, that token is the one secret the console holds that matters: it reads and changes your Firefly III data through the API. A compromised console could use it until it is revoked, but still could not reach Docker, the settings store or any saved key.

**By hand.** The wizard runs these, and they still work on their own: `scripts/firefly-pocket config set <KEY> <value>` for any setting (`-` reads the value without showing it), `./scripts/gen-secrets.sh` for every generated one (it prints the importer password once, and never overwrites a value), `scripts/set-eb-key.sh` for an Enable Banking key made elsewhere. `compose/.env.example` explains every setting.

A private fork is fetched with a read-only deploy key instead. Give the script the fork's SSH address: `ssh fireflyx@<ip> 'REPO_URL=git@github.com:<owner>/<repo>.git bash -s' < scripts/install-deploy-agent.sh`. Its first run prints the key; add it under the fork's **Settings → Deploy keys** (no write access), then run the same command again to check out `master`.

## 4. Connect your bank

`scripts/firefly-pocket setup bank` does the Enable Banking part (it is a step of the full run too, and the console's third page during setup in the browser, which hands out the certificate as a download):

1. It makes a private key and a certificate on the server. The key never leaves it; the certificate is `compose/secrets/eb/application.crt`.
2. In the Enable Banking control panel you register a **production** application with that certificate as its public key, and two **redirect URLs**, exactly so: `https://app.<domain>/eb-callback`, where links started from Firefly Pocket come back, and `https://import.<domain>/eb-callback`, for the importer's own UI (your `NEXT_HOSTNAME` and `IMPORT_HOSTNAME`, where you set those). Caddy sends a callback whose state starts with `fx-` to the importer fork on either host, and on `app.` one with the importer's own UUID state on to its pages at `https://admin.<domain>/importer/`. Its privacy policy and terms are `https://legal.<domain>/privacy` and `/terms`.
3. You paste back the application ID. It is kept only once Enable Banking takes a request signed with the key for it, and it says whether the application is sandbox or production, and whether both redirect URLs are registered (`scripts/bank.sh`; `scripts/set-eb-key.sh` does the same for a PEM made elsewhere: `scripts/set-eb-key.sh <private.pem> <application-id>`).

Then link the bank in Firefly Pocket: **Bank connections → Connect a bank** ([Adding another bank account](#adding-another-bank-account)). The importer's own UI is the fallback when Firefly Pocket is not reachable:

1. Open `https://import.<domain>` (basic auth) and **run one import interactively**: link the bank, map each bank account to a Firefly asset account, configure duplicate detection.
2. Download the resulting config and bring it into the importer's database as a **connection**. Only its bank, Enable Banking session and account mapping are kept; every other setting comes from the shared, committed `config/importer-base.json`, so all banks import the same way. The command refuses a config whose settings differ from the base, rather than silently changing how that bank imports:
   ```bash
   scp nlb.json <server>:/tmp/nlb.json
   ssh <server> "cd /opt/fireflyx/compose && docker compose exec -T importer php artisan fireflyx:connections:adopt - --name nlb < /tmp/nlb.json && rm /tmp/nlb.json"
   ```
   The config arrives on stdin because the importer runs as `www-data` and need not be able to read your files. `--name` is the connection's name (`a-z`, `0-9`, `-`) and the name of its rendered `<name>.json`.
3. Check what tonight's import will use:
   ```bash
   ssh <server> "cd /opt/fireflyx/compose && docker compose exec importer php artisan fireflyx:render --dry-run 2>/dev/null"
   ```
   `accounts` maps each Enable Banking account UID to a Firefly III asset account ID — that mapping, not `default_account`, is what the `eb` flow uses. Sessions are masked. The nightly job renders every connection from the database before every run; see [Bank connections](#bank-connections-importer-fork).

### Adding another bank account

In Firefly Pocket: **Bank connections → Connect a bank**. Pick the country and bank, give consent at the bank, and Firefly Pocket brings you to a page where each bank account is mapped to a Firefly III asset account (matched by IBAN when one already exists, or created for you) with an optional *Import history since* date (at most 90 days back, which is all banks usually share). **Save** and the next nightly run imports it — no compose, cron or script changes, and the import report fails loudly if it did not. A connection you leave half-way stays under *Bank connections* as **Needs mapping** with a *Set up accounts* button.

### Importing by hand ("Import now")

On a connection's card in Firefly Pocket, **Import now** opens a time frame (default: the last 30 days) and starts an import of that connection at once. Nothing else is configurable: it uses the same settings as the nightly import (`config/importer-base.json`, the connection's session and its account mapping), with only the dates replaced. When the import finishes cleanly, the category suggester runs over **the same time frame** and the card shows what it made, with a link to review it. An import that reports errors stops there and says why; the suggester is not run.

It runs on the server, so you can close Firefly Pocket meanwhile. Only one manual import runs at a time, and it does not count as the night's import (the nightly report is unaffected). Overlap with what is already imported is harmless: duplicates are matched by `external_id`.

**Banks limit unattended requests** (PSD2 allows about four a day per account when you are not present at the bank), and the nightly run uses one, so keep manual imports for when you need them.

The importer's UI plus `fireflyx:connections:adopt` (above) still work and are the fallback when Firefly Pocket is not reachable. Firefly Pocket lists, renews and removes connections too; the design is in `docs/design/bank-link.md`.

One `/autoimport` call imports every rendered `*.json`: the importer's `AutoImports::getFiles()` scans the directory and treats each config as its own job, each inside its own `try/catch`, so an expired consent on one bank does not stop the others.

## 5. Category suggestions (review in Firefly Pocket)

The **category-suggester** (`services/category-suggester`, compose service `suggester`) is the reviewed alternative to letting an LLM set categories directly. For uncategorized withdrawals it asks Claude — with web search for merchants it does not recognise — which category fits and which rule trigger would catch the merchant next time, then writes that as an **inactive** rule into the `Suggestions` rule group. Firefly Pocket lists them; approving one moves its triggers into `Category: {category}` in `Categorization`. Nothing is categorized until you approve.

Both sides follow one contract, [`docs/rule-suggestions.md`](docs/rule-suggestions.md): rule format, metadata, and what happens on approve / set category / reject.

Setup: `scripts/firefly-pocket setup suggestions` takes `ANTHROPIC_API_KEY`, from an account with credit, or a Gemini key; the suggester's own Firefly III token, `SUGGESTER_FIREFLY_TOKEN`, comes from the account step. The model reads each **category's notes** (Firefly → Categories → edit) as your definition of what belongs there, so a one-line definition per category steers it far better than the name alone.

```bash
cd compose
docker compose run --rm suggester suggest --dry-run   # last 30 days, prints the rules, writes nothing
docker compose run --rm suggester suggest --all       # backfill every uncategorized withdrawal
docker compose run --rm suggester notify              # one push to the Firefly Pocket app if anything is waiting
docker compose run --rm suggester notify --dry-run    # print what it would send, send nothing
```

The same suggester also runs after a manual import (**Import now** in Firefly Pocket, see [Importing by hand](#importing-by-hand-import-now)), limited to the time frame that was imported: the importer calls the `suggester-trigger` service, which runs `suggest --since … --until …`. A run lock in the `suggester_data` volume keeps it and the nightly job from overlapping. Existing servers need the new token once: `./scripts/gen-secrets.sh`, then `scripts/deploy.sh --force` (which starts `suggester-trigger`).

Suggestions you reject in Firefly Pocket are remembered (SQLite in the `suggester_data` volume) and never made again. Low-confidence guesses (below `SUGGESTER_MIN_CONFIDENCE`) are still suggested, but only with the exact transaction description as trigger.

Categorization rules live **only in Firefly** (the `Categorization` group). Change them there or by approving suggestions in Firefly Pocket; there is no seed file to keep in sync.

## 6. Alerts and the schedule

The wizard's last step, `updates`, starts the deploy agent ([Deploying](#deploying)), whose first run deploys `master` and installs the crontab, as every deploy does. On its own: `scripts/firefly-pocket setup updates`, or from the laptop `ssh fireflyx@<ip> 'bash -s' < scripts/install-deploy-agent.sh`; `ssh fireflyx@<ip> 'crontab -l'` a few minutes later shows the jobs.

`scripts/firefly-pocket setup alerts` sets the two alert channels that do not depend on Firefly Pocket. **This system's most likely failure mode is silent** — the bank consent expires, imports stop, and nothing looks broken. Alerting is what turns that into something you find out about.

- **ntfy** (`NTFY_URL`): the wizard makes a long random topic on ntfy.sh, since anyone who knows a topic can read it, and sends a test once you have subscribed in the ntfy app. Your own ntfy server's topic works too. Every alert goes there and to the [Firefly Pocket app](#push-alerts-in-firefly-pocket).
- **The dead man's switch** (`HEALTHCHECK_NIGHTLY_URL`, `HEALTHCHECK_BACKUP_URL`). Every other alert is sent *from* this machine, so if the machine is down or cron has stopped, there is only silence. Given a healthchecks.io API key (the project's read-write key, used once and not kept), the wizard makes one check per job with the schedule below in your timezone and an hour's grace, and pings each once; healthchecks.io then mails you when a ping does not arrive. Only "ok", "failed" and a one-line reason are sent, never transaction data. A backup that never left the machine pings as failed on purpose.

| When | What |
|---|---|
| 02:00 daily | Backup: dump every DB, archive attachments, push offsite, ping `HEALTHCHECK_BACKUP_URL` |
| 03:00 daily | App tokens with 30 days or less left made again → consent check → render the import configs → bank import → check the importer log → per-connection import report (one notification per bank) → category suggestions → Firefly III cron → ping `HEALTHCHECK_NIGHTLY_URL` |
| 19:00 daily | The suggestions digest: one push to the Firefly Pocket app if category suggestions are waiting. Each device chooses daily, weekly or off in Pocket's settings |
| :17 every hour | The console's Firefly III sign-ins older than 8 hours revoked (`console.sh expire`); nothing to do while no one signs in to it |
| 04:00 Sunday | Restore test of the local backup: every database, the attachments archive and the `.env` copy |
| 04:30 Sunday | The same restore test from the offsite (restic) copy |
| 05:30, when needed | Reboot after a kernel or libc update (unattended-upgrades; see [Host updates](#host-updates)) |

The nightly steps run sequentially in one script rather than at guessed offsets, so the category suggestions really do run after the import finishes.

### Push alerts in Firefly Pocket

There are two kinds of message. **Alerts** (backup, restore test and consent failures, a failed deploy, and any other step that fails) go to **ntfy** and to every device with the Firefly Pocket app. **Notifications** are what you chose to hear about, and each device chooses for itself in Pocket under **Settings → Notifications**:

| Notification | Says | Setting (default) |
|---|---|---|
| Import succeeded | "NLB Current import succeeded", and how many new transactions came in | on; "only when something new came in" on |
| Import problems | Which bank, what went wrong in plain words, what to do about it, and that the exact error is in the importer logs (`scripts/logs.sh`, or `/var/log/fireflyx/nightly.log`). A night that finds no transactions is not a problem | on |
| Suggestions waiting | How many category suggestions wait for review; sets the app badge and opens the list | weekly, Monday; or daily; or off |
| Upgrades | "Upgrade successful": Firefly III 6.6.6 → 6.7.0, or just "Firefly Pocket" for a build. Only for a deploy that changed a package; other deploys stay quiet | on |

Notifications go to the Firefly Pocket app only (the devices that want them); ntfy additionally gets import problems, so a broken Firefly Pocket cannot hide a broken import. The digest cron runs every day and Pocket decides who gets it. See `docs/design/push-alerts.md`.

| Setting | What |
|---|---|
| `NEXT_NOTIFY_TOKEN` | Bearer token for Firefly Pocket's internal `/api/internal/notify`; generated, at least 32 characters. Scripts only push when it is set |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | P-256 keypair identifying this server to the push services (base64url, public key uncompressed); generated with `openssl`. Without them Firefly Pocket answers 503 and alerts fall back to ntfy alone |
| `VAPID_SUBJECT` | `mailto:` address push services can contact; replace the `you@example.com` placeholder |

**Enabling it** (an existing server; a fresh install already has all of it):

1. On the server, in `/opt/fireflyx`: `./scripts/gen-secrets.sh`. It adds `NEXT_NOTIFY_TOKEN` and the VAPID keypair if they are missing; then set `VAPID_SUBJECT` to `mailto:` your address. (If the script says it could not generate the keypair, there is no `openssl`: run `npx web-push generate-vapid-keys` anywhere and paste both values in.) The compose file requires `NEXT_NOTIFY_TOKEN`, and a deploy without it stops at `docker compose` with `run scripts/gen-secrets.sh`, restarting nothing.
2. Merging this repository deploys the senders and the Caddyfile that hides `/api/internal/*` (a deploy recreates Caddy when the Caddyfile changed). Check: `curl -s -o /dev/null -w '%{http_code}\n' https://<NEXT_HOSTNAME>/api/internal/notify` prints `404`. If you changed `.env` after Firefly Pocket started, `scripts/deploy.sh --force` on the server restarts it with the new env.
3. On the phone: open Firefly Pocket, **Add to Home Screen**, open it from the Home Screen icon, and turn notifications on in its Settings. The permission prompt appears only after you tap that switch.

Test it from the server without waiting for a real failure:

```bash
cd /opt/fireflyx/compose
docker compose run --rm suggester notify --dry-run                         # what the digest would send
. ../scripts/lib.sh && notify "Firefly Pocket: test" "Push alerts work."         # an alert: ntfy + every device
. ../scripts/lib.sh && notify_event upgrade.success "Upgrade successful" "Test" # a notification: devices that want upgrades
```

**iOS caveats.** Web Push on iPhone and iPad needs iOS/iPadOS **16.4 or later**, Firefly Pocket **installed to the Home Screen** (it does not work from a Safari tab), and the notification permission granted from a **tap** inside the installed app. Android Chrome and desktop browsers need no install. Rotating the VAPID keys invalidates every existing subscription; open Firefly Pocket and switch notifications off and on again afterwards.

**ntfy stays as the fallback for what goes wrong.** It is called first and unchanged, independent of the Firefly Pocket push: if Firefly Pocket is down, the receiver is not configured yet (503), the token is wrong (401), or nobody has subscribed, the alert still arrives via ntfy and the failing step is not affected. Firefly Pocket failures only print `WARN: Firefly Pocket push notification failed` to the job log. Leave `NTFY_URL` set; it is also what tells you the push channel itself is broken.

Import results come from the importer, not from a log scan: `fireflyx:connections:report --json` returns, per bank connection, the notification text the importer wrote (the account's name and the number of new transactions, or the failure in plain words), and `nightly.sh` forwards each. Run it by hand to see them: `docker compose exec -T importer php artisan fireflyx:connections:report --since="$(date -d '1 day ago' -Is)" --json 2>/dev/null`.

The log check exists because `/autoimport` answers **HTTP 200 even when the import failed** — an expired consent or a revoked token is reported only in the importer's own log, which `curl --fail` cannot see. The import report goes one step further: the importer records each connection's result, and the step fails if a rendered connection was not imported at all, or imported with errors. The consent check alerts on the days a consent is 14, 7 and 3 days from ending, and once it has ended.

---

## Verification

Work through these in order — each gates the next.

- [ ] All three subdomains serve valid certificates
- [ ] Sign in, then `docker compose restart app`, and confirm your account survives
- [ ] `/register` shows "Registration is currently not available" (returns 200 — check the page, not the status)
- [ ] Attach a receipt to a transaction, `docker compose up -d --force-recreate app`, confirm it still downloads
- [ ] Firefly Pocket works **on your actual phone**; a transaction created there appears in Firefly III
- [ ] `https://import.<domain>` prompts for basic auth from outside
- [ ] `https://logs.<domain>` does not answer at all, and Dozzle opens through the SSH tunnel ([Logs](#logs-dozzle))
- [ ] `docker compose exec importer php artisan fireflyx:render` writes one `<name>.json` per connection, all sharing a `date_not_before` of today minus `IMPORT_LOOKBACK_DAYS`, and `docker compose exec importer ls -l /import` shows them all
- [ ] `docker compose exec importer php artisan fireflyx:connections:refresh` shows every connection with its days left
- [ ] `./scripts/nightly.sh` imports transactions into the right asset accounts, and its "bank import report" step lists every connection as `ok`
- [ ] **Run it a second time and confirm it imports nothing** — this proves duplicate detection, the single most likely thing to be misconfigured. It must still exit 0: if the "bank import error check" step trips on the re-fetched overlap, `IGNORE_DUPLICATE_ERRORS` is not set
- [ ] Drop `&directory=/import` from the autoimport URL in `nightly.sh` and confirm the step now *fails* with "Not allowed to import from this path" — then put it back. This proves the log check and the allowlist are both live
- [ ] `docker compose run --rm suggester suggest --dry-run` prints sensible rules for your uncategorized withdrawals and writes nothing
- [ ] After a real run, the suggestions show up in Firefly Pocket; approve one and confirm only uncategorized transactions changed
- [ ] Create a recurring transaction dated tomorrow, run the cron step, confirm it fires
- [ ] Break the importer token deliberately and confirm you actually receive the alert
- [ ] `./scripts/backup.sh && ./scripts/restore-test.sh` passes — **do this now**, while there is nothing to lose

---

## Runbook

### Re-authorising the bank (every 90–180 days)

PSD2 consent expires. The nightly consent check alerts 14, 7 and 3 days ahead. In Firefly Pocket, open **Bank connections** and tap **Renew consent** on the bank; the next import uses the new consent. If the bank returns different accounts than before, the importer changes nothing (Firefly Pocket only says the consent was not confirmed), and you re-link in the importer UI instead: open `https://import.<domain>`, run the Enable Banking flow for that bank, download the config, then replace the connection's session and account IDs in one go (they belong together; the old ones die with the old session):

```bash
scp nlb.json <server>:/tmp/nlb.json
ssh <server> "cd /opt/fireflyx/compose && docker compose exec -T importer php artisan fireflyx:connections:adopt - --name nlb --replace < /tmp/nlb.json && rm /tmp/nlb.json"
```

If the export uses `classic` duplicate detection, the command refuses it as different from the base config; set `"duplicate_detection_method": "cell"` in the file first, or pass `--accept-base`, which keeps only the session and accounts anyway. Then run `./scripts/nightly.sh` on the server and confirm the import report shows the bank as `ok`.

### Debugging a bank link

When a consent finishes at the bank but Firefly Pocket does not get the account back (`reason=no_accounts`, `bank_declined`, `session_failed`), turn the consent trace on for the importer, repeat the link once, and read what Enable Banking and the bank actually said:

```bash
ssh <server> "cd /opt/fireflyx && scripts/firefly-pocket config set FIREFLYX_EB_TRACE true && docker compose --project-directory compose up -d importer"
# link the bank in Firefly Pocket, then:
ssh <server> "cd /opt/fireflyx/compose && docker compose logs --since 30m importer | grep -E 'EB-TRACE|FireflyX:'"
```

Each step is one line: `POST /auth request` (bank, `psu_type`, redirect URL), `POST /auth response`, `callback reached` (the query the bank sent back, `error` and `error_description` included), `POST /sessions response` (session status, how many accounts, every field each account carries), and, when no account came back, `GET /sessions/{id} (second look)` and `GET /accounts/{uid}/details` for whatever uids the session lists. IBANs and names are masked. `FIREFLYX_EB_TRACE_RAW=true` adds Enable Banking's answers unmasked; switch it (and the trace) off again afterwards, with `config unset` and `up -d importer`.

What the lines tell you:

- **No `callback reached`**: the bank never redirected to `/eb-callback`, or Caddy did not route it (the state must start with `fx-`).
- **`callback reached` with `error=` and no `code`**: the bank refused or the user cancelled; `error_description` says which.
- **`POST /sessions response` with `accounts: {count: 0}` and `status: AUTHORIZED`**: the bank accepted the consent but shared nothing. Check, in this order: (1) in the Enable Banking control panel, if the application is in *restricted mode*, the exact account you authorise must be linked there. A restricted application only fetches data from accounts linked to it ([docs](https://enablebanking.com/docs/api/linked-accounts/)); an unlinked account may then come back as an empty list rather than an error (not documented, an inference); (2) `psu_type` matches the account (personal vs business login); (3) the control panel's *Requests* view for the same `POST /sessions`; Enable Banking support can read the bank's side of it.

Session ids are cut to eight characters in the trace; the control panel's Requests view filters by session id.

### Checking that nothing was lost

`scripts/fingerprint.sh` prints the row counts of the tables that hold your data, the date of the newest transaction and the number of attachment files. Take one before any change to the server and compare it afterwards; only rows a night's import added may differ:

```bash
ssh <server> "/opt/fireflyx/scripts/fingerprint.sh" > before.txt
# ...the change...
ssh <server> "/opt/fireflyx/scripts/fingerprint.sh" | diff before.txt -
```

Every backup stores one as `fingerprint-<stamp>.txt`, and `restore-test.sh` fails when the restored copy does not match it.

### Logs (Dozzle)

[Dozzle](https://dozzle.dev/) is a live log viewer for every container. It is not on the internet: it listens on the server's loopback (`127.0.0.1:8081`) only, so you open an SSH tunnel and browse to it on your laptop. From the laptop, one command does both:

```bash
scripts/logs.sh                       # tunnel + browser; Ctrl-C closes the tunnel
scripts/logs.sh fireflyx-importer     # open straight on one container
```

It uses the same SSH target as the deploy scripts (`DEPLOY_HOST` to override) and `LOGS_PORT` for another local port. By hand, the same thing is `ssh -N -L 8081:127.0.0.1:8081 <server>` and `http://localhost:8081`. Open it when the status page says *what* failed and you want the surrounding lines: filter the importer for `EB-TRACE` or `FireflyX:` while debugging a bank link, or pick `fireflyx-suggester-trigger` to watch an "Import now" suggestion run.

What it is not: Dozzle stores nothing. It shows what Docker still holds, which is the 10 MB x 3 `json-file` rotation per container, and a container that was recreated starts with an empty log. The one-shot `suggester` container of the nightly run exists only while it runs, and the host's own files (`/var/log/fireflyx/*.log`, written by cron) are not containers, so they stay in the log files. The status page keeps the history that matters (nightly results, connection events, suggester runs); Dozzle is for looking at the present.

How it is kept safe: Dozzle never touches the Docker socket. A `socket-proxy` ([tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)) holds the socket and answers only read requests for containers and info; every write call is refused, so Dozzle cannot start, stop or exec anything. The two talk over a Docker network with no route out, Dozzle sits on a network of its own (not the apps' one), and its shell and actions are off. Analytics and update checks are switched off. Dozzle's docs call the remote-host mode it is used in legacy; the alternative, its agent, needs the socket mounted itself, and a read-only mount does not limit the Docker API.

**Read-only is not harmless**, which is why there is no public route: the proxy's `CONTAINERS` permission allows every read under `/containers`, including *inspect* (each container's environment, i.e. every secret in `.env`) and *archive* (copying any file out of a container, the Postgres data included). Whoever controls Dozzle can read everything. Dozzle has had a steady stream of security advisories, and a browser that has a site's basic-auth login cached sends it on cross-site requests too, so an SSH tunnel is the only door it gets.

Moving an existing server off the old `logs.<domain>` site: deploying `master` does it (Caddy is recreated without the route, Dozzle on its loopback port), then delete the `logs.` A and AAAA records at your DNS provider. `LOGS_HOSTNAME` can be removed from `compose/.env`; nothing reads it any more.

### Bank connections (importer fork)

The importer is built from our fork, [Majster01/data-importer](https://github.com/Majster01/data-importer) (branch `fireflyx`): the official image plus bank connections stored in its own `fireflyx_importer` database (sessions encrypted with `IMPORTER_APP_KEY`), a token-guarded API for Firefly Pocket, and the artisan commands the nightly run uses. The design, and why it is a fork, is in `docs/design/bank-link.md`.

Every connection imports with the same settings: the committed `config/importer-base.json`. A connection holds only its bank, its Enable Banking session and which bank account feeds which Firefly III account. Before each import, `fireflyx:render` writes base + connection + date window into `/import` (the `importer_render` volume) and removes the files of connections that are gone, expired or unmapped. To change an import setting for every bank, edit `config/importer-base.json` and merge it into `master`; the next nightly run uses it. The render refuses a base that sets per-connection or date keys, or anything but `cell`/`external-id` duplicate detection.

The date window is `today − IMPORT_LOOKBACK_DAYS` for every connection. **This is not redundant with the config's `date_range: "partial"`**: the importer never recomputes a relative range unattended (`Configuration::updateDateRange()` is called only from the interactive form), so without the render the window would freeze at whatever day the config was exported.

`IMPORT_LOOKBACK_DAYS` defaults to **5**, not 1. Banks book transactions a few days late and no later run looks back far enough to catch those, so a literal 24-hour window loses them permanently. Duplicate detection discards the overlap and `IGNORE_DUPLICATE_ERRORS=true` keeps it out of the logs, so the only cost is a slightly longer fetch.

Useful commands (run in `/opt/fireflyx/compose`; add `2>/dev/null` to hide the importer's debug log):

| Command | Does |
|---|---|
| `docker compose exec importer php artisan fireflyx:connections:refresh` | Consent status and days left per connection |
| `docker compose exec importer php artisan fireflyx:render --dry-run` | The exact configs tonight's import will use (sessions masked) |
| `docker compose exec -T importer php artisan fireflyx:connections:adopt - --name <name> [--replace] < config.json` | Bring an exported config in as a connection, or replace its session after re-linking |

#### Upgrading an existing server to the fork (one-off)

```bash
# on the server, in /opt/fireflyx, BEFORE merging the compose change that adds the fork
./scripts/gen-secrets.sh               # adds IMPORTER_DB_PASSWORD, IMPORTER_APP_KEY, FIREFLYX_API_TOKEN
./scripts/setup-importer-db.sh         # creates the fireflyx_importer database (initdb only runs on an empty volume)
# merge into master; within two minutes the deploy pulls the fork's image and starts it
cd compose && docker compose exec -T importer php artisan fireflyx:connections:adopt - --name nlb < ../config/importers/nlb.json
docker compose exec importer php artisan fireflyx:render --dry-run 2>/dev/null   # compare with the old compose/importer/nlb.json
cd .. && ./scripts/nightly.sh          # the import report must show nlb as ok
```

The old `compose/importer/` directory is no longer mounted and can be deleted once the first nightly run on the fork has passed. Keep `config/importers/` until then, too.

### Status page in Firefly Pocket (System status)

One screen on the phone answers "did last night work, and what is the suggester doing?" without ssh. It shows, for the last 7, 30 or 90 days:

- **Nightly imports**: last import, new transactions, failed runs, and **nights missed**. The day list has an entry for every day, so a night where cron never ran shows as "No import" instead of simply not being there. **Show all errors** opens the import errors page ([below](#import-errors-by-day)).
- **Bank connections**: status, consent days left, last import result per bank.
- **Bank connection activity**: what happened to the connections, newest first. Consent started, **declined by the bank** (with what the bank said), session failed, **no accounts shared**, accounts did not match on a re-link, accounts mapped, removed, and from the nightly check: status check failed (once, not every hour), works again, **consent ended**. This is where a failed link to a **new** bank stays visible, although that connection is deleted when the consent fails. No IBAN, name, session id or authorisation code is ever stored, only the step, a short reason and a bounded message.
- **Category suggester**: runs, **AI calls** (model API requests, which can exceed the number of groups when a web search pauses a turn), how many suggestions fell **below the confidence threshold**, web searches, tokens in and out, errors, and what became of the suggestions (waiting, approved or categorized by hand, rejected). A run with errors lists what the first few said (the model refused, a rule could not be written).

Where it comes from: the importer records one `fireflyx_import_runs` row per connection per nightly import (kept `FIREFLYX_HISTORY_DAYS`, default 180) and the connection events in `fireflyx_connection_events` (kept `FIREFLYX_EVENTS_DAYS`, default 90), the suggester one `runs` row per real run in its SQLite file, and `GET /api/fireflyx/v1/status` on the importer joins them with the connections and fetches the suggester's `GET /stats` on the internal network. Firefly Pocket only talks to the importer, so it needs no token for the suggester. **History starts the day each table is created** — earlier nights were not recorded, and the page says so. "Import now" runs are counted separately (they are not nightly imports), and a dry run leaves no suggester row.

#### Import errors by day

The **Import errors** page (System status → Nightly imports → **Show all errors**, and the **See error** link on a failed import in Bank connections) lists every error message of the nightly and the "Import now" imports that started on one day, with a day picker and a filter by bank. Identical messages are counted once (`message ×3`), at most 50 distinct messages are kept per import (the page says how many more errors there were), and a message is cut at 1000 characters. It comes from `GET /api/fireflyx/v1/errors?date=…&connection=…` on the importer, which reads `error_messages` on the nightly rows (kept `FIREFLYX_HISTORY_DAYS`) and on the "Import now" rows (**not** pruned). **History starts the day that column is added**: earlier imports show the one error they kept. A bank that was not imported at all shows as a missed night on System status, not as an error here. Deploy the importer before Firefly Pocket: an older importer has no `/errors`, so the page, and the **See error** link, cannot load.

Upgrading an existing server: merge the three branches in this order, each merge being its deploy, because each side tolerates the other being old — this repository's `master` (suggester image and `suggester-trigger`), then the importer fork's `fireflyx` (its migration runs on start), then firefly-pocket's `main`. With an old suggester the page shows the suggester card as unavailable with the reason; with an old importer the page reports that it cannot load the status.

### Duplicate transactions

Every config must use `"duplicate_detection_method": "cell"` with `"unique_column_type": "external-id"`. `classic` hashes the whole payload the importer submits, and NLB revises some entries in the days after booking (fields Firefly hashes but does not store), so the overlapping lookback window imports those a second time — identical in Firefly, same `external_id`, different `import_hash_v2`. `cell` instead searches Firefly for the bank's `entry_reference`, which does not change; it also matches deleted transactions, so a duplicate you delete stays deleted. The importer fork refuses a base config without it.

To find duplicates already imported, group transactions by `external_id`; any group with more than one member is a re-import, and the later-created copy is the one to delete.

### Deploying

**Merging into `master` is deploying.** The server runs what `master` says and nothing else, so work on a branch and merge when you want it live. The two forks work the same way: their deploy branch is production too (their `DEPLOYING.md`).

```
fork merge ─► its CI builds the image ──────────┐
suggester change ─► "Suggester image" builds it ┴─► pin PR ─► CI ─► merges itself ─┐
Renovate PR (Firefly III, Postgres, Caddy, …) ─► CI ─► you merge ──────────────────┼─► master
your change ─► PR ─► CI ─► you merge ──────────────────────────────────────────────┘     │
                                                                                         ▼
                                       server, every 2 minutes: git fetch ─► scripts/deploy.sh
```

Every PR into `master` runs CI (`.github/workflows/ci.yml`), eight checks: `shellcheck` on every script, `compose` (the settings store's tests, `scripts/config-test.sh`, then `docker compose config` with a hand-edited `.env` made by `scripts/gen-secrets.sh`, as a server from before the store has one), `suggester` (its tests, inside the image the server runs, built for `linux/amd64` and, under QEMU, `linux/arm64`), `console` (the console's tests, in the image compose runs it on, as compose runs it), and `boot` (`scripts/boot-test.sh`: the whole stack from scratch, set up as a new server is, with throwaway answers piped in. First `setup web`: every name but the console's must redirect to it, and the console must refuse a wrong code, a form from another origin and a bad value, and hand a good save to `console apply`, which must also refuse the requests a compromised console could forge, and one without the setup code. Then the console's account step: the account and a token per app made inside Firefly III from the password it sends, everything started and the gate open, the password in no file, the console's session still on. Then its bank step, suggestions and alerts, against stand-ins on the runner for the services they talk to: Enable Banking's checks each request's signature with the certificate the console handed out, so a wrong application ID is refused and the right one kept and the importer started with it; a wrong AI key is refused; the ntfy topic is kept once a test alert reaches it; and healthchecks.io's two checks are made in the server's timezone, with no key in a file the console reaches. Then backups, with real restic (CI installs it, as cloud-init does on a server): a repository on the runner made with the password the console shows once, which opens it, a wrong password refused, and the password in no file the console reaches. Then updates, with stand-ins for `sudo` and `systemctl` (the runner's own would start the deploy agent, which would reset the checkout): refused without sudo that needs no password, then the deploy timer's units written for the checkout and the timer enabled. Then Finish, after which the setup code signs in no more. Then `scripts/firefly-pocket setup`, which must ask for no password and keep the console's tokens, application ID, AI key, alerts and repository, after which the console must change nothing; the account step run again to show it keeps the tokens, then the deploy's own smoke test. Then the console's sign-in with Firefly III, through its login and approval pages as a browser goes; signed in, a new bank key made from the browser, its certificate uploaded to the stand-in and the application ID kept with it; Sign out, after which Firefly III takes none of the console's tokens; requests after setup with no token, the old code, another app's token or a malformed one refused; and a sign-in made nine hours old revoked by `console expire`. Then `tokens`: each app token made today shows a year left, `tokens rotate` makes none again, and `tokens rotate --days 400` makes all three again, prints none of them, leaves Firefly III refusing the old ones, and starts the importer and Firefly Pocket again with the new ones. Firefly Pocket's sign-in must work as a browser does it: its offer, Firefly III's login and approval with a PKCE challenge, back to Pocket's `/oauth/callback` with the state, and the code swapped by Pocket's server for a token that works in Pocket, but not with another verifier, nor twice. The importer's own pages under `/importer/` on the console's host must open, with their links under that prefix, for the signed-in owner, and send any other browser to the console; the fork's API must not be there, and a callback with the importer's own state on Firefly Pocket's host must go on to them. On a pin PR that is the new image booting before it reaches the server, Firefly III's bootstrap included), `bundle` (the release bundle below, assembled but not pushed, then compared with the checkout by `scripts/agent.sh compare`), and `upgrade (stable)` and `upgrade (latest)` (`scripts/upgrade-test.sh`: that published bundle booted with its own boot test, then upgraded to the PR the way a deploy does it, with the old `.env` (and settings store, once it has one) and `gen-secrets.sh` for anything new, smoke-tested, and the token made on the old version checked against Firefly III, and Firefly Pocket's host checked to show the app, not the console's setup gate; a hand-edited `.env` is then moved into the store with `config import`, and `up -d` must recreate nothing; then the sign-in clients of the console and of Firefly Pocket are registered in the old version's Firefly III, as the deploy does it once on a server set up before them, Firefly Pocket starts again with its own, and both are kept when asked again; from `latest`, that is the very upgrade the merge causes on your server). Before the first release, `upgrade (stable)` passes with a note that there is nothing to upgrade from. Merge only when all eight are green. Pins are PRs too: *Pin fork image* opens one per service as the pin app (the *pin PR* above), and it merges itself once the checks pass. `master` takes no direct pushes at all ([GitHub settings](#github-settings-once)).

**The release bundle.** Every merge into `master` also publishes `ghcr.io/majster01/firefly-pocket-stack` (`.github/workflows/publish.yml`, built by `scripts/make-bundle.sh`): the files a server runs, at their paths in this repository, with every image in compose pinned to the digest its tag named at that moment, and a `release.json` that lists the version, the commit and each component with its digest and whether it migrates a database. It is tagged `sha-<commit>` for every merge and `latest` for the newest. `master` builds are numbered after the next minor release, `1.0.0-dev.<n>` until the first one. Your server still deploys from git; the server agent will move it onto the bundle, and until then checks each bundle against the deploy in shadow mode (below).

**Verifying a bundle.** *Publish bundle* signs every bundle it pushes with [cosign](https://docs.sigstore.dev/cosign/), keyless: GitHub vouches for the workflow that ran, Sigstore issues a short-lived certificate naming it, and the signing is recorded in Sigstore's public transparency log, so there is no key to keep or leak. The signature belongs to the digest, so `latest`, `stable` and every release tag carry it. To check one:

```bash
cosign verify ghcr.io/majster01/firefly-pocket-stack:stable \
  --certificate-identity https://github.com/Majster01/firefly-pocket-stack/.github/workflows/publish.yml@refs/heads/master \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Bundles published before signing began have no signature. The bundle pins every image by digest, so its signature vouches for those exact images too.

**Every image runs on x86 and ARM.** The three images this project builds (Firefly Pocket, the importer fork and the suggester) are published for `linux/amd64` and `linux/arm64` under one tag, like every upstream image in the stack, so the server can be an ARM one (`server_type` in `terraform/variables.tf`).

The server pulls; nothing logs into it to deploy. `/opt/fireflyx` is a git checkout of `master`, fetched over HTTPS without credentials. Every two minutes `fireflyx-deploy.timer` runs `scripts/deploy.sh`, and when `master` has moved, that resets the checkout to it and:

1. pulls every image. If one is missing, nothing has restarted. Nothing is built on the server, the suggester included;
2. if Firefly III's, Postgres' or the importer's image is changing: backs up, and proves the backup restores. They migrate a database on start;
3. runs `docker compose up -d --no-build --remove-orphans`, which restarts only services whose image or settings changed (and Caddy when the Caddyfile changed);
4. installs `crontab`;
5. checks that Firefly III, the importer and Firefly Pocket (`/` and `/api/test`) answer and that every service runs.

A failure arrives as a push (ntfy and the Firefly Pocket app): `Firefly Pocket: deploy abc1234: <step> FAILED` with the step's output. A success says something only when it upgraded a package: "Upgrade successful" in the Firefly Pocket app. A revision that failed is not tried again until `master` moves; `scripts/deploy.sh --force` on the server retries it. Untracked files (`compose/.env`, `compose/secrets/`, `config/importers/`) are never touched.

The deploy and the cron jobs share one lock, `/run/lock/fireflyx.lock`: a deploy waits for the backup, the nightly import or a restore test, and they wait for a deploy. So the import is never cut off by a restart.

| What changed | How it gets to the server | Restarts |
|---|---|---|
| Firefly Pocket | merge into `main` of [firefly-pocket](https://github.com/Majster01/firefly-pocket) | `next` |
| The importer fork | merge into `fireflyx` of [data-importer](https://github.com/Majster01/data-importer) | `importer`, after a backup and restore test |
| Firefly III, Postgres, Caddy, Dozzle, the socket proxy, the images the scripts use | Renovate opens a PR on Monday mornings; merge it | that service; Firefly III and Postgres after a backup and restore test |
| The category suggester (`services/category-suggester`) | merge into `master`; *Suggester image* builds and tests the image, then "Pin fork image" opens its pin PR | `suggester-trigger`; the nightly run uses it the same night |
| Anything else in this repository: compose, Caddyfile, scripts, `crontab`, `config/importer-base.json` | merge into `master` | whatever compose sees changed |
| A setting (only on the server) | `scripts/firefly-pocket config set <KEY> <value>` there, then `scripts/deploy.sh --force` | the services whose environment changed |

Rules:

- **Never edit tracked files on the server.** The deploy refuses to run over them and alerts. Put the change into `master`.
- **A new secret or setting goes onto the server before the merge** (`./scripts/gen-secrets.sh`, or `config set`). Without it the deploy stops at `docker compose` with the `:?` message, and nothing restarts.
- **Features across repositories**: merge the side the others call first, usually this repository, then the importer, then Firefly Pocket. Each tolerates the others being older.
- **Roll back a fork or the suggester**: Actions → *Pin fork image* → *Run workflow* with the service and an earlier tag (the `Bump …` commits in `master` list them). It opens a pin PR that merges itself, like any other. Anything else: *Revert* on the merged PR in GitHub, which opens a PR that undoes it. Rolling back an image that has migrated a database also needs that database restored ([Restoring](#restoring)).
- **What runs now**: `cat /opt/fireflyx/.deployed-rev`; the log is `journalctl -u fireflyx-deploy`, and what shadow mode found is in `/opt/fireflyx/.shadow.log`.

With `DEPLOY_STATUS_TOKEN` set (`config set DEPLOY_STATUS_TOKEN -`; a fine-grained token for this repository only, *Commit statuses: Read and write*), every commit in GitHub shows a `deploy/server` status: pending, success or failure. A release needs it: that status is the canary gate's evidence ([Releasing](#releasing)). Without it, or with a token for another repository, the deploy only logs `WARN: could not set the GitHub commit status`.

**Shadow mode.** The server agent will deploy from the release bundle instead of the checkout. Its first step only watches: on a tick with nothing to deploy, `scripts/deploy.sh` runs `scripts/agent.sh shadow`, which, once for each revision the server deployed, fetches the bundle `latest` names and compares it with the checkout. It fetches anonymously from GHCR's registry API and checks each piece against its digest. The bundle must hold the same files as the checkout, with the same contents and executable bits; in compose only the image lines may differ, and each must pin the very image the server pulled for that tag. It deploys nothing, and it cannot fail a deploy: a problem is a `WARN` in the log, and the next tick tries again. While `latest` is another revision's bundle (the deploy or *Publish bundle* is still running), it waits. Each result is a line in `/opt/fireflyx/.shadow.log` and, with `DEPLOY_STATUS_TOKEN`, an `agent/shadow` status on the commit beside `deploy/server`. A difference also goes to ntfy. To look at a bundle yourself: `scripts/agent.sh fetch latest <empty-dir>`, then `scripts/agent.sh compare <dir>`.

Optional: `NEXT_WARMUP_FIREFLY_TOKEN` (a separate Firefly token of your user, set with `config set`) turns on Firefly Pocket's cache warm-up; then `scripts/deploy.sh --force`. Firefly III's webhooks stay off, so Firefly Pocket's cache learns about changes made outside it only from its own changes and its TTL.

#### Setting it up on an existing server (once)

The old laptop deploys (`deploy-pico.sh`, `deploy-firefly.sh`, `deploy-cron.sh`, which rsynced the repo to the server) are gone; the server's copy becomes a git checkout instead. In this order:

1. **Token for the forks.** Create a fine-grained personal access token: resource owner Majster01, *Only select repositories* → firefly-pocket-stack, repository permission *Actions: Read and write*, nothing else. It can start this repository's workflows and nothing more. Add it as the Actions secret `FIREFLY_POCKET_DISPATCH_TOKEN` in both `Majster01/firefly-pocket` and `Majster01/data-importer`. Note its expiry date: when it expires, the forks' deploy job fails, and GitHub emails you about it.
2. **Merge this repository's change.** The server does not pull yet, so nothing deploys.
3. **Merge both forks' changes.** Their first CI run builds and pushes the image, then starts *Pin fork image*, and that first pin fails: a new GHCR package is private, and the server pulls without a login. Make both public (your GitHub profile → *Packages* → `firefly-pocket` and `data-importer` → *Package settings* → *Change visibility* → *Public*), then re-run the two failed *Pin fork image* runs.
4. **Install the deploy agent**, from the laptop:
   ```bash
   ssh <server> 'bash -s' < scripts/install-deploy-agent.sh   # git checkout + timer
   ```
   It lists the files on the server that git does not track, which are mostly files deleted from the repository after they were synced; delete the stale ones. Within two minutes the first deploy runs: it pulls both GHCR images (the importer counts as a new image, so a backup and restore test come first) and installs the crontab with the shared lock.
5. **Renovate.** Install the [Renovate app](https://github.com/apps/renovate) on this repository only. `renovate.json` is already here, so there is no onboarding PR; the *Dependency Dashboard* issue lists what it tracks and what is waiting.

`scripts/logs.sh` (Dozzle over SSH) still runs from the laptop as before.

#### GitHub settings (once)

`master` takes no direct pushes: every change, a pin included, is a PR that passes CI. A pin's PR is opened by a GitHub App of your own, because a PR opened with a workflow's built-in token starts no workflows, so CI would never run on it. Set this up once, in this order:

1. **The pin app.** Your profile → *Settings* → *Developer settings* → *GitHub Apps* → *New GitHub App*. Any name GitHub accepts (it must be unique, e.g. `firefly-pocket-pin-<you>`), any homepage URL, *Webhook* → *Active* off. *Repository permissions*: *Contents* and *Pull requests*, both *Read and write*, nothing else. *Only on this account*. Create it and note its **App ID**; under *Private keys*, *Generate a private key* (a `.pem` file downloads). Then *Install App* → your account → *Only select repositories* → firefly-pocket-stack.
2. **Hand it to the workflow.** This repository → *Settings* → *Secrets and variables* → *Actions*: the **variable** `PIN_APP_ID` (the App ID) and the **secret** `PIN_APP_PRIVATE_KEY` (the whole `.pem` file). Delete the `.pem` afterwards; the app page makes a new key whenever you need one.
3. **Pull requests.** *Settings* → *General* → *Pull Requests*: *Allow squash merging* and *Allow auto-merge* on, and *Automatically delete head branches* on.
4. **Protect `master`.** *Settings* → *Rules* → *Rulesets* → *New branch ruleset*: name `master`, *Enforcement status* Active, *Target branches* → *Include default branch*, and nothing in *Bypass list*. Rules: *Restrict deletions*, *Block force pushes*, *Require a pull request before merging* (0 approvals), and *Require status checks to pass* with `shellcheck`, `compose`, `suggester`, `boot`, `bundle` and `upgrade (latest)`, and `upgrade (stable)` once `1.0.0` is out (before it, that check has nothing to upgrade from). Leave *Require branches to be up to date before merging* off, so two pins waiting at once both merge.
5. **Security.** *Settings* → *Advanced Security*: *Private vulnerability reporting*, *Secret scanning* and *Push protection* on. `SECURITY.md` points reporters at the first.

From then on a pin arrives as a PR from the app, *Bump Next to abc1234*, that merges itself when the checks pass, usually within a few minutes (`boot` takes the longest, about a minute and a half), and the merge deploys. A pin PR left open has a failed check; its CI run says which. Each service has one branch, `pin/<service>`: a newer pin replaces a waiting one, and a pin of the tag `master` already runs closes it.

### Releasing

A release names one bundle that has already run as `latest`, and promotes it without rebuilding: Actions → *Release* → *Run workflow*, with a bump and optionally the commit (`scripts/release.sh`). Tick *Dry run* first to see the version and the release notes. It points the release tags at that commit's bundle digest, `X.Y.Z`, `X.Y` and `stable`, then pushes the git tag `vX.Y.Z` and a GitHub release listing every component's image and tag and the changes since the last release.

| Tag | Moves when | For |
| --- | --- | --- |
| `latest` | every merge into `master` | your server, and anyone who wants each change |
| `stable` | every release | the default for new installs |
| `X.Y` | every release in that line | fixes only |
| `X.Y.Z`, `sha-<commit>` | never | pinning and rollback |

The bump says what a person running a server has to do: **major**, act (a value only they can give, a Postgres major, a hostname change); **minor**, nothing, migrations included; **patch**, fixes only. The first release is `1.0.0` whatever the bump. A release only moves forward: it refuses a commit older than the last release, one that is not on `master`, one without a published bundle, and one whose bundle *Publish bundle* did not sign on `master` ([Verifying a bundle](#deploying)). The release notes say how to check the signature.

**The canary gate.** Your server is the canary: a commit can be released only once its `deploy/server` status has been `success` for 24 hours, counted from its first successful deploy since the last failed one. So a `deploy.sh --force` does not restart the clock, and a failed deploy does. A commit the server never deployed has no status and cannot be released. A refusal says when the commit becomes eligible. *Skip the canary* is for an urgent fix only, and its release notes say it skipped. The bundle's `release.json` keeps the build number it was published with (`1.0.0-dev.<n>`); the release's version is its tag.

### Updating Firefly III

Never blind-pull. Firefly III migrates the database on boot, so a version bump is a reviewed PR: Renovate opens one for each new `fireflyiii/core` release. Read the [release notes](https://github.com/firefly-iii/firefly-iii/releases) of every version it crosses, then merge. The server backs up, proves the backup restores, and starts the new version; `docker compose logs -f app` shows the migrations. A new Postgres major version is never offered, since it needs a dump and restore by hand.

### Host updates

`unattended-upgrades` installs Ubuntu's security updates daily. Out of the box it leaves two gaps, which `terraform/cloud-init.yaml` closes on a new server: kernel and libc updates only take effect after a reboot, which nothing ever does; and Docker CE comes from Docker's own repository, which it does not include, so the engine, containerd and runc never update. The fix lets it update Docker and reboot at 05:30 when an update needs one, after the night's jobs. Containers come back by themselves (`restart: unless-stopped`).

A server created before this has neither. Add the same file once:

```bash
ssh <server> 'sudo tee /etc/apt/apt.conf.d/52fireflyx-unattended >/dev/null' <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        "origin=Docker";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "05:30";
EOF
```

Check it took effect: `ssh <server> 'sudo unattended-upgrade --dry-run --debug 2>&1 | grep -i "allowed origins"'` lists `origin=Docker`. Whether a reboot is pending right now: `ssh <server> 'cat /var/run/reboot-required 2>/dev/null || echo none'`.

### Restoring

```bash
docker compose stop app next
docker compose exec -T db psql -U postgres -c 'DROP DATABASE firefly;'
docker compose exec -T db psql -U postgres -c 'CREATE DATABASE firefly OWNER firefly;'
docker compose exec -T db pg_restore -U postgres -d firefly --no-owner < /var/backups/fireflyx/firefly-<stamp>.dump
docker compose start app next
```

Attachments restore from the matching `uploads-<stamp>.tar.gz` into the `fireflyx_firefly_upload` volume.

Firefly Pocket's database restores the same way with only `next` stopped: `firefly_next`, owned by `next`, from `firefly_next-<stamp>.dump`.

### Settings

Every setting `compose/.env.example` lists lives in a small store on the server: the plain ones in `compose/config.json`, each secret in its own file under `compose/secrets/env/` (mode 600). `scripts/settings.json` says how each is checked and what its default is. `compose/.env` is written from the store and from nothing else:

```bash
scripts/firefly-pocket config list                  # every setting; a secret shows only its last 4 characters
scripts/firefly-pocket config set <KEY> <value>     # checked, kept, and .env written again
scripts/firefly-pocket config set <KEY> -           # the value read without being shown
scripts/firefly-pocket config unset <KEY>           # back to its default
scripts/deploy.sh --force                           # apply it now; otherwise at the next deploy
```

Every deploy writes `.env` again, for the `settings.json` of the revision it deploys. **Do not edit `.env` by hand**: the deploy notices, stops before restarting anything and alerts, naming the settings that differ (never their values). Put the edit in with `config set --force <KEY> <value>`, or drop it with `config render --force`. The nightly backup keeps the store beside its copy of `.env`.

#### Moving an existing server to the store (once)

A server set up before the store has a hand-edited `.env` and no `compose/config.json`. Until it moves, nothing changes for it: the deploy writes no `.env`, and `config set` refuses. To move it:

```bash
ssh fireflyx@<ip>
cd /opt/fireflyx
scripts/firefly-pocket config import
scripts/firefly-pocket config list
```

`import` checks every value first and, if one fails its check, changes nothing and says which. Otherwise every line of `.env` goes into the store, lines no setting reads anymore included, and `.env` is written again with each value exactly as it was. It adds only settings the old `.env` never had, each with the value compose already used for it, and lists them. The old file stays as `compose/.env.before-import`. Nothing restarts, and the next deploy finds nothing to change. To go back: `rm compose/config.json compose/.env.rendered; rm -r compose/secrets/env`, and `.env` is a hand-edited one again, with every value.

### Rotating a secret

`scripts/firefly-pocket config unset <KEY>`, re-run `./scripts/gen-secrets.sh`, then `docker compose up -d`. Note that **database passwords are not rotated this way** — the `initdb` script only runs on a first-ever start, so changing `FIREFLY_DB_PASSWORD` also requires `ALTER ROLE firefly WITH PASSWORD '...'` by hand.

Rotating `NEXT_NOTIFY_TOKEN` also needs `docker compose up -d next`; the host scripts re-read `.env` on each run.

**The apps' Firefly III tokens** (`IMPORTER_FIREFLY_TOKEN`, `SUGGESTER_FIREFLY_TOKEN`, `NEXT_WARMUP_FIREFLY_TOKEN`) rotate themselves: Firefly III gives each a year, and the nightly run's first step (`scripts/firefly-pocket tokens rotate`) makes a new one, under the same name in Firefly III, for any that has 30 days or less left or that Firefly III no longer takes. Minting the name again revokes the old token. The new one goes into the settings store, `.env` is written again, and the services that changed start again (`docker compose up -d`, as a deploy does: the importer and Firefly Pocket; the suggester reads its token each time it runs), before the night's import. A failed rotation alerts and the rest of the night runs on, the old tokens working until they expire. `scripts/firefly-pocket tokens` shows the days each has left; `tokens rotate --days 400` makes all three again now. The days come from each token's own `exp` claim, as Firefly III checks it.

### Troubleshooting

| Symptom | Cause |
|---|---|
| Caddy will not start / no certificate | DNS not resolving yet, or ports 80/443 blocked |
| Firefly III 500s on first boot | Migrations still running — watch `docker compose logs app` |
| Logged out after a deploy | Expected: file-based sessions, see design notes |
| Import returns nothing | Consent expired. (Before the importer fork's `[eb003]` change, a window in which the bank returned no transactions at all also failed the night; it is a warning now and a quiet night shows as "Nothing new") |
| Import runs but finds only old transactions | The "render import configs" step failed, so `/import` still holds an old window. Its alert says why; see [Bank connections](#bank-connections-importer-fork) |
| `Not allowed to import from this path` (HTTP 500) | The `/autoimport` call is missing `&directory=/import`; without it the importer resolves `./` and fails `IMPORT_DIR_ALLOWLIST` |
| Bank import fails with HTTP 405 | `/autoimport` is `Route::post`. Use `internal_http_post`, not `internal_http` — a GET is rejected by the router, so nothing reaches the log either |
| A cron job never runs, and leaves no log | Its log path is not writable: `/var/log` is root-owned, so `>> /var/log/x.log` fails before the script starts. Logs go to `/var/log/fireflyx/` (owned by the admin user; `sudo install -d -o fireflyx -g fireflyx -m 755 /var/log/fireflyx` on an older host) |
| Nightly reports success but nothing imported | Should no longer happen — the "bank import error check" step scans the importer log precisely for this. If it does, the failure was logged below `ERROR` level |
| One bank imports, another does not | Expected isolation, not a bug — each config runs in its own try/catch. The import report names the connection; its consent has likely expired, so re-link it ([Re-authorising](#re-authorising-the-bank-every-90180-days)) |
| Importer will not start after an update | `docker compose logs importer`: the fork's migrations run at start and need the database (`setup-importer-db.sh`) and `IMPORTER_APP_KEY` |
| No push in the Firefly Pocket app, ntfy works | `WARN: Firefly Pocket push notification failed (HTTP …)` in the job log: 503 = no VAPID keys or the Firefly Pocket build predates the receiver, 401 = `NEXT_NOTIFY_TOKEN` differs between `.env` and the running `next` container (recreate it), `none` = Firefly Pocket or Docker unreachable. If the call succeeds but nothing shows, the phone has not subscribed: see the iOS caveats under [Push alerts](#push-alerts-in-firefly-pocket) |
| No category suggestions appear | It only looks at **uncategorized withdrawals** from the last 30 days; check `/var/log/fireflyx-nightly.log`, that `SUGGESTER_FIREFLY_TOKEN` and `ANTHROPIC_API_KEY` are set, and that the Anthropic account has credit |
| `initdb` changes have no effect | It runs only against an empty `db_data` volume — apply by hand with psql |
| Deploy alert "Tracked files were edited on the server" | Someone changed a file git tracks in `/opt/fireflyx`. Put the change into `master`, or `git checkout -- <file>` on the server, then `scripts/deploy.sh --force` |
| A merge in a fork never shows up on the server | Find where it stopped: the fork's *Deploy* run (build, or an expired `FIREFLY_POCKET_DISPATCH_TOKEN`), then this repository's *Pin fork image* run ("cannot be pulled without a login": the GHCR package is private; a failure at the app token: `PIN_APP_ID` or `PIN_APP_PRIVATE_KEY`), then the pin PR's checks (a red one stops the merge), then `journalctl -u fireflyx-deploy` on the server |

---

## Cost

Live figures from the Hetzner API for `nbg1`, September 2026.

| Item | Net | Note |
|---|---|---|
| Hetzner **cx23** (2 vCPU / 4 GB / 40 GB) | €5.49 | cx22 is retired and can no longer be ordered |
| Primary IPv4 address | €0.50 | Hetzner bills IPv4 separately |
| Automatic backups | €1.10 | 20% of server price |
| **Subtotal (net)** | **€7.09** | |
| Slovenian VAT @ 22% | €1.56 | |
| **Hetzner total (gross)** | **€8.65** | |
| Anthropic API (category suggestions, a few dozen a month) | <€1 | usage-based |
| Offsite backups (Backblaze B2 at this volume) | ~€0.10 | |
| **All-in** | **~€9.25/mo** | |

> An earlier draft of this README said ~€4.60/mo. That was wrong on three counts: it priced the retired cx22 at €3.49, omitted the IPv4 charge, and quoted net prices without VAT. The figures above are what you will actually be billed.

The one real lever is `enable_hetzner_backups = false`, saving €1.34 gross. That drops whole-machine recovery but keeps the restic offsite backups, which hold the actual data. Keeping it is the safer default.

For comparison, the same stack on Cloud Run + Cloud SQL prices at roughly **$21–26/mo** — and needs a two-stage Terraform bootstrap, a gcsfuse volume mount, a forced single-instance pin to keep sessions coherent, and the AI categorizer (since replaced by the category suggester) demoted to batch because exposing it was unsafe. A single VM removes all four.

What you take on instead: OS patching (mostly handled by `unattended-upgrades`), backups (scripted here, but **you must verify them**), and no HA. For a single-user finance app, that is a sound trade.
