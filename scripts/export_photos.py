#!/usr/bin/env python3
"""Repeat the export from a Photos library to year folders plus one tar.

This is the same naming and date rule that produced the files already in
the mounted backup. It reads the library and writes copies. It does not
modify the source library.

Example, after the empty sparse bundle is mounted at /Volumes/Photos:

  python3 export_photos.py \
    --library "$HOME/Pictures/Photos Library.photoslibrary" \
    --media /Volumes/Photos \
    --archive /Volumes/Transcend/PhotoBackup/Photos-library-other.tar
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from photos_lib import SMALL_DIRS, connect, load_assets

os.environ["COPYFILE_DISABLE"] = "1"


def copy_file(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.stat().st_size == src.stat().st_size:
        return
    with src.open("rb") as s, dst.open("wb") as d:
        while True:
            buf = s.read(8 * 1024 * 1024)
            if not buf:
                break
            d.write(buf)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    db = args.library / "database" / "Photos.sqlite"
    conn = connect(db)
    items, missing = load_assets(conn, args.library)
    conn.close()
    manifest = args.archive.parent / "manifest.jsonl"
    with manifest.open("w", encoding="utf-8") as handle:
        for item in items:
            row = {key: item[key] for key in (
                "year", "name", "directory", "filename", "uuid", "kind", "size", "created",
            )}
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    (args.archive.parent / "missing.txt").write_text(
        "\n".join(f"{m['year']}\t{m['name']}\t{m['source']}" for m in missing) + ("\n" if missing else ""),
        encoding="utf-8",
    )
    print(f"manifest {manifest}")
    items.sort(key=lambda item: (item["year"], item["name"].lower()))
    print(f"{len(items)} files, {len(missing)} missing from the library")
    for item in items:
        src = Path(item["source"])
        dst = args.media / item["year"] / item["name"]
        copy_file(src, dst)
        if item["created"]:
            try:
                os.utime(dst, (item["created"], item["created"]))
            except OSError:
                pass
    (args.media / "_missing.txt").write_text(
        "\n".join(f"{m['year']}\t{m['name']}\t{m['source']}" for m in missing),
        encoding="utf-8",
    )
    if args.archive.exists():
        args.archive.unlink()
    subprocess.check_call(
        ["tar", "-cf", str(args.archive), "-C", str(args.library), *SMALL_DIRS],
        env={**os.environ, "COPYFILE_DISABLE": "1"},
    )
    print(f"archive {args.archive}")


if __name__ == "__main__":
    main()
