"""Minimal Firefly III API client (standard library only)."""

from __future__ import annotations

import html
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

UNKNOWN_DESTINATION = "(unknown destination)"


class FireflyUnreachable(Exception):
    """Firefly could not be reached or refused the token — the run cannot continue."""


class FireflyError(Exception):
    """One request failed (validation error, missing object) — the run can go on."""


@dataclass(frozen=True)
class Txn:
    """One split (journal) of a Firefly transaction group."""

    transaction_id: int  # the transaction group id
    journal_id: int  # the split that carries the category
    type: str
    date: str
    amount: str
    currency: str
    description: str
    destination_id: int | None
    destination_name: str
    category: str | None

    @property
    def destination_unknown(self) -> bool:
        return not self.destination_name or self.destination_name == UNKNOWN_DESTINATION


def txns_from_groups(groups: list[dict]) -> list[Txn]:
    txns = []
    for group in groups:
        for split in group["attributes"]["transactions"]:
            dest_id = split.get("destination_id")
            txns.append(
                Txn(
                    transaction_id=int(group["id"]),
                    journal_id=int(split["transaction_journal_id"]),
                    type=split["type"],
                    date=split["date"][:10],
                    amount=f"{float(split['amount']):.2f}",
                    currency=split.get("currency_code") or "",
                    description=split.get("description") or "",
                    destination_id=int(dest_id) if dest_id else None,
                    destination_name=split.get("destination_name") or "",
                    category=split.get("category_name"),
                )
            )
    return txns


class Firefly:
    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url.rstrip("/")
        self._token = token

    def _request(self, method: str, path: str, payload: dict | None = None) -> dict:
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(
            f"{self.base_url}/api/v1{path}",
            data=body,
            method=method,
            headers={
                "Authorization": f"Bearer {self._token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:2000]
            if exc.code in (401, 403) or exc.code >= 500:
                raise FireflyUnreachable(f"{method} {path} -> HTTP {exc.code}") from None
            # Firefly's validation errors are the only thing that names the
            # rejected field, so they travel with the exception.
            raise FireflyError(f"{method} {path} -> HTTP {exc.code}: {detail}") from None
        except (urllib.error.URLError, TimeoutError) as exc:
            reason = getattr(exc, "reason", exc)
            raise FireflyUnreachable(f"cannot reach {self.base_url}: {reason}") from None
        return json.loads(raw) if raw else {}

    def get(self, path: str) -> dict:
        return self._request("GET", path)

    def get_all(self, path: str, max_pages: int | None = None) -> list[dict]:
        """Follow pagination so a long list is never silently truncated."""
        items: list[dict] = []
        page = 1
        while True:
            joiner = "&" if "?" in path else "?"
            body = self.get(f"{path}{joiner}limit=100&page={page}")
            items.extend(body.get("data", []))
            total_pages = body.get("meta", {}).get("pagination", {}).get("total_pages", 1)
            if page >= total_pages or (max_pages and page >= max_pages):
                return items
            page += 1

    def search(self, query: str, max_pages: int | None = None) -> list[Txn]:
        q = urllib.parse.quote(query)
        return txns_from_groups(self.get_all(f"/search/transactions?query={q}", max_pages))

    def search_total(self, query: str) -> int:
        q = urllib.parse.quote(query)
        body = self.get(f"/search/transactions?query={q}&limit=1")
        return int(body.get("meta", {}).get("pagination", {}).get("total", 0))

    def categories(self) -> dict[str, str]:
        """Category name -> its notes, which hold the owner's definition of it.

        Unescaped defensively: Firefly HTML-escapes some free-text fields on the
        way out (rule descriptions certainly), and a definition is plain text.
        """
        return {
            c["attributes"]["name"]: html.unescape(c["attributes"].get("notes") or "").strip()
            for c in self.get_all("/categories")
        }

    def rule_group_id(self, title: str) -> str | None:
        """Groups are looked up by title, never by id (contract)."""
        for group in self.get_all("/rule-groups"):
            if group["attributes"]["title"] == title:
                return group["id"]
        return None

    def rules(self, group_id: str) -> list[dict]:
        return self.get_all(f"/rule-groups/{group_id}/rules")

    def create_rule(self, payload: dict) -> dict:
        return self._request("POST", "/rules", payload)
