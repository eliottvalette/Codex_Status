"""Integration checks for the standalone claude-accounts command."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


COMMAND = Path(__file__).resolve().parents[2] / "bin" / "claude-accounts"

# Stands in for Claude Code. The default account answers with no CLAUDE_CONFIG_DIR; an
# API key in the environment must never reach it.
FAKE_CLAUDE = """#!/bin/sh
if [ "$1" = "--version" ]; then echo "2.1.331 (Claude Code)"; exit 0; fi
if [ -n "$ANTHROPIC_API_KEY" ]; then echo '{"loggedIn": false}'; exit 0; fi
case "${CLAUDE_CONFIG_DIR-unset}" in
  unset) echo '{"loggedIn": true, "email": "me@example.com", "authMethod": "claude.ai"}' ;;
  */.claude-work) echo '{"loggedIn": true, "email": "work@example.com", "authMethod": "claude.ai"}' ;;
  *) echo '{"loggedIn": false}' ;;
esac
"""


def run(home: Path, *arguments: str, shell: str = "/bin/zsh") -> subprocess.CompletedProcess[str]:
    bin_directory = home / "bin"
    return subprocess.run(
        [sys.executable, str(COMMAND), *arguments],
        env={
            "HOME": str(home), "SHELL": shell, "PATH": f"{bin_directory}:/usr/bin:/bin",
            "ANTHROPIC_API_KEY": "sk-test", "CLAUDE_CONFIG_DIR": "/elsewhere",
        },
        capture_output=True, text=True,
    )


class ClaudeAccountsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary_directory.name).resolve()
        claude = self.home / "bin" / "claude"
        claude.parent.mkdir()
        claude.write_text(FAKE_CLAUDE)
        claude.chmod(claude.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_lists_each_account_with_its_alias_and_sign_in(self) -> None:
        for name in (".claude", ".claude-work", ".claude-old"):
            (self.home / name / "projects" / "-Users-me-app").mkdir(parents=True)
        (self.home / ".claude-work" / "projects" / "-Users-me-app" / "s1.jsonl").write_text("{}\n")
        (self.home / ".claude-work" / "projects" / "-Users-me-app" / "agent-a.jsonl").write_text("{}\n")
        (self.home / ".claude-notes.txt").write_text("not an account")
        # Another tool's folder, with no Claude Code data in it.
        (self.home / ".claude-mem").mkdir()
        (self.home / ".zshrc").write_text("alias claude-work='CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\" claude'\n")

        completed = run(self.home)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        lines = completed.stdout.splitlines()
        self.assertTrue(lines[0].startswith("Claude Code 2.1.331 at "))
        rows = [line.split() for line in lines if line.startswith("claude")]
        self.assertEqual([row[0] for row in rows], ["claude", "claude-old", "claude-work"])
        self.assertEqual(rows[0][1:], ["claude", "me@example.com", "(claude.ai)", "0"])
        self.assertEqual(rows[1][1:], ["(no", "alias)", "not", "signed", "in", "0"])
        self.assertEqual(rows[2][1:], ["claude-work", "work@example.com", "(claude.ai)", "1"])
        self.assertIn("claude-accounts add NAME", completed.stdout)

    def test_flags_a_claude_code_too_old_for_the_app(self) -> None:
        (self.home / "bin" / "claude").write_text(FAKE_CLAUDE.replace("2.1.331", "2.1.112"))
        completed = run(self.home)
        self.assertIn("too old for CodexMeter", completed.stdout.splitlines()[0])

    def test_adds_an_account_directory_and_alias_once(self) -> None:
        first = run(self.home, "add", "claude-work")
        second = run(self.home, "add", "work")

        self.assertEqual(first.returncode, 0, first.stderr)
        directory = self.home / ".claude-work"
        self.assertTrue(directory.is_dir())
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertEqual(
            (self.home / ".zshrc").read_text().count(
                "alias claude-work='CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\" claude'"
            ),
            1,
        )
        self.assertIn("already exists", second.stdout)
        self.assertIn("/login", first.stdout)

    def test_prints_the_alias_without_writing_it_when_asked(self) -> None:
        completed = run(self.home, "add", "personal", "--no-alias", shell="/bin/bash")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse((self.home / ".bashrc").exists())
        self.assertIn(".bashrc", completed.stdout)
        self.assertIn("alias claude-personal=", completed.stdout)

    def test_rejects_unusable_names(self) -> None:
        for name in ("Work", "my work", "-x", "a/b"):
            with self.subTest(name=name):
                completed = run(self.home, "add", name)
                self.assertEqual(completed.returncode, 2)
                self.assertFalse(any(self.home.glob(".claude-*")))


if __name__ == "__main__":
    unittest.main()
