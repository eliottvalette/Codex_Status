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

CodexMeter validates every JSONL rollout before copying it, recursively includes
the source rollouts required by forked conversation history, never overwrites a
different destination history, and accepts a destination conversation that has
already continued from the exported history. After copying, it asks Codex App
Server to rebuild the destination history index so the conversations and their
previews are immediately available in `/resume`. A transfer failure remains
visible in the overlay instead of silently falling back.

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

For development, `swift run CodexMeter` also works, but running the packaged
app is recommended because its `Info.plist` enables menu-bar-only behavior.

## Test

```bash
swift test
```

The unit tests validate rate-limit parsing, activity-window classification,
App Server error handling, recent-conversation selection, rollout integrity,
safe re-export, and destination conflict handling.
