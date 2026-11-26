#!/usr/bin/env python3
"""Rebuild a Photos .photoslibrary from this backup.

The media stays in year folders. This script creates the package Photos.app
opens: database and resources come from Photos-library-other.tar, and each
original is placed back at originals/<ZDIRECTORY>/<ZFILENAME>.

On the same APFS volume as the mounted backup, files are cloned (cp -c),
so the restore does not use another 114 GB. The default destination is
inside the mounted backup for that reason. The internal disk on this Mac
does not have room for a second full copy.

Usage:
  python3 restore_photos_library.py
  python3 restore_photos_library.py --dest ~/Pictures/Restored.photoslibrary
  python3 restore_photos_library.py --dry-run
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

os.environ["COPYFILE_DISABLE"] = "1"
ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "manifest.jsonl"
ARCHIVE = ROOT / "Photos-library-other.tar"


def mount_point():
    script = Path(__file__).resolve().parent / "mount_backup.sh"
    out = subprocess.check_output(["bash", str(script)], text=True).strip().splitlines()
    return Path(out[-1])


def same_device(a: Path, b: Path) -> bool:
    return a.stat().st_dev == b.stat().st_dev


def place(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.stat().st_size == src.stat().st_size:
        return
    if dst.exists():
        dst.unlink()
    if same_device(src, dst.parent):
        result = subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True)
        if result.returncode == 0 and dst.exists():
            return
    subprocess.check_call(["cp", str(src), str(dst)])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dest", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not MANIFEST.exists() or not ARCHIVE.exists():
        raise SystemExit(f"Need {MANIFEST} and {ARCHIVE}")
    media = mount_point()
    dest = args.dest or (media / "Restored Photos Library.photoslibrary")
    records = []
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.strip():
            records.append(json.loads(line))
    print(f"manifest {len(records)} files")
    print(f"media    {media}")
    print(f"dest     {dest}")
    if args.dry_run:
        missing = 0
        for rec in records[:20]:
            src = media / rec["year"] / rec["name"]
            print(("OK" if src.exists() else "MISSING"), src)
            missing += not src.exists()
        print(f"checked 20, missing {missing}")
        return
    dest.mkdir(parents=True, exist_ok=True)
    print("extracting database and resources...")
    subprocess.check_call(["tar", "-xf", str(ARCHIVE), "-C", str(dest)])
    done = 0
    for rec in records:
        src = media / rec["year"] / rec["name"]
        if not src.exists():
            print("missing", src, file=sys.stderr)
            continue
        dst = dest / "originals" / rec["directory"] / rec["filename"]
        place(src, dst)
        done += 1
        if done % 500 == 0:
            print(f"{done}/{len(records)}", flush=True)
    print(f"restored {done} originals into {dest}")
    print("Open in Photos with:")
    print(f'  open -a Photos "{dest}"')


if __name__ == "__main__":
    main()
