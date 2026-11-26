import AppKit
import SwiftUI

struct MosaicIndex {
    var files: [FileRecord] = []
    var months: [String: [Int]] = [:]
    var yearStart: [String: Int] = [:]
    var monthStart: [String: Int] = [:]
}

// One view draws every tiny cell. Thirty thousand item views would not scroll.
struct MosaicGrid: NSViewRepresentable {
    var index: MosaicIndex
    var cell: Double
    var selection: Set<String>
    var database: LibraryDB?
    var indexer: Indexer
    var groups: [PhotoGroup]
    var token: Int
    var scrollIndex: Int
    var scrollToken: Int
    var onVisible: (FileRecord) -> Void
    var onSelection: (Set<String>) -> Void
    var onOpen: (FileRecord) -> Void
    var onCopy: ([FileRecord]) -> Void
    var onShare: ([FileRecord]) -> Void
    var onExport: ([FileRecord]) -> Void
    var onClip: (ClipCommand, [FileRecord]) -> Void
    var onAddToGroup: (String, [FileRecord]) -> Void
    var onNewGroup: ([FileRecord]) -> Void
    var onScroll: (Bool) -> Void
    var libraryAlbums: [PhotoAlbum] = []
    var inUserAlbum: Bool = false
    var inTrash: Bool = false
    var onLibrary: (LibraryCommand, [FileRecord]) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MosaicScroll {
        let scroll = MosaicScroll()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let canvas = MosaicCanvas()
        canvas.coordinator = context.coordinator
        scroll.documentView = canvas
        context.coordinator.attach(scroll: scroll, canvas: canvas)
        return scroll
    }

    func updateNSView(_ scroll: MosaicScroll, context: Context) {
        let coordinator = context.coordinator
        coordinator.database = database
        coordinator.indexer = indexer
        coordinator.groups = groups
        coordinator.onVisible = onVisible
        coordinator.onSelection = onSelection
        coordinator.onOpen = onOpen
        coordinator.onCopy = onCopy
        coordinator.onShare = onShare
        coordinator.onExport = onExport
        coordinator.onClip = onClip
        coordinator.onAddToGroup = onAddToGroup
        coordinator.onNewGroup = onNewGroup
        coordinator.onScroll = onScroll
        coordinator.libraryAlbums = libraryAlbums
        coordinator.inUserAlbum = inUserAlbum
        coordinator.inTrash = inTrash
        coordinator.onLibrary = onLibrary
        let canvas = scroll.canvas
        let filesChanged = coordinator.fileToken != token
        coordinator.fileToken = token
        canvas?.files = index.files
        canvas?.selection = selection
        let side = CGFloat(cell)
        let cellChanged = abs((canvas?.cell ?? 0) - side) > 0.5
        canvas?.cell = side
        if filesChanged || cellChanged {
            coordinator.fit(force: true)
            canvas?.needsDisplay = true
            coordinator.loadVisible()
        }
        if coordinator.appliedScroll != scrollToken {
            coordinator.appliedScroll = scrollToken
            coordinator.scrollTo(index: scrollIndex)
        }
    }

    static func dismantleNSView(_ nsView: MosaicScroll, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var database: LibraryDB?
        var indexer = Indexer()
        var groups: [PhotoGroup] = []
        var onVisible: (FileRecord) -> Void = { _ in }
        var onSelection: (Set<String>) -> Void = { _ in }
        var onOpen: (FileRecord) -> Void = { _ in }
        var onCopy: ([FileRecord]) -> Void = { _ in }
        var onShare: ([FileRecord]) -> Void = { _ in }
        var onExport: ([FileRecord]) -> Void = { _ in }
        var onClip: (ClipCommand, [FileRecord]) -> Void = { _, _ in }
        var onAddToGroup: (String, [FileRecord]) -> Void = { _, _ in }
        var onNewGroup: ([FileRecord]) -> Void = { _ in }
        var onScroll: (Bool) -> Void = { _ in }
        var libraryAlbums: [PhotoAlbum] = []
        var inUserAlbum = false
        var inTrash = false
        var onLibrary: (LibraryCommand, [FileRecord]) -> Void = { _, _ in }
        var appliedScroll = 0
        var fileToken = -1

        private weak var canvas: MosaicCanvas?
        private var observer: NSObjectProtocol?
        private var scrollTimer: Timer?
        private var loadTask: Task<Void, Never>?
        private var adjusting = false
        private var fitting = false
        private var lastPlace: String?
        private var anchorIndex = 0
        private var menuFiles: [FileRecord] = []

        func attach(scroll: MosaicScroll, canvas: MosaicCanvas) {
            self.canvas = canvas
            scroll.onLayout = { [weak self] in self?.fit(force: false) }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            canvas.menu = menu
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.userScrolled()
            }
        }

