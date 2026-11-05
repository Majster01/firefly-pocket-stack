"""The `pico-suggestion:v1` contract shared with Firefly Pocket.

Source of truth: docs/rule-suggestions.md in this repository. Everything that
touches the wire format of a suggestion rule lives here, so the two sides can be
checked against each other in one place.
"""

from __future__ import annotations

import html
import json
from dataclasses import dataclass, field

from .firefly import Txn

MARKER = "pico-suggestion:v1"
CONTRACT_MAJOR = 1

GROUP_CATEGORIZATION = "Categorization"
GROUP_SUGGESTIONS = "Suggestions"
CATEGORY_RULE_PREFIX = "Category: "

TRIGGER_TYPES = (
    "description_contains",
    "destination_account_contains",
    "destination_account_is",
    "destination_account_id",
)

# Firefly caps rule titles at 255; keep well clear so the category always fits.
MAX_LABEL = 80


def encode_description(meta: dict) -> str:
    """Writers send plain JSON on the same line as the marker."""
    return f"{MARKER} {json.dumps(meta, ensure_ascii=False)}"


def decode_description(description: str | None) -> dict | None:
    """Metadata of a suggestion rule, or None when it is not one we understand.

    Firefly 6.6.6 returns rule descriptions HTML-escaped (&quot; &amp; &#039;), so
    unescape before stripping the marker. Unescaping plain JSON is a no-op unless the
    JSON itself contains an entity, which ours never does on purpose.
    """
    if not description:
        return None
    text = html.unescape(description).strip()
    if not text.startswith(MARKER + " "):
        return None
    try:
        meta = json.loads(text[len(MARKER) + 1 :])
    except ValueError:
        return None
    if not isinstance(meta, dict):
        return None
    try:
        major = int(str(meta.get("v", "")).split(".")[0])
    except ValueError:
        return None
    return meta if major == CONTRACT_MAJOR else None


def journal_ids(meta: dict) -> set[int]:
    ids = set()
    for entry in meta.get("transactions") or []:
        try:
            ids.add(int(entry["journal_id"]))
        except (KeyError, TypeError, ValueError):
            continue
    return ids


@dataclass
class Suggestion:
    category: str
    confidence: float
    low_confidence: bool
    company: str | None
    reason: str
    transactions: list[Txn]
    # (type, value) pairs, already validated.
    triggers: list[tuple[str, str]]
    model: str
    # (type, value, why) — for dry-run output only, never written.
    rejected: list[tuple[str, str, str]] = field(default_factory=list)
    # Free-text notes for dry-run output (fallbacks taken, demotions, ...).
    notes: list[str] = field(default_factory=list)

    @property
    def basis(self) -> str:
        kinds = {"description" if t == "description_contains" else "destination" for t, _ in self.triggers}
        return "both" if len(kinds) == 2 else (kinds.pop() if kinds else "description")

    @property
    def label(self) -> str:
        if self.company:
            # "Burgerlab — burger restaurant, Ljubljana" -> "Burgerlab"
            label = self.company.split(" — ")[0].split(" - ")[0].strip()
        else:
            label = next((v for t, v in self.triggers if t == "description_contains"), "")
            label = label or self.transactions[0].description
        return label[:MAX_LABEL].strip()

    @property
    def title(self) -> str:
        return f"Suggest: {self.category} · {self.label}"

    def metadata(self, created: str) -> dict:
        return {
            "v": 1,
            "transactions": [
                {"transaction_id": t.transaction_id, "journal_id": t.journal_id} for t in self.transactions
            ],
            "category": self.category,
            "confidence": round(self.confidence, 2),
            "low_confidence": self.low_confidence,
            "basis": self.basis,
            "company": self.company,
            "reason": self.reason,
            "model": self.model,
            "created": created,
        }

    def rule_payload(self, group_id: str, created: str) -> dict:
        return {
            "title": self.title,
            "description": encode_description(self.metadata(created)),
            "rule_group_id": group_id,
            "active": False,  # a suggestion never fires
            "trigger": "store-journal",
            # Same settings as the Category: rules, so Pico can copy triggers across.
            "strict": False,
            "stop_processing": True,
            "triggers": [
                {"type": t, "value": v, "active": True, "stop_processing": True} for t, v in self.triggers
            ],
            "actions": [
                {"type": "set_category", "value": self.category, "active": True, "stop_processing": False}
            ],
        }
