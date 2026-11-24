# Set up CodexMeter with several Claude accounts

This guide is for developers who use more than one Claude account in Claude
Code, for example a work account and a personal one. At the end you will have:

- one shell command per account, such as `claude-work` and `claude-personal`;
- CodexMeter in the menu bar, showing each account's five-hour, weekly and
  per-model limits;
- a **Recent chats** list that copies a conversation to another account in one
  click, so you can continue it when one account runs out;
- `claude-who`, which lists recent conversations for the current project across
  accounts, and `claude-accounts`, which shows who each account is signed in as.

Codex accounts work alongside Claude accounts. This guide covers Claude only.

## 1. Check the requirements

- macOS 14 or newer.
- Swift 6.2 or newer, from Xcode 26 or its Command Line Tools. Check with
  `swift --version`; install the tools with `xcode-select --install`.
- Claude Code 2.1.261 or newer. Check with `claude --version` and update with
  `claude update`. CodexMeter looks for it at `~/.local/bin/claude`,
  `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` or
  `~/.claude/local/claude`.
- Python 3.10 or newer for the command-line helpers.

## 2. Install

```zsh
git clone <this repository> CodexMeter
cd CodexMeter
./Scripts/install.sh
```

The script builds the app, installs it as `~/Applications/CodexMeter.app`,
links `claude-who`, `claude-accounts` and `codex-who` into `~/.local/bin`, and
opens the app. If it says `~/.local/bin` is not on your `PATH`, add the line it
prints to `~/.zshrc`.

To start CodexMeter when you log in, turn on **Open at login** in its
settings menu (the gear at the bottom of the dashboard).

## 3. Add your Claude accounts

Each account is its own configuration directory. `~/.claude` is the account
the plain `claude` command uses. Every other account lives in
`~/.claude-<name>` and opens with a `claude-<name>` alias.

```zsh
claude-accounts add work
source ~/.zshrc
claude-work
```

In the new session, sign in with `/login` using the work account, then quit.
Repeat for each account. The **+** button at the bottom of the dashboard does
the same from the app: it asks for a name, creates the account and opens
Terminal there to sign in. Then check them all:

```zsh
claude-accounts
```

```text
Claude Code 2.1.331 at /Users/you/.local/bin/claude

ACCOUNT      OPEN WITH    SIGNED IN AS                    CHATS
claude       claude       you@example.com (claude.ai)     42
claude-work  claude-work  you@company.com (claude.ai)     7
```

Restart CodexMeter after adding an account with `claude-accounts`: it finds
accounts when it starts. An account added with **+** appears at once. Each
account box shows the email it is signed in as.

## 4. Use it

**The menu bar.** The gauge shows the lowest limit left across all accounts.
Click it to open the dashboard. Each Claude account has up to three rings:

- **5H**: the five-hour session limit, when the plan has one;
- **WEEK**: the weekly limit across all models;
- a model name, such as **FABLE**: the tightest weekly limit for a single
  model, when the plan has one in use.

The number is the share left; the outer ring and the label below show the time
until the reset. **idle** means the window has not started; the app starts it
with one small request to the smallest model, at most once an hour.

**Move a conversation to another account.** Below the accounts, **Recent
chats** lists the eight newest conversations across accounts. Click
**→ claude-work** on a row to copy that conversation. The original stays where
it is. Then continue it from the same project folder:

```zsh
cd path/to/the/project
claude-work --resume
```

After the copy, the exact command is already on your clipboard: paste it in
a terminal to open the conversation in the other account. The copy button on
each row gives the command for the row's account. The first time an account
opens a project, Claude Code asks whether you trust the folder. A ✓ next to an
account means it already has an identical copy.

**When an account runs low.** An account is low when any of its limits has 10%
or less left. Recent chats then suggests moving that account's chats to the
account with the most room; click **Move**. In the settings menu you can turn
this off or let the app move them on its own, and turn on a notification when
an account becomes low.

To copy the three newest conversations at once, right-click the source account
and then the destination account.

**Rename a conversation.** Double-click its title in Recent chats, or
right-click it and choose **Rename…**, type the new name and press Return.
Claude Code's `/resume` shows the new name too.

**Reconnect an account.** When an account box shows an error instead of its
limits, click **Reconnect** to read it again. If it is still disconnected,
Terminal opens in it so you can sign in again with `/login`; click
**Reconnect** once more afterwards.

**Find a conversation.** In a project folder, run `claude-who` to see the ten
latest conversations there, across accounts, with the account to open.

**Settings.** The gear at the bottom of the dashboard sets whether the app
starts idle windows, how often it refreshes (every 2 minutes by default), the
low-limit notification, what happens to chats on a low account, and whether
the app opens at login.

## 5. Update

```zsh
cd CodexMeter
git pull
./Scripts/install.sh
```

## Troubleshooting

| What you see | What to do |
|---|---|
| "This Claude Code is too old to report usage" | Run `claude update`, then refresh with **⌘R**. |
| "This profile has no Claude plan limits" | The account is signed out or uses an API key. Click **Reconnect** to sign in with a Claude subscription. |
| "Usage is unavailable for now" | Anthropic's usage service is limiting reads for this account, often after many reads in a short time. The box keeps the last reading and the app tries again after 15 minutes; it usually clears within an hour. |
| "Claude Code executable not found" | Install Claude Code in one of the locations in step 1. |
| An account is missing | Check `claude-accounts`: the account must be signed in. Then restart CodexMeter. |
| A copied conversation is not in `/resume` | Open the destination account from the conversation's project folder. The folder column in Recent chats shows which one. |
| A copy fails with "incomplete JSONL record" | Claude Code was still writing to that conversation. Try again a moment later. |

## What the app reads

- Quotas come from Claude Code itself: the app runs `claude` with a usage
  request and no prompt, so a reading uses no quota. It never reads the
  Keychain or any stored credential.
- Recent chats and `claude-who` read conversation files under each account's
  `projects` folder, on your Mac only.
- `claude-accounts` gets sign-in details from `claude auth status`.
