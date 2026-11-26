import AppKit
import AVKit
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case year(String)
    case group(Int64)
    case album(Int64)
    case database
}

enum ViewMode: String, CaseIterable, Identifiable {
    case thumbs, table, gallery
    var id: String { rawValue }
}

struct RowRef {
    var index: UInt32
    var path: String
    var name: String
    var created: TimeInterval
    var year: String
    var kindName: String
    var size: Int64
    var width: Int
    var height: Int
    var pixelCount: Int
}

struct MonthSection: Identifiable {
    var year: String
    var month: Int
    var files: [FileRecord]
    var id: String { "\(year)-\(month)" }
}

@main
struct PhotoBackupApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class IndexStatus: ObservableObject {
    @Published var text = ""
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var files: [FileRecord] = []
    @Published var years: [YearStat] = []
    @Published var groups: [PhotoGroup] = []
    @Published var groupPaths: [Int64: Set<String>] = [:]
    @Published var albums: [PhotoAlbum] = []
    @Published var albumPaths: [Int64: Set<String>] = [:]
    @Published var status = "Ищу копию"
    @Published var mediaRoot: URL?
    @Published var database: LibraryDB?
    @Published var pixelEpoch = 0
    @Published var groupsEpoch = 0
    @Published var albumsEpoch = 0
    var sortKeys = SortKeys()
    let indexStatus = IndexStatus()
    let indexer = Indexer()
    private var started = false

    var totalBytes: Int64 { years.reduce(0) { $0 + $1.bytes } }

    func refresh() async {
        guard !started else { return }
        started = true
        guard let root = backupRoot() else {
            status = "Рядом с приложением нет Photos.sparsebundle"
            started = false
            return
        }
        status = "Монтирую копию"
        do {
            let bundle = root.appendingPathComponent("Photos.sparsebundle")
            let mount = try await Task.detached { try ensureMounted(bundle: bundle) }.value
            mediaRoot = mount
            let database = LibraryDB(path: root.appendingPathComponent("library.sqlite").path)
            status = "Считаю размеры папок"
            let manifest = root.appendingPathComponent("manifest.jsonl")
            // Names are ranked off the main thread. Opening the database stays
            // off it as well, so the window can show the privacy prompt.
            let loaded = try await Task.detached {
                try database.open()
                let snapshot = database.syncDisk(mount: mount, manifest: manifest)
                let keys = SortKeys.make(files: snapshot.files)
                return (snapshot, keys)
            }.value
            self.database = database
            let snapshot = loaded.0
            sortKeys = loaded.1
            let groups = database.loadGroups()
            files = snapshot.files
            years = snapshot.years
            self.groups = groups.groups
            groupPaths = groups.paths
            reloadAlbums()
            if database.lastPurged > 0 {
                status = "Корзина очищена автоматически · \(database.lastPurged)"
            } else {
                status = "\(files.count) файлов · \(ByteText.string(totalBytes))"
            }
            if snapshot.pending.isEmpty {
                indexStatus.text = "Миниатюры сохранены"
            } else {
                indexStatus.text = "Миниатюры 0/\(snapshot.pending.count)"
                indexer.start(items: snapshot.pending, db: database) { [weak self] event in
                    Task { @MainActor in
                        self?.apply(event)
                    }
                }
            }
        } catch {
            status = "Не удалось открыть копию"
            started = false
        }
    }

    func apply(_ event: IndexEvent) {
        if event.done == event.total {
            indexStatus.text = event.failed == 0 ? "Миниатюры сохранены" : "Миниатюры сохранены, ошибок \(event.failed)"
        } else if event.failed == 0 {
            indexStatus.text = "Миниатюры \(event.done)/\(event.total) · \(event.year)"
        } else {
            indexStatus.text = "Миниатюры \(event.done)/\(event.total) · ошибок \(event.failed)"
        }
        guard let year = event.completedYear, let database else { return }
        let sizes = database.dimensions(for: year)
        var next = files
        var changed = false
        for index in next.indices where next[index].year == year {
            guard let size = sizes[next[index].path] else { continue }
            let pixels = UInt64(max(size.0, 0)) * UInt64(max(size.1, 0))
            if index < sortKeys.pixels.count, sortKeys.pixels[index] != pixels {
                sortKeys.pixels[index] = pixels
                changed = true
            }
            if next[index].width != size.0 || next[index].height != size.1 {
                next[index].width = size.0
                next[index].height = size.1
                changed = true
            }
        }
        if changed {
            files = next
            pixelEpoch &+= 1
        }
        if let index = years.firstIndex(where: { $0.year == year }) {
            years[index].complete = true
        }
    }

    func reloadGroups() {
        guard let database else { return }
        let loaded = database.loadGroups()
        groups = loaded.groups
        groupPaths = loaded.paths
        groupsEpoch &+= 1
    }

    func makeGroup(name: String, paths: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let database, !trimmed.isEmpty, !paths.isEmpty else { return }
        _ = database.ensureGroup(name: trimmed, paths: paths)
        reloadGroups()
        status = "Группа «\(trimmed)»: \(paths.count)"
    }

    func removeFromGroup(_ id: Int64, paths: [String]) {
        database?.remove(paths: paths, from: id)
        reloadGroups()
    }

    func deleteGroup(_ id: Int64) {
        database?.deleteGroup(id)
        reloadGroups()
    }

    var userAlbums: [PhotoAlbum] { albums.filter(\.isUser) }
    var trashAlbum: PhotoAlbum? { albums.first(where: \.isTrash) }

    func album(_ id: Int64) -> PhotoAlbum? {
        albums.first { $0.id == id }
    }

    func reloadAlbums() {
        guard let database else { return }
        let loaded = database.loadAlbums()
        albums = loaded.albums
        albumPaths = loaded.paths
        albumsEpoch &+= 1
    }

    func createAlbum(name: String, paths: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let database, !trimmed.isEmpty else { return }
        let id = database.createAlbum(name: trimmed)
        if id != 0, !paths.isEmpty {
            database.addToAlbum(id, paths: paths)
        }
        reloadAlbums()
        status = "Альбом «\(trimmed)»"
    }

    func addToAlbum(_ id: Int64, paths: [String]) {
        guard let database, !paths.isEmpty else { return }
        database.addToAlbum(id, paths: paths)
        reloadAlbums()
        let name = album(id)?.name ?? "альбом"
        status = "В альбоме «\(name)»: \(paths.count)"
    }

    func removeFromAlbum(_ id: Int64, paths: [String]) {
        database?.removeFromAlbum(id, paths: paths)
        reloadAlbums()
    }

    func moveToAlbum(paths: [String], from source: Int64, to dest: Int64) {
        database?.moveToAlbum(paths: paths, from: source, to: dest)
        reloadAlbums()
        let name = album(dest)?.name ?? "альбом"
        status = "Перенесено в «\(name)»: \(paths.count)"
    }

