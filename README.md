# CodexMeter

A native macOS menu bar app that displays live Codex usage for multiple local
`CODEX_HOME` profiles.

## Profiles

The initial profile list matches the aliases configured on this Mac:

| Label | `CODEX_HOME` |
| --- | --- |
| `codex` | `~/.codex` |
| `codex-yot` | `~/.codex-yot` |
| `codex-matt` | `~/.codex-matt` |
| `codex-bio` | `~/.codex-bio` |
| `codex-ster` | `~/.codex-ster` |

CodexMeter reads only the main `codex` rate-limit bucket. Model-specific
buckets such as `codex_bengalfox` are deliberately ignored.

## Data source

Each refresh starts a short-lived `codex app-server` process with the matching
`CODEX_HOME` and calls the official `account/rateLimits/read` RPC method. The
app does not parse `auth.json`, copy credentials, or use session logs as a
quota source.

Recent activity is computed separately from each profile's local
`state_5.sqlite` thread index. That database is never used for quota values.

## Conversation transfer

Right-click a profile in the overlay to select it as the source, then
right-click another profile to copy the source profile's three most recently
used, non-archived parent conversations. Right-click the source again or press
Escape to cancel. Transfer state is shown only as a compact footer message.

CodexMeter validates every JSONL rollout before copying it and recursively
includes the source rollouts required by forked and paginated conversation
history (`forked_from_id` and `history_base.thread_id`). History segments are
resolved from rollout files, including segments absent from the thread index. A
conversation already present at the destination is left untouched and skipped,
even when its history has diverged; the other conversations in the batch still
transfer. Missing history segments are copied even when the final rollout is
already present. After copying, CodexMeter asks Codex App Server to index new
or repaired conversations so they and their previews are immediately available in
`/resume`. A transfer failure remains visible in the overlay instead of
silently falling back.

If a refresh fails, the exact error is shown. A previous successful result may
remain visible, but it is explicitly marked stale.

## Requirements

- macOS 14 or newer
- Swift 6.2 / Xcode 26 or newer
- Codex installed at `/opt/homebrew/bin/codex`

## Build the macOS app

```bash
cd /Users/eliottvalette/Documents/Experimentations/Codex_Status
./Scripts/build_app.sh
open dist/CodexMeter.app
```

The generated app has no Dock window. Click the gauge in the menu bar to see
all profiles. It refreshes at launch, every two minutes, and on demand.

## Recent conversations in the terminal

From this repository's root, install the command into a directory on your `PATH`:

```bash
ln -s "$(pwd)/bin/codex-who" "$HOME/.local/bin/codex-who"
```

Run `codex-who` from a project directory. It makes read-only queries against
each local `.codex*` profile's `state_5.sqlite` database and shows up to ten
non-archived parent conversations whose saved working directory exactly
matches the current directory. The age is time since the last user message in
the conversation's local rollout log, so merely reopening a conversation does
not make it appear recent. Entire rows are colored when output goes to a
terminal; `NO_COLOR` disables color.

For development, `swift run CodexMeter` also works, but running the packaged
app is recommended because its `Info.plist` enables menu-bar-only behavior.

## Test

```bash
swift test
```

The unit tests validate rate-limit parsing, activity-window classification,
App Server error handling, recent-conversation selection, rollout integrity,
safe re-export, and destination conflict handling.
