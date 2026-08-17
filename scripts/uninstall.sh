#!/bin/zsh
set -euo pipefail

installed_app="$HOME/Applications/CodexBar.app"
launch_agent="$HOME/Library/LaunchAgents/com.local.CodexBar.plist"

launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true
if [[ -e "$launch_agent" ]]; then
    mv "$launch_agent" "$HOME/.Trash/com.local.CodexBar.plist"
fi
if [[ -e "$installed_app" ]]; then
    mv "$installed_app" "$HOME/.Trash/CodexBar.app"
fi

echo "CodexBar 已移到废纸篓"
