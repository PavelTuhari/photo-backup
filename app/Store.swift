import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

let imageTypes: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "dng", "webp", "avif",
]
let videoTypes: Set<String> = ["mov", "mp4", "m4v"]

enum ThumbSpec {
    // One hardware-decoded frame, stored once. The grid scales this bitmap.
    static let storedMaxPixel = 144
    static let storedQuality = 0.38
    static let previewMaxPixel = 2800
}

enum ByteText {
    static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

struct FileRecord: Identifiable, Hashable, Sendable {
    var path: String
    var year: String
    var name: String
    var ext: String
    var isVideo: Bool
    var size: Int64
    var width: Int
    var height: Int
    var created: TimeInterval
    var trashedAt: TimeInterval = 0
    var id: String { path }

    var pixelLabel: String {
        if width > 0, height > 0 { return "\(width)×\(height)" }
        return "—"
    }

    var pixelCount: Int { width * height }
    var kindName: String { isVideo ? "Видео" : "Фото" }
}

enum DateText {
    // Capture time is the camera wall clock stored as a Unix value that
    // gmtime already shows correctly. A local time zone would shift it.
    static let zone = TimeZone(secondsFromGMT: 0)!
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = zone
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static func string(_ time: TimeInterval) -> String {
        if time == 0 { return "—" }
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
}

enum CaptureCalendar {
    static let names = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
    ]
    static let shortNames = ["янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.zone
        return calendar
    }()

    static func month(_ time: TimeInterval) -> Int? {
        if time == 0 { return nil }
        let month = calendar.component(.month, from: Date(timeIntervalSince1970: time))
        guard (1...12).contains(month) else { return nil }
        return month
    }
}

struct YearStat: Identifiable, Hashable, Sendable {
    var year: String
    var count: Int
    var bytes: Int64
    var complete: Bool
    var id: String { year }
}

struct PhotoGroup: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var count: Int
}

struct PhotoAlbum: Identifiable, Hashable, Sendable {
    var id: Int64
    var uuid: String
    var name: String
    var kind: String
    var technical: String
    var count: Int

    var isTrash: Bool { technical == "trash" }
    var isUser: Bool { kind == "user" }
}

enum TrashPolicy {
    static let keepSeconds: TimeInterval = 30 * 24 * 60 * 60
}

struct DiskFile: Sendable {
    var path: String
    var year: String
    var name: String
}

struct WorkItem: Sendable {
    var path: String
    var year: String
    var url: URL
    var isVideo: Bool
}

struct SyncSnapshot: Sendable {
    var files: [FileRecord]
    var years: [YearStat]
    var groups: [PhotoGroup]
    var groupPaths: [Int64: Set<String>]
    var pending: [WorkItem]
}

struct IndexEvent: Sendable {
    var done: Int
    var failed: Int
    var total: Int
    var year: String
    var completedYear: String?
}

struct QueryResult: Sendable {
    var columns: [String]
    var rows: [[String]]
    var message: String
}

struct ThumbPayload: Sendable {
    var jpeg: Data
    var width: Int
    var height: Int
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func backupRoot() -> URL? {
    let beside = Bundle.main.bundleURL.deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: beside.appendingPathComponent("Photos.sparsebundle").path) {
        return beside
    }
    let fallback = URL(fileURLWithPath: "/Volumes/Transcend/PhotoBackup")
    if FileManager.default.fileExists(atPath: fallback.appendingPathComponent("Photos.sparsebundle").path) {
        return fallback
    }
    return nil
}

func mountedBackup() -> URL? {
    let volumes = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: "/Volumes"),
        includingPropertiesForKeys: nil
    )) ?? []
    for volume in volumes {
        if FileManager.default.fileExists(atPath: volume.appendingPathComponent("2015").path),
           FileManager.default.fileExists(atPath: volume.appendingPathComponent("2024").path),
           FileManager.default.fileExists(atPath: volume.appendingPathComponent("_missing.txt").path) {
            return volume
        }
    }
    return nil
}