    func setTrashed(_ paths: [String], at time: TimeInterval) {
        guard let database, !paths.isEmpty else { return }
        database.setTrashed(paths, at: time)
        let wanted = Set(paths)
        var next = files
        for index in next.indices where wanted.contains(next[index].path) {
            next[index].trashedAt = time
        }
        files = next
        reloadAlbums()
    }

    func forget(_ paths: [String]) -> Int {
        guard let database, let root = mediaRoot, !paths.isEmpty else { return 0 }
        let wanted = Set(paths)
        let doomed = files.filter { wanted.contains($0.path) }.map {
            DiskFile(path: $0.path, year: $0.year, name: $0.name)
        }
        let removed = doomed.filter { MediaDelete.remove($0, mount: root) }.map(\.path)
        guard !removed.isEmpty else { return 0 }
        database.forget(removed)
        let gone = Set(removed)
        files.removeAll { gone.contains($0.path) }
        reloadAlbums()
        reloadGroups()
        refreshYearStats()
        return removed.count
    }

    func purgeExpired() -> Int {
        guard let database, let root = mediaRoot else { return 0 }
        let doomed = Set(database.expiredFiles(now: Date().timeIntervalSince1970).map(\.path))
        let n = database.purgeExpiredNow(mount: root)
        guard n > 0 else { return 0 }
        files.removeAll { doomed.contains($0.path) }
        reloadAlbums()
        refreshYearStats()
        return n
    }

    private func refreshYearStats() {
        guard let database else { return }
        let result = database.run("SELECT year, file_count, total_bytes, complete FROM years ORDER BY year DESC")
        var next: [YearStat] = []
        for row in result.rows {
            guard row.count >= 4, let count = Int(row[1]), let bytes = Int64(row[2]) else { continue }
            next.append(YearStat(year: row[0], count: count, bytes: bytes, complete: row[3] == "1"))
        }
        if !next.isEmpty { years = next }
    }
}

struct BrowserView: View {
    @StateObject private var model = LibraryModel()
    @State private var sidebar: SidebarItem = .all
    @State private var didPickYear = false
    @State private var mode: ViewMode = .thumbs
    @State private var thumbSide: Double = 160
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var viewerItem: FileRecord?
    @State private var grouping = false
    @State private var groupName = ""
    @State private var tableOrder: [RowRef] = []
    @State private var tableToken = 0
    @State private var activeColumn: HardwareColumn = .created
    @State private var sortDescending = true
    @State private var monthSections: [MonthSection] = []
    @State private var jumpedMonth: Int?
    @State private var gridScrollToken = 0
    @State private var galleryAnchor: String?
    @State private var mosaic = MosaicIndex()
    @State private var mosaicToken = 0
    @State private var mosaicCell: Double = 12
    @State private var mosaicJumpIndex = 0
    @State private var mosaicJumpToken = 0
    @State private var focusYear: String?
    @State private var focusMonth: Int?
    @State private var pinMonthUntil: TimeInterval = 0
    @State private var tableScrollPath: String?
    @State private var tableScrollToken = 0
    @State private var viewerList: [FileRecord] = []
    @State private var resizeToken = 0
    @AppStorage("pb.showAlbums") private var showAlbums = true
    @State private var albumName = ""
    @State private var makingAlbum = false
    @State private var lastTrash: [String] = []

    private var visible: [FileRecord] {
        var rows = model.files
        switch sidebar {
        case .year(let year):
            rows = rows.filter { $0.year == year && $0.trashedAt == 0 }
        case .group(let id):
            let paths = model.groupPaths[id] ?? []
            rows = rows.filter { paths.contains($0.path) && $0.trashedAt == 0 }
        case .album(let id):
            if model.album(id)?.isTrash == true {
                rows = rows.filter { $0.trashedAt != 0 }
            } else {
                let paths = model.albumPaths[id] ?? []
                rows = rows.filter { paths.contains($0.path) && $0.trashedAt == 0 }
            }
        case .all, .database:
            rows = rows.filter { $0.trashedAt == 0 }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            rows = rows.filter { $0.name.localizedStandardContains(needle) }
        }
        return rows
    }

    private var selectedRecords: [FileRecord] {
        let picked = selection
        if picked.isEmpty { return [] }
        if mode == .table {
            var rows: [FileRecord] = []
            rows.reserveCapacity(picked.count)
            for row in tableOrder where picked.contains(row.path) {
                rows.append(live(row))
            }
            return rows
        }
        return visible.filter { picked.contains($0.path) }
    }

