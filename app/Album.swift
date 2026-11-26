import AppKit
import Foundation
import SQLite3

private let albumTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LibraryCommand: Equatable {
    case trash
    case purge
    case restore
    case removeFromAlbum
    case emptyTrash
    case newAlbum
    case add(Int64)
    case move(Int64)
}

enum MediaDelete {
    static func remove(_ file: DiskFile, mount: URL) -> Bool {
        let year = file.year
        let name = file.name
        if year.isEmpty || name.isEmpty || year.contains("/") || name.contains("/") || year == ".." || name == ".." {
            return false
        }
        let folder = mount.appendingPathComponent(year, isDirectory: true).standardizedFileURL
        let url = folder.appendingPathComponent(name).standardizedFileURL
        let root = mount.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard url.path.hasPrefix(prefix), url.deletingLastPathComponent().path == folder.path else { return false }
        if !FileManager.default.fileExists(atPath: url.path) { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}

func addLibraryMenu(
    _ menu: NSMenu,
    target: AnyObject,
    albums: [PhotoAlbum],
    inUserAlbum: Bool,
    inTrash: Bool,
    trash: Selector,
    purge: Selector,
    restore: Selector,
    remove: Selector,
    empty: Selector,
    newAlbum: Selector,
    add: Selector,
    move: Selector
) {
    func item(_ title: String, _ action: Selector, id: Int64? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = target
        if let id {
            entry.representedObject = NSNumber(value: id)
        }
        return entry
    }
    if inTrash {
        menu.addItem(item("Восстановить", restore))
        menu.addItem(item("Удалить навсегда", purge))
        menu.addItem(item("Очистить корзину", empty))
    } else {
        menu.addItem(item("Удалить в корзину", trash))
        menu.addItem(item("Удалить навсегда", purge))
    }
    let user = albums.filter(\.isUser)
    let addMenu = NSMenu()
    addMenu.autoenablesItems = false
    for album in user {
        addMenu.addItem(item(album.name, add, id: album.id))
    }
    if !user.isEmpty { addMenu.addItem(.separator()) }
    addMenu.addItem(item("Новый альбом…", newAlbum))
    let addParent = NSMenuItem(title: "В альбом", action: nil, keyEquivalent: "")
    addParent.submenu = addMenu
    menu.addItem(addParent)
    if inUserAlbum {
        let moveMenu = NSMenu()
        moveMenu.autoenablesItems = false
        for album in user {
            moveMenu.addItem(item(album.name, move, id: album.id))
        }
        let moveParent = NSMenuItem(title: "Перенести в альбом", action: nil, keyEquivalent: "")
        moveParent.submenu = moveMenu
        menu.addItem(moveParent)
        menu.addItem(item("Убрать из альбома", remove))
    }
}

enum AlbumExport {
    static func write(folder: URL, album: PhotoAlbum, files: [FileRecord], root: URL) -> Int {
        setenv("COPYFILE_DISABLE", "1", 1)
        let safe = folder.appendingPathComponent(clean(album.name), isDirectory: true)
        try? FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        var copied: [(FileRecord, String)] = []
        for file in files {
            let source = fileURL(root: root, file: file)
            let dest = uniqueDestination(folder: safe, name: file.name)
            do {
                try FileManager.default.copyItem(at: source, to: dest)
                copied.append((file, dest.lastPathComponent))
            } catch {
                continue
            }
        }
        let dbURL = safe.appendingPathComponent("album.sqlite")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            try? FileManager.default.removeItem(at: dbURL)
        }
        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let handle else { return copied.count }
        defer { sqlite3_close(handle) }
        let schema = """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE album(
          uuid TEXT NOT NULL,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          technical TEXT NOT NULL,
          exported_at REAL NOT NULL
        );
        CREATE TABLE files(
          archive_path TEXT NOT NULL,
          stored_name TEXT NOT NULL,
          year TEXT NOT NULL,
          ext TEXT NOT NULL,
          kind TEXT NOT NULL,
          size INTEGER NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          created REAL NOT NULL,
          trashed_at REAL,
          sort_order INTEGER NOT NULL
        );
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
        func meta(_ key: String, _ value: String) {
            guard let stmt = prepare(handle, "INSERT INTO meta(key, value) VALUES (?, ?)") else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            bind(stmt, 2, value)
            sqlite3_step(stmt)
        }
        meta("format", "photo-backup-album-1")
        meta("about", "Album export. stored_name is the file in this folder. archive_path is year/name in the backup.")
        if let stmt = prepare(handle, "INSERT INTO album(uuid, name, kind, technical, exported_at) VALUES (?, ?, ?, ?, ?)") {
            bind(stmt, 1, album.uuid)
            bind(stmt, 2, album.name)
            bind(stmt, 3, album.kind)
            bind(stmt, 4, album.technical)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare(handle, """
            INSERT INTO files(archive_path, stored_name, year, ext, kind, size, width, height, created, trashed_at, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) {
            for (index, pair) in copied.enumerated() {
                let file = pair.0
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(stmt, 1, file.path)
                bind(stmt, 2, pair.1)
                bind(stmt, 3, file.year)
                bind(stmt, 4, file.ext)
                bind(stmt, 5, file.isVideo ? "video" : "photo")
                sqlite3_bind_int64(stmt, 6, file.size)
                sqlite3_bind_int(stmt, 7, Int32(file.width))
                sqlite3_bind_int(stmt, 8, Int32(file.height))
                sqlite3_bind_double(stmt, 9, file.created)
                if file.trashedAt == 0 {
                    sqlite3_bind_null(stmt, 10)
                } else {
                    sqlite3_bind_double(stmt, 10, file.trashedAt)
                }
                sqlite3_bind_int(stmt, 11, Int32(index))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return copied.count
    }

    private static func clean(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "album" }
        return String(cleaned.prefix(80))
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private static func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, albumTransient) }
    }
}
