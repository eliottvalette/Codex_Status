"""Integration checks for the standalone claude-who command."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path


COMMAND = Path(__file__).resolve().parents[2] / "bin" / "claude-who"


def project_name(path: Path) -> str:
    return "".join(character if character.isascii() and character.isalnum() else "-" for character in str(path))


def stamp(seconds: float) -> str:
    return datetime.fromtimestamp(seconds, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def prompt(text: object, seconds: float, cwd: Path, **extra: object) -> str:
    return json.dumps({
        "type": "user", "isSidechain": False, "cwd": str(cwd), "timestamp": stamp(seconds),
        "message": {"role": "user", "content": text}, **extra,
    }, separators=(",", ":"))


def run(cwd: Path, home: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(COMMAND)], cwd=cwd,
        env={**os.environ, "HOME": str(home), "NO_COLOR": "1"},
        capture_output=True, text=True,
    )


class ClaudeWhoTests(unittest.TestCase):
    def test_merges_profiles_and_filters_to_the_current_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            project = root / "my_project"
            other_project = root / "other"
            project.mkdir()
            other_project.mkdir()
            now = time.time()

            for profile, offsets in ((".claude", range(0, 8)), (".claude-work", range(8, 13))):
                sessions = root / profile / "projects" / project_name(project)
                sessions.mkdir(parents=True)
                for offset in offsets:
                    message_time = now - offset * 3600
                    transcript = sessions / f"session-{offset}.jsonl"
                    transcript.write_text(
                        prompt(f"Prompt {offset}", message_time, project) + "\n"
                        # A tool result is a user-role record that the user did not type.
                        + prompt([{"type": "tool_result", "content": "ok"}], now + 100, project) + "\n"
                        + json.dumps({"type": "ai-title", "aiTitle": f"Conversation {offset}"}) + "\n"
                    )
                    os.utime(transcript, (message_time + 5, message_time + 5))
                elsewhere = root / profile / "projects" / project_name(other_project)
                elsewhere.mkdir()
                (elsewhere / "other.jsonl").write_text(prompt("Wrong project", now, other_project) + "\n")
                (sessions / "agent-abc.jsonl").write_text(prompt("Legacy subagent", now, project) + "\n")
                subagents = sessions / "session-0" / "subagents"
                subagents.mkdir(parents=True)
                (subagents / "agent-def.jsonl").write_text(prompt("Subagent", now, project) + "\n")
                (sessions / "sidechain.jsonl").write_text(
                    prompt("Sidechain only", now, project, isSidechain=True) + "\n"
                )
            # Other tools keep folders with similar names.
            (root / ".claude-mem").mkdir()
            (root / ".claude.json").write_text("{}")

            result = run(project, root)

            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 10)
            self.assertTrue(lines[0].startswith("claude "), lines[0])
            self.assertIn("Conversation 0", lines[0])
            self.assertIn("now", lines[0])
            self.assertIn("claude-work", lines[-1])
            self.assertIn("Conversation 9", lines[-1])
            for hidden in ("Wrong project", "subagent", "Subagent", "Sidechain", "Prompt"):
                self.assertNotIn(hidden, result.stdout)
            self.assertNotIn("\033[", result.stdout)
            self.assertEqual(result.stderr, "")

    def test_orders_by_the_last_user_message_not_the_file_time(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            sessions = root / ".claude" / "projects" / project_name(root)
            sessions.mkdir(parents=True)
            now = time.time()
            for offset in range(14):
                message_time = now - offset * 3600
                transcript = sessions / f"session-{offset}.jsonl"
                transcript.write_text(prompt(f"Conversation {offset}.", message_time, root) + "\n")
                # The oldest conversation was touched last, as a finishing tool call would.
                modified_at = now if offset == 13 else message_time + 5
                os.utime(transcript, (modified_at, modified_at))

            result = run(root, root)

            self.assertEqual(result.returncode, 0, result.stderr)
            titles = [line.split(None, 2)[2] if "now" in line else line.split("  ")[-1]
                      for line in result.stdout.splitlines()]
            self.assertEqual(titles, [f"Conversation {offset}." for offset in range(10)])

    def test_titles_prefer_the_user_name_and_fall_back_to_the_first_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            sessions = root / ".claude" / "projects" / project_name(root)
            sessions.mkdir(parents=True)
            now = time.time()
            (sessions / "renamed.jsonl").write_text(
                prompt("first words", now - 60, root) + "\n"
                + json.dumps({"type": "ai-title", "aiTitle": "Generated title"}) + "\n"
                + json.dumps({"type": "custom-title", "customTitle": "Renamed by me"}) + "\n"
                + json.dumps({"type": "ai-title", "aiTitle": "Later generated title"}) + "\n"
            )
            (sessions / "untitled.jsonl").write_text(
                prompt([{"type": "text", "text": "Fix the\x1b[31m login\nbug " + "x" * 200}], now - 7200, root) + "\n"
                + prompt("a later prompt", now - 3700, root) + "\n"
            )
            (sessions / "summary.jsonl").write_text(
                json.dumps({"type": "summary", "summary": "Older summary title"}) + "\n"
                + prompt("hello", now - 90000, root) + "\n"
            )

            result = run(root, root)

            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 3)
            self.assertRegex(lines[0], r"^claude\s+1m\s+Renamed by me$")
            self.assertRegex(lines[1], r"^claude\s+1h\s+Fix the \[31m login bug x+…$")
            self.assertLessEqual(len(lines[1].split(None, 2)[2]), 100)
            self.assertRegex(lines[2], r"^claude\s+1d 1h\s+Older summary title$")

    def test_tolerates_a_record_still_being_written_but_not_a_malformed_one(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            sessions = root / ".claude" / "projects" / project_name(root)
            sessions.mkdir(parents=True)
            transcript = sessions / "live.jsonl"
            complete = prompt("Readable", time.time(), root) + "\n"
            transcript.write_text(complete + '{"type":"user","message":{"role":"user","content":"half')

            result = run(root, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Readable", result.stdout)

            transcript.write_text(complete + '{"type":"user", broken}\n')
            result = run(root, root)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Invalid JSON", result.stderr)
            self.assertIn("line 2", result.stderr)

    def test_reports_no_profiles_and_no_conversations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            result = run(root, root)
            self.assertEqual(result.returncode, 1)
            self.assertIn("No Claude Code profiles found", result.stderr)

            (root / ".claude" / "projects").mkdir(parents=True)
            result = run(root, root)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No Claude Code conversations found", result.stdout)

    def test_long_paths_match_the_truncated_folder_by_saved_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            project = root / ("a" * 120) / ("b" * 120)
            sibling = root / ("a" * 120) / ("b" * 120 + "c")
            project.mkdir(parents=True)
            sibling.mkdir(parents=True)
            projects = root / ".claude" / "projects"
            prefix = project_name(project)[:200]
            self.assertEqual(prefix, project_name(sibling)[:200])
            for directory, cwd, title in ((f"{prefix}-1abc", project, "Mine"), (f"{prefix}-2def", sibling, "Sibling")):
                (projects / directory).mkdir(parents=True)
                (projects / directory / "s.jsonl").write_text(prompt(title, time.time(), cwd) + "\n")

            result = run(project, root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Mine", result.stdout)
            self.assertNotIn("Sibling", result.stdout)


if __name__ == "__main__":
    unittest.main()
