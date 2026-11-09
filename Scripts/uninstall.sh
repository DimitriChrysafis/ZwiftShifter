#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remove_link() {
  local source_path="$1" target_path="$2"
  if [[ -L "$target_path" && "$(readlink "$target_path")" == "$source_path" ]]; then
    rm "$target_path"
    echo "Removed $target_path"
  fi
}
remove_link "$project_root/build/zwiftshift" "$HOME/.local/bin/zwiftshift"
remove_link "$project_root/build/ZwiftShift.app" "$HOME/Applications/ZwiftShift.app"
echo 'Quit ZwiftShift to stop its local service. Project files, settings, and backups are preserved.'