        func teardown() {
            loadTask?.cancel()
            scrollTimer?.invalidate()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            onScroll(false)
        }

        func fit(force: Bool) {
            guard !fitting, let canvas, let scroll = canvas.enclosingScrollView else { return }
            let width = scroll.contentView.bounds.width
            guard width > 2 else { return }
            let widthChanged = abs(canvas.frame.width - width) > 0.5
            if !force && !widthChanged { return }
            fitting = true
            defer { fitting = false }
            let keep = canvas.index(at: NSPoint(x: 1, y: scroll.contentView.bounds.minY + 1)) ?? anchorIndex
            canvas.relayout(width: width)
            scrollTo(index: keep)
        }

        func scrollTo(index: Int) {
            guard let canvas, let scroll = canvas.enclosingScrollView, !canvas.files.isEmpty else { return }
            let clamped = min(max(0, index), canvas.files.count - 1)
            anchorIndex = clamped
            let row = clamped / max(canvas.columns, 1)
            let y = CGFloat(row) * canvas.stride
            let maxOffset = max(0, canvas.frame.height - scroll.contentView.bounds.height)
            var origin = scroll.contentView.bounds.origin
            origin.y = min(max(0, y), maxOffset)
            adjusting = true
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            adjusting = false
            publishVisible()
        }