func ensureMounted(bundle: URL) throws -> URL {
    if let existing = mountedBackup() { return existing }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    task.arguments = ["attach", "-plist", bundle.path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    let entities = plist?["system-entities"] as? [[String: Any]] ?? []
    let points = entities.compactMap { $0["mount-point"] as? String }
    guard let last = points.last else { throw CocoaError(.fileReadUnknown) }
    return URL(fileURLWithPath: last)
}

func fileURL(root: URL, file: FileRecord) -> URL {
    root.appendingPathComponent(file.year).appendingPathComponent(file.name)
}

enum ClipCommand {
    case name, path, folder, finder
}

enum FileClip {
    static func copyText(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func names(_ files: [FileRecord]) -> String {
        files.map(\.name).joined(separator: "\n")
    }

    static func paths(_ files: [FileRecord], root: URL, named: Bool) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for file in files {
            let url = fileURL(root: root, file: file)
            let line = named ? url.path : url.deletingLastPathComponent().path
            if named || seen.insert(line).inserted {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

func quoteIdent(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

// ImageIO downsamples with the Apple Silicon media decoder. VideoToolbox does the same for frames.
func hardwareThumbnail(url: URL, video: Bool) async -> ThumbPayload? {
    if video { return await videoThumbnail(url: url) }
    return imageThumbnail(url: url)
}

func imageThumbnail(url: URL) -> ThumbPayload? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    var width = 0
    var height = 0
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    }
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: ThumbSpec.storedMaxPixel,
        kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    guard let jpeg = jpegData(image, quality: ThumbSpec.storedQuality) else { return nil }
    return ThumbPayload(jpeg: jpeg, width: width, height: height)
}

func videoThumbnail(url: URL) async -> ThumbPayload? {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: ThumbSpec.storedMaxPixel, height: ThumbSpec.storedMaxPixel)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
    let first = CMTime(seconds: 0.2, preferredTimescale: 600)
    let image = (try? generator.copyCGImage(at: first, actualTime: nil))
        ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
    guard let image else { return nil }
    var width = 0
    var height = 0
    if let track = try? await asset.loadTracks(withMediaType: .video).first {
        if let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let box = CGRect(origin: .zero, size: natural).applying(transform)
            width = Int(abs(box.width).rounded())
            height = Int(abs(box.height).rounded())
        }
    }
    guard let jpeg = jpegData(image, quality: ThumbSpec.storedQuality) else { return nil }
    return ThumbPayload(jpeg: jpeg, width: width, height: height)
}

func previewJPEG(url: URL, maxPixel: Int) -> Data? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    return jpegData(image, quality: 0.82)
}

func jpegData(_ image: CGImage, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        return nil
    }
    let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(dest, image, props)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

actor ReadyThumbs {
    static let shared = ReadyThumbs()
    private var ready: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func mark(_ path: String) {
        ready.insert(path)
        let pending = waiters.removeValue(forKey: path) ?? []
        for waiter in pending { waiter.resume() }
    }

    func wait(_ path: String) async {
        if ready.contains(path) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[path, default: []].append(continuation)
        }
    }
}

