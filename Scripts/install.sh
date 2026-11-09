#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -x "$project_root/build/zwiftshift" || ! -d "$project_root/build/ZwiftShift.app" ]]; then
  "$project_root/Scripts/build.sh"
fi
install_link() {
  local source_path="$1" target_path="$2"
  if [[ -L "$target_path" && "$(readlink "$target_path")" == "$source_path" ]]; then return; fi
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    echo "Preserving existing $target_path; move it aside before installing." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$target_path")"
  ln -s "$source_path" "$target_path"
}
install_link "$project_root/build/zwiftshift" "$HOME/.local/bin/zwiftshift"
install_link "$project_root/build/ZwiftShift.app" "$HOME/Applications/ZwiftShift.app"
echo "Installed ZwiftShift in ~/Applications and zwiftshift in ~/.local/bin."
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo 'Add ~/.local/bin to PATH to run zwiftshift by name.' ;; esac
