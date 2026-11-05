"""One model call per transaction group, with structured output.

Two backends share the prompt and the output schema: Claude through the anthropic
SDK, and Gemini through its REST API (standard library only). The backend is chosen
by the model name — `gemini-*` goes to Gemini, everything else to Claude. Only the
Claude backend can search the web; Gemini's Search grounding needs a paid project
and is not wired up.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass

from .normalize import PERSON, TxnGroup


class ModelUnreachable(Exception):
    """The model API could not be reached or refused the key — the run cannot continue."""


@dataclass(frozen=True)
class Classification:
    category: str
    confidence: float
    company: str | None
    reason: str
    description_keywords: list[str]
    use_destination: bool
    counterparty_is_person: bool
    # Billing, for the run summary: (input incl. cache, output) tokens, web searches.
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0
    # API requests it took: 1, plus one per web-search pause_turn continuation.
    calls: int = 1


SYSTEM_TEMPLATE = """\
You help one person in Slovenia categorize their bank withdrawals in Firefly III.

You get one group of uncategorized withdrawals that share a counterparty. Decide which \
existing category they belong to, and propose rule triggers so future transactions from \
the same counterparty get that category automatically. A human reviews every suggestion \
before anything changes.

## Categories
Use exactly one of these names. The text after a name is the owner's own \
definition of that category: follow it over your general idea of what the name \
means, including where it says a kind of payment belongs elsewhere.
{categories}

## Existing rules
These keywords already categorize transactions (description substring -> category). \
They show how this person uses each category; do not propose a keyword that is already \
listed.
{examples}

## Reading the descriptions
- Descriptions are written by Slovenian banks: "NAKUP" = card purchase, "PLAČILO" = \
payment, "STORITVE" = services, "DAVEK" = tax, "NRC00" = instant transfer (usually to a \
private person). d.o.o. / d.d. / s.p. are Slovenian company forms.
- Card terminals truncate merchant names ("SumUp *Zadruga za raz"), and often append a \
place ("LJ-RUDNIK", "RUDNIK", "LJUBLJANA").
- Identify the counterparty from what you know. When you do not recognise it, use web \
search if it is available: search the merchant name as written, adding "Slovenija" or the \
place when that helps. Do not search for brands you already know. If you still cannot tell \
who it is, say so with `company` = null and lower your confidence rather than guessing.

