#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
exec "$project_dir/scripts/swift.sh" run CodexBar
