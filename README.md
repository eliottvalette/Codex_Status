# CodexMeter

CodexMeter tracks Codex usage across local profiles in the macOS menu bar and
copies recent conversations between profiles. The companion `codex-who` command
shows recent conversations for the current project.

## For humans

### Use multiple Codex accounts

Each alias is a short command for a separate Codex account and its conversation
history. For example, run `codex-work` to start a session on the work account
or `codex-personal` to use the personal account. An agent can set up
aliases with the names you choose and guide you through sign-in.

### Find a recent conversation

Run `codex-who` from the project folder whenever you need to find a thread.
It shows up to ten recent conversations for that folder across your local
profiles, with the alias, title, and time since your last message. Each row
uses the account's color, so you can see which alias to open and use
`/resume` to pick up the conversation.

### Track quotas and reset times

The Codex gauge in the macOS menu bar shows the lowest quota remaining.
Click it to see each account's quota and the time until its next reset,
when Codex provides one.

- **Automatic refresh.** Quotas update when the app opens, when the Mac wakes
  from sleep, and about every two minutes while the app runs. Use the refresh
  button or press **⌘R** to update on demand. A warning marks old quota data
  if a refresh fails.
- **Automatic activation.** When a refresh detects an idle quota window,
  the app can send a short background request to start the window and
  check for a reset time. The request runs in a temporary conversation
  and can use a small amount of quota.

### Continue a conversation on another account

To switch accounts and keep the context, right-click the source account in
the dashboard, then right-click the destination account. The second click
starts the copy immediately. Up to three recent conversations are copied,
and the originals remain available.

Check the result at the bottom of the dashboard, then open Codex with the
destination alias and use `/resume` to continue. To cancel before choosing a
destination, left-click any account or press **Escape**.

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

### Install `codex-who`

From the repository root, install the command and add its directory to your
shell's `PATH`. The command requires Python 3.10 or newer.

```zsh
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/bin/codex-who" "$HOME/.local/bin/codex-who"
```

If needed, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and run
`source ~/.zshrc`.

Use the conversation's exact saved working directory. Set `NO_COLOR=1` for
plain text. Terminal rows are bold and colored by profile.

### Build and configure the menu bar app

The menu bar app requires macOS 14 or newer, Xcode 26 or newer with Swift 6.2,
and an executable Codex CLI at `/opt/homebrew/bin/codex`.

The app uses a fixed profile list in
[Models.swift](Sources/CodexMeter/Models.swift). To use different aliases in
the app, update each relevant entry's `id`, `displayName`, and directory name
to match the shell aliases. Keep the five entries and their order for the
current layout, which places the final two profiles in a shared quadrant.
`codex-who` discovers profiles independently and needs no source changes.

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

Run the checks from the repository root:

```sh
swift test
python3 -B -m unittest discover -s Tests/CodexWhoTests
```