## What to return
- `category`: the best category, even when unsure.
- `confidence`: 0–1, how sure you are of the category. Above 0.8 only when the \
counterparty is clearly identified and the category obviously follows. Below 0.6 when you \
cannot tell who the counterparty is or what was bought.
- `company`: "Name — what it is, where" when you can identify it, else null.
- `reason`: one short sentence for the reviewer.
- `description_keywords`: zero to two substrings, copied character for character from the \
descriptions, that identify this counterparty and appear in EVERY description of the \
group. At least 4 characters. Never generic words (NAKUP, PLAČILO, STORITVE, D.O.O., \
SPLETNI), place names (RUDNIK, LJUBLJANA), amounts, dates or reference numbers — they would \
match other merchants. Prefer the shortest distinctive merchant name ("BURGERLAB", not \
"BURGERLAB LJ-RUDNIK"). Empty when no such substring exists.
- `use_destination`: true when the destination account is the merchant or organisation \
itself, so matching on the account is the most reliable trigger. False for an unknown \
destination or a private person.
- `counterparty_is_person`: true when the counterparty is a private individual rather than \
a business or institution.
"""


def _schema(categories: list[str]) -> dict:
    return {
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": categories},
            "confidence": {"type": "number"},
            "company": {"anyOf": [{"type": "string"}, {"type": "null"}]},
            "reason": {"type": "string"},
            "description_keywords": {"type": "array", "items": {"type": "string"}},
            "use_destination": {"type": "boolean"},
            "counterparty_is_person": {"type": "boolean"},
        },
        "required": [
            "category",
            "confidence",
            "company",
            "reason",
            "description_keywords",
            "use_destination",
            "counterparty_is_person",
        ],
        "additionalProperties": False,
    }


def _group_prompt(group: TxnGroup) -> str:
    destination = None if group.counterparty == "unknown" else group.destination_name
    payload = {
        "destination_account": destination,
        "counterparty_kind_by_rules": group.counterparty,
        "transactions": [
            {"date": t.date, "amount": f"{t.amount} {t.currency}", "description": t.description}
            for t in group.txns
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=1)


class Classifier:
    """Shared prompt and parsing; subclasses make the actual call."""

    def __init__(self, model: str, categories: dict[str, str], examples: dict[str, list[str]]):
        self.model = model
        self.categories = sorted(categories)  # names; the values are definitions
        # Sorted and frozen: the system prompt is the cacheable prefix, so it must
        # be byte-identical across every call of a run.
        lines = [f"- {cat}: {', '.join(sorted(kws, key=str.lower))}" for cat, kws in sorted(examples.items()) if kws]
        self.system = SYSTEM_TEMPLATE.format(
            categories="\n".join(
                f"- {name}: {categories[name]}" if categories[name] else f"- {name}" for name in self.categories
            ),
            examples="\n".join(lines) or "(none yet)",
        )

    def classify(self, group: TxnGroup) -> Classification:
        raise NotImplementedError

    @staticmethod
    def _parse(text: str, input_tokens: int, output_tokens: int, searches: int = 0, calls: int = 1) -> Classification:
        data = json.loads(text)
        return Classification(
            category=data["category"],
            confidence=max(0.0, min(1.0, float(data["confidence"]))),
            company=(data.get("company") or None),
            reason=data["reason"].strip(),
            description_keywords=[k for k in data["description_keywords"] if isinstance(k, str)],
            use_destination=bool(data["use_destination"]),
            counterparty_is_person=bool(data["counterparty_is_person"]),
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            searches=searches,
            calls=calls,
        )


# The basic variant on purpose: on Haiku 5.5 the dynamic-filtering one
# (web_search_20260209) used ~50% more input tokens for these one-name lookups
# without a better answer. No user_location: Slovenia (SI) is not a supported
# country. max_uses caps the cost of a single group at 3 searches.
WEB_SEARCH_TOOL = {"type": "web_search_20250305", "name": "web_search", "max_uses": 3}
# pause_turn resumptions allowed per group.
MAX_CONTINUATIONS = 2


class ClaudeClassifier(Classifier):
    def __init__(self, api_key: str, model: str, categories: dict[str, str], examples: dict[str, list[str]]):
        super().__init__(model, categories, examples)
        import anthropic

        self._anthropic = anthropic
        self.client = anthropic.Anthropic(api_key=api_key, max_retries=3, timeout=120.0)

    def classify(self, group: TxnGroup) -> Classification:
        anthropic = self._anthropic
        messages: list[dict] = [{"role": "user", "content": _group_prompt(group)}]
        # Never send a private person's name to a search engine.
        tools = [] if group.counterparty == PERSON else [WEB_SEARCH_TOOL]
        input_tokens = output_tokens = searches = calls = 0
        for _ in range(MAX_CONTINUATIONS + 1):
            try:
                response = self.client.messages.create(
                    model=self.model,
                    max_tokens=8000,
                    system=[{"type": "text", "text": self.system, "cache_control": {"type": "ephemeral"}}],
                    messages=messages,
                    tools=tools,
                    output_config={
                        "effort": "medium",
                        "format": {"type": "json_schema", "schema": _schema(self.categories)},
                    },
                )
            except (anthropic.APIConnectionError, anthropic.AuthenticationError, anthropic.PermissionDeniedError) as exc:
                raise ModelUnreachable(f"{type(exc).__name__}: {exc}") from None
            except anthropic.BadRequestError as exc:
                # An empty credit balance arrives as a 400, but it fails every call
                # alike — the account is unusable, not this one group.
                if "credit balance" in str(exc).lower():
                    raise ModelUnreachable(f"billing: {exc.message}") from None
                raise
            calls += 1
            usage = response.usage
            input_tokens += usage.input_tokens + (usage.cache_read_input_tokens or 0) + (usage.cache_creation_input_tokens or 0)
            output_tokens += usage.output_tokens
            if usage.server_tool_use:
                searches += usage.server_tool_use.web_search_requests or 0
            if response.stop_reason != "pause_turn":
                break
            # A long server-tool turn paused; send it back as-is to let it finish.
            # Blocks of earlier pauses stay in front, so the turn reads as one.
            paused = (messages[1]["content"] if len(messages) > 1 else []) + list(response.content)
            messages = [messages[0], {"role": "assistant", "content": paused}]
        else:
            raise ValueError("turn still paused after web search continuations")

        if response.stop_reason == "refusal":
            raise ValueError("model refused")
        if response.stop_reason == "max_tokens":
            raise ValueError("response cut off at max_tokens")
        # With web search there can be narration before the searches; the
        # structured answer is the final text block.
        texts = [b.text for b in response.content if b.type == "text"]
        if not texts:
            raise ValueError(f"no text block (stop_reason={response.stop_reason})")
        return self._parse(texts[-1], input_tokens, output_tokens, searches, calls)


GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models"
GEMINI_ATTEMPTS = 4


class GeminiClassifier(Classifier):
    def __init__(self, api_key: str, model: str, categories: dict[str, str], examples: dict[str, list[str]]):
        super().__init__(model, categories, examples)
        self._api_key = api_key

    def _post(self, body: dict) -> dict:
        req = urllib.request.Request(
            f"{GEMINI_ENDPOINT}/{self.model}:generateContent",
            data=json.dumps(body).encode("utf-8"),
            method="POST",
            # The key goes in a header, never the URL, so it cannot end up in a log line.
            headers={"x-goog-api-key": self._api_key, "Content-Type": "application/json"},
        )
        for attempt in range(GEMINI_ATTEMPTS):
            try:
                with urllib.request.urlopen(req, timeout=180) as response:
                    return json.loads(response.read())
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:1000]
                if exc.code == 429 and "PerDay" in detail:
                    # Daily quota: waiting seconds will not help, and every
                    # further group would fail the same way.
                    raise ModelUnreachable(f"Gemini daily quota exhausted for {self.model}") from None
                if exc.code in (429, 500, 502, 503, 504) and attempt + 1 < GEMINI_ATTEMPTS:
                    time.sleep(2 ** (attempt + 1))
                    continue
                if exc.code in (401, 403) or "API_KEY_INVALID" in detail:
                    raise ModelUnreachable(f"Gemini refused the key: HTTP {exc.code}") from None
                if exc.code == 404:
                    # Retired models still show up in the listing but 404 here.
                    raise ModelUnreachable(f"Gemini model {self.model} not found: {detail}") from None
                raise ValueError(f"Gemini HTTP {exc.code}: {detail}") from None
            except TimeoutError:
                # The request may well have been served and counted against the
                # quota (the free tier allows 20 a day per model), so do not retry.
                raise ValueError("Gemini did not answer within the timeout") from None
            except urllib.error.URLError as exc:
                if isinstance(exc.reason, TimeoutError):
                    raise ValueError("Gemini did not answer within the timeout") from None
                if attempt + 1 < GEMINI_ATTEMPTS:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise ModelUnreachable(f"cannot reach Gemini: {exc.reason}") from None
        raise AssertionError("unreachable")

    def classify(self, group: TxnGroup) -> Classification:
        body = self._post(
            {
                "systemInstruction": {"parts": [{"text": self.system}]},
                "contents": [{"role": "user", "parts": [{"text": _group_prompt(group)}]}],
                "generationConfig": {
                    "responseMimeType": "application/json",
                    "responseJsonSchema": _schema(self.categories),
                    "maxOutputTokens": 8000,
                },
            }
        )
        candidates = body.get("candidates") or []
        if not candidates:
            raise ValueError(f"no candidates (promptFeedback={body.get('promptFeedback')})")
        candidate = candidates[0]
        finish = candidate.get("finishReason")
        if finish not in (None, "STOP"):
            raise ValueError(f"generation stopped: {finish}")
        parts = candidate.get("content", {}).get("parts", [])
        text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
        if not text:
            raise ValueError("empty response")
        usage = body.get("usageMetadata", {})
        return self._parse(
            text,
            usage.get("promptTokenCount", 0),
            usage.get("candidatesTokenCount", 0) + usage.get("thoughtsTokenCount", 0),
        )


def make_classifier(
    model: str, *, anthropic_key: str, gemini_key: str, categories: dict[str, str], examples: dict[str, list[str]]
) -> Classifier:
    if is_gemini(model):
        return GeminiClassifier(gemini_key, model, categories, examples)
    return ClaudeClassifier(anthropic_key, model, categories, examples)


def is_gemini(model: str) -> bool:
    return model.startswith("gemini")
