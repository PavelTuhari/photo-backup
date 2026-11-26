#!/usr/bin/env python3
"""Copy Photos albums into the backup library.sqlite.

Reads the Apple Photos database and manifest.jsonl. Writes albums and
album_files. Does not copy photo or video bytes and does not modify the
Photos library.

User albums are ZGENERICALBUM rows with ZKIND = 2. Membership comes from
Z_34ASSETS. A file is linked only when its ZUUID is in manifest.jsonl and
its year/name path already exists in library.sqlite.

Technical albums are recomputed each run:

- technical:trash        Удалённые     files.trashed_at, not album membership
- technical:favorites    Избранное     ZFAVORITE = 1
- technical:hidden       Скрытые       ZHIDDEN = 1
- technical:videos       Видео         ZASSET.ZKIND = 1
- technical:screenshots  Скриншоты     ZISDETECTEDSCREENSHOT = 1
- technical:selfies      Селфи         ZCAMERACAPTUREDEVICE = 1

Photos trash (ZTRASHEDSTATE = 1) was not part of the original copy. If such
a file is present in the backup, trashed_at is set from ZTRASHEDDATE when
the backup row is not already trashed. Rows the app has already trashed are
left alone.

The backup app must be quit first. library.sqlite uses DELETE journal mode.

    python3 scripts/migrate_albums.py
    python3 scripts/migrate_albums.py --dry-run
"""

import argparse
import json
import sqlite3
import time
from pathlib import Path
from urllib.parse import quote

CORE_DATA_EPOCH = 978307200

TECHNICAL = (
    ("technical:trash", "Удалённые", "trash", 0),
    ("technical:favorites", "Избранное", "favorites", 1),
    ("technical:hidden", "Скрытые", "hidden", 2),
    ("technical:videos", "Видео", "videos", 3),
    ("technical:screenshots", "Скриншоты", "screenshots", 4),
    ("technical:selfies", "Селфи", "selfies", 5),
)


def connect_ro(path: Path):
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def load_manifest(path: Path):
    mapping = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            uuid = item.get("uuid")
            year = item.get("year")
            name = item.get("name")
            if uuid and year and name:
                mapping[uuid] = f"{year}/{name}"
    return mapping


def fetch_members(photos, sql):
    return [row[0] for row in photos.execute(sql) if row[0]]


