"""Shared rules for the Photos backup.

The year-folder names on disk were produced by load_assets() with no ORDER BY.
Do not sort the SQL rows. A different order changes _2, _3 suffixes.
"""

import sqlite3
import time
from pathlib import Path
from urllib.parse import quote

CORE_DATA_EPOCH = 978307200
SMALL_DIRS = ("database", "resources", "private", "scopes", "internal", "external")
ILLEGAL = set('\\/:*?"<>|')


def clean_name(name):
    cleaned = "".join("_" if ch in ILLEGAL or ord(ch) < 32 else ch for ch in (name or ""))
    cleaned = cleaned.strip().rstrip(".")
    if len(cleaned) > 240:
        stem = Path(cleaned).stem[:200]
        cleaned = stem + Path(cleaned).suffix[:20]
    return cleaned or "untitled"


def connect(db: Path):
    uri = "file:" + quote(str(db), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def load_assets(conn, library: Path):
    """Return (items, missing). items match the files copied into year folders."""
    rows = conn.execute(
        """
        SELECT z.ZDIRECTORY, z.ZFILENAME, z.ZKIND, z.ZUUID, z.ZDATECREATED,
               a.ZORIGINALFILENAME, a.ZTIMEZONEOFFSET
        FROM ZASSET z
        LEFT JOIN ZADDITIONALASSETATTRIBUTES a
          ON a.Z_PK = z.ZADDITIONALATTRIBUTES
        WHERE z.ZTRASHEDSTATE = 0
          AND z.ZFILENAME IS NOT NULL
          AND z.ZDIRECTORY IS NOT NULL
        """
    ).fetchall()
    items = []
    missing = []
    used = {}
    originals = library / "originals"
    for directory, filename, kind, uuid, created, original_name, tz in rows:
        src = originals / directory / filename
        if created is None:
            year = "unknown"
            local_unix = None
        else:
            offset = tz if tz is not None else 0
            local_unix = float(created) + CORE_DATA_EPOCH + offset
            year = time.strftime("%Y", time.gmtime(local_unix))
        raw_name = clean_name(original_name or filename or uuid or "untitled")
        key = (year, raw_name.lower())
        name = raw_name
        if key in used:
            stem = Path(raw_name).stem
            ext = Path(raw_name).suffix
            n = 2
            while (year, f"{stem}_{n}{ext}".lower()) in used:
                n += 1
            name = f"{stem}_{n}{ext}"
            key = (year, name.lower())
        used[key] = True
        try:
            size = src.stat().st_size
        except OSError:
            missing.append({"year": year, "name": name, "source": str(src)})
            continue
        items.append(
            {
                "year": year,
                "name": name,
                "directory": directory,
                "filename": filename,
                "uuid": uuid,
                "kind": "video" if kind == 1 else "photo",
                "size": size,
                "created": local_unix,
                "source": str(src),
            }
        )
    return items, missing
