# CodexMeter

CodexMeter tracks Codex and Claude Code usage across local profiles in the macOS
menu bar and copies recent conversations between profiles. The companion
`codex-who` and `claude-who` commands show recent conversations for the current
project.

## For humans

### Use multiple Codex accounts

Each alias is a short command for a separate Codex account and its conversation
history. For example, run `codex-work` to start a session on the work account
or `codex-personal` to use the personal account. An agent can set up
aliases with the names you choose and guide you through sign-in.

### Use multiple Claude accounts

Claude Code works the same way. Each alias, such as `claude-work` or
`claude-personal`, opens Claude Code with its own sign-in, settings, and
conversation history. The regular `claude` command keeps the account it
already has.

### Find a recent conversation

Run `codex-who` from the project folder whenever you need to find a thread.
It shows up to ten recent conversations for that folder across your local
profiles, with the alias, title, and time since your last message. Each row
uses the account's color, so you can see which alias to open and use
`/resume` to pick up the conversation.

Run `claude-who` for the same list of Claude Code conversations.

### Track quotas and reset times

The gauge in the macOS menu bar shows the lowest quota remaining and names
the provider it belongs to. Click it to see each account's quota and the time
until its next reset, when the provider reports one. Claude accounts appear
below the Codex accounts, two to a row, each with its five-hour and weekly
quota. When a plan also limits a single model each week, such as
"Weekly · Fable" in Claude's usage panel, a third ring shows the tightest of
those limits, and the menu bar figure counts it.

- **Automatic refresh.** Quotas update when the app opens, when the Mac wakes
  from sleep, and about every two minutes while the app runs. Use the refresh
  button or press **⌘R** to update on demand. A warning marks old quota data
  if a refresh fails.
- **Automatic activation.** When a refresh detects an idle quota window,
  the app can send a short background request to start the window and
  check for a reset time. The request runs in a temporary conversation
  and can use a small amount of quota. For a Claude account, the request
  goes to the smallest model, at most once an hour.

### Continue a conversation on another account

To switch accounts and keep the context, right-click the source account in
the dashboard, then right-click the destination account. The second click
starts the copy immediately. Up to three recent conversations are copied,
and the originals remain available.

Check the result at the bottom of the dashboard, then open Codex with the
destination alias and use `/resume` to continue. To cancel before choosing a
destination, left-click any account or press **Escape**.

Conversations move between accounts of the same provider: Codex to Codex, or
Claude to Claude. Open Claude Code from the same project folder to find a
copied conversation in `/resume`.

With two or more Claude accounts, **Recent chats** below the accounts lists
the eight newest Claude conversations across them, with the account, the time
since your last message, the title, and the project folder. Click
**→ account** on a row to copy that one conversation; with three or more
accounts, choose the destination from **Copy to…**. A conversation that
already has an identical copy on another account is listed once, with a ✓
next to that account.

### Sync recent conversations across accounts

Click the two arrows at the bottom of the dashboard to share conversations
active in the last 10 days across the configured accounts. Open a destination
alias in the project and use `/resume` to pick up a conversation. If the same
conversation has different histories on two accounts, the sync reports the
conflict, keeps both copies, and continues with other conversations. When
Codex filters a copied conversation out of the destination account's
`/resume` list, CodexMeter creates a branch under that account with the
original conversation's last-message time.

## For agents

