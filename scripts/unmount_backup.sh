#!/bin/bash
# Eject the mounted photo backup. Does not mount it if it is already ejected.
set -euo pipefail
found=""
for vol in /Volumes/Photos /Volumes/Photos\ *; do
  if [ -d "$vol/2015" ] && [ -d "$vol/2024" ] && [ -f "$vol/_missing.txt" ]; then
    found="$vol"
    break
  fi
done
if [ -z "$found" ]; then
  echo "Not mounted"
  exit 0
fi
hdiutil detach "$found"
echo "ejected $found"
