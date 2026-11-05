"""Turn raw bank descriptions into merchant keys, and group transactions by them.

Slovenian bank descriptions wrap the merchant in noise that changes every time:
"NAKUP HETZNER ONLINE GMBH 8,65 EUR", "SI121234567890123 STORITVE 28.8. DO 27.9.2026".
Grouping on the noisy text would give one group (one Claude call, one suggestion)
per transaction; grouping on the normalised text gives one per merchant.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

from .firefly import Txn

_NOISE = [
    # Card-purchase prefix.
    re.compile(r"^NAKUP\s+"),
    # Amounts: "8,65 EUR", "1.234,50 EUR".
    re.compile(r"\b\d{1,3}(?:\.\d{3})*,\d{2}\s*(?:EUR|USD|GBP|CHF|HRK)\b"),
    # IBANs and Slovenian payment references (SI00 / SI12 / SI19 models...):
    # country code, two check digits, then digits and dashes.
    re.compile(r"\b[A-Z]{2}\d{2}[0-9][0-9-]{3,}\b"),
    # Dates: "28.8.", "27.9.2026".
    re.compile(r"\b\d{1,2}\.\d{1,2}\.(?:\d{2,4})?"),
    # Long digit runs: phone numbers, order and statement numbers.
    re.compile(r"\b\d{5,}\b"),
    # Mixed letter/digit order codes like "AB3C4D" (at least two digits, so names
    # with one digit — "A1", "PROJEKT5" — survive).
    re.compile(r"\b(?=(?:[A-Z]*\d){2})(?=[A-Z0-9]*[A-Z])[A-Z0-9]{5,}\b"),
    # Trailing till / terminal numbers: "BLAGAJNA CENTER - 73".
    re.compile(r"[\s-]+\d{1,4}$"),
]


def normalize_description(description: str) -> str:
    text = unicodedata.normalize("NFC", description).upper().strip()
    for pattern in _NOISE:
        text = pattern.sub(" ", text).strip()
    text = re.sub(r"\s+", " ", text)
    return text.strip(" -,.*/")


# --- counterparty ----------------------------------------------------------

UNKNOWN, PERSON, COMPANY = "unknown", "person", "company"

# Legal-form suffixes and public bodies: a destination carrying one is never a
# private person, whatever the payment type.
_COMPANY_MARKERS = re.compile(
    r"(?:\bD\.\s?O\.\s?O\b|\bD\.\s?D\b|\bS\.\s?P\b|\bD\.O\.O|\bDOO\b|\bGMBH\b|\bAG\b|\bLTD\b|\bINC\b|\bLLC\b"
    r"|\bS\.?R\.?L\b|\bZAVOD\b|\bOBČINA\b|\bOBCINA\b|\bDRUŠTVO\b|\bDRUSTVO\b|\bBANKA\b|\bZADRUGA\b"
    r"|\bPDP\b|\bZZZS\b|\bZPIZ\b|\bPOLICIJA\b|\bUPRAVA\b|\bPRORAČUN|\bPRORACUN|\bFURS\b|\bUNIVERZA\b)"
)
# "ŽAN K." — given name and an initial, how instant payments name a person.
_PERSON_NAME = re.compile(r"^[^\W\d_]+(?:\s[^\W\d_]+)?\s[^\W\d_]\.?$")


def classify_counterparty(txn: Txn) -> str:
    """unknown / person / company, decided by rules rather than by the model.

    The model may later demote a company to a person (never the other way), so a
    mistake here can only ever cost a destination trigger, not add a wrong one.
    """
    if txn.destination_unknown:
        return UNKNOWN
    name = unicodedata.normalize("NFC", txn.destination_name).upper().strip()
    if _COMPANY_MARKERS.search(name):
        return COMPANY
    # NRC00: SEPA instant credit transfer, which is how person-to-person payments
    # (Flik and friends) show up.
    if txn.description.upper().startswith("NRC00") or _PERSON_NAME.match(name):
        return PERSON
    return COMPANY


# --- grouping --------------------------------------------------------------


@dataclass
class TxnGroup:
    key: str
    counterparty: str  # unknown / person / company
    normalized: str
    txns: list[Txn]

    @property
    def descriptions(self) -> list[str]:
        return sorted({t.description for t in self.txns})

    @property
    def destination_id(self) -> int | None:
        return self.txns[0].destination_id

    @property
    def destination_name(self) -> str:
        return self.txns[0].destination_name


def group_transactions(txns: list[Txn]) -> list[TxnGroup]:
    """One group per counterparty.

    A known company is grouped by its destination account (every A1 bill is one
    group, whatever the description says). Everything else — unknown destinations
    and private people — is grouped by normalised description, and a person's
    payments additionally by the person, so two friends' "kosilo" never merge.
    """
    groups: dict[str, TxnGroup] = {}
    for txn in sorted(txns, key=lambda t: (t.date, t.journal_id), reverse=True):
        kind = classify_counterparty(txn)
        normalized = normalize_description(txn.description)
        if kind == COMPANY:
            key = f"dest:{txn.destination_id}"
        elif kind == PERSON:
            key = f"person:{txn.destination_id}:{normalized}"
        else:
            key = f"desc:{normalized}"
        group = groups.setdefault(key, TxnGroup(key=key, counterparty=kind, normalized=normalized, txns=[]))
        group.txns.append(txn)
    return list(groups.values())
