#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$project_root/build/ZwiftShift.app" ]]; then "$project_root/Scripts/build.sh"; fi
open "$project_root/build/ZwiftShift.app"
