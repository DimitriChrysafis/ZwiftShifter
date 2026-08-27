#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/build/ZwiftShifter.app"
CONTENTS="$APP/Contents"
BIN=$(swift build --package-path "$ROOT" --configuration release --product ZwiftShifter --show-bin-path)

swift build --package-path "$ROOT" --configuration release --product ZwiftShifter
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/ZwiftShifter" "$CONTENTS/MacOS/ZwiftShifter"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
xcrun clang -fobjc-arc -dynamiclib -arch arm64 -mmacosx-version-min=14.0 -framework Foundation "$ROOT/Sources/ZwiftShifterBridge/ZwiftShiftBridge.m" -o "$CONTENTS/Resources/ZwiftShiftBridge.dylib"
codesign --force --sign - "$CONTENTS/Resources/ZwiftShiftBridge.dylib"
codesign --force --deep --sign - "$APP"
printf '%s\n' "$APP"
