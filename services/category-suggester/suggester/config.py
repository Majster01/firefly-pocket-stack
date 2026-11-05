"""Settings, from the process environment first and an optional .env file second."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_MODEL = "claude-haiku-5-5"
DEFAULT_DB_PATH = "/data/suggester.sqlite3"


class ConfigError(Exception):
    pass


def load_env_file(path: Path) -> dict[str, str]:
    """Parse a compose .env without executing it.

    Same contract as load_env() in scripts/lib.sh: only KEY=VALUE lines with an
    uppercase key are accepted, so comments and stray text can never run as code.
    """
    env: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", key):
            env[key] = value
    return env


@dataclass(frozen=True)
class Settings:
    firefly_url: str
    firefly_token: str
    anthropic_api_key: str
    gemini_api_key: str
    model: str
    min_confidence: float
    max_per_run: int
    db_path: str
    ntfy_url: str
    pico_url: str
    # Firefly Pocket's internal Web Push endpoint and its bearer token. Push is on only
    # when both are set. The digest goes only there (ntfy_url is no longer used by
    # `notify`: ntfy is for failures).
    next_notify_url: str = ""
    next_notify_token: str = ""

    @classmethod
    def load(cls, env_file: Path | None, need_model: bool = True) -> "Settings":
        """need_model=False (notify): only Firefly is needed, not the model key."""
        file_env = load_env_file(env_file) if env_file else {}

        def get(key: str, default: str = "") -> str:
            # A variable that is set but empty counts as unset, like compose's :-.
            return os.environ.get(key) or file_env.get(key) or default

        firefly_url = get("FIREFLY_URL")
        if not firefly_url and get("FIREFLY_HOSTNAME"):
            # Local runs: Caddy adds no auth to the Firefly vhost, so the public
            # URL works from a laptop exactly as the internal one does in compose.
            firefly_url = f"https://{get('FIREFLY_HOSTNAME')}"
        pico_url = get("PICO_URL")
        if not pico_url and get("PICO_HOSTNAME"):
            pico_url = f"https://{get('PICO_HOSTNAME')}"

        model = get("SUGGESTER_MODEL", DEFAULT_MODEL)
        # Only the key of the provider the model belongs to is required.
        key_name = "GEMINI_API_KEY" if model.startswith("gemini") else "ANTHROPIC_API_KEY"
        required = ["SUGGESTER_FIREFLY_TOKEN"] + ([key_name] if need_model else [])
        missing = ([] if firefly_url else ["FIREFLY_URL"]) + [name for name in required if not get(name)]
        if missing:
            raise ConfigError(f"not set: {', '.join(missing)}")

        try:
            min_confidence = float(get("SUGGESTER_MIN_CONFIDENCE", "0.6"))
            max_per_run = int(get("SUGGESTER_MAX_PER_RUN", "50"))
        except ValueError as exc:
            raise ConfigError(f"bad number in SUGGESTER_* settings: {exc}") from None

        return cls(
            firefly_url=firefly_url.rstrip("/"),
            firefly_token=get("SUGGESTER_FIREFLY_TOKEN"),
            anthropic_api_key=get("ANTHROPIC_API_KEY"),
            gemini_api_key=get("GEMINI_API_KEY"),
            model=model,
            min_confidence=min_confidence,
            max_per_run=max_per_run,
            db_path=get("SUGGESTER_DB", DEFAULT_DB_PATH),
            ntfy_url=get("NTFY_URL"),
            pico_url=pico_url.rstrip("/"),
            next_notify_url=get("NEXT_NOTIFY_URL"),
            next_notify_token=get("NEXT_NOTIFY_TOKEN"),
        )