final class ThumbMemory: @unchecked Sendable {
    static let shared = ThumbMemory()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 700 }

    @MainActor
    func cached(path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    @MainActor
    func image(path: String, data: Data) -> NSImage? {
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

final class LibraryDB: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "photo-backup.sqlite")
    private var db: OpaquePointer?
    private(set) var lastError = ""

    init(path: String) { self.path = path }

    func open() throws {
        try queue.sync {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            let rc = path.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
            guard rc == SQLITE_OK, let handle else {
                throw DBError("Не удалось открыть \(path)")
            }
            db = handle
            sqlite3_busy_timeout(handle, 5000)
            exec("PRAGMA journal_mode=DELETE")
            exec("PRAGMA synchronous=NORMAL")
            exec("PRAGMA temp_store=MEMORY")
            exec("PRAGMA foreign_keys=ON")
            ensureSchema()
        }
    }

    func syncDisk(mount: URL, manifest: URL) -> SyncSnapshot {
        healCompletedYears()
        let done = completedYears()
        let names = yearFolderNames(mount)
        for year in names where !done.contains(year) {
            let records = scanYear(mount.appendingPathComponent(year), year: year)
            importYear(year, records)
        }
        fillCreated(from: manifest)
        lastPurged = purgeExpiredNow(mount: mount)
        return loadSnapshot(mount: mount)
    }

    private(set) var lastPurged = 0

    func thumbJPEG(_ path: String) -> Data? {
        queue.sync {
            guard let stmt = prepare("SELECT thumb FROM files WHERE path=? AND thumb_state=1") else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) == SQLITE_BLOB else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            return Data(bytes: bytes, count: count)
        }
    }

    func saveThumb(path: String, jpeg: Data?, width: Int, height: Int, state: Int) {
        queue.sync {
            let sql = "UPDATE files SET thumb=?, width=?, height=?, thumb_state=? WHERE path=? AND thumb_state=0"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            if let jpeg, state == 1 {
                _ = jpeg.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(jpeg.count), sqliteTransient)
                }
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int(stmt, 2, Int32(width))
            sqlite3_bind_int(stmt, 3, Int32(height))
            sqlite3_bind_int(stmt, 4, Int32(state))
            bindText(stmt, 5, path)
            sqlite3_step(stmt)
        }
    }

    func tryComplete(year: String) -> Bool {
        queue.sync {
            let sql = """
            UPDATE years SET complete=1, updated_at=?
            WHERE year=? AND complete=0
              AND NOT EXISTS (
                SELECT 1 FROM files WHERE files.year=years.year AND thumb_state=0
              )
            """
            guard let stmt = prepare(sql) else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, 2, year)
            sqlite3_step(stmt)
            return sqlite3_changes(db) > 0
        }
    }

    func dimensions(for year: String) -> [String: (Int, Int)] {
        queue.sync {
            guard let stmt = prepare("SELECT path, width, height FROM files WHERE year=?") else { return [:] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, year)
            var out: [String: (Int, Int)] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = columnText(stmt, 0)
                out[path] = (Int(sqlite3_column_int(stmt, 1)), Int(sqlite3_column_int(stmt, 2)))
            }
            return out
        }
    }

    func ensureGroup(name: String, paths: [String]) -> Int64 {
        queue.sync {
            let sql = """
            INSERT INTO groups(name, created_at) VALUES (?, ?)
            ON CONFLICT(name) DO UPDATE SET created_at=groups.created_at
            RETURNING id
            """
            guard let stmt = prepare(sql) else { return 0 }
            bindText(stmt, 1, name)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                sqlite3_finalize(stmt)
                return 0
            }
            let id = sqlite3_column_int64(stmt, 0)
            sqlite3_finalize(stmt)
            guard let link = prepare("INSERT OR IGNORE INTO group_files(group_id, path) VALUES (?, ?)") else { return id }
            defer { sqlite3_finalize(link) }
            for path in paths {
                sqlite3_reset(link)
                sqlite3_clear_bindings(link)
                sqlite3_bind_int64(link, 1, id)
                bindText(link, 2, path)
                sqlite3_step(link)
            }
            return id
        }
    }

    func remove(paths: [String], from group: Int64) {
        queue.sync {
            guard let stmt = prepare("DELETE FROM group_files WHERE group_id=? AND path=?") else { return }
            defer { sqlite3_finalize(stmt) }
            for path in paths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, group)
                bindText(stmt, 2, path)
                sqlite3_step(stmt)
            }
        }
    }

    func deleteGroup(_ id: Int64) {
        queue.sync {
            guard let stmt = prepare("DELETE FROM groups WHERE id=?") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    func loadAlbums() -> (albums: [PhotoAlbum], paths: [Int64: Set<String>]) {
        queue.sync { loadAlbumsLocked() }
    }

    func deleteAlbum(_ id: Int64) {
        queue.sync {
            guard albumTechnicalLocked(id).isEmpty else { return }
            guard let stmt = prepare("DELETE FROM albums WHERE id=? AND kind='user'") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    func createAlbum(name: String) -> Int64 {
        queue.sync {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            let uuid = "local:\(UUID().uuidString)"
            guard let stmt = prepare("""
                INSERT INTO albums(uuid, name, kind, technical, sort_order, created_at)
                VALUES (?, ?, 'user', '', 0, ?)
            """) else { return 0 }
            bindText(stmt, 1, uuid)
            bindText(stmt, 2, trimmed)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                return 0
            }
            sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func addToAlbum(_ id: Int64, paths: [String]) {
        queue.sync {
            guard !albumIsTechnicalLocked(id, only: "trash") else { return }
            guard let stmt = prepare("""
                INSERT OR IGNORE INTO album_files(album_id, path, sort_order, added_at)
                VALUES (?, ?, 0, ?)
            """) else { return }
            defer { sqlite3_finalize(stmt) }
            let now = Date().timeIntervalSince1970
            for path in paths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                bindText(stmt, 2, path)
                sqlite3_bind_double(stmt, 3, now)
                sqlite3_step(stmt)
            }
        }
    }

    func removeFromAlbum(_ id: Int64, paths: [String]) {
        queue.sync {
            guard let stmt = prepare("DELETE FROM album_files WHERE album_id=? AND path=?") else { return }
            defer { sqlite3_finalize(stmt) }
            for path in paths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                bindText(stmt, 2, path)
                sqlite3_step(stmt)
            }
        }
    }

    func moveToAlbum(paths: [String], from source: Int64, to dest: Int64) {
        guard source != dest else { return }
        removeFromAlbum(source, paths: paths)
        addToAlbum(dest, paths: paths)
    }

    func setTrashed(_ paths: [String], at time: TimeInterval) {
        queue.sync {
            guard let stmt = prepare("UPDATE files SET trashed_at=? WHERE path=?") else { return }
            defer { sqlite3_finalize(stmt) }
            for path in paths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                if time == 0 {
                    sqlite3_bind_null(stmt, 1)
                } else {
                    sqlite3_bind_double(stmt, 1, time)
                }
                bindText(stmt, 2, path)
                sqlite3_step(stmt)
            }
        }
    }

    func filesForAlbum(_ id: Int64) -> [DiskFile] {
        queue.sync {
            let trash = albumTechnicalLocked(id) == "trash"
            let sql = trash
                ? "SELECT path, year, name FROM files WHERE trashed_at IS NOT NULL ORDER BY trashed_at"
                : """
                SELECT f.path, f.year, f.name
                FROM album_files af
                JOIN files f ON f.path=af.path
                WHERE af.album_id=? AND f.trashed_at IS NULL
                ORDER BY af.sort_order, f.name
                """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            if !trash { sqlite3_bind_int64(stmt, 1, id) }
            var out: [DiskFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DiskFile(path: columnText(stmt, 0), year: columnText(stmt, 1), name: columnText(stmt, 2)))
            }
            return out
        }
    }

    func forget(_ paths: [String]) {
        queue.sync {
            exec("BEGIN")
            if let group = prepare("DELETE FROM group_files WHERE path=?"),
               let album = prepare("DELETE FROM album_files WHERE path=?"),
               let file = prepare("DELETE FROM files WHERE path=?") {
                for path in paths {
                    for stmt in [group, album, file] {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        bindText(stmt, 1, path)
                        sqlite3_step(stmt)
                    }
                }
                sqlite3_finalize(group)
                sqlite3_finalize(album)
                sqlite3_finalize(file)
            }
            exec("""
            UPDATE years SET
              file_count=(SELECT COUNT(*) FROM files WHERE files.year=years.year),
              total_bytes=(SELECT IFNULL(SUM(size),0) FROM files WHERE files.year=years.year),
              updated_at=\(Date().timeIntervalSince1970)
            """)
            exec("COMMIT")
        }
    }

    func expiredFiles(now: TimeInterval) -> [DiskFile] {
        queue.sync {
            let cutoff = now - TrashPolicy.keepSeconds
            guard let stmt = prepare("""
                SELECT path, year, name FROM files
                WHERE trashed_at IS NOT NULL AND trashed_at<=?
            """) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var out: [DiskFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DiskFile(path: columnText(stmt, 0), year: columnText(stmt, 1), name: columnText(stmt, 2)))
            }
            return out
        }
    }

    func trashedFiles() -> [DiskFile] {
        queue.sync {
            guard let stmt = prepare("SELECT path, year, name FROM files WHERE trashed_at IS NOT NULL") else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [DiskFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DiskFile(path: columnText(stmt, 0), year: columnText(stmt, 1), name: columnText(stmt, 2)))
            }
            return out
        }
    }

    func loadGroups() -> (groups: [PhotoGroup], paths: [Int64: Set<String>]) {
        queue.sync {
            var groups: [PhotoGroup] = []
            if let stmt = prepare("""
                SELECT g.id, g.name, COUNT(f.path)
                FROM groups g
                LEFT JOIN group_files f ON f.group_id=g.id
                GROUP BY g.id
                ORDER BY g.name
            """) {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    groups.append(PhotoGroup(
                        id: sqlite3_column_int64(stmt, 0),
                        name: columnText(stmt, 1),
                        count: Int(sqlite3_column_int(stmt, 2))
                    ))
                }
            }
            var paths: [Int64: Set<String>] = [:]
            if let stmt = prepare("SELECT group_id, path FROM group_files") {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(stmt, 0)
                    paths[id, default: []].insert(columnText(stmt, 1))
                }
            }
            return (groups, paths)
        }
    }

    func tableNames() -> [String] {
        queue.sync {
            guard let stmt = prepare("""
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
            """) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(columnText(stmt, 0))
            }
            return names
        }
    }

    func columnNames(_ table: String) -> [String] {
        queue.sync {
            guard let stmt = prepare("PRAGMA table_info(\(quoteIdent(table)))") else { return [] }
            defer { sqlite3_finalize(stmt) }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(columnText(stmt, 1))
            }
            return names
        }
    }

    func preview(table: String, limit: Int = 300) -> QueryResult {
        let columns = columnNames(table)
        let shown = columns.map { column -> String in
            if column == "thumb" { return "length(thumb) AS thumb_bytes" }
            return quoteIdent(column)
        }
        let sql = "SELECT rowid AS rowid, \(shown.joined(separator: ", ")) FROM \(quoteIdent(table)) LIMIT \(limit)"
        return run(sql)
    }

    func updateCell(table: String, rowid: Int64, column: String, value: String?) {
        queue.sync {
            let sql = "UPDATE \(quoteIdent(table)) SET \(quoteIdent(column))=? WHERE rowid=?"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            if let value {
                bindText(stmt, 1, value)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, rowid)
            sqlite3_step(stmt)
        }
    }

    func deleteRow(table: String, rowid: Int64) {
        queue.sync {
            guard let stmt = prepare("DELETE FROM \(quoteIdent(table)) WHERE rowid=?") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, rowid)
            sqlite3_step(stmt)
        }
    }

    func run(_ sql: String) -> QueryResult {
        queue.sync { runLocked(sql) }
    }

    private func healCompletedYears() {
        queue.sync {
            exec("""
            UPDATE years SET complete=1
            WHERE complete=0 AND file_count>0
              AND NOT EXISTS (
                SELECT 1 FROM files WHERE files.year=years.year AND thumb_state=0
              )
            """)
        }
    }

    private func completedYears() -> Set<String> {
        queue.sync {
            guard let stmt = prepare("SELECT year FROM years WHERE complete=1") else { return [] }
            defer { sqlite3_finalize(stmt) }
            var years: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                years.insert(columnText(stmt, 0))
            }
            return years
        }
    }

    private func importYear(_ year: String, _ records: [FileRecord]) {
        queue.sync {
            exec("BEGIN")
            let sql = """
            INSERT OR IGNORE INTO files(path, year, name, ext, kind, size, width, height, thumb_state)
            VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0)
            """
            if let stmt = prepare(sql) {
                for record in records {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, record.path)
                    bindText(stmt, 2, record.year)
                    bindText(stmt, 3, record.name)
                    bindText(stmt, 4, record.ext)
                    bindText(stmt, 5, record.isVideo ? "video" : "photo")
                    sqlite3_bind_int64(stmt, 6, record.size)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            let bytes = records.reduce(Int64(0)) { $0 + $1.size }
            let update = """
            INSERT INTO years(year, file_count, total_bytes, complete, updated_at)
            VALUES (?, ?, ?, 0, ?)
            ON CONFLICT(year) DO UPDATE SET
              file_count=excluded.file_count,
              total_bytes=excluded.total_bytes,
              updated_at=excluded.updated_at
            WHERE years.complete=0
            """
            if let stmt = prepare(update) {
                bindText(stmt, 1, year)
                sqlite3_bind_int64(stmt, 2, Int64(records.count))
                sqlite3_bind_int64(stmt, 3, bytes)
                sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            exec("COMMIT")
        }
    }

    private func loadSnapshot(mount: URL) -> SyncSnapshot {
        queue.sync {
            var files: [FileRecord] = []
            var pending: [WorkItem] = []
            if let stmt = prepare("""
                SELECT path, year, name, ext, kind, size, width, height, thumb_state, created, trashed_at
                FROM files
            """) {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let path = columnText(stmt, 0)
                    let year = columnText(stmt, 1)
                    let name = columnText(stmt, 2)
                    let created = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 9)
                    let trashed = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 10)
                    let record = FileRecord(
                        path: path,
                        year: year,
                        name: name,
                        ext: columnText(stmt, 3),
                        isVideo: columnText(stmt, 4) == "video",
                        size: sqlite3_column_int64(stmt, 5),
                        width: Int(sqlite3_column_int(stmt, 6)),
                        height: Int(sqlite3_column_int(stmt, 7)),
                        created: created,
                        trashedAt: trashed
                    )
                    files.append(record)
                    if sqlite3_column_int(stmt, 8) == 0 {
                        pending.append(WorkItem(
                            path: path,
                            year: year,
                            url: mount.appendingPathComponent(year).appendingPathComponent(name),
                            isVideo: record.isVideo
                        ))
                    }
                }
            }
            files.sort { lhs, rhs in
                if lhs.year != rhs.year { return lhs.year > rhs.year }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            pending.sort { $0.year < $1.year }
            var years: [YearStat] = []
            if let stmt = prepare("SELECT year, file_count, total_bytes, complete FROM years ORDER BY year DESC") {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    years.append(YearStat(
                        year: columnText(stmt, 0),
                        count: Int(sqlite3_column_int(stmt, 1)),
                        bytes: sqlite3_column_int64(stmt, 2),
                        complete: sqlite3_column_int(stmt, 3) == 1
                    ))
                }
            }
            return SyncSnapshot(files: files, years: years, groups: [], groupPaths: [:], pending: pending)
        }
    }

    private func ensureSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS files (
          path TEXT PRIMARY KEY,
          year TEXT NOT NULL,
          name TEXT NOT NULL,
          ext TEXT NOT NULL,
          kind TEXT NOT NULL,
          size INTEGER NOT NULL,
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          thumb BLOB,
          thumb_state INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS years (
          year TEXT PRIMARY KEY,
          file_count INTEGER NOT NULL,
          total_bytes INTEGER NOT NULL,
          complete INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS groups (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS group_files (
          group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          PRIMARY KEY (group_id, path)
        );
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
        CREATE INDEX IF NOT EXISTS files_year ON files(year);
        CREATE INDEX IF NOT EXISTS files_state ON files(thumb_state);
        CREATE INDEX IF NOT EXISTS album_files_path ON album_files(path);
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        setMeta("thumb_engine", "ImageIO CGImageSource + AVAssetImageGenerator/VideoToolbox, arm64")
        setMeta("thumb_max_pixel", "144")
        setMeta("thumb_jpeg_quality", "0.38")
        setMeta("year_rule", "complete=1 means the year is never scanned or thumbnailed again")
        if !columnExists("files", "created") {
            exec("ALTER TABLE files ADD COLUMN created REAL")
        }
        if !columnExists("files", "trashed_at") {
            exec("ALTER TABLE files ADD COLUMN trashed_at REAL")
        }
        exec("CREATE INDEX IF NOT EXISTS files_trashed ON files(trashed_at)")
        ensureTechnicalAlbums()
    }

    private func ensureTechnicalAlbums() {
        let rows: [(String, String, String, Int)] = [
            ("technical:trash", "Удалённые", "trash", 0),
            ("technical:favorites", "Избранное", "favorites", 1),
            ("technical:hidden", "Скрытые", "hidden", 2),
            ("technical:videos", "Видео", "videos", 3),
            ("technical:screenshots", "Скриншоты", "screenshots", 4),
            ("technical:selfies", "Селфи", "selfies", 5),
        ]
        guard let stmt = prepare("""
            INSERT INTO albums(uuid, name, kind, technical, sort_order, created_at)
            VALUES (?, ?, 'technical', ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET
              name=excluded.name,
              kind='technical',
              technical=excluded.technical,
              sort_order=excluded.sort_order
        """) else { return }
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, row.0)
            bindText(stmt, 2, row.1)
            bindText(stmt, 3, row.2)
            sqlite3_bind_int(stmt, 4, Int32(row.3))
            sqlite3_bind_double(stmt, 5, now)
            sqlite3_step(stmt)
        }
    }

    private func loadAlbumsLocked() -> (albums: [PhotoAlbum], paths: [Int64: Set<String>]) {
        var albums: [PhotoAlbum] = []
        if let stmt = prepare("""
            SELECT a.id, a.uuid, a.name, a.kind, a.technical,
              CASE WHEN a.technical='trash' THEN (
                SELECT COUNT(*) FROM files WHERE trashed_at IS NOT NULL
              ) ELSE (
                SELECT COUNT(*) FROM album_files af
                JOIN files f ON f.path=af.path
                WHERE af.album_id=a.id AND f.trashed_at IS NULL
              ) END
            FROM albums a
            ORDER BY CASE a.kind WHEN 'user' THEN 0 WHEN 'technical' THEN 1 ELSE 2 END,
                     a.sort_order, a.name
        """) {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                albums.append(PhotoAlbum(
                    id: sqlite3_column_int64(stmt, 0),
                    uuid: columnText(stmt, 1),
                    name: columnText(stmt, 2),
                    kind: columnText(stmt, 3),
                    technical: columnText(stmt, 4),
                    count: Int(sqlite3_column_int(stmt, 5))
                ))
            }
        }
        var paths: [Int64: Set<String>] = [:]
        if let stmt = prepare("""
            SELECT af.album_id, af.path
            FROM album_files af
            JOIN files f ON f.path=af.path
            WHERE f.trashed_at IS NULL
        """) {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                paths[sqlite3_column_int64(stmt, 0), default: []].insert(columnText(stmt, 1))
            }
        }
        if let trash = albums.first(where: { $0.isTrash }),
           let stmt = prepare("SELECT path FROM files WHERE trashed_at IS NOT NULL") {
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(columnText(stmt, 0))
            }
            paths[trash.id] = set
        }
        return (albums, paths)
    }

    private func albumTechnicalLocked(_ id: Int64) -> String {
        guard let stmt = prepare("SELECT technical FROM albums WHERE id=?") else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
        return columnText(stmt, 0)
    }

    private func albumIsTechnicalLocked(_ id: Int64, only technical: String) -> Bool {
        albumTechnicalLocked(id) == technical
    }

    func purgeExpiredNow(mount: URL) -> Int {
        queue.sync {
            removeDiskAndRows(expiredFilesUnlocked(Date().timeIntervalSince1970), mount: mount)
        }
    }

    private func expiredFilesUnlocked(_ now: TimeInterval) -> [DiskFile] {
        let cutoff = now - TrashPolicy.keepSeconds
        guard let stmt = prepare("""
            SELECT path, year, name FROM files
            WHERE trashed_at IS NOT NULL AND trashed_at<=?
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        var out: [DiskFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DiskFile(path: columnText(stmt, 0), year: columnText(stmt, 1), name: columnText(stmt, 2)))
        }
        return out
    }

    private func removeDiskAndRows(_ files: [DiskFile], mount: URL) -> Int {
        guard !files.isEmpty else { return 0 }
        var gone: [String] = []
        for file in files {
            if MediaDelete.remove(file, mount: mount) {
                gone.append(file.path)
            }
        }
        guard !gone.isEmpty else { return 0 }
        exec("BEGIN")
        if let group = prepare("DELETE FROM group_files WHERE path=?"),
           let album = prepare("DELETE FROM album_files WHERE path=?"),
           let file = prepare("DELETE FROM files WHERE path=?") {
            for path in gone {
                for stmt in [group, album, file] {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, path)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(group)
            sqlite3_finalize(album)
            sqlite3_finalize(file)
        }
        exec("""
        UPDATE years SET
          file_count=(SELECT COUNT(*) FROM files WHERE files.year=years.year),
          total_bytes=(SELECT IFNULL(SUM(size),0) FROM files WHERE files.year=years.year)
        """)
        exec("COMMIT")
        return gone.count
    }

    // Photo dates come from manifest.jsonl. This does not read image files or rebuild thumbnails.
    private func fillCreated(from manifest: URL) {
        let loaded = queue.sync { metaValue("dates_loaded") == "1" }
        if loaded { return }
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return }
        var pairs: [(String, Double)] = []
        pairs.reserveCapacity(32_000)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let year = object["year"] as? String,
                  let name = object["name"] as? String
            else { continue }
            let created: Double
            if let number = object["created"] as? Double {
                created = number
            } else if let number = object["created"] as? NSNumber {
                created = number.doubleValue
            } else {
                continue
            }
            pairs.append(("\(year)/\(name)", created))
        }
        queue.sync {
            exec("BEGIN")
            if let stmt = prepare("UPDATE files SET created=? WHERE path=?") {
                for pair in pairs {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_double(stmt, 1, pair.1)
                    bindText(stmt, 2, pair.0)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            exec("COMMIT")
            setMeta("dates_loaded", "1")
        }
    }

    private func columnExists(_ table: String, _ name: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(\(quoteIdent(table)))") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == name { return true }
        }
        return false
    }

    private func metaValue(_ key: String) -> String? {
        guard let stmt = prepare("SELECT value FROM meta WHERE key=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    private func setMeta(_ key: String, _ value: String) {
        guard let stmt = prepare("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        sqlite3_step(stmt)
    }

    private func runLocked(_ sql: String) -> QueryResult {
        guard db != nil else { return QueryResult(columns: [], rows: [], message: "База не открыта") }
        var last = QueryResult(columns: [], rows: [], message: "")
        let buffer = Array(sql.utf8CString)
        buffer.withUnsafeBufferPointer { raw in
            guard var cursor = raw.baseAddress else { return }
            while cursor.pointee != 0 {
                while cursor.pointee == 32 || cursor.pointee == 10 || cursor.pointee == 9 || cursor.pointee == 13 || cursor.pointee == 59 {
                    cursor = cursor.advanced(by: 1)
                }
                if cursor.pointee == 0 { break }
                var stmt: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(db, cursor, -1, &stmt, &tail)
                if rc != SQLITE_OK {
                    last.message = String(cString: sqlite3_errmsg(db))
                    return
                }
                guard let stmt else {
                    if let tail, tail != cursor {
                        cursor = tail
                        continue
                    }
                    break
                }
                last = stepAll(stmt)
                sqlite3_finalize(stmt)
                if last.message.hasPrefix("Ошибка") { return }
                guard let tail else { break }
                cursor = tail
            }
        }
        if last.message.isEmpty {
            if last.columns.isEmpty {
                last.message = "Готово, изменено строк: \(sqlite3_changes(db))"
            } else {
                last.message = "Строк в ответе: \(last.rows.count)"
            }
        }
        return last
    }

    private func stepAll(_ stmt: OpaquePointer) -> QueryResult {
        let count = sqlite3_column_count(stmt)
        var columns: [String] = []
        for index in 0..<count {
            columns.append(String(cString: sqlite3_column_name(stmt, index)))
        }
        var rows: [[String]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW {
                return QueryResult(columns: columns, rows: rows, message: "Ошибка: \(String(cString: sqlite3_errmsg(db)))")
            }
            if rows.count >= 1000 { break }
            var row: [String] = []
            for index in 0..<count {
                row.append(columnDisplay(stmt, index))
            }
            rows.append(row)
        }
        var message = ""
        if rows.count >= 1000 { message = "Показаны первые 1000 строк" }
        return QueryResult(columns: columns, rows: rows, message: message)
    }

    private func columnDisplay(_ stmt: OpaquePointer, _ index: Int32) -> String {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return "NULL"
        case SQLITE_BLOB:
            return "blob \(sqlite3_column_bytes(stmt, index)) байт"
        default:
            return columnText(stmt, index)
        }
    }

    private func yearFolderNames(_ mount: URL) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: mount,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.compactMap { url in
            let name = url.lastPathComponent
            guard name.count == 4, Int(name) != nil else { return nil }
            return name
        }
    }

    private func scanYear(_ folder: URL, year: String) -> [FileRecord] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var records: [FileRecord] = []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("._") { continue }
            let ext = url.pathExtension.lowercased()
            let video = videoTypes.contains(ext)
            if !video && !imageTypes.contains(ext) { continue }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == false { continue }
            let size = Int64(values?.fileSize ?? 0)
            records.append(FileRecord(
                path: "\(year)/\(name)",
                year: year,
                name: name,
                ext: ext,
                isVideo: video,
                size: size,
                width: 0,
                height: 0,
                created: 0
            ))
        }
        return records
    }

    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            lastError = error.map { String(cString: $0) } ?? "sqlite"
            sqlite3_free(error)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(db))
            return nil
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, sqliteTransient) }
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: raw)
    }
}

struct DBError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var high: [WorkItem] = []
    private var low: [WorkItem] = []
    private var highIDs: Set<String> = []
    private var lowIDs: Set<String> = []
    private var busy: Set<String> = []
    private var finished = false

    func add(_ items: [WorkItem]) {
        lock.lock()
        defer { lock.unlock() }
        for item in items where lowIDs.insert(item.path).inserted {
            low.append(item)
        }
    }

    @discardableResult
    func prioritize(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if highIDs.contains(path) || busy.contains(path) { return true }
        guard let index = low.lastIndex(where: { $0.path == path }) else { return false }
        let item = low.remove(at: index)
        lowIDs.remove(path)
        high.append(item)
        highIDs.insert(path)
        return true
    }

    func pop() -> WorkItem? {
        lock.lock()
        defer { lock.unlock() }
        let item: WorkItem?
        if let next = high.popLast() {
            highIDs.remove(next.path)
            item = next
        } else if let next = low.popLast() {
            lowIDs.remove(next.path)
            item = next
        } else {
            item = nil
        }
        if let item { busy.insert(item.path) }
        return item
    }

    func finish(_ path: String) {
        lock.lock()
        busy.remove(path)
        lock.unlock()
    }

    func giveBack(_ item: WorkItem) {
        lock.lock()
        busy.remove(item.path)
        if !highIDs.contains(item.path), !lowIDs.contains(item.path) {
            high.append(item)
            highIDs.insert(item.path)
        }
        lock.unlock()
    }

    func isQueued(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return highIDs.contains(path) || lowIDs.contains(path) || busy.contains(path)
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished && high.isEmpty && low.isEmpty
    }
}

final class Indexer: @unchecked Sendable {
    private let queue = WorkQueue()
    private let progress = ProgressBox()
    private let gate = NSLock()
    private var paused = false
    private var task: Task<Void, Never>?

    func setPaused(_ paused: Bool) {
        gate.lock()
        self.paused = paused
        gate.unlock()
    }

    func isPaused() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return paused
    }

    func start(items: [WorkItem], db: LibraryDB, onEvent: @escaping @Sendable (IndexEvent) -> Void) {
        guard task == nil else { return }
        queue.add(items)
        queue.markFinished()
        let total = items.count
        guard total > 0 else { return }
        task = Task.detached(priority: .background) {
            await self.worker(db: db, total: total, onEvent: onEvent)
        }
    }

    @discardableResult
    func prioritize(_ path: String) -> Bool {
        queue.prioritize(path)
    }

    func isQueued(_ path: String) -> Bool {
        queue.isQueued(path)
    }

    private func worker(db: LibraryDB, total: Int, onEvent: @escaping @Sendable (IndexEvent) -> Void) async {
        while !Task.isCancelled {
            if isPaused() {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            guard let item = queue.pop() else {
                if queue.isDrained { return }
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            if isPaused() {
                queue.giveBack(item)
                continue
            }
            let payload = await hardwareThumbnail(url: item.url, video: item.isVideo)
            let failed = payload == nil
            if let payload {
                db.saveThumb(path: item.path, jpeg: payload.jpeg, width: payload.width, height: payload.height, state: 1)
            } else {
                db.saveThumb(path: item.path, jpeg: nil, width: 0, height: 0, state: 2)
            }
            await ReadyThumbs.shared.mark(item.path)
            queue.finish(item.path)
            let counts = progress.bump(failed: failed)
            let completed = db.tryComplete(year: item.year) ? item.year : nil
            if completed != nil || counts.done == total || counts.done % 8 == 0 {
                onEvent(IndexEvent(
                    done: counts.done,
                    failed: counts.failed,
                    total: total,
                    year: item.year,
                    completedYear: completed
                ))
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var failed = 0

    func bump(failed: Bool) -> (done: Int, failed: Int) {
        lock.lock()
        defer { lock.unlock() }
        done += 1
        if failed { self.failed += 1 }
        return (done, self.failed)
    }
}
