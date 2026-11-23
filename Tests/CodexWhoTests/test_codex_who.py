"""Integration checks for the standalone codex-who command."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path


COMMAND = Path(__file__).resolve().parents[2] / "bin" / "codex-who"


class CodexWhoTests(unittest.TestCase):
    def test_missing_rollout_is_excluded_without_warnings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            profile = root / ".codex"
            profile.mkdir()
            missing = profile / "missing.jsonl"
            readable = profile / "readable.jsonl"
            readable.write_text(json.dumps({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "type": "event_msg",
                "payload": {"type": "user_message"},
            }) + "\n")
            with sqlite3.connect(profile / "state_5.sqlite") as database:
                database.execute("""CREATE TABLE threads (
                    cwd TEXT, name TEXT, title TEXT, preview TEXT,
                    archived INTEGER, agent_path TEXT, source TEXT, rollout_path TEXT
                )""")
                for path in (missing, readable):
                    database.execute(
                        "INSERT INTO threads VALUES (?, NULL, ?, '', 0, NULL, 'cli', ?)",
                        (str(root), path.stem, str(path)),
                    )

            result = subprocess.run(
                [str(COMMAND)], cwd=root,
                env={**os.environ, "HOME": str(root), "NO_COLOR": "1"},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("readable", result.stdout)
            self.assertNotIn("missing", result.stdout)
            self.assertEqual(result.stderr, "")

            readable.write_text("invalid JSON\n")
            result = subprocess.run(
                [str(COMMAND)], cwd=root,
                env={**os.environ, "HOME": str(root), "NO_COLOR": "1"},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Invalid JSON", result.stderr)

    def test_merges_profiles_and_filters_to_the_current_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            project = root / "project"
            other_project = root / "other"
            project.mkdir()
            other_project.mkdir()
            now = int(time.time())

            for profile, offsets in (("codex-yot", range(0, 8)), ("codex-matt", range(8, 13))):
                directory = root / f".{profile}"
                directory.mkdir()
                with sqlite3.connect(directory / "state_5.sqlite") as database:
                    database.execute(
                        """CREATE TABLE threads (
                            id TEXT, cwd TEXT, updated_at INTEGER, name TEXT,
                            title TEXT, preview TEXT, archived INTEGER,
                            agent_path TEXT, source TEXT, rollout_path TEXT
                        )"""
                    )
                    for offset in offsets:
                        rollout = directory / f"rollout-{offset}.jsonl"
                        message_time = datetime.fromtimestamp(
                            now - offset * 3600, tz=timezone.utc
                        ).isoformat()
                        rollout.write_text(
                            json.dumps(
                                {
                                    "timestamp": message_time,
                                    "type": "response_item",
                                    "payload": {"type": "message", "role": "user"},
                                }
                            )
                            + "\n"
                            + json.dumps(
                                {
                                    "timestamp": datetime.fromtimestamp(
                                        now + 100, tz=timezone.utc
                                    ).isoformat(),
                                    "type": "event_msg",
                                    "payload": {"type": "thread_settings_applied"},
                                }
                            )
                            + "\n"
                        )
                        database.execute(
                            "INSERT INTO threads VALUES (?, ?, ?, NULL, ?, '', 0, NULL, 'cli', ?)",
                            (str(offset), str(project), now + offset, f"Conversation {offset}", str(rollout)),
                        )
                    database.execute(
                        "INSERT INTO threads VALUES ('other', ?, ?, NULL, 'Wrong project', '', 0, NULL, 'cli', '')",
                        (str(other_project), now + 100),
                    )
                    database.execute(
                        "INSERT INTO threads VALUES ('archived', ?, ?, NULL, 'Archived', '', 1, NULL, 'cli', '')",
                        (str(project), now + 100),
                    )
                    database.execute(
                        "INSERT INTO threads VALUES ('child', ?, ?, NULL, 'Subagent', '', 0, 'child', 'cli', '')",
                        (str(project), now + 100),
                    )

            result = subprocess.run(
                [str(COMMAND)],
                cwd=project,
                env={**os.environ, "HOME": str(root), "NO_COLOR": "1"},
                capture_output=True,
                text=True,
                check=True,
            )
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 10)
            self.assertIn("codex-yot", lines[0])
            self.assertIn("Conversation 0", lines[0])
            self.assertIn("codex-matt", lines[-1])
            self.assertIn("Conversation 9", lines[-1])
            self.assertNotIn("Wrong project", result.stdout)
            self.assertNotIn("Archived", result.stdout)
            self.assertNotIn("Subagent", result.stdout)
            self.assertNotIn("\033[", result.stdout)


if __name__ == "__main__":
    unittest.main()
