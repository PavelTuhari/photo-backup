#!/bin/bash
# Mount the APFS sparse bundle that holds the year folders.
# Prints the mount point. Safe to run when the volume is already mounted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/Photos.sparsebundle"
if [ ! -d "$BUNDLE" ]; then
  echo "Bundle not found: $BUNDLE" >&2
  exit 1
fi

# Already mounted if this backup's year folders are visible.
for vol in /Volumes/Photos /Volumes/Photos\ *; do
  if [ -d "$vol/2015" ] && [ -d "$vol/2024" ] && [ -f "$vol/_missing.txt" ]; then
    echo "$vol"
    exit 0
  fi
done

# hdiutil prints a plist when -plist is set. The mount-point is inside it.
PLIST="$(mktemp)"
hdiutil attach -plist "$BUNDLE" >"$PLIST"
python3 - "$PLIST" <<'PY'
import plistlib, sys
data = plistlib.load(open(sys.argv[1], "rb"))
points = []
for ent in data.get("system-entities", []):
    point = ent.get("mount-point")
    if point:
        points.append(point)
if not points:
    raise SystemExit("attach succeeded but no mount-point was returned")
print(points[-1])
PY
rm -f "$PLIST"
