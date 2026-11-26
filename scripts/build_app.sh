#!/bin/bash
# Build Photo Backup.app from app/PhotoBackup.swift into this folder.
# The binary is linked against the same system frameworks Photos uses to
# show a file: QuickLookThumbnailing, AppKit/ImageIO, and AVKit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
STAGE="$WORK/Photo Backup.app"
mkdir -p "$STAGE/Contents/MacOS"
cp "$ROOT/app/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
# Table sort is an M-series NEON radix (ArmSort.c), not a Swift comparator.
clang -O3 -mcpu=apple-m1 -std=c11 -target arm64-apple-macos14.0 \
  -c "$ROOT/app/ArmSort.c" -o "$WORK/ArmSort.o"
swiftc -parse-as-library -O -target arm64-apple-macos14.0 \
  -import-objc-header "$ROOT/app/ArmSort.h" \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation \
  -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers \
  -lsqlite3 \
  "$ROOT"/app/*.swift \
  "$WORK/ArmSort.o" \
  -o "$STAGE/Contents/MacOS/PhotoBackup"
codesign --force --sign - "$STAGE"
export COPYFILE_DISABLE=1
rm -rf "$ROOT/Photo Backup.app"
ditto "$STAGE" "$ROOT/Photo Backup.app"
if ! codesign --verify "$ROOT/Photo Backup.app"; then
  codesign --force --sign - "$ROOT/Photo Backup.app"
fi
rm -rf "$WORK"
echo "$ROOT/Photo Backup.app"
