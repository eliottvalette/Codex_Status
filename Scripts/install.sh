#!/bin/zsh

# Builds CodexMeter, installs it in ~/Applications, links the command-line helpers into
# ~/.local/bin, and opens the app. Run it again after `git pull` to update.

set -euo pipefail

project_root="${0:A:h:h}"
applications="$HOME/Applications"
installed_app="$applications/CodexMeter.app"
bin_directory="$HOME/.local/bin"
open_app=true

for argument in "$@"; do
    case "$argument" in
        --no-open) open_app=false ;;
        *)
            print -u2 "usage: Scripts/install.sh [--no-open]"
            exit 2
            ;;
    esac
done

"$project_root/Scripts/build_app.sh"

# Quit a running copy so the new build replaces it.
if pgrep -x CodexMeter >/dev/null; then
    pkill -x CodexMeter || true
    sleep 1
fi
mkdir -p "$applications"
rm -rf "$installed_app"
cp -R "$project_root/dist/CodexMeter.app" "$installed_app"
print "Installed $installed_app"

mkdir -p "$bin_directory"
for command in codex-who claude-who claude-accounts; do
    target="$bin_directory/$command"
    if [[ -e "$target" && ! -L "$target" ]]; then
        print -u2 "Skipped $target: a file that is not a link is already there."
        continue
    fi
    ln -sfn "$project_root/bin/$command" "$target"
    print "Linked $target"
done

if [[ ":$PATH:" != *":$bin_directory:"* ]]; then
    print "\nAdd ~/.local/bin to your PATH, for example in ~/.zshrc:"
    print "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

print "\nTo start CodexMeter when you log in, add it in System Settings > General > Login Items."
if $open_app; then
    open "$installed_app"
fi