If you are an agent, ask the user to read the [For humans](#for-humans) section.

### Configure shell aliases

A profile is a directory selected through `CODEX_HOME`. Use a different directory
for each account. For example, add these aliases to `~/.zshrc`:

```zsh
alias codex-work='CODEX_HOME="$HOME/.codex-work" codex'
alias codex-personal='CODEX_HOME="$HOME/.codex-personal" codex'
```

Reload the shell configuration, sign in with the intended account for each
profile, and check the sign-in status:

```zsh
source ~/.zshrc
codex-work login
codex-personal login
codex-work login status
codex-personal login status
```

With `CODEX_HOME` unset, the regular `codex` command uses `~/.codex`.
Run an alias such as `codex-work` from a project directory to start a
conversation under that profile.

A Claude Code profile is a directory selected through `CLAUDE_CONFIG_DIR`.
Name each directory `~/.claude-<name>` so the app and `claude-who` can find it:

```zsh
alias claude-work='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'
alias claude-personal='CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude'
```

Reload the shell configuration, then run each alias once and sign in with
`/login`. Check the sign-in status:

```zsh
claude-work auth status
claude-personal auth status
```

With `CLAUDE_CONFIG_DIR` unset, the regular `claude` command uses `~/.claude`.

### Install `codex-who` and `claude-who`

From the repository root, install the commands and add their directory to your
shell's `PATH`. The commands require Python 3.10 or newer.

```zsh
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/bin/codex-who" "$HOME/.local/bin/codex-who"
ln -s "$PWD/bin/claude-who" "$HOME/.local/bin/claude-who"
```

If needed, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and run
`source ~/.zshrc`.

Use the conversation's exact saved working directory. Set `NO_COLOR=1` for
plain text. Terminal rows are bold and colored by profile.

### Build and configure the menu bar app

The menu bar app requires macOS 14 or newer, Xcode 26 or newer with Swift 6.2,
and an executable Codex CLI at `/opt/homebrew/bin/codex`. Claude accounts
require Claude Code 2.1.261 or newer (tested with 2.1.331) at
`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`,
or `~/.claude/local/claude`. An older version cannot report usage, and the
account's box says so. Run `claude update` to update it.

The app uses a fixed profile list in
[Models.swift](Sources/CodexMeter/Models.swift). To use different aliases in
the app, update each relevant entry's `id`, `displayName`, and directory name
to match the shell aliases. The dashboard displays up to four profiles in the order listed.
`codex-who` discovers profiles independently and needs no source changes.

Claude profiles need no source changes. At launch the app adds `~/.claude` and
every `~/.claude-*` directory that contains `projects` or `.claude.json`. When
it finds Claude profiles and none of the Codex directories exist, it leaves
the Codex accounts out. To stop the app from starting idle Claude windows, set
`automaticActivation` to `false` in
[ClaudeProfiles.swift](Sources/CodexMeter/ClaudeProfiles.swift).

From the repository root, build and open the app:

```zsh
./Scripts/build_app.sh
open dist/CodexMeter.app
```

### Implementation notes

- **Profiles and activity.** The app uses its compiled profile list.
  `codex-who` independently discovers `~/.codex*` directories containing
  `state_5.sqlite` and queries their thread indexes in read-only mode. It
  sorts by the last user message in each rollout. Missing indexed rollout
  files are skipped. Other read failures and malformed records are errors.
- **Usage status.** Each refresh starts `codex app-server` with the target
  `CODEX_HOME` and calls `account/rateLimits/read` for the main `codex`
  bucket. Profile SQLite indexes supply recent activity. Quota values come
  from App Server.
- **Automatic activation.** Launch and wake request an activation cycle.
  Any refresh that finds a dormant or unconfirmed zero-usage window can also
  trigger one. For an unconfirmed window, the app takes a second quota reading
  after six seconds before classifying it. For a dormant window, it sends a
  turn in an ephemeral App Server thread and checks the quota again after
  activation.
- **Transfer behavior.** The app validates JSONL rollouts and recursively
  includes dependencies referenced by `forked_from_id` and
  `history_base.thread_id`, including segments absent from the thread index.
  Eligible replacements are atomic. Identical and newer destination
  conversations are skipped. Divergent histories are compared by user request
  timestamps. Missing dependencies are repaired even if the final rollout
  already exists. App Server indexes new or repaired conversations for
  `/resume`, and failures appear in the dashboard footer.

- **Claude profiles and activity.** A profile's conversations are the
  transcripts at `projects/<project>/<session-id>.jsonl`, where `<project>`
  is the working directory with every character outside `A-Z`, `a-z`, and
  `0-9` replaced by a hyphen. Subagent transcripts are ignored. `claude-who`
  reads the folder for the current directory in every `~/.claude*` profile
  and sorts by the last message the user typed. A record still being written
  is skipped. A malformed record is an error.
- **Claude usage status.** Each refresh starts `claude --print` in stream-JSON
  mode with the profile's `CLAUDE_CONFIG_DIR` and sends one `get_usage`
  control request. Claude Code answers with the five-hour and weekly
  utilization of the signed-in plan. No prompt is sent, so the read uses no
  quota, and the app never reads the stored credentials. The run saves no
  session and loads no hooks, MCP servers, skills, or tools. The default
  `~/.claude` profile runs with `CLAUDE_CONFIG_DIR` unset, because Claude Code
  ties its sign-in to that variable. Claude Code marks `get_usage` as
  experimental, so a later version may change the response. The request
  and its `skip_behaviors` option first appear together in 2.1.261; 2.1.112
  answers `Unsupported control request subtype`.
- **Claude automatic activation.** A window with no reset time is idle. The
  app then runs `claude --print "Reply exactly OK." --model haiku` once and
  reads the quota again. It waits an hour before it tries the same profile
  again.
- **Claude recent chats.** The list reads the transcripts of every Claude
  profile, newest first, and sorts them by the last message the user typed, as
  `claude-who` does. The title is the custom title, then the AI title, then the
  summary, then the first prompt. A transcript is read again only when its
  modification time or size changes. Only lines whose record type, written near
  the start of the line, marks a title or a prompt are parsed; tool results,
  most of a long transcript, are skipped unparsed. A copy counts as identical
  when its size and modification time match the original's.
- **Claude transfer behavior.** The app copies the three most recently changed
  conversations, or the one chosen in Recent chats, to the same
  `projects/<project>/` path in the destination and keeps their modification
  times. Claude Code lists conversations by reading
  that folder, so no indexing step follows. Replacement, skipping, and
  divergent histories follow the Codex rules above. Subagent transcripts and
  saved tool output stay in the source profile.

Run the checks from the repository root:

```sh
swift test
python3 -B -m unittest discover -s Tests/CodexWhoTests
python3 -B -m unittest discover -s Tests/ClaudeWhoTests
```
