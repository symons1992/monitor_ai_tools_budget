#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/dist/CodexBar.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/CodexBar.app"
launch_agents_dir="$HOME/Library/LaunchAgents"
launch_agent="$launch_agents_dir/com.local.CodexBar.plist"

"$project_dir/scripts/package-app.sh" release
mkdir -p "$install_dir"
ditto "$source_app" "$installed_app"

if [[ "${1:-}" == "--login" ]]; then
    mkdir -p "$launch_agents_dir"
    /usr/libexec/PlistBuddy -c "Clear dict" "$launch_agent" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :Label string com.local.CodexBar" "$launch_agent"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$launch_agent"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $installed_app/Contents/MacOS/CodexBar" "$launch_agent"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$launch_agent"
    launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$launch_agent"
else
    open "$installed_app"
fi

echo "CodexBar 已安装到 $installed_app"