    private var detailTitle: String {
        switch sidebar {
        case .database:
            return "База"
        case .all:
            return "Все годы · \(visible.count) · \(ByteText.string(model.totalBytes))"
        case .year(let year):
            if let stat = model.years.first(where: { $0.year == year }) {
                return "\(year) · \(stat.count) · \(ByteText.string(stat.bytes))"
            }
            return year
        case .group(let id):
            return model.groups.first { $0.id == id }?.name ?? "Группа"
        case .album(let id):
            if let album = model.album(id) {
                return "\(album.name) · \(album.count)"
            }
            return "Альбом"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebarList
            } detail: {
                if sidebar == .database, let database = model.database {
                    DatabaseBrowser(db: database)
                } else if model.files.isEmpty {
                    Text(model.status).foregroundStyle(.secondary)
                } else {
                    photoBody
                }
            }
            .navigationTitle(detailTitle)
            statusBar
        }
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
        .task {
            await model.refresh()
            if !didPickYear, let year = model.years.first?.year {
                sidebar = .year(year)
                didPickYear = true
            }
            reorderTable()
        }
        .onChange(of: sidebar) { _, _ in reorderTable() }
        .onChange(of: query) { _, _ in reorderTable() }
        .onChange(of: model.files.count) { _, _ in reorderTable() }
        .onChange(of: model.groupsEpoch) { _, _ in
            if case .group = sidebar { reorderTable() }
        }
        .onChange(of: model.albumsEpoch) { _, _ in
            if case .album = sidebar { reorderTable() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                let n = model.purgeExpired()
                if n > 0 {
                    model.status = "Корзина очищена автоматически · \(n)"
                    reorderTable()
                }
            }
        }
        .onChange(of: model.pixelEpoch) { _, _ in
            if activeColumn == .pixels {
                reorderTable()
            } else {
                patchTablePixels()
            }
        }
        .sheet(item: $viewerItem) { item in
            Viewer(
                items: viewerList.isEmpty ? [item] : viewerList,
                start: item,
                root: model.mediaRoot,
                onCopy: { copy([$0]) },
                onShare: { share([$0]) },
                onClip: { command, file in clip(command, [file]) },
                onLibrary: { command, file in handleLibrary(command, [file]) },
                onExport: { export([$0]) }
            )
        }
        .sheet(isPresented: $grouping) { groupSheet }
        .sheet(isPresented: $makingAlbum) { albumSheet }
    }

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Section("Библиотека") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Все годы")
                    Text("\(model.files.count) · \(ByteText.string(model.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(SidebarItem.all)
                ForEach(model.years) { year in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(year.year)
                            if year.complete {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(year.count) · \(ByteText.string(year.bytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(SidebarItem.year(year.year))
                    .listRowBackground(
                        sidebar == .all && focusYear == year.year
                            ? Color.accentColor.opacity(0.28)
                            : Color.clear
                    )
                    .contextMenu {
                        Button("Показать") { sidebar = .year(year.year) }
                    }
                }
            }
            Section("Группы") {
                ForEach(model.groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                        Text("\(group.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.group(group.id))
                    .contextMenu {
                        Button("Удалить группу") {
                            model.deleteGroup(group.id)
                            if sidebar == .group(group.id) { sidebar = .all }
                        }
                    }
                }
            }
            Section("Альбомы") {
                if showAlbums {
                    ForEach(model.userAlbums) { album in
                        albumRow(album)
                    }
                    ForEach(model.albums.filter { $0.kind == "technical" }) { album in
                        albumRow(album)
                    }
                }
                Button(showAlbums ? "Скрыть альбомы" : "Показать альбомы") {
                    showAlbums.toggle()
                    if !showAlbums, case .album = sidebar { sidebar = .all }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("База") {
                Label("SQLite", systemImage: "tablecells")
                    .tag(SidebarItem.database)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        .safeAreaInset(edge: .bottom) {
            Text("Размеры и миниатюры считаются один раз")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var userAlbumOpen: Bool {
        if case .album(let id) = sidebar { return model.album(id)?.isUser == true }
        return false
    }

    private var trashOpen: Bool {
        if case .album(let id) = sidebar { return model.album(id)?.isTrash == true }
        return false
    }

    private func albumRow(_ album: PhotoAlbum) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.name)
            Text(album.isTrash ? "\(album.count) · 30 дней" : "\(album.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(SidebarItem.album(album.id))
        .contextMenu {
            Button("Экспорт альбома") { exportAlbum(album) }
            if album.isTrash {
                Button("Очистить корзину") { emptyTrash() }
            }
            if album.isUser {
                Button("Удалить альбом") {
                    model.database?.deleteAlbum(album.id)
                    model.reloadAlbums()
                    if sidebar == .album(album.id) { sidebar = .all }
                }
            }
        }
    }

    private var activeMonths: [MonthSection] {
        guard case .year(let year) = sidebar else { return [] }
        return monthSections.filter { $0.year == year }
    }

    private var browserFiles: [FileRecord] {
        let months = activeMonths
        if !months.isEmpty { return months.flatMap(\.files) }
        return visible
    }

    @ViewBuilder
    private var photoBody: some View {
        if case .all = sidebar {
            allYearsBody
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if !activeMonths.isEmpty {
                        monthStrip { section in
                            jump(to: section, proxy: proxy)
                        }
                    }
                    switch mode {
                    case .thumbs:
                        thumbGrid
                    case .table:
                        fileTable
                    case .gallery:
                        gallery
                    }
                }
            }
        }
    }

    private var allYearsBody: some View {
        HStack(spacing: 0) {
            yearRail
            VStack(spacing: 0) {
                allMonthStrip
                switch mode {
                case .thumbs:
                    mosaicGrid
                case .table:
                    fileTable
                case .gallery:
                    gallery
                }
            }
        }
    }

    private var yearRail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.years) { year in
                        let on = focusYear == year.year
                        Button {
                            jumpAll(year: year.year, month: mosaic.months[year.year]?.max())
                        } label: {
                            Text(year.year)
                                .font(on ? .headline : .body.monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, on ? 8 : 4)
                                .background(on ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .id(year.year)
                    }
                }
                .padding(8)
            }
            .frame(width: 84)
            .background(.bar)
            .onChange(of: focusYear) { _, year in
                guard let year else { return }
                proxy.scrollTo(year, anchor: .center)
            }
        }
    }

    private var allMonthStrip: some View {
        let months = (mosaic.months[focusYear ?? ""] ?? []).sorted()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let focusYear {
                    Text(focusYear)
                        .font(.headline)
                }
                if let focusMonth, (1...12).contains(focusMonth) {
                    Text(CaptureCalendar.names[focusMonth - 1])
                        .font(.headline)
                        .padding(.trailing, 4)
                }
                ForEach(months, id: \.self) { month in
                    let on = focusMonth == month
                    Button {
                        if let focusYear {
                            jumpAll(year: focusYear, month: month)
                        }
                    } label: {
                        Text(CaptureCalendar.shortNames[month - 1])
                            .font(.caption.weight(on ? .bold : .regular))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(on ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var mosaicGrid: some View {
        MosaicGrid(
            index: mosaic,
            cell: mosaicCell,
            selection: selection,
            database: model.database,
            indexer: model.indexer,
            groups: model.groups,
            token: mosaicToken,
            scrollIndex: mosaicJumpIndex,
            scrollToken: mosaicJumpToken,
            onVisible: { file in
                guard Date().timeIntervalSinceReferenceDate > pinMonthUntil else { return }
                noteFocus(file)
            },
            onSelection: { selection = $0 },
            onOpen: { open($0) },
            onCopy: { copy($0) },
            onShare: { share($0) },
            onExport: { export($0) },
            onClip: { command, files in clip(command, files) },
            onAddToGroup: { name, files in model.makeGroup(name: name, paths: files.map(\.path)) },
            onNewGroup: { files in
                selection = Set(files.map(\.path))
                grouping = true
            },
            onScroll: { model.indexer.setPaused($0) },
            libraryAlbums: model.userAlbums,
            inUserAlbum: userAlbumOpen,
            inTrash: trashOpen,
            onLibrary: { command, files in handleLibrary(command, files) }
        )
    }

    private func noteFocus(_ file: FileRecord) {
        focusYear = file.year
        focusMonth = CaptureCalendar.month(file.created)
    }

    private func jumpAll(year: String, month: Int?) {
        pinMonthUntil = Date().timeIntervalSinceReferenceDate + 0.35
        focusYear = year
        if let month { focusMonth = month }
        switch mode {
        case .thumbs:
            let key = month.map { "\(year)-\($0)" }
            mosaicJumpIndex = key.flatMap { mosaic.monthStart[$0] } ?? mosaic.yearStart[year] ?? 0
            mosaicJumpToken &+= 1
        case .table:
            if let row = tableOrder.first(where: { row in
                row.year == year && (month == nil || CaptureCalendar.month(row.created) == month)
            }) {
                selection = [row.path]
                anchor = row.path
                tableScrollPath = row.path
                tableScrollToken &+= 1
            }
        case .gallery:
            if let file = mosaic.files.first(where: { file in
                file.year == year && (month == nil || CaptureCalendar.month(file.created) == month)
            }) {
                selection = [file.path]
                anchor = file.path
                galleryAnchor = file.path
            }
        }
    }

    private func monthStrip(jump: @escaping (MonthSection) -> Void) -> some View {
        let sections = activeMonths.filter { $0.month >= 1 }.sorted { $0.month < $1.month }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sections) { section in
                        let on = jumpedMonth == section.month
                        Button {
                            jump(section)
                        } label: {
                            Text("\(CaptureCalendar.shortNames[section.month - 1]) \(section.files.count)")
                                .font(.caption.weight(on ? .bold : .regular).monospacedDigit())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(on ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06), in: Capsule())
                        .overlay {
                            Capsule().stroke(on ? Color.accentColor : Color.clear, lineWidth: 1)
                        }
                        .id(section.month)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .onChange(of: jumpedMonth) { _, month in
                guard let month else { return }
                proxy.scrollTo(month, anchor: .center)
            }
            .onAppear {
                if let jumpedMonth {
                    proxy.scrollTo(jumpedMonth, anchor: .center)
                }
            }
        }
    }

    private func jump(to section: MonthSection, proxy: ScrollViewProxy) {
        jumpedMonth = section.month
        pinMonthUntil = Date().timeIntervalSinceReferenceDate + 0.45
        guard let newest = section.files.first else { return }
        switch mode {
        case .thumbs:
            selection = [newest.path]
            anchor = newest.path
            gridScrollToken &+= 1
        case .gallery:
            selection = [newest.path]
            anchor = newest.path
            galleryAnchor = newest.path
            proxy.scrollTo(newest.path, anchor: .leading)
        case .table:
            let path = tableOrder.first { CaptureCalendar.month($0.created) == section.month }?.path ?? newest.path
            selection = [path]
            anchor = path
            tableScrollPath = path
            tableScrollToken &+= 1
        }
    }

    @ViewBuilder
    private var thumbGrid: some View {
        if activeMonths.isEmpty {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSide), spacing: 12)], spacing: 16) {
                    ForEach(visible) { file in
                        card(file)
                    }
                }
                .padding(16)
            }
            .pauseIndexingWhileScrolling(model.indexer)
        } else {
            MonthGrid(
                sections: activeMonths,
                thumbSide: thumbSide,
                selection: selection,
                database: model.database,
                indexer: model.indexer,
                groups: model.groups,
                scrollMonth: jumpedMonth,
                scrollToken: gridScrollToken,
                onVisibleMonth: { month in
                    guard Date().timeIntervalSinceReferenceDate > pinMonthUntil else { return }
                    if jumpedMonth != month { jumpedMonth = month }
                },
                onSelection: { selection = $0 },
                onOpen: { open($0) },
                onCopy: { copy($0) },
                onShare: { share($0) },
                onExport: { export($0) },
                onAddToGroup: { name, files in model.makeGroup(name: name, paths: files.map(\.path)) },
                onNewGroup: { files in
                    selection = Set(files.map(\.path))
                    grouping = true
                },
                onScroll: { model.indexer.setPaused($0) },
                onClip: { command, files in clip(command, files) },
                libraryAlbums: model.userAlbums,
                inUserAlbum: userAlbumOpen,
                inTrash: trashOpen,
                onLibrary: { command, files in handleLibrary(command, files) }
            )
        }
    }

    private func card(_ file: FileRecord) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                CachedThumb(path: file.path, db: model.database, indexer: model.indexer, video: file.isVideo)
                if file.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .padding(6)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }
            .frame(height: thumbSide)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selection.contains(file.path) ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            Text(file.name).font(.caption).lineLimit(1)
            Text(DateText.string(file.created))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(ByteText.string(file.size))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(file) }
        .simultaneousGesture(TapGesture().onEnded { select(file.path) })
        .contextMenu { itemMenu(file) }
        .help("\(file.name)\n\(DateText.string(file.created))\n\(ByteText.string(file.size))")
    }

    private var fileTable: some View {
        HardwareTable(
            rows: tableOrder,
            token: tableToken,
            column: activeColumn,
            descending: sortDescending,
            selection: selection,
            groups: model.groups,
            onSort: { column, descending in
                reorderTable(column: column, descending: descending)
            },
            onSelection: { paths in
                selection = paths
                guard case .all = sidebar, paths.count == 1, let path = paths.first,
                      let row = tableOrder.first(where: { $0.path == path }) else { return }
                noteFocus(live(row))
            },
            onOpen: { index in
                guard tableOrder.indices.contains(index) else { return }
                open(live(tableOrder[index]))
            },
            onCopy: { paths in copy(records(paths)) },
            onShare: { paths in share(records(paths)) },
            onExport: { paths in export(records(paths)) },
            scrollPath: tableScrollPath,
            scrollToken: tableScrollToken,
            onAddToGroup: { name, paths in model.makeGroup(name: name, paths: paths) },
            onNewGroup: { paths in
                selection = Set(paths)
                grouping = true
            },
            onScroll: { model.indexer.setPaused($0) },
            onVisibleMonth: { year, month in
                guard Date().timeIntervalSinceReferenceDate > pinMonthUntil else { return }
                switch sidebar {
                case .year:
                    if jumpedMonth != month { jumpedMonth = month }
                case .all:
                    if focusYear != year { focusYear = year }
                    if focusMonth != month { focusMonth = month }
                default:
                    break
                }
            },
            onClip: { command, paths in clip(command, records(paths)) },
            libraryAlbums: model.userAlbums,
            inUserAlbum: userAlbumOpen,
            inTrash: trashOpen,
            onLibrary: { command, paths in handleLibrary(command, records(paths)) }
        )
    }

    private var gallery: some View {
        let files: [FileRecord] = {
            if case .all = sidebar, !mosaic.files.isEmpty { return mosaic.files }
            return browserFiles
        }()
        let current = galleryItem
        return VStack(spacing: 0) {
            ZStack {
                Color.black
                if let current, let root = model.mediaRoot {
                    if current.isVideo {
                        VideoPane(
                            url: fileURL(root: root, file: current),
                            onCopy: { copy([current]) },
                            onShare: { share([current]) },
                            onClip: { clip($0, [current]) },
                            onTrash: { trash([current]) },
                            onPurge: { purge([current]) },
                            onRestore: { restore([current]) }
                        )
                    } else {
                        StillPhoto(url: fileURL(root: root, file: current), maxPixel: ThumbSpec.previewMaxPixel)
                            .contextMenu { copyShareMenu([current]) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                if let current {
                    copyShareMenu([current])
                }
            }
            if let current {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.name).font(.headline).lineLimit(1)
                        Text(DateText.string(current.created))
                            .font(.callout.monospacedDigit())
                        Text("\(ByteText.string(current.size)) · \(current.pixelLabel) · \(current.year)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Просмотр") { open(current) }
                    Button("Скопировать") { copy([current]) }
                    Button("Поделиться") { share([current]) }
                    Button("Выгрузить") { export([current]) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(files) { file in
                        VStack(spacing: 2) {
                            CachedThumb(path: file.path, db: model.database, indexer: model.indexer, video: file.isVideo)
                                .frame(width: 104, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(current?.path == file.path ? Color.accentColor : Color.clear, lineWidth: 2)
                                }
                            Text(DateText.string(file.created))
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(width: 104)
                        }
                        .id(file.path)
                        .onTapGesture {
                            selection = [file.path]
                            if case .all = sidebar {
                                noteFocus(file)
                            } else if let month = CaptureCalendar.month(file.created) {
                                jumpedMonth = month
                            }
                        }
                        .onTapGesture(count: 2) { open(file) }
                        .contextMenu { itemMenu(file) }
                        .help(DateText.string(file.created))
                    }
                }
                .padding(10)
                .modifier(ScrollTargets())
            }
            .frame(height: 118)
            .modifier(ScrollFollow(anchor: $galleryAnchor, pinUntil: $pinMonthUntil) { path in
                guard let file = files.first(where: { $0.path == path }) else { return }
                if case .all = sidebar {
                    noteFocus(file)
                    return
                }
                guard let month = CaptureCalendar.month(file.created), jumpedMonth != month else { return }
                jumpedMonth = month
            })
            .pauseIndexingWhileScrolling(model.indexer)
        }
        .pauseIndexingWhileScrolling(model.indexer)
    }

    private var galleryItem: FileRecord? {
        if let path = selectedRecords.first { return path }
        return browserFiles.first
    }

    private var statusBar: some View {
        StatusLine(
            indexStatus: model.indexStatus,
            status: model.status,
            selectionCount: selection.count,
            selectionDate: selectedRecords.count == 1 ? DateText.string(selectedRecords[0].created) : nil
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Picker("Вид", selection: $mode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.thumbs)
                Image(systemName: "list.bullet").tag(ViewMode.table)
                Image(systemName: "rectangle.grid.1x2").tag(ViewMode.gallery)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Миниатюры, таблица или галерея")
            if mode == .thumbs, sidebar == .all {
                Slider(value: $mosaicCell, in: 6...36)
                    .frame(width: 140)
                    .help("Размер мозаики")
            } else if mode == .thumbs {
                Slider(value: $thumbSide, in: 72...280)
                    .frame(width: 140)
                    .help("Размер миниатюр")
                    .onChange(of: thumbSide) { _, _ in
                        model.indexer.setPaused(true)
                        resizeToken += 1
                        let token = resizeToken
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            guard token == resizeToken else { return }
                            model.indexer.setPaused(false)
                        }
                    }
            }
            TextField("Поиск", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if sidebar != .database {
                Button("Просмотр") { openSelected() }
                    .disabled(selectedRecords.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button("Скопировать") { copy(selectedRecords) }
                    .disabled(selectedRecords.isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Выгрузить") { export(selectedRecords) }
                    .disabled(selectedRecords.isEmpty)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Группа") { grouping = true }
                    .disabled(selectedRecords.isEmpty)
                Button("В корзину") { trash(selectedRecords) }
                    .disabled(selectedRecords.isEmpty)
                Button("Навсегда") { purge(selectedRecords) }
                    .disabled(selectedRecords.isEmpty)
                Button("Отменить удаление") { undoTrash() }
                    .disabled(lastTrash.isEmpty)
                if case .album(let id) = sidebar, let album = model.album(id) {
                    Button("Экспорт альбома") { exportAlbum(album) }
                    if album.isTrash {
                        Button("Восстановить") { restore(selectedRecords) }
                            .disabled(selectedRecords.isEmpty)
                        Button("Очистить корзину") { emptyTrash() }
                    }
                }
                if case .group(let id) = sidebar {
                    Button("Убрать") { model.removeFromGroup(id, paths: selectedRecords.map(\.path)); selection = [] }
                        .disabled(selectedRecords.isEmpty)
                }
            }
        }
    }

    private var groupSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новая группа").font(.headline)
            Text("\(selectedRecords.count) файлов").foregroundStyle(.secondary)
            TextField("Название", text: $groupName)
            HStack {
                Button("Отмена") { grouping = false }
                Spacer()
                Button("Сохранить") {
                    model.makeGroup(name: groupName, paths: selectedRecords.map(\.path))
                    groupName = ""
                    grouping = false
                }
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var albumSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новый альбом").font(.headline)
            Text("\(selectedRecords.count) файлов").foregroundStyle(.secondary)
            TextField("Название", text: $albumName)
            HStack {
                Button("Отмена") { makingAlbum = false }
                Spacer()
                Button("Сохранить") {
                    model.createAlbum(name: albumName, paths: selectedRecords.map(\.path))
                    albumName = ""
                    makingAlbum = false
                    reorderTable()
                }
                .disabled(albumName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private func itemMenu(_ file: FileRecord) -> some View {
        Button("Просмотр") { open(file) }
        Button("Скопировать") {
            let files = selection.contains(file.path) ? selectedRecords : [file]
            copy(files)
        }
        clipButtons(selection.contains(file.path) ? selectedRecords : [file])
        libraryButtons(selection.contains(file.path) ? selectedRecords : [file])
        Button("Поделиться") {
            let files = selection.contains(file.path) ? selectedRecords : [file]
            share(files)
        }
        Button("Выгрузить…") {
            let files = selection.contains(file.path) ? selectedRecords : [file]
            export(files)
        }
        Menu("В группу") {
            ForEach(model.groups) { group in
                Button(group.name) {
                    let files = selection.contains(file.path) ? selectedRecords : [file]
                    model.makeGroup(name: group.name, paths: files.map(\.path))
                }
            }
            Button("Новая группа…") {
                if !selection.contains(file.path) { selection = [file.path] }
                grouping = true
            }
        }
    }

    private func records(_ paths: [String]) -> [FileRecord] {
        guard !paths.isEmpty else { return [] }
        var byPath: [String: RowRef] = [:]
        byPath.reserveCapacity(paths.count)
        let wanted = Set(paths)
        for row in tableOrder where wanted.contains(row.path) {
            byPath[row.path] = row
        }
        return paths.compactMap { byPath[$0].map(live) }
    }

    private func live(_ row: RowRef) -> FileRecord {
        let index = Int(row.index)
        if model.files.indices.contains(index), model.files[index].path == row.path {
            return model.files[index]
        }
        if let file = model.files.first(where: { $0.path == row.path }) {
            return file
        }
        return FileRecord(
            path: row.path,
            year: row.year,
            name: row.name,
            ext: "",
            isVideo: row.kindName == "Видео",
            size: row.size,
            width: 0,
            height: 0,
            created: row.created
        )
    }

    private func patchTablePixels() {
        let files = model.files
        var rows = tableOrder
        var changed = false
        for index in rows.indices {
            let source = Int(rows[index].index)
            guard files.indices.contains(source), files[source].path == rows[index].path else { continue }
            let file = files[source]
            if rows[index].width != file.width || rows[index].height != file.height {
                rows[index].width = file.width
                rows[index].height = file.height
                rows[index].pixelCount = file.pixelCount
                changed = true
            }
        }
        if changed {
            tableOrder = rows
            tableToken &+= 1
        }
    }

    @ViewBuilder
    private func copyShareMenu(_ files: [FileRecord]) -> some View {
        Button("Скопировать") { copy(files) }
        clipButtons(files)
        libraryButtons(files)
        Button("Поделиться") { share(files) }
    }

    @ViewBuilder
    private func libraryButtons(_ files: [FileRecord]) -> some View {
        let inTrash = files.allSatisfy { $0.trashedAt != 0 }
        if inTrash {
            Button("Восстановить") { restore(files) }
            Button("Удалить навсегда") { purge(files) }
            Button("Очистить корзину") { emptyTrash() }
        } else {
            Button("Удалить в корзину") { trash(files) }
            Button("Удалить навсегда") { purge(files) }
        }
        Menu("В альбом") {
            ForEach(model.userAlbums) { album in
                Button(album.name) { model.addToAlbum(album.id, paths: files.map(\.path)) }
            }
            Button("Новый альбом…") {
                selection = Set(files.map(\.path))
                makingAlbum = true
            }
        }
        if case .album(let id) = sidebar, model.album(id)?.isUser == true {
            Menu("Перенести в альбом") {
                ForEach(model.userAlbums.filter { $0.id != id }) { album in
                    Button(album.name) {
                        model.moveToAlbum(paths: files.map(\.path), from: id, to: album.id)
                        reorderTable()
                    }
                }
            }
            Button("Убрать из альбома") {
                model.removeFromAlbum(id, paths: files.map(\.path))
                reorderTable()
            }
        }
    }

    private func trash(_ files: [FileRecord]) {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        model.setTrashed(paths, at: now)
        lastTrash = paths
        selection = []
        model.status = "В корзине · \(paths.count) · 30 дней"
        reorderTable()
    }

    private func restore(_ files: [FileRecord]) {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        model.setTrashed(paths, at: 0)
        lastTrash.removeAll { paths.contains($0) }
        model.status = "Восстановлено · \(paths.count)"
        reorderTable()
    }

    private func undoTrash() {
        let paths = lastTrash
        guard !paths.isEmpty else { return }
        let files = model.files.filter { paths.contains($0.path) && $0.trashedAt != 0 }
        restore(files)
        lastTrash = []
    }

    private func purge(_ files: [FileRecord]) {
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить навсегда \(files.count)?"
        alert.informativeText = "Файлы пропадут из архива и с диска. Это нельзя отменить."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить навсегда")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = model.forget(files.map(\.path))
        selection = []
        model.status = "Удалено навсегда · \(n)"
        reorderTable()
    }

    private func emptyTrash() {
        let files = model.files.filter { $0.trashedAt != 0 }
        guard !files.isEmpty else {
            model.status = "Корзина пуста"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Очистить корзину (\(files.count))?"
        alert.informativeText = "Все файлы в корзине будут удалены с диска."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = model.forget(files.map(\.path))
        lastTrash = []
        selection = []
        model.status = "Корзина очищена · \(n)"
        reorderTable()
    }

    private func exportAlbum(_ album: PhotoAlbum) {
        let records = model.files.filter { file in
            if album.isTrash { return file.trashedAt != 0 }
            return model.albumPaths[album.id, default: []].contains(file.path) && file.trashedAt == 0
        }
        guard !records.isEmpty, model.mediaRoot != nil else {
            model.status = "В альбоме нет файлов"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Экспорт"
        panel.message = "Папка для альбома «\(album.name)»: \(records.count) файлов и album.sqlite"
        guard panel.runModal() == .OK, let folder = panel.url, let root = model.mediaRoot else { return }
        model.status = "Экспорт «\(album.name)»…"
        Task.detached {
            let saved = AlbumExport.write(folder: folder, album: album, files: records, root: root)
            let total = records.count
            await MainActor.run {
                model.status = "Альбом экспортирован · \(saved) из \(total)"
            }
        }
    }

    private func handleLibrary(_ command: LibraryCommand, _ files: [FileRecord]) {
        switch command {
        case .trash:
            trash(files)
        case .purge:
            purge(files)
        case .restore:
            restore(files)
        case .emptyTrash:
            emptyTrash()
        case .removeFromAlbum:
            if case .album(let id) = sidebar {
                model.removeFromAlbum(id, paths: files.map(\.path))
                reorderTable()
            }
        case .newAlbum:
            selection = Set(files.map(\.path))
            makingAlbum = true
        case .add(let id):
            model.addToAlbum(id, paths: files.map(\.path))
        case .move(let id):
            if case .album(let source) = sidebar {
                model.moveToAlbum(paths: files.map(\.path), from: source, to: id)
                reorderTable()
            }
        }
    }

    private func share(_ files: [FileRecord]) {
        guard let root = model.mediaRoot, !files.isEmpty else { return }
        let urls = files.map { fileURL(root: root, file: $0) }
        SharePresenter.shared.show(urls)
    }

    private func rebuildMonths() {
        guard case .year(let year) = sidebar else {
            monthSections = []
            jumpedMonth = nil
            return
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var files = model.files.filter { file in
            file.year == year && file.trashedAt == 0 && (needle.isEmpty || file.name.localizedStandardContains(needle))
        }
        files.sort { lhs, rhs in
            if lhs.created == rhs.created { return lhs.path < rhs.path }
            return lhs.created > rhs.created
        }
        var grouped: [Int: [FileRecord]] = [:]
        var undated: [FileRecord] = []
        for file in files {
            if let month = CaptureCalendar.month(file.created) {
                grouped[month, default: []].append(file)
            } else {
                undated.append(file)
            }
        }
        var sections: [MonthSection] = grouped.keys.sorted(by: >).compactMap { month in
            guard let files = grouped[month] else { return nil }
            return MonthSection(year: year, month: month, files: files)
        }
        if !undated.isEmpty {
            sections.append(MonthSection(year: year, month: 0, files: undated))
        }
        monthSections = sections
        if let jumpedMonth, !monthSections.contains(where: { $0.month == jumpedMonth }) {
            self.jumpedMonth = nil
        }
        if self.jumpedMonth == nil, let first = monthSections.first(where: { $0.month >= 1 }) {
            self.jumpedMonth = first.month
        }
    }

    private func rebuildMosaic() {
        guard case .all = sidebar else { return }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var files = model.files.filter { file in
            file.trashedAt == 0 && (needle.isEmpty || file.name.localizedStandardContains(needle))
        }
        files.sort { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            if lhs.created != rhs.created { return lhs.created > rhs.created }
            return lhs.path < rhs.path
        }
        var built = MosaicIndex()
        built.files = files
        for (index, file) in files.enumerated() {
            if built.yearStart[file.year] == nil {
                built.yearStart[file.year] = index
            }
            guard let month = CaptureCalendar.month(file.created) else { continue }
            let key = "\(file.year)-\(month)"
            if built.monthStart[key] == nil {
                built.monthStart[key] = index
                built.months[file.year, default: []].append(month)
            }
        }
        mosaic = built
        mosaicToken &+= 1
        if focusYear == nil || built.yearStart[focusYear ?? ""] == nil, let first = files.first {
            focusYear = first.year
            focusMonth = CaptureCalendar.month(first.created)
        }
    }

    private func reorderTable(column: HardwareColumn? = nil, descending: Bool? = nil) {
        rebuildMonths()
        rebuildMosaic()
        if let column { activeColumn = column }
        if let descending { sortDescending = descending }
        let files = model.files
        guard !files.isEmpty else {
            tableOrder = []
            tableToken &+= 1
            return
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var indices: [UInt32] = []
        indices.reserveCapacity(files.count)
        let accept: (FileRecord) -> Bool = { file in
            needle.isEmpty || file.name.localizedStandardContains(needle)
        }
        let listed: (FileRecord) -> Bool = { file in
            if case .album(let id) = sidebar, model.album(id)?.isTrash == true {
                return file.trashedAt != 0 && accept(file)
            }
            return file.trashedAt == 0 && accept(file)
        }
        switch sidebar {
        case .all, .database:
            for (index, file) in files.enumerated() where listed(file) {
                indices.append(UInt32(index))
            }
        case .year(let year):
            for (index, file) in files.enumerated() where file.year == year && listed(file) {
                indices.append(UInt32(index))
            }
        case .group(let id):
            let paths = model.groupPaths[id] ?? []
            for (index, file) in files.enumerated() where paths.contains(file.path) && listed(file) {
                indices.append(UInt32(index))
            }
        case .album(let id):
            if model.album(id)?.isTrash == true {
                for (index, file) in files.enumerated() where listed(file) {
                    indices.append(UInt32(index))
                }
            } else {
                let paths = model.albumPaths[id] ?? []
                for (index, file) in files.enumerated() where paths.contains(file.path) && listed(file) {
                    indices.append(UInt32(index))
                }
            }
        }
        if model.sortKeys.count == files.count {
            model.sortKeys.permute(&indices, column: activeColumn, descending: sortDescending)
        }
        var rows: [RowRef] = []
        rows.reserveCapacity(indices.count)
        for index in indices {
            let file = files[Int(index)]
            rows.append(RowRef(
                index: index,
                path: file.path,
                name: file.name,
                created: file.created,
                year: file.year,
                kindName: file.kindName,
                size: file.size,
                width: file.width,
                height: file.height,
                pixelCount: file.pixelCount
            ))
        }
        tableOrder = rows
        tableToken &+= 1
    }

    private func select(_ path: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
            anchor = path
        } else if flags.contains(.shift), let anchor {
            let ordered = mode == .table && !tableOrder.isEmpty ? tableOrder.map { live($0) } : browserFiles
            if let start = ordered.firstIndex(where: { $0.path == anchor }),
               let end = ordered.firstIndex(where: { $0.path == path }) {
                let slice = ordered[min(start, end)...max(start, end)]
                selection = Set(slice.map(\.path))
            }
        } else {
            selection = [path]
            anchor = path
        }
        if case .all = sidebar, let file = model.files.first(where: { $0.path == path }) {
            noteFocus(file)
        }
        model.indexer.prioritize(path)
    }

    private func open(_ file: FileRecord) {
        if mode == .table, !tableOrder.isEmpty {
            viewerList = tableOrder.map { live($0) }
        } else if case .all = sidebar, !mosaic.files.isEmpty {
            viewerList = mosaic.files
        } else {
            viewerList = browserFiles
        }
        if viewerList.isEmpty { viewerList = [file] }
        viewerItem = file
    }

    private func openSelected() {
        if let file = selectedRecords.first { open(file) }
    }

    private func clip(_ command: ClipCommand, _ files: [FileRecord]) {
        guard !files.isEmpty else { return }
        switch command {
        case .name:
            FileClip.copyText(FileClip.names(files))
            model.status = files.count == 1 ? "Имя скопировано" : "Имена скопированы · \(files.count)"
        case .path, .folder:
            guard let root = model.mediaRoot else { return }
            FileClip.copyText(FileClip.paths(files, root: root, named: command == .path))
            model.status = command == .path ? "Путь скопирован" : "Путь без имени скопирован"
        case .finder:
            guard let root = model.mediaRoot else { return }
            FileClip.reveal(files.map { fileURL(root: root, file: $0) })
            model.status = "Открыто в Finder"
        }
    }

    @ViewBuilder
    private func clipButtons(_ files: [FileRecord]) -> some View {
        Button("Копировать имя") { clip(.name, files) }
        Button("Копировать путь") { clip(.path, files) }
        Button("Копировать путь без имени") { clip(.folder, files) }
        Button("Показать в Finder") { clip(.finder, files) }
    }

    private func copy(_ files: [FileRecord]) {
        guard let root = model.mediaRoot, !files.isEmpty else { return }
        let urls = files.map { fileURL(root: root, file: $0) as NSURL }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(urls)
        model.status = "Скопировано \(urls.count) · \(ByteText.string(files.reduce(0) { $0 + $1.size }))"
    }

    private func export(_ files: [FileRecord]) {
        guard let root = model.mediaRoot, !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выгрузить"
        panel.message = "Папка для \(files.count) файлов"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let pairs = files.map { (fileURL(root: root, file: $0), $0.name) }
        model.status = "Выгружаю \(files.count)…"
        Task.detached {
            var saved = 0
            for pair in pairs {
                let dest = uniqueDestination(folder: folder, name: pair.1)
                do {
                    try FileManager.default.copyItem(at: pair.0, to: dest)
                    saved += 1
                } catch {
                    continue
                }
            }
            let savedCount = saved
            let total = files.count
            await MainActor.run {
                model.status = "Выгружено \(savedCount) из \(total)"
            }
        }
    }
}

func uniqueDestination(folder: URL, name: String) -> URL {
    let direct = folder.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: direct.path) { return direct }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 2
    while true {
        let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
        let url = folder.appendingPathComponent(candidate)
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        number += 1
    }
}

struct StatusLine: View {
    @ObservedObject var indexStatus: IndexStatus
    var status: String
    var selectionCount: Int
    var selectionDate: String?

    var body: some View {
        HStack {
            Text(status)
            if selectionCount > 0 {
                Text("· выбрано \(selectionCount)")
            }
            if let selectionDate {
                Text("· \(selectionDate)").monospacedDigit()
            }
            Spacer()
            Text(indexStatus.text)
            Text("ImageIO · VideoToolbox · M-series")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

extension View {
    func pauseIndexingWhileScrolling(_ indexer: Indexer) -> some View {
        modifier(ScrollPauseModifier(indexer: indexer))
    }
}

struct ScrollTargets: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.scrollTargetLayout()
        } else {
            content
        }
    }
}

struct ScrollFollow: ViewModifier {
    @Binding var anchor: String?
    @Binding var pinUntil: TimeInterval
    var onPath: (String) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .scrollPosition(id: $anchor, anchor: .leading)
                .onChange(of: anchor) { _, path in
                    guard Date().timeIntervalSinceReferenceDate > pinUntil, let path else { return }
                    onPath(path)
                }
        } else {
            content
        }
    }
}

struct ScrollPauseModifier: ViewModifier {
    let indexer: Indexer

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                indexer.setPaused(phase != .idle)
            }
        } else {
            content
        }
    }
}

struct CachedThumb: View {
    let path: String
    let db: LibraryDB?
    let indexer: Indexer
    var video: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.04)
            }
        }
        .clipped()
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let db else { return }
        if let cached = ThumbMemory.shared.cached(path: path) {
            image = cached
            return
        }
        // Skip disk and database work while the cell is only flashing past.
        try? await Task.sleep(nanoseconds: 160_000_000)
        if Task.isCancelled { return }
        while indexer.isPaused() {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if Task.isCancelled { return }
        }
        if let loaded = await fetch(db) {
            image = loaded
            return
        }
        let queue = indexer
        let itemPath = path
        let queued = await Task.detached(priority: .background) {
            queue.prioritize(itemPath)
            return queue.isQueued(itemPath)
        }.value
        guard queued else { return }
        await ReadyThumbs.shared.wait(itemPath)
        if Task.isCancelled { return }
        if let loaded = await fetch(db) {
            image = loaded
        }
    }

    private func fetch(_ db: LibraryDB) async -> NSImage? {
        let itemPath = path
        let data = await Task.detached(priority: .utility) { db.thumbJPEG(itemPath) }.value
        guard let data else { return nil }
        return ThumbMemory.shared.image(path: itemPath, data: data)
    }
}

