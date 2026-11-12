import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from suggester.config import Settings


class FireflyUrlTest(unittest.TestCase):
    """Where a run outside compose (--env-file compose/.env, on a laptop) finds Firefly III."""

    def load(self, env_lines: str, **environ: str) -> Settings:
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            env_file.write_text(env_lines + "SUGGESTER_FIREFLY_TOKEN=t\n", encoding="utf-8")
            with mock.patch.dict(os.environ, environ, clear=True):
                return Settings.load(env_file, need_model=False)

    def test_iii_dot_domain_from_a_fresh_env(self):
        self.assertEqual(self.load("DOMAIN=example.com\n").firefly_url, "https://iii.example.com")

    def test_a_hostname_set_on_its_own_wins(self):
        settings = self.load("DOMAIN=example.com\nFIREFLY_HOSTNAME=money.example.org\n")
        self.assertEqual(settings.firefly_url, "https://money.example.org")

    def test_the_compose_url_wins_over_both(self):
        settings = self.load("DOMAIN=example.com\n", FIREFLY_URL="http://app:8080/")
        self.assertEqual(settings.firefly_url, "http://app:8080")


if __name__ == "__main__":
    unittest.main()
