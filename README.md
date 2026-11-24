# CodexMeter

CodexMeter tracks Codex and Claude Code usage across local profiles in the macOS
menu bar and copies recent conversations between profiles. The companion
`codex-who` and `claude-who` commands show recent conversations for the current
project.

## For humans

Setting up several Claude accounts on a Mac? Follow
[docs/setup.md](docs/setup.md) for the whole setup in five steps.

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
  from sleep, and every two minutes while the app runs (see
  [Settings](#settings)). Use the refresh button or press **⌘R** to update on
  demand. A warning marks old quota data if a refresh fails.
- **Automatic activation.** When a refresh detects an idle quota window,
  the app can send a short background request to start the window and
  check for a reset time. The request runs in a temporary conversation
  and can use a small amount of quota. For a Claude account, the request
  goes to the smallest model, at most once an hour, and the settings menu
  can turn it off.
- **Accounts.** Each Claude account shows the email it is signed in as. When
  an account has no current reading, because it is signed out or its usage
  cannot be read, **Reconnect** reads it again at once and, if it is still
  disconnected, opens Terminal in that account so you can sign in again. The **+** button at
  the bottom adds a Claude account: it creates `~/.claude-<name>` and a
  `claude-<name>` alias, then opens Terminal there to sign in.
- **Low limits.** An account is low when any of its limits has 10% or less
  left. The app can notify you once when an account becomes low, naming the
  account of the same provider with the most room left.

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
since your last message, the title, and the project folder; **See more**
shows more. Conversations archived in the Claude desktop app are left out, and
its titles are used. Cloud sessions are not listed: they have no copy on the
Mac. Click
**→ account** on a row to copy that one conversation; with three or more
accounts, choose the destination from **Copy to…**. A conversation that
already has an identical copy on another account is listed once, with a ✓
next to that account. After a copy, the command that resumes the
conversation in the destination is on the clipboard, ready to paste in a
terminal. The copy button on each row puts the command for the row's account
there. The pen next to a title renames the conversation; the new name also
shows in Claude Code's `/resume` and in `claude-who`.

When a Claude account is low, Recent chats suggests moving its chats to the
Claude account with the most room, with a **Move** button. The settings menu
can turn the suggestion off, or have the app move them on its own after each
refresh. Moving copies: the originals stay where they are.

### Settings

The gear at the bottom of the dashboard opens the settings:

- **Start idle Claude windows**: the automatic activation above, on by
  default.
- **Refresh every**: 1, 2 (the default), 5 or 10 minutes.
- **Notify when a limit is low**: off by default. macOS asks for permission
  the first time.
- **Chats on a low Claude account**: off, suggest moving them (the default),
  or move them automatically.
- **Open at login**: adds the app to the login items.

### Sync recent conversations across accounts

Click the two arrows at the bottom of the dashboard to share conversations
active in the last 10 days across the configured Codex accounts. Open a destination
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

### Install `codex-who`, `claude-who` and `claude-accounts`

`./Scripts/install.sh` builds the app, installs it in `~/Applications`, and
links the three commands into `~/.local/bin`. To link them by hand instead,
run this from the repository root and add the directory to your shell's
`PATH`. The commands require Python 3.10 or newer.

```zsh
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/bin/codex-who" "$HOME/.local/bin/codex-who"
ln -s "$PWD/bin/claude-who" "$HOME/.local/bin/claude-who"
ln -s "$PWD/bin/claude-accounts" "$HOME/.local/bin/claude-accounts"
```

`claude-accounts` lists each Claude Code account with its alias, who it is
signed in as (from `claude auth status`), and its number of conversations.
`claude-accounts add work` creates `~/.claude-work` and adds a `claude-work`
alias to `~/.zshrc`.

If needed, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and run
`source ~/.zshrc`.

Use the conversation's exact saved working directory. Set `NO_COLOR=1` for
plain text. Terminal rows are bold and colored by profile.

### Build and configure the menu bar app

The menu bar app requires macOS 14 or newer, Swift 6.2 or newer from Xcode 26 or its Command Line Tools,
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
the Codex accounts out. Behaviour you may want to change, such as starting
idle Claude windows, is in the [settings menu](#settings).

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
  answers `Unsupported control request subtype`. When Anthropic's usage
  service answers 429, Claude Code stops asking for a while and answers with
  no limits. The app then keeps the last reading, says usage is unavailable,
  and does not read that profile again for 15 minutes.
- **Claude automatic activation.** A window with no reset time is idle. The
  app then runs `claude --print "Reply exactly OK." --model haiku` once and
  reads the quota again. It waits an hour before it tries the same profile
  again.
- **Claude accounts.** The email comes from `claude auth status`, read until
  the profile is signed in. Reconnect clears the 15-minute pause and reads
  the profile again. A new account's sign-in runs in Terminal from a
  `.command` file, which needs no automation permission.
- **Claude renames.** A rename appends the record Claude Code writes for
  `/rename`, `{"type":"custom-title",...}`, to the transcript and to each
  identical copy, and gives them the same modification time so they stay
  identical. A transcript whose last record is still being written is left
  alone.
- **Low limits and chat moves.** After each refresh, a profile whose lowest
  window, per-model limits included, is at 10% or less is low. Each profile
  that has just become low is announced once. A chat move takes the lowest
  Claude profile that has chats in Recent chats, and copies those chats that
  the Claude profile with the most room does not already hold identically.
  Settings live in the app's user defaults.
- **Claude recent chats.** The list reads the transcripts of every Claude
  profile, newest first, and sorts them by the last message the user typed, as
  `claude-who` does. The title is the custom title, then the Claude desktop
  app's title, then the AI title, then the summary, then the first prompt. The
  desktop app keeps one file per local Code session under
  `~/Library/Application Support/Claude/claude-code-sessions/`; the app reads
  only `cliSessionId`, `isArchived` and `title` from it, and leaves out
  archived conversations. A transcript is read again only when its
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
python3 -B -m unittest discover -s Tests/ClaudeAccountsTests
```
