#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/CodexBar.app"
executable_dir="$app_dir/Contents/MacOS"

cd "$project_dir"
"$project_dir/scripts/swift.sh" build -c "$configuration"
binary_path="$("$project_dir/scripts/swift.sh" build -c "$configuration" --show-bin-path)/CodexBar"

mkdir -p "$executable_dir"
cp "$binary_path" "$executable_dir/CodexBar"

plist_path="$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$plist_path" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string CodexBar" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.local.CodexBar" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string CodexBar" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.0" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist_path"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