struct StillPhoto: View {
    let url: URL
    var maxPixel: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let pixels = maxPixel
            let data = await Task.detached { previewJPEG(url: url, maxPixel: pixels) }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

struct Viewer: View {
    let items: [FileRecord]
    let start: FileRecord
    let root: URL?
    var onCopy: (FileRecord) -> Void
    var onShare: (FileRecord) -> Void
    var onClip: (ClipCommand, FileRecord) -> Void
    var onLibrary: (LibraryCommand, FileRecord) -> Void
    var onExport: (FileRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        let item = items[index]
        ZStack {
            Color.black.ignoresSafeArea()
            if let root {
                if item.isVideo {
                    VideoPane(
                        url: fileURL(root: root, file: item),
                        onCopy: { onCopy(item) },
                        onShare: { onShare(item) },
                        onClip: { onClip($0, item) },
                        onTrash: { onLibrary(.trash, item) },
                        onPurge: { onLibrary(.purge, item) },
                        onRestore: { onLibrary(.restore, item) }
                    )
                } else {
                    StillPhoto(url: fileURL(root: root, file: item), maxPixel: ThumbSpec.previewMaxPixel)
                        .contextMenu { viewerActions(item) }
                }
            }
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout).lineLimit(1)
                        Text(DateText.string(item.created))
                            .font(.callout.monospacedDigit())
                        Text("\(ByteText.string(item.size)) · \(item.pixelLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(index + 1) / \(items.count)").monospacedDigit()
                    Button("Скопировать") { onCopy(item) }
                    Button("Поделиться") { onShare(item) }
                    Button("Выгрузить") { onExport(item) }
                    Button("Закрыть") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                .contextMenu { viewerActions(item) }
                Spacer()
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index + 1 >= items.count)
                }
                .font(.title2)
                .padding(20)
                .contextMenu { viewerActions(item) }
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .contextMenu { viewerActions(item) }
        .onAppear { index = items.firstIndex(of: start) ?? 0 }
    }

    @ViewBuilder
    private func viewerActions(_ item: FileRecord) -> some View {
        Button("Скопировать") { onCopy(item) }
        Button("Копировать имя") { onClip(.name, item) }
        Button("Копировать путь") { onClip(.path, item) }
        Button("Копировать путь без имени") { onClip(.folder, item) }
        Button("Показать в Finder") { onClip(.finder, item) }
        Button("Поделиться") { onShare(item) }
        if item.trashedAt != 0 {
            Button("Восстановить") { onLibrary(.restore, item) }
            Button("Удалить навсегда") { onLibrary(.purge, item) }
        } else {
            Button("Удалить в корзину") { onLibrary(.trash, item) }
            Button("Удалить навсегда") { onLibrary(.purge, item) }
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if items.indices.contains(next) { index = next }
    }
}

