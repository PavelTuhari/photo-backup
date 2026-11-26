import Foundation
import SQLite3

// The photo list lives in its own file so opening the browser does not read
// the thumbnail blobs stored in library.sqlite.
struct CatalogSnapshot: Sendable {
    var files: [FileRecord]
    var years: [YearStat]
    var groups: [PhotoGroup]
    var groupPaths: [Int64: Set<String>]
    var albums: [PhotoAlbum]
    var albumPaths: [Int64: Set<String>]
}

enum CatalogCache {
    private static let queue = DispatchQueue(label: "photo-backup.catalog")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func read(root: URL) -> CatalogSnapshot? {
        queue.sync { readLocked(root: root) }
    }

    static func writeAsync(root: URL, snapshot: CatalogSnapshot) {
        queue.async { writeLocked(root: root, snapshot: snapshot) }
    }

    private static func fileURL(_ root: URL) -> URL {
        root.appendingPathComponent("catalog.sqlite")
    }

    private static func readLocked(root: URL) -> CatalogSnapshot? {
        let path = fileURL(root).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            return nil
        }
        defer { sqlite3_close(db) }
        guard meta(db, "catalog_version") == "1" else { return nil }

        var files: [FileRecord] = []
        if let stmt = prepare(db, """
            SELECT path, year, name, ext, kind, size, width, height, thumb_state, created, trashed_at
            FROM files
        """) {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                files.append(FileRecord(
                    path: text(stmt, 0),
                    year: text(stmt, 1),
                    name: text(stmt, 2),
                    ext: text(stmt, 3),
                    isVideo: text(stmt, 4) == "video",
                    size: sqlite3_column_int64(stmt, 5),
                    width: Int(sqlite3_column_int(stmt, 6)),
                    height: Int(sqlite3_column_int(stmt, 7)),
                    created: sqlite3_column_double(stmt, 9),
                    trashedAt: sqlite3_column_double(stmt, 10),
                    thumbPending: sqlite3_column_int(stmt, 8) == 0
                ))
            }
        }
        guard !files.isEmpty else { return nil }
        files.sort { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var years: [YearStat] = []
        if let stmt = prepare(db, "SELECT year, file_count, total_bytes, complete FROM years ORDER BY year DESC") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                years.append(YearStat(
                    year: text(stmt, 0),
                    count: Int(sqlite3_column_int(stmt, 1)),
                    bytes: sqlite3_column_int64(stmt, 2),
                    complete: sqlite3_column_int(stmt, 3) == 1
                ))
            }
        }

        var groups: [PhotoGroup] = []
        if let stmt = prepare(db, "SELECT id, name, count FROM groups ORDER BY name") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                groups.append(PhotoGroup(
                    id: sqlite3_column_int64(stmt, 0),
                    name: text(stmt, 1),
                    count: Int(sqlite3_column_int(stmt, 2))
                ))
            }
        }
        var groupPaths: [Int64: Set<String>] = [:]
        if let stmt = prepare(db, "SELECT group_id, path FROM group_files") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                groupPaths[sqlite3_column_int64(stmt, 0), default: []].insert(text(stmt, 1))
            }
        }

        var albums: [PhotoAlbum] = []
        if let stmt = prepare(db, "SELECT id, uuid, name, kind, technical, count FROM albums ORDER BY id") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                albums.append(PhotoAlbum(
                    id: sqlite3_column_int64(stmt, 0),
                    uuid: text(stmt, 1),
                    name: text(stmt, 2),
                    kind: text(stmt, 3),
                    technical: text(stmt, 4),
                    count: Int(sqlite3_column_int(stmt, 5))
                ))
            }
        }
        var albumPaths: [Int64: Set<String>] = [:]
        if let stmt = prepare(db, "SELECT album_id, path FROM album_files") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                albumPaths[sqlite3_column_int64(stmt, 0), default: []].insert(text(stmt, 1))
            }
        }
        return CatalogSnapshot(
            files: files,
            years: years,
            groups: groups,
            groupPaths: groupPaths,
            albums: albums,
            albumPaths: albumPaths
        )
    }

    private static func writeLocked(root: URL, snapshot: CatalogSnapshot) {
        guard !snapshot.files.isEmpty else { return }
        let destination = fileURL(root)
        let temporary = root.appendingPathComponent("catalog.sqlite.building")
        try? FileManager.default.removeItem(at: temporary)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else { return }
        exec(db, "PRAGMA journal_mode=DELETE")
        exec(db, "PRAGMA synchronous=NORMAL")
        exec(db, "PRAGMA temp_store=MEMORY")
        exec(db, """
        CREATE TABLE files (
          path TEXT PRIMARY KEY,
          year TEXT NOT NULL,
          name TEXT NOT NULL,
          ext TEXT NOT NULL,
          kind TEXT NOT NULL,
          size INTEGER NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          thumb_state INTEGER NOT NULL,
          created REAL NOT NULL,
          trashed_at REAL NOT NULL
        );
        CREATE TABLE years (
          year TEXT PRIMARY KEY,
          file_count INTEGER NOT NULL,
          total_bytes INTEGER NOT NULL,
          complete INTEGER NOT NULL
        );
        CREATE TABLE groups (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          count INTEGER NOT NULL
        );
        CREATE TABLE group_files (
          group_id INTEGER NOT NULL,
          path TEXT NOT NULL,
          PRIMARY KEY (group_id, path)
        );
        CREATE TABLE albums (
          id INTEGER PRIMARY KEY,
          uuid TEXT NOT NULL,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          technical TEXT NOT NULL,
          count INTEGER NOT NULL
        );
        CREATE TABLE album_files (
          album_id INTEGER NOT NULL,
          path TEXT NOT NULL,
          PRIMARY KEY (album_id, path)
        );
        CREATE TABLE meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        exec(db, "BEGIN")
        if let stmt = prepare(db, """
            INSERT INTO files(path, year, name, ext, kind, size, width, height, thumb_state, created, trashed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) {
            for file in snapshot.files {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(stmt, 1, file.path)
                bind(stmt, 2, file.year)
                bind(stmt, 3, file.name)
                bind(stmt, 4, file.ext)
                bind(stmt, 5, file.isVideo ? "video" : "photo")
                sqlite3_bind_int64(stmt, 6, file.size)
                sqlite3_bind_int(stmt, 7, Int32(file.width))
                sqlite3_bind_int(stmt, 8, Int32(file.height))
                sqlite3_bind_int(stmt, 9, file.thumbPending ? 0 : 1)
                sqlite3_bind_double(stmt, 10, file.created)
                sqlite3_bind_double(stmt, 11, file.trashedAt)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "INSERT INTO years(year, file_count, total_bytes, complete) VALUES (?, ?, ?, ?)") {
            for year in snapshot.years {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(stmt, 1, year.year)
                sqlite3_bind_int(stmt, 2, Int32(year.count))
                sqlite3_bind_int64(stmt, 3, year.bytes)
                sqlite3_bind_int(stmt, 4, year.complete ? 1 : 0)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "INSERT INTO groups(id, name, count) VALUES (?, ?, ?)") {
            for group in snapshot.groups {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, group.id)
                bind(stmt, 2, group.name)
                sqlite3_bind_int(stmt, 3, Int32(group.count))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "INSERT INTO group_files(group_id, path) VALUES (?, ?)") {
            for (id, paths) in snapshot.groupPaths {
                for path in paths {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, id)
                    bind(stmt, 2, path)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "INSERT INTO albums(id, uuid, name, kind, technical, count) VALUES (?, ?, ?, ?, ?, ?)") {
            for album in snapshot.albums {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, album.id)
                bind(stmt, 2, album.uuid)
                bind(stmt, 3, album.name)
                bind(stmt, 4, album.kind)
                bind(stmt, 5, album.technical)
                sqlite3_bind_int(stmt, 6, Int32(album.count))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "INSERT INTO album_files(album_id, path) VALUES (?, ?)") {
            for (id, paths) in snapshot.albumPaths {
                for path in paths {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, id)
                    bind(stmt, 2, path)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(db, "INSERT INTO meta(key, value) VALUES ('catalog_version', '1')") {
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec(db, "COMMIT")
        sqlite3_close(db)
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func meta(_ db: OpaquePointer, _ key: String) -> String? {
        guard let stmt = prepare(db, "SELECT value FROM meta WHERE key=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: raw)
    }
}
