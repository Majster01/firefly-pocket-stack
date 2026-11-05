"""Turn a model classification into contract-valid suggestions.

Everything the contract promises Firefly Pocket about triggers is enforced
here, after the model, so a bad answer can only lose a trigger — never write
one that breaks a rule:

- the category exists;
- `(unknown destination)` and private people never become destination triggers;
- description keywords are >= 4 characters and a substring of every covered description;
- nothing already in `Categorization` is suggested again;
- a keyword that a Firefly search shows would also catch other merchants is dropped.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable

from .contract import Suggestion
from .firefly import Firefly, Txn
from .llm import Classification
from .normalize import COMPANY, PERSON, TxnGroup, normalize_description
from .store import trigger_key

MIN_KEYWORD = 4
# A keyword hitting this many transactions is generic whatever else is true.
PREVIEW_MAX_PAGES = 3
PREVIEW_CEILING = 100 * PREVIEW_MAX_PAGES

# Words that appear across unrelated merchants. A keyword made only of these is
# rejected before it costs a preview search.
GENERIC_WORDS = {
    "NAKUP", "PLAČILO", "PLACILO", "PLAČILA", "PLACILA", "STORITVE", "SPLETNI", "RAČUN",
    "RACUN", "RAČUNA", "RACUNA", "DAVKA", "DAVEK", "NALOGA", "NRC00", "SUMUP", "BLAGAJNA",
    "POSL", "TRGOVINA", "D.O.O", "DOO", "D.D", "S.P", "GMBH", "EUR", "WWW", "COM", "SI",
    "LJUBLJANA", "LJ", "RUDNIK", "MARIBOR", "KOPER", "KRANJ", "CELJE", "CENTER", "SHOP",
}


def is_generic_word(keyword: str) -> bool:
    tokens = [t for t in re.split(r"[\s.,*/\-]+", keyword.upper()) if t]
    return not tokens or all(t in GENERIC_WORDS or t.isdigit() for t in tokens)


@dataclass
class ExistingRules:
    """Triggers already live in `Categorization`, lower-cased for comparison."""

    description: set[str] = field(default_factory=set)
    destination_ids: set[str] = field(default_factory=set)
    destination_names: set[str] = field(default_factory=set)

    @classmethod
    def from_rules(cls, rules: list[dict]) -> "ExistingRules":
        existing = cls()
        for rule in rules:
            for trig in rule["attributes"]["triggers"]:
                value = (trig.get("value") or "").strip().lower()
                if trig["type"] == "description_contains":
                    existing.description.add(value)
                elif trig["type"] == "destination_account_id":
                    existing.destination_ids.add(value)
                elif trig["type"] in ("destination_account_contains", "destination_account_is"):
                    existing.destination_names.add(value)
        return existing

    def covers_destination(self, txn: Txn) -> bool:
        name = txn.destination_name.lower()
        return str(txn.destination_id) in self.destination_ids or any(v and v in name for v in self.destination_names)


# (query) -> transactions matching it in Firefly. Injected so tests need no server.
SearchFn = Callable[[str], list[Txn]]


def firefly_search(ff: Firefly) -> SearchFn:
    return lambda query: ff.search(query, max_pages=PREVIEW_MAX_PAGES)


def preview_problem(search: SearchFn, query: str, group: TxnGroup, category: str, same_counterparty: bool) -> str | None:
    """Why a trigger is too generic, judged by what it would match today, or None.

    Firefly Pocket backfills over all time on approval, so every
    transaction the trigger matches — any type, any date — gets this category
    unless it already has one. A trigger is generic when it also matches:
      - transactions already in a different category (it would fight that rule), or
      - uncategorized transactions of a different merchant (it would mislabel them).
    `same_counterparty` (destination triggers) skips the second test: everything
    paid to one account is the same counterparty by definition.
    """
    matches = search(query)
    if len(matches) >= PREVIEW_CEILING:
        return f"too generic: matches {PREVIEW_CEILING}+ transactions"
    own = {t.journal_id for t in group.txns}
    found = {t.journal_id for t in matches}
    if not own <= found:
        return "Firefly search does not match every covered transaction"
    own_keys = {normalize_description(t.description) for t in group.txns}
    others = [t for t in matches if t.journal_id not in own]
    conflicts = [t for t in others if t.category and t.category != category]
    foreign = [] if same_counterparty else [
        t for t in others if not t.category and normalize_description(t.description) not in own_keys
    ]
    bad = conflicts + foreign
    if not bad:
        return None
    sample = bad[0]
    where = f"categorized {sample.category}" if sample.category else "uncategorized"
    return f"too generic: also matches {len(bad)} other transaction(s), e.g. {sample.description!r} ({where})"


def _quote(value: str) -> str | None:
    """Firefly search value in quotes, or None when it cannot be quoted safely."""
    return None if '"' in value else f'"{value}"'


def build_suggestions(
    group: TxnGroup,
    result: Classification,
    *,
    categories: set[str],
    existing: ExistingRules,
    search: SearchFn,
    min_confidence: float,
    model: str,
    rejected: set[tuple[str, str, str]] = frozenset(),
) -> list[Suggestion]:
    """`rejected`: trigger_key()s the user said no to before — never suggested again."""
    if result.category not in categories:
        raise ValueError(f"model returned unknown category {result.category!r}")

    counterparty = group.counterparty
    notes: list[str] = []
    if counterparty == COMPANY and result.counterparty_is_person:
        # Demote only, never promote: a person must not get a destination trigger.
        counterparty = PERSON
        notes.append("model says the destination is a private person — no destination trigger")

    def suggestion(txns: list[Txn], triggers: list[tuple[str, str]], low: bool, drops) -> Suggestion:
        return Suggestion(
            category=result.category,
            confidence=result.confidence,
            low_confidence=low,
            company=result.company,
            reason=result.reason,
            transactions=txns,
            triggers=triggers,
            model=model,
            rejected=list(drops),
            notes=list(notes),
        )

    dropped: list[tuple[str, str, str]] = []
    low_confidence = result.confidence < min_confidence

    if not low_confidence:
        triggers: list[tuple[str, str]] = []
        for raw in result.description_keywords:
            keyword = raw.strip()
            reason = _keyword_problem(keyword, group, existing)
            if reason is None and trigger_key("description_contains", keyword, result.category) in rejected:
                reason = "rejected before with this category"
            if reason is None:
                quoted = _quote(keyword)
                reason = "contains a double quote" if quoted is None else preview_problem(
                    search, f"description_contains:{quoted}", group, result.category, same_counterparty=False
                )
            if reason:
                dropped.append(("description_contains", keyword, reason))
            elif keyword.lower() not in {v.lower() for _, v in triggers}:
                triggers.append(("description_contains", keyword))

        if result.use_destination:
            reason = _destination_problem(group, counterparty, existing)
            if reason is None:
                reason = preview_problem(
                    search, f"destination_account_id:{group.destination_id}", group, result.category, same_counterparty=True
                )
            value = str(group.destination_id) if not group.txns[0].destination_unknown else group.destination_name
            if reason is None and trigger_key("destination_account_id", value, result.category) in rejected:
                reason = "rejected before with this category"
            if reason:
                dropped.append(("destination_account_id", value, reason))
            else:
                triggers.append(("destination_account_id", value))

        if triggers:
            return [suggestion(group.txns, triggers, low=False, drops=dropped)]
        notes.append("no proposed trigger survived validation — falling back to the full description")

    # Low confidence (or nothing survived): the only trigger is the full
    # description, which by construction matches only that exact text. Groups
    # whose descriptions differ become one suggestion per description.
    out = []
    for description in group.descriptions:
        txns = [t for t in group.txns if t.description == description]
        value = description.strip()
        if len(value) < MIN_KEYWORD or value.lower() in existing.description:
            dropped.append(("description_contains", value, "full description unusable (too short or already a rule)"))
            continue
        if trigger_key("description_contains", value, result.category) in rejected:
            dropped.append(("description_contains", value, "rejected before with this category"))
            continue
        out.append(suggestion(txns, [("description_contains", value)], low=low_confidence, drops=dropped))
    return out


def _keyword_problem(keyword: str, group: TxnGroup, existing: ExistingRules) -> str | None:
    if len(keyword) < MIN_KEYWORD:
        return f"shorter than {MIN_KEYWORD} characters"
    # Firefly's description_contains is case-insensitive.
    missing = [d for d in group.descriptions if keyword.lower() not in d.lower()]
    if missing:
        return f"not a substring of {missing[0]!r}"
    if keyword.lower() in existing.description:
        return "already a trigger in Categorization"
    if is_generic_word(keyword):
        return "generic word"
    return None


def _destination_problem(group: TxnGroup, counterparty: str, existing: ExistingRules) -> str | None:
    if group.txns[0].destination_unknown:
        return "destination is (unknown destination)"
    if counterparty == PERSON:
        return "destination is a private person"
    if counterparty != COMPANY or group.destination_id is None:
        return "destination is not a company account"
    if existing.covers_destination(group.txns[0]):
        return "destination already has a trigger in Categorization"
    return None