struct VideoPane: NSViewRepresentable {
    let url: URL
    var onCopy: () -> Void
    var onShare: () -> Void
    var onClip: (ClipCommand) -> Void
    var onTrash: () -> Void = {}
    var onPurge: () -> Void = {}
    var onRestore: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onCopy: () -> Void = {}
        var onShare: () -> Void = {}
        var onClip: (ClipCommand) -> Void = { _ in }
        var onTrash: () -> Void = {}
        var onPurge: () -> Void = {}
        var onRestore: () -> Void = {}

        @objc func copyItem(_ sender: Any?) { onCopy() }
        @objc func shareItem(_ sender: Any?) { onShare() }
        @objc func nameItem(_ sender: Any?) { onClip(.name) }
        @objc func pathItem(_ sender: Any?) { onClip(.path) }
        @objc func folderItem(_ sender: Any?) { onClip(.folder) }
        @objc func finderItem(_ sender: Any?) { onClip(.finder) }
        @objc func trashItem(_ sender: Any?) { onTrash() }
        @objc func purgeItem(_ sender: Any?) { onPurge() }
        @objc func restoreItem(_ sender: Any?) { onRestore() }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        view.player?.play()
        view.menu = menu(context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.onCopy = onCopy
        context.coordinator.onShare = onShare
        context.coordinator.onClip = onClip
        context.coordinator.onTrash = onTrash
        context.coordinator.onPurge = onPurge
        context.coordinator.onRestore = onRestore
        if view.menu?.items.first?.action != #selector(Coordinator.copyItem(_:)) {
            view.menu = menu(context.coordinator)
        }
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
            view.player?.play()
        }
    }

    private func menu(_ coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func entry(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = coordinator
            return item
        }
        menu.items = [
            entry("Скопировать", #selector(Coordinator.copyItem(_:))),
            entry("Копировать имя", #selector(Coordinator.nameItem(_:))),
            entry("Копировать путь", #selector(Coordinator.pathItem(_:))),
            entry("Копировать путь без имени", #selector(Coordinator.folderItem(_:))),
            entry("Показать в Finder", #selector(Coordinator.finderItem(_:))),
            entry("Поделиться", #selector(Coordinator.shareItem(_:))),
            entry("Удалить в корзину", #selector(Coordinator.trashItem(_:))),
            entry("Восстановить", #selector(Coordinator.restoreItem(_:))),
            entry("Удалить навсегда", #selector(Coordinator.purgeItem(_:))),
        ]
        return menu
    }
}

final class SharePresenter: NSObject {
    static let shared = SharePresenter()
    private var picker: NSSharingServicePicker?

    func show(_ urls: [URL]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            self.picker = picker
            guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
            let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 2, height: 2)
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }
}