        func loadVisible() {
            guard let canvas, let database, let clip = canvas.enclosingScrollView?.contentView else { return }
            let paths = canvas.paths(in: clip.bounds.insetBy(dx: 0, dy: -canvas.stride * 4))
            loadTask?.cancel()
            loadTask = Task { @MainActor in
                var missing: [String] = []
                for path in paths {
                    if Task.isCancelled { return }
                    if let image = ThumbMemory.shared.cached(path: path) {
                        canvas.remember(path, image)
                    } else {
                        missing.append(path)
                    }
                }
                canvas.needsDisplay = true
                var start = 0
                while start < missing.count {
                    if Task.isCancelled { return }
                    let end = min(start + 6, missing.count)
                    let batch = Array(missing[start..<end])
                    let loaded = await Task.detached { () -> [(String, Data)] in
                        batch.compactMap { path in database.thumbJPEG(path).map { (path, $0) } }
                    }.value
                    guard !Task.isCancelled else { return }
                    for (path, data) in loaded {
                        if let image = ThumbMemory.shared.image(path: path, data: data) {
                            canvas.remember(path, image)
                        }
                    }
                    canvas.needsDisplay = true
                    start = end
                }
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let canvas, let event = NSApp.currentEvent else { return }
            let point = canvas.convert(event.locationInWindow, from: nil)
            guard let index = canvas.index(at: point) else { return }
            let file = canvas.files[index]
            if canvas.selection.contains(file.path), canvas.selection.count > 1 {
                menuFiles = canvas.files.filter { canvas.selection.contains($0.path) }
            } else {
                menuFiles = [file]
            }
            menu.addItem(item("Просмотр", #selector(openMenu(_:))))
            menu.addItem(item("Скопировать", #selector(copyMenu(_:))))
            menu.addItem(item("Копировать имя", #selector(nameMenu(_:))))
            menu.addItem(item("Копировать путь", #selector(pathMenu(_:))))
            menu.addItem(item("Копировать путь без имени", #selector(folderMenu(_:))))
            menu.addItem(item("Показать в Finder", #selector(finderMenu(_:))))
            menu.addItem(item("Поделиться", #selector(shareMenu(_:))))
            menu.addItem(item("Выгрузить…", #selector(exportMenu(_:))))
            let groupMenu = NSMenu()
            groupMenu.autoenablesItems = false
            for group in groups {
                let entry = item(group.name, #selector(addToGroup(_:)))
                entry.representedObject = group.name
                groupMenu.addItem(entry)
            }
            if !groups.isEmpty { groupMenu.addItem(.separator()) }
            groupMenu.addItem(item("Новая группа…", #selector(newGroup(_:))))
            let parent = NSMenuItem(title: "В группу", action: nil, keyEquivalent: "")
            parent.submenu = groupMenu
            menu.addItem(parent)
            addLibraryMenu(
                menu,
                target: self,
                albums: libraryAlbums,
                inUserAlbum: inUserAlbum,
                inTrash: inTrash,
                trash: #selector(trashMenu(_:)),
                purge: #selector(purgeMenu(_:)),
                restore: #selector(restoreMenu(_:)),
                remove: #selector(removeAlbumMenu(_:)),
                empty: #selector(emptyTrashMenu(_:)),
                newAlbum: #selector(newAlbumMenu(_:)),
                add: #selector(addAlbumMenu(_:)),
                move: #selector(moveAlbumMenu(_:))
            )
        }

        @objc private func openMenu(_ sender: Any?) { if let file = menuFiles.first { onOpen(file) } }
        @objc private func copyMenu(_ sender: Any?) { onCopy(menuFiles) }
        @objc private func nameMenu(_ sender: Any?) { onClip(.name, menuFiles) }
        @objc private func pathMenu(_ sender: Any?) { onClip(.path, menuFiles) }
        @objc private func folderMenu(_ sender: Any?) { onClip(.folder, menuFiles) }
        @objc private func finderMenu(_ sender: Any?) { onClip(.finder, menuFiles) }
        @objc private func shareMenu(_ sender: Any?) { onShare(menuFiles) }
        @objc private func exportMenu(_ sender: Any?) { onExport(menuFiles) }
        @objc private func addToGroup(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            onAddToGroup(name, menuFiles)
        }
        @objc private func newGroup(_ sender: Any?) { onNewGroup(menuFiles) }
        @objc private func trashMenu(_ sender: Any?) { onLibrary(.trash, menuFiles) }
        @objc private func purgeMenu(_ sender: Any?) { onLibrary(.purge, menuFiles) }
        @objc private func restoreMenu(_ sender: Any?) { onLibrary(.restore, menuFiles) }
        @objc private func removeAlbumMenu(_ sender: Any?) { onLibrary(.removeFromAlbum, menuFiles) }
        @objc private func emptyTrashMenu(_ sender: Any?) { onLibrary(.emptyTrash, menuFiles) }
        @objc private func newAlbumMenu(_ sender: Any?) { onLibrary(.newAlbum, menuFiles) }
        @objc private func addAlbumMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSNumber else { return }
            onLibrary(.add(id.int64Value), menuFiles)
        }
        @objc private func moveAlbumMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSNumber else { return }
            onLibrary(.move(id.int64Value), menuFiles)
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            return entry
        }

        private func userScrolled() {
            if adjusting { return }
            publishVisible()
            onScroll(true)
            loadTask?.cancel()
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                self?.onScroll(false)
                self?.loadVisible()
            }
        }

        private func publishVisible() {
            guard let canvas, let clip = canvas.enclosingScrollView?.contentView, !canvas.files.isEmpty else { return }
            let index = canvas.index(at: NSPoint(x: 1, y: clip.bounds.minY + 1)) ?? 0
            guard canvas.files.indices.contains(index) else { return }
            anchorIndex = index
            let file = canvas.files[index]
            let month = CaptureCalendar.month(file.created) ?? 0
            let place = "\(file.year)-\(month)"
            guard place != lastPlace else { return }
            lastPlace = place
            onVisible(file)
        }
    }
}

final class MosaicScroll: NSScrollView {
    var canvas: MosaicCanvas? { documentView as? MosaicCanvas }
    var onLayout: (() -> Void)?
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class MosaicCanvas: NSView {
    weak var coordinator: MosaicGrid.Coordinator?
    var files: [FileRecord] = []
    var selection: Set<String> = []
    var cell: CGFloat = 14
    var gap: CGFloat = 1
    var columns = 1
    var stride: CGFloat { cell + gap }
    private var images: [String: NSImage] = [:]
    private var anchorPath: String?

    override var isFlipped: Bool { true }

    func remember(_ path: String, _ image: NSImage) {
        if images.count > 2400, let drop = images.keys.first, drop != path {
            images.removeValue(forKey: drop)
        }
        images[path] = image
    }

    func relayout(width: CGFloat) {
        columns = max(1, Int((width + gap) / max(stride, 1)))
        let rows = files.isEmpty ? 1 : Int(ceil(Double(files.count) / Double(columns)))
        frame = NSRect(x: 0, y: 0, width: width, height: max(1, CGFloat(rows) * stride))
    }

    func index(at point: NSPoint) -> Int? {
        guard columns > 0, stride > 0 else { return nil }
        let col = Int(point.x / stride)
        let row = Int(point.y / stride)
        guard col >= 0, col < columns, row >= 0 else { return nil }
        let index = row * columns + col
        guard files.indices.contains(index) else { return nil }
        let originX = CGFloat(col) * stride
        let originY = CGFloat(row) * stride
        if point.x > originX + cell || point.y > originY + cell { return nil }
        return index
    }

    func paths(in rect: NSRect) -> [String] {
        guard columns > 0, stride > 0, !files.isEmpty else { return [] }
        let first = max(0, Int(rect.minY / stride))
        let last = min(Int(rect.maxY / stride), Int(ceil(Double(files.count) / Double(columns))) - 1)
        guard last >= first else { return [] }
        var paths: [String] = []
        for row in first...last {
            for col in 0..<columns {
                let index = row * columns + col
                guard files.indices.contains(index) else { break }
                paths.append(files[index].path)
            }
        }
        return paths
    }

    override func draw(_ dirtyRect: NSRect) {
        guard columns > 0, stride > 0 else { return }
        let first = max(0, Int(dirtyRect.minY / stride))
        let last = min(Int(dirtyRect.maxY / stride), max(0, Int(ceil(Double(files.count) / Double(columns))) - 1))
        guard last >= first else { return }
        for row in first...last {
            for col in 0..<columns {
                let index = row * columns + col
                guard files.indices.contains(index) else { break }
                let rect = NSRect(x: CGFloat(col) * stride, y: CGFloat(row) * stride, width: cell, height: cell)
                guard dirtyRect.intersects(rect) else { continue }
                let file = files[index]
                if let image = images[file.path] ?? ThumbMemory.shared.cached(path: file.path) {
                    draw(image, in: rect)
                } else {
                    NSColor.white.withAlphaComponent(0.08).setFill()
                    rect.fill()
                }
                if selection.contains(file.path) {
                    NSColor.controlAccentColor.setStroke()
                    let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = max(1, min(2, cell / 8))
                    path.stroke()
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        let file = files[index]
        if event.clickCount == 2 {
            coordinator?.onOpen(file)
            return
        }
        var next = selection
        if event.modifierFlags.contains(.command) {
            if next.contains(file.path) { next.remove(file.path) } else { next.insert(file.path) }
            anchorPath = file.path
        } else if event.modifierFlags.contains(.shift), let anchorPath,
                  let start = files.firstIndex(where: { $0.path == anchorPath }) {
            let slice = files[min(start, index)...max(start, index)]
            next = Set(slice.map(\.path))
        } else {
            next = [file.path]
            anchorPath = file.path
        }
        selection = next
        needsDisplay = true
        coordinator?.onSelection(next)
        coordinator?.onVisible(file)
    }

    private func draw(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        let dest = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).setClip()
        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
