#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration=release
if [[ "${1:-}" == "--debug" ]]; then configuration=debug; fi
if [[ $# -gt 1 || ($# -eq 1 && "${1:-}" != "--debug") ]]; then
  echo "Usage: Scripts/build.sh [--debug]" >&2
  exit 2
fi
swift build --package-path "$project_root" -c "$configuration"
binary_dir="$(swift build --package-path "$project_root" -c "$configuration" --show-bin-path)"
app_dir="$project_root/build/ZwiftShift.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
swift "$project_root/Scripts/make_icon.swift" "$project_root/build/AppIcon.iconset"
iconutil -c icns "$project_root/build/AppIcon.iconset" -o "$project_root/build/AppIcon.icns"
install -m 755 "$binary_dir/ZwiftShiftApp" "$app_dir/Contents/MacOS/ZwiftShiftApp"
install -m 755 "$binary_dir/zwiftshift" "$project_root/build/zwiftshift"
install -m 755 "$binary_dir/zwiftshift" "$app_dir/Contents/Helpers/zwiftshift"
resource_bundle="$binary_dir/ZwiftShift_ZwiftShiftCore.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  echo "Missing Swift package resource bundle: $resource_bundle" >&2
  exit 1
fi
ditto "$resource_bundle" "$app_dir/Contents/Resources/ZwiftShift_ZwiftShiftCore.bundle"
ditto "$resource_bundle" "$project_root/build/ZwiftShift_ZwiftShiftCore.bundle"
plist="$app_dir/Contents/Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleName -string ZwiftShift "$plist"
plutil -insert CFBundleDisplayName -string ZwiftShift "$plist"
plutil -insert CFBundleIdentifier -string dev.dimitri.zwiftshift "$plist"
plutil -insert CFBundleExecutable -string ZwiftShiftApp "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
plutil -insert CFBundleShortVersionString -string 1.0.0 "$plist"
plutil -insert CFBundleVersion -string 1 "$plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$plist"
plutil -insert NSPrincipalClass -string NSApplication "$plist"
plutil -insert NSHighResolutionCapable -bool true "$plist"
plutil -insert NSLocalNetworkUsageDescription -string 'ZwiftShift advertises a software shifting controller for Zwift running on this Mac.' "$plist"
plutil -insert NSBonjourServices -json '["_wahoo-fitness-tnp._tcp."]' "$plist"
if [[ -f "$project_root/build/AppIcon.icns" ]]; then
  cp "$project_root/build/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
  plutil -insert CFBundleIconFile -string AppIcon "$plist"
fi
codesign --force --sign - "$app_dir/Contents/Helpers/zwiftshift"
codesign --force --sign - "$app_dir"
echo "Built $app_dir"
echo "CLI: $project_root/build/zwiftshift"