def ensure_schema(library):
    library.executescript(
        """
        CREATE TABLE IF NOT EXISTS albums (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          uuid TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          technical TEXT NOT NULL DEFAULT '',
          sort_order INTEGER NOT NULL DEFAULT 0,
          source_pk INTEGER,
          created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS album_files (
          album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          added_at REAL NOT NULL,
          PRIMARY KEY (album_id, path)
        );
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """
    )
    columns = {row[1] for row in library.execute("PRAGMA table_info(files)")}
    if "trashed_at" not in columns:
        library.execute("ALTER TABLE files ADD COLUMN trashed_at REAL")
    library.commit()


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Migrate Photos albums into library.sqlite")
    parser.add_argument(
        "--photos-db",
        type=Path,
        default=Path.home() / "Pictures" / "Photos Library.photoslibrary" / "database" / "Photos.sqlite",
    )
    parser.add_argument("--library", type=Path, default=root / "library.sqlite")
    parser.add_argument("--manifest", type=Path, default=root / "manifest.jsonl")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    photos = connect_ro(args.photos_db)
    library = sqlite3.connect(args.library, timeout=30)
    library.row_factory = sqlite3.Row
    library.execute("PRAGMA foreign_keys=ON")
    library.execute("PRAGMA busy_timeout=5000")

    if not args.dry_run:
        ensure_schema(library)
    known = {row[0] for row in library.execute("SELECT path FROM files")}
    def keep(uuids):
        paths = []
        missed = 0
        for uuid in uuids:
            path = manifest.get(uuid)
            if path in known:
                paths.append(path)
            else:
                missed += 1
        return paths, missed

    user_rows = photos.execute(
        """
        SELECT Z_PK, ZUUID, ZTITLE
        FROM ZGENERICALBUM
        WHERE ZKIND=2 AND ZTITLE IS NOT NULL AND IFNULL(ZTRASHEDSTATE, 0)=0
        ORDER BY ZTITLE
        """
    ).fetchall()
    user_members = {}
    missed_user = 0
    for album in user_rows:
        uuids = fetch_members(
            photos,
            f"""
            SELECT z.ZUUID
            FROM Z_34ASSETS m
            JOIN ZASSET z ON z.Z_PK=m.Z_3ASSETS
            WHERE m.Z_34ALBUMS={int(album["Z_PK"])}
            ORDER BY m.Z_FOK_3ASSETS
            """,
        )
        paths, missed = keep(uuids)
        missed_user += missed
        user_members[album["ZUUID"]] = paths

    technical_queries = {
        "favorites": "SELECT ZUUID FROM ZASSET WHERE ZFAVORITE=1 AND IFNULL(ZTRASHEDSTATE,0)=0",
        "hidden": "SELECT ZUUID FROM ZASSET WHERE ZHIDDEN=1 AND IFNULL(ZTRASHEDSTATE,0)=0",
        "videos": "SELECT ZUUID FROM ZASSET WHERE ZKIND=1 AND IFNULL(ZTRASHEDSTATE,0)=0",
        "screenshots": "SELECT ZUUID FROM ZASSET WHERE ZISDETECTEDSCREENSHOT=1 AND IFNULL(ZTRASHEDSTATE,0)=0",
        "selfies": """
            SELECT z.ZUUID
            FROM ZASSET z
            JOIN ZADDITIONALASSETATTRIBUTES a ON a.Z_PK=z.ZADDITIONALATTRIBUTES
            WHERE a.ZCAMERACAPTUREDEVICE=1 AND IFNULL(z.ZTRASHEDSTATE,0)=0
        """,
    }
    technical_paths = {}
    missed_technical = 0
    for key, sql in technical_queries.items():
        paths, missed = keep(fetch_members(photos, sql))
        technical_paths[key] = paths
        missed_technical += missed

    photos_trash = photos.execute(
        """
        SELECT ZUUID, ZTRASHEDDATE
        FROM ZASSET
        WHERE IFNULL(ZTRASHEDSTATE, 0) != 0 AND ZUUID IS NOT NULL
        """
    ).fetchall()

    print(f"manifest {len(manifest)}  library files {len(known)}")
    print(f"user albums {len(user_rows)}  linked {sum(len(v) for v in user_members.values())}  unmatched {missed_user}")
    for key, _, technical, _ in TECHNICAL:
        if technical == "trash":
            print(f"technical {technical}: photos trash rows {len(photos_trash)}")
        else:
            print(f"technical {technical}: {len(technical_paths.get(technical, []))}")
    print(f"technical unmatched {missed_technical}")

    if args.dry_run:
        for album in user_rows:
            print(f"  {album['ZTITLE']}: {len(user_members[album['ZUUID']])}")
        return

    now = time.time()
    library.execute("BEGIN")
    library.execute("DELETE FROM albums WHERE uuid LIKE 'photos:%' OR uuid LIKE 'technical:%'")
    for uuid, name, technical, order in TECHNICAL:
        library.execute(
            """
            INSERT INTO albums(uuid, name, kind, technical, sort_order, source_pk, created_at)
            VALUES (?, ?, 'technical', ?, ?, NULL, ?)
            """,
            (uuid, name, technical, order, now),
        )
    for album in user_rows:
        library.execute(
            """
            INSERT INTO albums(uuid, name, kind, technical, sort_order, source_pk, created_at)
            VALUES (?, ?, 'user', '', 0, ?, ?)
            """,
            (f"photos:{album['ZUUID']}", album["ZTITLE"], int(album["Z_PK"]), now),
        )
        album_id = library.execute("SELECT last_insert_rowid()").fetchone()[0]
        library.executemany(
            "INSERT OR IGNORE INTO album_files(album_id, path, sort_order, added_at) VALUES (?, ?, ?, ?)",
            ((album_id, path, index, now) for index, path in enumerate(user_members[album["ZUUID"]])),
        )
    id_by_technical = {
        row["technical"]: row["id"]
        for row in library.execute("SELECT id, technical FROM albums WHERE kind='technical'")
    }
    for technical, paths in technical_paths.items():
        album_id = id_by_technical[technical]
        library.executemany(
            "INSERT OR IGNORE INTO album_files(album_id, path, sort_order, added_at) VALUES (?, ?, ?, ?)",
            ((album_id, path, index, now) for index, path in enumerate(paths)),
        )
    stamped = 0
    for row in photos_trash:
        path = manifest.get(row["ZUUID"])
        if path not in known:
            continue
        created = row["ZTRASHEDDATE"]
        when = float(created) + CORE_DATA_EPOCH if created is not None else now
        changed = library.execute(
            """
            UPDATE files SET trashed_at=?
            WHERE path=? AND trashed_at IS NULL
            """,
            (when, path),
        ).rowcount
        stamped += changed
    library.execute(
        "INSERT INTO meta(key, value) VALUES ('albums_migrated', ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (str(int(now)),),
    )
    library.execute("COMMIT")
    print(f"wrote albums, photos-trash stamps {stamped}")


if __name__ == "__main__":
    main()
