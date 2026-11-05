# Rule suggestions contract (`pico-suggestion:v1`)

The shared contract between the **category-suggester** (`services/category-suggester` in this repository, writes suggestions) and **Firefly Pocket** (reads, edits, approves, rejects them). Neither side depends on the other's code — only on this file and on Firefly III's rules API.

Firefly III is the source of truth. Both components are API clients with their own Personal Access Token.

This file used to live in Pico's repository, now archived as `Majster01/firefly-pocket-archive`. The marker keeps Pico's name until Retire Pico step 4 renames it.

## Rule groups

Groups are looked up **by title**, never by id.

| Group | Firefly Pocket setting | Holds | Active |
| --- | --- | --- | --- |
| `Categorization` | `RULE_GROUP_CATEGORIZATION` | Live rules: the guard `Stop: already categorized` at order 1, then one `Category: {category}` rule per category | yes |
| `Suggestions` | `RULE_GROUP_SUGGESTIONS` | Pending suggestions only, written by the suggester | no (backstop) |

Only the suggester writes to `Suggestions`. Rules there without the `pico-suggestion:v1` marker are not supported and Firefly Pocket hides them.

## Suggestion rule

| Field | Value |
| --- | --- |
| `title` | `Suggest: {category} · {company or keyword}` |
| `rule_group_id` | id of the `Suggestions` group |
| `active` | `false` — a suggestion never fires |
| `trigger` | `store-journal` |
| `strict` | `false` (triggers OR together) |
| `stop_processing` | `true` |
| `triggers[]` | one or more of `description_contains`, `destination_account_contains`, `destination_account_is`, `destination_account_id`; each `active: true`, `stop_processing: true` |
| `actions[]` | exactly one: `set_category={category}`, `active: true`. Firefly requires a value, so a low-confidence suggestion carries the model's best guess |
| `description` | `pico-suggestion:v1 ` followed by the metadata JSON on the same line |

The trigger/strict/stop_processing settings match the `Category:` rules, so triggers can be copied across unchanged.

**Reading `description`:** Firefly 6.6.6 returns rule descriptions HTML-escaped (`&quot;`, `&amp;`, `&#039;`), while titles, triggers and actions come back as written. Readers must HTML-unescape the description (PHP `html_entity_decode($d, ENT_QUOTES)`, Python `html.unescape`) before stripping the `pico-suggestion:v1 ` prefix and parsing the JSON. Writers send plain JSON.

### Metadata JSON

```json
{
  "v": 1,
  "transactions": [{ "transaction_id": 285, "journal_id": 285 }],
  "category": "Food & Drink",
  "confidence": 0.86,
  "low_confidence": false,
  "basis": "description",
  "company": "Burgerlab — burger restaurant, Ljubljana Center",
  "reason": "Card purchase at a burger chain",
  "model": "claude-haiku-5-5",
  "created": "2026-10-29"
}
```

| Key | Meaning |
| --- | --- |
| `v` | Contract version. Readers ignore rules with an unknown major version. |
| `transactions[]` | Every uncategorized transaction this suggestion covers. `transaction_id` = Firefly transaction group id; `journal_id` = the split that gets the category. |
| `category` | Category name the suggester proposes (same as the `set_category` value). |
| `confidence` | 0–1, from the model. |
| `low_confidence` | `true` when `confidence` < `SUGGESTER_MIN_CONFIDENCE` (default 0.6). Then the only trigger is `description_contains` = the full transaction description. |
| `basis` | `description`, `destination` or `both` — what the triggers match on. |
| `company` | Who the model thinks the counterparty is (from web lookup), or `null`. |
| `reason` | One short sentence for the reviewer. |
| `model`, `created` | Provenance. |

### Trigger rules the suggester follows

- `(unknown destination)` is never used as a trigger value.
- Destination is a private person (e.g. `NRC00` instant payments): description triggers only, never a destination trigger.
- Destination is a company or organisation: `destination_account_id` is preferred.
- `description_contains` values are ≥ 4 characters and are substrings of every covered description.

## Lifecycle

| Action (Firefly Pocket) | Effect in Firefly |
| --- | --- |
| **Approve** `{category, triggers[]}` | Append triggers (deduplicated) to `Category: {category}` in `Categorization`, creating that rule if missing. Backfill by search: over all time, find `has_no_category:true` transactions matching each approved trigger (the same search as the editor's preview) and set the category on exactly those, plus the suggestion's own `transactions`. Delete the suggestion. Never call a rule or rule-group trigger endpoint (see below). |
| **Set category only** `{category}` | Set the category on its `transactions`. Delete the suggestion. No rule is written. |
| **Reject** | Delete the suggestion. Transactions stay uncategorized. |

No tags or other actions are added in v1.

**Why no rule trigger:** in Firefly 6.6.6, `POST /rule-groups/{id}/trigger` and `POST /rules/{id}/trigger` fire rules outside the group context, so the `Stop: already categorized` guard does not stop them and they would overwrite existing categories. The guard only holds for `store-journal` on new transactions. The search-based backfill never touches a categorized transaction.

## Reconcile (suggester, start of every run)

For each suggestion it created earlier that is no longer in `Suggestions`:

- any of its transactions now has a category → **resolved** (approved or set manually);
- otherwise → **rejected**: the suggester stores the normalised keyword, category and journal ids and never suggests them again.
