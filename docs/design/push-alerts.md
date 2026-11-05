# Push alerts to the Firefly Pocket app

This was first built for Pico. Pico is no longer used, so this stack's senders now call Firefly Pocket's receiver, which takes the same requests; `NEXT_NOTIFY_TOKEN` replaced `PICO_NOTIFY_TOKEN` and the suggestions link is `/suggestions`.

Alerts used to reach one place, an ntfy topic (`NTFY_URL`). They now also arrive as native notifications in the installed Firefly Pocket PWA, with the app badge showing how many category suggestions are waiting. Firefly Pocket implements the receiving side (service worker, subscriptions, sending); this repo only calls it.

## Contract with Firefly Pocket

`POST http://next:80/api/internal/notify`, on the compose network, never through the public hostname.

- Header `Authorization: Bearer <NEXT_NOTIFY_TOKEN>` (Firefly Pocket's `NOTIFY_API_TOKEN`, at least 32 characters).
- JSON body: `title` (required, at most 100 characters), `body` (required, at most 300), `path` (optional, the page a tap opens, default `/`), `badge` (optional integer, 0 clears), `tag` (optional, at most 64; a new notification with the same tag replaces the previous one).
- Answers: `200 {"sent":n,"failed":n,"removed":n}` (all zero when nobody subscribed), `401` bad token, `422` invalid body, `503` push not configured (no VAPID keys).

Firefly Pocket's other settings are `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT`. All four come from `compose/.env` (see [`.env.example`](../../compose/.env.example)); `scripts/gen-secrets.sh` generates the token and the keypair.

## Alerts and notifications

Two kinds of message, told apart by the optional `event` field of the body (`event` and `count` are used to pick the devices and are not delivered to them):

- **Alert**, no `event`: something failed or needs attention (backup, restore test, consent, deploy, a failing nightly step). Every device gets it, and ntfy too.
- **Notification**, with an `event`: something the user chose to hear about. Pocket sends it only to the devices whose settings (Settings → Notifications, stored per device) want it.

| `event` | Meaning | Setting |
|---|---|---|
| `import.success` | One connection imported cleanly; `count` is the number of new transactions | on/off, and "only when something new came in" (`count` 0 is skipped) |
| `import.failure` | One connection did not import, or the import could not be checked | on/off |
| `suggestions.digest` | Suggestions waiting; `badge` is the number | off, daily, or weekly on a weekday (read in Pocket's `NOTIFY_TIMEZONE`/`TZ`) |
| `upgrade.success` | A deploy changed a package | on/off |

Answers add `skipped`: `{"sent":n,"failed":n,"removed":n,"skipped":n}`, the devices that turned the event off. The contract and the settings are documented in firefly-pocket, `docs/web-push.md`.

## Senders

| Sender | Where | Sends |
|---|---|---|
| `notify()` in `scripts/lib.sh` | every alert of the backup, restore test, deploy and nightly scripts | an alert: `title`, `body` (cut to the limits), `path: "/"`; no badge. To ntfy and Pocket |
| `notify_event()` in `scripts/lib.sh` | the nightly import report, the deploy | a notification with its `event`, `path` and `count`. To Pocket; `import.failure` also to ntfy |
| `nightly.sh` | after the import | one message per bank connection, from `fireflyx:connections:report --json` (the importer's `ImportNotice`): `import.success` ("NLB Current import succeeded", "3 new transactions imported.") or `import.failure` (what happened, what to do, "Exact error: importer logs."). The steps that used to alert with raw output (`bank import`, `bank import error check`, `bank import report`) now only log; if the report cannot be had, one `import.failure` says the import could not be checked |
| `deploy.sh` | after a successful deploy | `upgrade.success`, "Upgrade successful" with the packages whose image changed (`upgraded_packages` compares the compose files of the two revisions). Nothing when no package changed |
| `suggester notify` | daily 19:00 | `suggestions.digest`; `path` is the suggestion list, `badge` the number pending, `tag: "suggestions"`. Pocket only |

Choices that are easy to get wrong:

- **Independent channels.** ntfy is called first and exactly as before. A Firefly Pocket failure (401, 422, 503, a timeout, Docker unavailable) only prints a `WARN` to stderr; it never fails the calling step and never skips ntfy. Until Firefly Pocket has the receiver and keys the endpoint answers 503, so a half-finished rollout is harmless.
- **Internal only.** Host scripts reach Firefly Pocket the way they reach the importer, with a throwaway `curl` container on the `fireflyx` network (the token goes in on stdin, not on the command line). The suggester is already on that network. Caddy answers 404 for `/api/internal/*` on the public Firefly Pocket hostname.
- **No push to clear the badge.** iOS requires every Web Push to show a notification, so the suggester sends nothing when no suggestion is pending. Firefly Pocket clears the badge itself when it is opened.
- **Pocket decides, the senders do not.** The digest runs every day and `import.success` is sent every night even with nothing new; whether that reaches a device is its setting. A Pocket that predates the settings (firefly-pocket's `pico`) ignores `event` and delivers everything, so it would show the digest daily and "Nothing new" nightly: deploy this change after the Pocket that has the settings is the live receiver.
- **The exact error is in the log.** A failure message never carries the raw error; `nightly.log` has the importer's text for each connection, and `scripts/logs.sh fireflyx-importer` the importer's own log.
- **`--dry-run`** logs what the suggester would send to ntfy and to Firefly Pocket and sends nothing.

## iOS

Web Push on iPhone and iPad needs iOS/iPadOS 16.4 or later, Firefly Pocket added to the Home Screen and opened from there, and the permission granted from a tap inside the app. See the README ("Push alerts in Firefly Pocket") for the rollout order.
