"""Command line.

    python -m suggester suggest [--dry-run] [--since YYYY-MM-DD | --all] [--until YYYY-MM-DD]
    python -m suggester notify [--dry-run]
    python -m suggester serve [--port 8080]

Exit status is non-zero only when Firefly or the model API cannot be used at all
(unreachable, bad token, no credit) or Firefly is missing a rule group. A group
the model or Firefly chokes on is logged and skipped; the next run retries it.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import sqlite3
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Iterator

from . import contract
from .config import ConfigError, Settings
from .contract import Suggestion
from .firefly import Firefly, FireflyError, FireflyUnreachable, Txn
from .llm import Classification, ModelUnreachable, make_classifier
from .normalize import group_transactions
from .store import Run, Store, journal_categories, reconcile, trigger_key
from .validate import ExistingRules, build_suggestions, firefly_search

# How far back a normal (nightly) run looks. Older uncategorized transactions are
# left to a deliberate `--all` backfill.
DEFAULT_WINDOW_DAYS = 30
# Parallel model calls. Small on purpose: a run is a few dozen groups at most.
WORKERS = 4
# Where Firefly Pocket lists pending suggestions.
SUGGESTIONS_PATH = "/suggestions"
NOTIFY_TITLE = "Firefly Pocket: category suggestions"

EXIT_OK = 0
EXIT_SETUP = 1
EXIT_UNREACHABLE = 2

SOURCES = ("nightly", "manual")


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="suggester", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--env-file",
        type=Path,
        help="read settings missing from the environment from this compose .env (parsed, never executed)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    suggest = sub.add_parser("suggest", help="suggest category rules for uncategorized withdrawals")
    suggest.add_argument("--dry-run", action="store_true", help="print the rules it would write; change nothing")
    window = suggest.add_mutually_exclusive_group()
    window.add_argument("--since", type=dt.date.fromisoformat, metavar="YYYY-MM-DD", help="oldest date to consider")
    window.add_argument("--all", action="store_true", help="every uncategorized withdrawal, any date (backfill)")
    suggest.add_argument("--until", type=dt.date.fromisoformat, metavar="YYYY-MM-DD", help="newest date to consider (default: no limit)")
    suggest.add_argument(
        "--include-pending",
        action="store_true",
        help="dry run only: also look at transactions already covered by a pending suggestion",
    )
    suggest.add_argument("--report", type=Path, help="also write the full result as JSON to this file")
    suggest.add_argument(
        "--source",
        choices=SOURCES,
        default="nightly",
        help="who asked, for the run history shown in Firefly Pocket (the importer's `serve` passes manual)",
    )

    serve = sub.add_parser("serve", help="run suggest on request from the importer (internal network only)")
    serve.add_argument("--port", type=int, default=8080)

    notify = sub.add_parser("notify", help="push the suggestions digest to the Firefly Pocket app if suggestions are waiting")
    notify.add_argument("--dry-run", action="store_true", help="print what would be sent instead of sending it")
    return parser.parse_args(argv)


@contextlib.contextmanager
def run_lock(db_path: str) -> Iterator[None]:
    """One writing run at a time: the nightly job and a run asked for by the importer share the memory of rejected suggestions."""
    with open(f"{db_path}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.command == "serve":
        from .serve import serve

        return serve(args.port)
    try:
        settings = Settings.load(args.env_file, need_model=args.command == "suggest")
    except (ConfigError, OSError) as exc:
        log(f"FATAL: {exc}")
        return EXIT_UNREACHABLE
    try:
        if args.command == "suggest":
            if args.dry_run:
                return cmd_suggest(args, settings)
            with run_lock(settings.db_path):
                return cmd_suggest_recorded(args, settings)
        if args.command == "notify":
            return cmd_notify(args, settings)
    except FireflyUnreachable as exc:
        log(f"FATAL: Firefly unreachable: {exc}")
        return EXIT_UNREACHABLE
    except ModelUnreachable as exc:
        log(f"FATAL: model API unreachable: {exc}")
        return EXIT_UNREACHABLE
    return EXIT_OK


# --- reading Firefly -------------------------------------------------------


def category_examples(rules: list[dict]) -> dict[str, list[str]]:
    """Description keywords per category, from the live Category: rules."""
    examples: dict[str, list[str]] = {}
    for rule in rules:
        attrs = rule["attributes"]
        if not attrs["title"].startswith(contract.CATEGORY_RULE_PREFIX):
            continue
        category = _rule_category(rule)
        if not category:
            continue
        examples.setdefault(category, []).extend(
            t["value"] for t in attrs["triggers"] if t["type"] == "description_contains"
        )
    return examples


def _rule_category(rule: dict) -> str | None:
    return next((a["value"] for a in rule["attributes"]["actions"] if a["type"] == "set_category"), None)


def suggestion_metas(rules: list[dict]) -> list[dict]:
    """Metadata of every contract suggestion in `Suggestions`, whoever wrote it."""
    metas = []
    for rule in rules:
        meta = contract.decode_description(rule["attributes"].get("description"))
        if meta:
            metas.append(meta)
    return metas


def pending_trigger_keys(rules: list[dict]) -> set[tuple[str, str, str]]:
    """Triggers already waiting in `Suggestions`.

    A new transaction from a merchant whose suggestion is still unreviewed needs
    no second suggestion: approving it in Firefly Pocket backfills every
    uncategorized match.
    """
    keys = set()
    for rule in rules:
        category = _rule_category(rule)
        if category and contract.decode_description(rule["attributes"].get("description")):
            keys |= {trigger_key(t["type"], t["value"], category) for t in rule["attributes"]["triggers"]}
    return keys


# --- suggest ---------------------------------------------------------------


def date_window(since: dt.date | None, until: dt.date | None) -> tuple[str, Callable[[str], bool]]:
    """Search terms for a date window, and the exact test for a transaction's date.

    The search gets a day of margin on each side, so it does not matter whether
    Firefly's date_after/date_before include their own date; the test is exact.
    """
    query = ""
    if since:
        query += f" date_after:{(since - dt.timedelta(days=1)).isoformat()}"
    if until:
        query += f" date_before:{(until + dt.timedelta(days=1)).isoformat()}"
    return query, lambda date: (not since or date >= since.isoformat()) and (not until or date <= until.isoformat())


def cmd_suggest_recorded(args: argparse.Namespace, settings: Settings) -> int:
    """cmd_suggest, with what happened saved to the `runs` table whatever the outcome."""
    now = lambda: dt.datetime.now().isoformat(timespec="seconds")  # noqa: E731
    run = Run(
        started=now(),
        source=args.source,
        model=settings.model,
        min_confidence=settings.min_confidence,
        window_since=None if args.all else (args.since or dt.date.today() - dt.timedelta(days=DEFAULT_WINDOW_DAYS)).isoformat(),
        window_until=args.until.isoformat() if args.until else None,
    )
    try:
        status = cmd_suggest(args, settings, run)
        if status != EXIT_OK:
            run.status = "failed"
        return status
    except Exception as exc:
        run.status, run.error = "failed", run.error or f"{type(exc).__name__}: {exc}"
        raise
    finally:
        run.finished = now()
        try:
            Store.open(settings.db_path).record_run(run)
        except sqlite3.Error as exc:  # the history is a convenience; never fail the run over it
            log(f"! could not save the run history: {exc}")


def cmd_suggest(args: argparse.Namespace, settings: Settings, run: Run | None = None) -> int:
    run = run or Run(started="", source=args.source, model=settings.model, min_confidence=settings.min_confidence)
    if args.include_pending and not args.dry_run:
        log("FATAL: --include-pending is for dry runs only")
        return EXIT_SETUP

    ff = Firefly(settings.firefly_url, settings.firefly_token)
    categories = ff.categories()
    group_ids = {title: ff.rule_group_id(title) for title in (contract.GROUP_CATEGORIZATION, contract.GROUP_SUGGESTIONS)}
    missing = [title for title, gid in group_ids.items() if gid is None]
    if missing:
        run.error = f"rule group(s) not found by title: {', '.join(missing)}"
        log(f"FATAL: {run.error}")
        return EXIT_SETUP
    suggestions_group = group_ids[contract.GROUP_SUGGESTIONS]
    categorization = ff.rules(group_ids[contract.GROUP_CATEGORIZATION])
    suggestion_rules = ff.rules(suggestions_group)
    today = dt.date.today().isoformat()

    # 1. Reconcile: what happened to the suggestions we wrote earlier?
    store = Store.open(settings.db_path, readonly=args.dry_run)
    decisions = reconcile(
        store, {int(r["id"]) for r in suggestion_rules}, lambda txns: journal_categories(ff, txns)
    )
    for d in decisions:
        log(f"reconcile  rule {d.pending.rule_id} ({d.pending.category}): {d.status}")
    if not args.dry_run:
        store.apply(decisions)
    rejected_triggers = store.rejected_triggers()
    rejected_journals = store.rejected_journals()
    for d in decisions:  # so a dry run already behaves as the real run will
        if d.status == "rejected":
            rejected_triggers |= {trigger_key(t, v, d.pending.category) for t, v in d.pending.triggers}
            rejected_journals |= {jid for _, jid in d.pending.transactions}

    # 2. Select uncategorized withdrawals.
    since = None if args.all else args.since or (dt.date.today() - dt.timedelta(days=DEFAULT_WINDOW_DAYS))
    window_query, in_window = date_window(since, args.until)
    query = "type:withdrawal has_no_category:true" + window_query
    # A group can mix categorized and uncategorized splits; judge each split.
    txns = [t for t in ff.search(query) if t.type == "withdrawal" and not t.category and in_window(t.date)]
    pending = set().union(*(contract.journal_ids(m) for m in suggestion_metas(suggestion_rules)))
    in_pending = [t for t in txns if t.journal_id in pending]
    if not args.include_pending:
        txns = [t for t in txns if t.journal_id not in pending]
    was_rejected = [t for t in txns if t.journal_id in rejected_journals]
    txns = [t for t in txns if t.journal_id not in rejected_journals]
    groups = group_transactions(txns)
    deferred = groups[settings.max_per_run :]
    groups = groups[: settings.max_per_run]
    run.transactions, run.groups_sent, run.deferred = len(txns), len(groups), len(deferred)
    log(
        f"{len(txns)} uncategorized withdrawal(s) in {len(groups) + len(deferred)} group(s)"
        f"{f' since {since}' if since else ''}{f' until {args.until}' if args.until else ''}; skipped {len(in_pending)} in a pending suggestion"
        f"{' (included)' if args.include_pending else ''} and {len(was_rejected)} rejected before"
        + (f"; {len(deferred)} group(s) left for the next run (SUGGESTER_MAX_PER_RUN={settings.max_per_run})" if deferred else "")
    )

    # 3. Classify, one model call per group.
    classifier = make_classifier(
        settings.model,
        anthropic_key=settings.anthropic_api_key,
        gemini_key=settings.gemini_api_key,
        categories=categories,
        examples=category_examples(categorization),
    )
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(classifier.classify, g) for g in groups]
        outcomes: list[Classification | Exception] = []
        for future in futures:
            try:
                outcomes.append(future.result())
            except ModelUnreachable:
                raise
            except Exception as exc:  # one bad group must not sink the run
                outcomes.append(exc)

    # 4. Validate into contract suggestions.
    search = firefly_search(ff)
    existing = ExistingRules.from_rules(categorization)
    already_pending = pending_trigger_keys(suggestion_rules)
    report = []
    suggestions: list[Suggestion] = []
    usage = {"input_tokens": 0, "output_tokens": 0, "searches": 0, "calls": 0}
    group_errors = 0
    for group, outcome in zip(groups, outcomes):
        entry: dict = {"group": group.key, "counterparty": group.counterparty, "transactions": [_txn(t) for t in group.txns]}
        report.append(entry)
        if isinstance(outcome, Exception):
            group_errors += 1
            entry["error"] = f"{type(outcome).__name__}: {outcome}"
            log(f"! {group.key}: {entry['error']}")
            run.add_error(f"model: {entry['error']}")
            continue
        for key in usage:
            usage[key] += getattr(outcome, key)
        entry["classification"] = {k: v for k, v in vars(outcome).items() if k not in usage}
        try:
            built = build_suggestions(
                group,
                outcome,
                categories=set(categories),
                existing=existing,
                search=search,
                min_confidence=settings.min_confidence,
                model=settings.model,
                rejected=rejected_triggers,
            )
        except FireflyUnreachable:
            raise
        except Exception as exc:
            group_errors += 1
            entry["error"] = f"{type(exc).__name__}: {exc}"
            log(f"! {group.key}: {entry['error']}")
            run.add_error(f"suggestion: {entry['error']}")
            continue
        kept = []
        for s in built:
            if any(trigger_key(t, v, s.category) in already_pending for t, v in s.triggers):
                log(f"- {s.title}: same trigger already waiting in Suggestions, not repeated")
            else:
                kept.append(s)
        entry["suggestions"] = [_suggestion(s, today) for s in kept]
        suggestions.extend(kept)

    if len(suggestions) > settings.max_per_run:
        log(f"{len(suggestions) - settings.max_per_run} suggestion(s) over SUGGESTER_MAX_PER_RUN, left for the next run")
        suggestions = suggestions[: settings.max_per_run]
    run.input_tokens, run.output_tokens, run.searches, run.calls = (usage[k] for k in ("input_tokens", "output_tokens", "searches", "calls"))
    run.group_errors, run.suggestions = group_errors, len(suggestions)
    run.low_confidence = sum(s.low_confidence for s in suggestions)

    # 5. Write (or print).
    written = write_errors = 0
    for s in suggestions:
        if args.dry_run:
            print_suggestion(s, today)
            continue
        try:
            created = ff.create_rule(s.rule_payload(suggestions_group, today))
        except FireflyError as exc:
            write_errors += 1
            log(f"! could not write {s.title!r}: {exc}")
            run.add_error(f"could not write a rule: {exc}")
            continue
        rule_id = int(created["data"]["id"])
        store.record(rule_id, s, today)
        written += 1
        print_suggestion(s, today, rule_id)
    run.written, run.write_errors = written, write_errors

    low = sum(s.low_confidence for s in suggestions)
    verb = "would write" if args.dry_run else f"wrote {written} of"
    log(
        f"\n{verb} {len(suggestions)} suggestion(s), {low} low-confidence, from {len(groups)} group(s); "
        f"{group_errors} group error(s){f', {write_errors} write error(s)' if write_errors else ''}; "
        f"model {settings.model}: {usage['input_tokens']} input / {usage['output_tokens']} output tokens, "
        f"{usage['searches']} web search(es)"
    )
    if args.dry_run:
        log("(dry run — nothing was written, the database was not changed)")

    if args.report:
        args.report.write_text(
            json.dumps({"model": settings.model, "query": query, "usage": usage, "written": written, "groups": report}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
    return EXIT_OK


def _txn(t: Txn) -> dict:
    return {
        "transaction_id": t.transaction_id,
        "journal_id": t.journal_id,
        "date": t.date,
        "amount": f"{t.amount} {t.currency}",
        "description": t.description,
        "destination": t.destination_name,
    }


def _suggestion(s: Suggestion, created: str) -> dict:
    return {
        "title": s.title,
        "triggers": s.triggers,
        "rejected": s.rejected,
        "notes": s.notes,
        "metadata": s.metadata(created),
    }


def print_suggestion(s: Suggestion, created: str, rule_id: int | None = None) -> None:
    flag = "  LOW CONFIDENCE" if s.low_confidence else ""
    where = f"  -> rule {rule_id}" if rule_id else ""
    print(f"\n+ {s.title}   [{s.confidence:.2f}, basis {s.basis}]{flag}{where}")
    for kind, value in s.triggers:
        print(f"    trigger   {kind} = {value!r}")
    for kind, value, why in s.rejected:
        print(f"    dropped   {kind} = {value!r}: {why}")
    for note in s.notes:
        print(f"    note      {note}")
    for t in s.transactions:
        print(f"    covers    #{t.transaction_id} {t.date} {t.amount:>8} {t.currency}  {t.description}  -> {t.destination_name}")
    print(f"    company   {s.company or '-'}")
    print(f"    reason    {s.reason}")
    print(f"    metadata  {contract.encode_description(s.metadata(created))}")


# --- notify ----------------------------------------------------------------


def reminder(metas: list[dict]) -> str | None:
    """The reminder text, or None when nothing is waiting."""
    if not metas:
        return None
    low = sum(bool(m.get("low_confidence")) for m in metas)
    text = f"{len(metas)} category suggestion{'s' if len(metas) != 1 else ''} waiting for review"
    return text + (f" ({low} low-confidence)." if low else ".")


def cmd_notify(args: argparse.Namespace, settings: Settings) -> int:
    ff = Firefly(settings.firefly_url, settings.firefly_token)
    group_id = ff.rule_group_id(contract.GROUP_SUGGESTIONS)
    if group_id is None:
        log(f"FATAL: rule group not found by title: {contract.GROUP_SUGGESTIONS}")
        return EXIT_SETUP
    metas = suggestion_metas(ff.rules(group_id))
    message = reminder(metas)
    if message is None:
        # Nothing is pushed: iOS insists a Web Push shows a notification, so a
        # "0 waiting" push would only be noise. The app badge is not ours to clear:
        # it is the user's unread count in Firefly Pocket's notifications center.
        log("no pending suggestions — nothing sent")
        return EXIT_OK
    push = next_push(settings, message, len(metas))
    if args.dry_run or not push:
        why = "dry run" if args.dry_run else "NEXT_NOTIFY_URL and NEXT_NOTIFY_TOKEN not set"
        log(f"{why} — would send: {message}")
        if push:
            log(f"{why} — would push to Firefly Pocket: {json.dumps(push)}")
        return EXIT_OK
    # Only Firefly Pocket gets the digest: which device wants it, and how often, is each
    # device's setting there, and ntfy is kept for failures. A missed digest is
    # not worth failing the cron job over (tomorrow's comes).
    send_next(settings, push)
    return EXIT_OK


def next_push(settings: Settings, message: str, pending: int) -> dict | None:
    """The Web Push body for Firefly Pocket, or None when push is not configured.

    The tag makes a newer reminder replace the previous one instead of stacking;
    the badge is the number of suggestions waiting, which Firefly Pocket ignores
    since its notifications center (the badge is each user's unread count there);
    older Pockets still show it. The cron job runs every day:
    each device's setting (off, daily, weekly on a weekday) decides if it arrives.
    """
    if not (settings.next_notify_url and settings.next_notify_token):
        if settings.next_notify_url or settings.next_notify_token:
            log("WARN: NEXT_NOTIFY_URL and NEXT_NOTIFY_TOKEN must both be set — Firefly Pocket push skipped")
        return None
    return {
        # Firefly Pocket sends it to the devices that chose to get this digest, today
        "event": "suggestions.digest",
        "title": NOTIFY_TITLE,
        "body": message,
        "path": SUGGESTIONS_PATH,
        "badge": pending,
        "tag": "suggestions",
    }


def send_next(settings: Settings, body: dict) -> None:
    """POST to Firefly Pocket's /api/internal/notify. Failure is only a warning."""
    req = urllib.request.Request(
        settings.next_notify_url,
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {settings.next_notify_token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        # 401 wrong token, 422 rejected body, 503 Firefly Pocket has no VAPID keys / receiver yet.
        log(f"WARN: Firefly Pocket push notification failed: HTTP {exc.code}")
        return
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        log(f"WARN: Firefly Pocket push notification failed: {getattr(exc, 'reason', exc)}")
        return
    sent = result.get("sent", "?") if isinstance(result, dict) else "?"
    failed = result.get("failed", "?") if isinstance(result, dict) else "?"
    skipped = result.get("skipped") if isinstance(result, dict) else None
    log(f"pushed to Firefly Pocket: {sent} sent, {failed} failed" + (f", {skipped} skipped by their settings" if skipped else ""))
