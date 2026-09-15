#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/dist/CodexMeter.app"
contents_path="$app_path/Contents"

cd "$project_root"
swift build -c release
binary_path="$(swift build -c release --show-bin-path)/CodexMeter"

if [[ ! -x "$binary_path" ]]; then
    print -u2 "Release executable not found at $binary_path"
    exit 1
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/CodexMeter"
cp "$project_root/Resources/Info.plist" "$contents_path/Info.plist"
codesign --force --deep --sign - "$app_path"

print "Built $app_path"
