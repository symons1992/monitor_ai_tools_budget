#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
module_cache="$project_dir/.build/module-cache"
sdk_root="${CODEXBAR_SDKROOT:-}"

if [[ -z "$sdk_root" ]]; then
    sdk_root="$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d -name 'MacOSX*.sdk' 2>/dev/null | sort -V | head -n 1)"
fi
if [[ -z "$sdk_root" ]]; then
    sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$module_cache"
cd "$project_dir"
swift_command="${1:?请指定 Swift 子命令，例如 build 或 run}"
shift
env \
    SDKROOT="$sdk_root" \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift "$swift_command" --disable-sandbox "$@"
