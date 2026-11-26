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

# An attached image can lose the Photos volume. Mount that volume. If it
# will not mount, eject the image and attach it again.
python3 - "$BUNDLE" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

bundle = Path(sys.argv[1]).resolve()
apfs = "41504653-0000-11AA-AA11-00306543ECAC"

def backup(path):
    vol = Path(path)
    return (vol / "2015").is_dir() and (vol / "2024").is_dir() and (vol / "_missing.txt").is_file()

def mounted():
    root = Path("/Volumes")
    if not root.is_dir():
        return None
    for vol in root.iterdir():
        if backup(vol):
            return vol
    return None

def entities():
    raw = subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"])
    for image in plistlib.loads(raw).get("images", []):
        path = image.get("image-path")
        if path and Path(path).resolve() == bundle:
            return image.get("system-entities", [])
    return None

def publish(path):
    print(path)
    raise SystemExit(0)

found = entities()
if found is not None:
    for ent in found:
        point = ent.get("mount-point")
        if point and backup(point):
            publish(point)
    for ent in found:
        dev = ent.get("dev-entry")
        if ent.get("content-hint") == apfs and dev:
            subprocess.run(["/usr/sbin/diskutil", "mount", dev], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            point = mounted()
            if point:
                publish(point)
    for ent in found:
        dev = ent.get("dev-entry")
        if ent.get("content-hint") == "GUID_partition_scheme" and dev:
            subprocess.run(["/usr/sbin/diskutil", "eject", dev], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

subprocess.check_call(
    ["/usr/sbin/diskutil", "image", "--plist", "attach", str(bundle)],
    stdout=subprocess.DEVNULL,
)
point = mounted()
if point is None:
    raise SystemExit("attach succeeded but the Photos volume is not mounted")
print(point)
PY
