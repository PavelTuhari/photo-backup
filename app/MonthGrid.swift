import AppKit
import SwiftUI

// Year grid with a real flow layout. Every month has a frame before its
// cells exist, so a click can scroll to that frame and scrolling can name
// the month that is actually at the top.
struct MonthGrid: NSViewRepresentable {
    var sections: [MonthSection]
    var thumbSide: Double
    var selection: Set<String>
    var database: LibraryDB?
    var indexer: Indexer
    var groups: [PhotoGroup]
    var scrollMonth: Int?
    var scrollToken: Int
    var onVisibleMonth: (Int) -> Void
    var onSelection: (Set<String>) -> Void
    var onOpen: (FileRecord) -> Void
    var onCopy: ([FileRecord]) -> Void
    var onShare: ([FileRecord]) -> Void
    var onExport: ([FileRecord]) -> Void
    var onAddToGroup: (String, [FileRecord]) -> Void
    var onNewGroup: ([FileRecord]) -> Void
    var onScroll: (Bool) -> Void
    var onClip: (ClipCommand, [FileRecord]) -> Void
    var libraryAlbums: [PhotoAlbum] = []
    var inUserAlbum: Bool = false
    var inTrash: Bool = false
    var onLibrary: (LibraryCommand, [FileRecord]) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MonthScrollView {
        let scroll = MonthScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        let collection = NSCollectionView()
        collection.collectionViewLayout = context.coordinator.flow
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(MonthItem.self, forItemWithIdentifier: Coordinator.itemID)
        collection.register(
            MonthHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: Coordinator.headerID
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        collection.menu = menu

        scroll.documentView = collection
        context.coordinator.attach(scroll: scroll, collection: collection)
        return scroll
    }

    func updateNSView(_ scroll: MonthScrollView, context: Context) {
        let coordinator = context.coordinator
        let hadDatabase = coordinator.database != nil
        coordinator.sections = sections
        coordinator.database = database
        coordinator.indexer = indexer
        coordinator.groups = groups
        coordinator.onVisibleMonth = onVisibleMonth
        coordinator.onSelection = onSelection
        coordinator.onOpen = onOpen
        coordinator.onCopy = onCopy
        coordinator.onShare = onShare
        coordinator.onExport = onExport
        coordinator.onAddToGroup = onAddToGroup
        coordinator.onNewGroup = onNewGroup
        coordinator.onScroll = onScroll
        coordinator.onClip = onClip
        coordinator.libraryAlbums = libraryAlbums
        coordinator.inUserAlbum = inUserAlbum
        coordinator.inTrash = inTrash
        coordinator.onLibrary = onLibrary

        let thumb = CGFloat(thumbSide)
        let thumbChanged = abs(coordinator.thumb - thumb) > 0.5
        coordinator.thumb = thumb
        let signature = sections.map { "\($0.id):\($0.files.count)" }.joined(separator: "|")
        guard let collection = scroll.collection else { return }
        let dataChanged = coordinator.signature != signature
        if dataChanged {
            coordinator.signature = signature
            collection.reloadData()
        }
        if thumbChanged {
            coordinator.flow.invalidateLayout()
        }
        if dataChanged || thumbChanged {
            coordinator.fit(force: true)
        } else if !hadDatabase, database != nil {
            collection.reloadItems(at: collection.indexPathsForVisibleItems())
        }
        if coordinator.appliedScroll != scrollToken {
            coordinator.appliedScroll = scrollToken
            if let scrollMonth {
                coordinator.scrollToMonth(scrollMonth)
            }
        } else if thumbChanged, let anchor = coordinator.topIndexPath() {
            coordinator.pin(anchor)
        }
        coordinator.applySelection(selection)
    }

    static func dismantleNSView(_ nsView: MonthScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout, NSMenuDelegate {
        static let itemID = NSUserInterfaceItemIdentifier("MonthItem")
        static let headerID = NSUserInterfaceItemIdentifier("MonthHeader")

        let flow = NSCollectionViewFlowLayout()
        var sections: [MonthSection] = []
        var database: LibraryDB?
        var indexer = Indexer()
        var groups: [PhotoGroup] = []
        var thumb: CGFloat = 160
        var signature = ""
        var appliedScroll = 0
        var onVisibleMonth: (Int) -> Void = { _ in }
        var onSelection: (Set<String>) -> Void = { _ in }
        var onOpen: (FileRecord) -> Void = { _ in }
        var onCopy: ([FileRecord]) -> Void = { _ in }
        var onShare: ([FileRecord]) -> Void = { _ in }
        var onExport: ([FileRecord]) -> Void = { _ in }
        var onAddToGroup: (String, [FileRecord]) -> Void = { _, _ in }
        var onNewGroup: ([FileRecord]) -> Void = { _ in }
        var onScroll: (Bool) -> Void = { _ in }
        var onClip: (ClipCommand, [FileRecord]) -> Void = { _, _ in }
        var libraryAlbums: [PhotoAlbum] = []
        var inUserAlbum = false
        var inTrash = false
        var onLibrary: (LibraryCommand, [FileRecord]) -> Void = { _, _ in }

        private weak var collection: NSCollectionView?
        private var observer: NSObjectProtocol?
        private var scrollTimer: Timer?
        private var suppressSelection = false
        private var adjustingScroll = false
        private var fitting = false
        private var lastMonth: Int?
        private var clickedPath: IndexPath?
        private var anchorPath: String?

        func attach(scroll: MonthScrollView, collection: NSCollectionView) {
            self.collection = collection
            scroll.onLayout = { [weak self] in self?.fit(force: false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.userScrolled()
            }
        }

        func teardown() {
            scrollTimer?.invalidate()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            onScroll(false)
        }

        func fit(force: Bool) {
            guard !fitting, let collection, let scroll = collection.enclosingScrollView else { return }
            let width = scroll.contentView.bounds.width
            guard width > 2 else { return }
            let widthChanged = abs(collection.frame.width - width) > 0.5
            if !force && !widthChanged { return }
            fitting = true
            defer { fitting = false }
            if widthChanged {
                collection.frame.size.width = width
            }
            flow.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            let height = max(flow.collectionViewContentSize.height, 1)
            if abs(collection.frame.height - height) > 1 || abs(collection.frame.width - width) > 0.5 {
                collection.frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
        }

        func scrollToMonth(_ month: Int) {
            guard let section = sections.firstIndex(where: { $0.month == month }) else { return }
            fit(force: true)
            let index = IndexPath(item: 0, section: section)
            let y: CGFloat
            if let header = flow.layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader,
                at: index
            ) {
                y = header.frame.minY
            } else if let item = flow.layoutAttributesForItem(at: index) {
                y = max(0, item.frame.minY - 32)
            } else {
                return
            }
            scroll(to: y)
            lastMonth = month
        }

        func pin(_ index: IndexPath) {
            guard let item = flow.layoutAttributesForItem(at: index) else { return }
            scroll(to: item.frame.minY)
        }

        private func scroll(to y: CGFloat) {
            guard let collection, let scroll = collection.enclosingScrollView else { return }
            let visible = scroll.contentView.bounds.height
            let maxOffset = max(0, collection.frame.height - visible)
            var origin = scroll.contentView.bounds.origin
            origin.y = min(max(0, y), maxOffset)
            adjustingScroll = true
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            adjustingScroll = false
        }

        func topIndexPath() -> IndexPath? {
            guard let collection, let clip = collection.enclosingScrollView?.contentView else { return nil }
            let line = clip.bounds.minY + 1
            var best: (y: CGFloat, path: IndexPath)?
            for path in collection.indexPathsForVisibleItems() {
                guard let frame = flow.layoutAttributesForItem(at: path)?.frame else { continue }
                if frame.minY <= line, best == nil || frame.minY > best!.y {
                    best = (frame.minY, path)
                }
            }
            if let best { return best.path }
            return collection.indexPathsForVisibleItems().min { lhs, rhs in
                let ly = flow.layoutAttributesForItem(at: lhs)?.frame.minY ?? 0
                let ry = flow.layoutAttributesForItem(at: rhs)?.frame.minY ?? 0
                return ly < ry
            }
        }

        func applySelection(_ selection: Set<String>) {
            guard let collection else { return }
            if selection.count == 1, let only = selection.first {
                anchorPath = only
            }
            var indexes = Set<IndexPath>()
            for (section, bucket) in sections.enumerated() {
                for (item, file) in bucket.files.enumerated() where selection.contains(file.path) {
                    indexes.insert(IndexPath(item: item, section: section))
                }
            }
            if collection.selectionIndexPaths == indexes { return }
            suppressSelection = true
            collection.deselectItems(at: collection.selectionIndexPaths)
            collection.selectItems(at: indexes, scrollPosition: [])
            suppressSelection = false
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            sections.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            guard sections.indices.contains(section) else { return 0 }
            return sections[section].files.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath)
            guard let cell = item as? MonthItem, sections.indices.contains(indexPath.section) else { return item }
            let files = sections[indexPath.section].files
            guard files.indices.contains(indexPath.item) else { return item }
            let file = files[indexPath.item]
            cell.show(file, database: database, indexer: indexer)
            cell.onOpen = { [weak self] in self?.onOpen(file) }
            cell.onShift = { [weak self] in self?.extendSelection(to: file.path) }
            return cell
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: Self.headerID,
                for: indexPath
            )
            guard let header = view as? MonthHeader, sections.indices.contains(indexPath.section) else { return view }
            let section = sections[indexPath.section]
            header.set(month: section.month, count: section.files.count)
            return header
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            itemSize(width: collectionView.bounds.width)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> NSSize {
            NSSize(width: collectionView.bounds.width, height: 32)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            NSEdgeInsets(top: 4, left: 16, bottom: 22, right: 16)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            minimumInteritemSpacingForSectionAt section: Int
        ) -> CGFloat { 12 }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            minimumLineSpacingForSectionAt section: Int
        ) -> CGFloat { 16 }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !suppressSelection else { return }
            if indexPaths.count == 1, let path = indexPaths.first, let file = file(at: path) {
                anchorPath = file.path
            }
            publishSelection()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !suppressSelection else { return }
            if indexPaths.count == 1,
               let path = indexPaths.first,
               let file = file(at: path),
               NSEvent.modifierFlags.contains(.command) {
                anchorPath = file.path
            }
            publishSelection()
        }

        /// NSCollectionView keeps a shift-click inside one month. The range follows the grid order, including later months.
        func extendSelection(to path: String) {
            guard let collection else { return }
            var ordered: [String] = []
            var indexByPath: [String: IndexPath] = [:]
            for (section, bucket) in sections.enumerated() {
                for (item, file) in bucket.files.enumerated() {
                    ordered.append(file.path)
                    indexByPath[file.path] = IndexPath(item: item, section: section)
                }
            }
            guard let end = ordered.firstIndex(of: path) else { return }
            let anchor = anchorPath.flatMap { indexByPath[$0] == nil ? nil : $0 } ?? path
            guard let start = ordered.firstIndex(of: anchor) else { return }
            let indexes = Set(ordered[min(start, end)...max(start, end)].compactMap { indexByPath[$0] })
            if anchorPath == nil { anchorPath = path }
            suppressSelection = true
            collection.deselectItems(at: collection.selectionIndexPaths)
            collection.selectItems(at: indexes, scrollPosition: [])
            suppressSelection = false
            publishSelection()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let collection, let event = NSApp.currentEvent else { return }
            let point = collection.convert(event.locationInWindow, from: nil)
            clickedPath = collection.indexPathForItem(at: point)
            let paths = targetFiles()
            guard !paths.isEmpty else { return }
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

        @objc private func openMenu(_ sender: Any?) {
            guard let file = targetFiles().first else { return }
            onOpen(file)
        }

        @objc private func copyMenu(_ sender: Any?) { onCopy(targetFiles()) }
        @objc private func nameMenu(_ sender: Any?) { onClip(.name, targetFiles()) }
        @objc private func pathMenu(_ sender: Any?) { onClip(.path, targetFiles()) }
        @objc private func folderMenu(_ sender: Any?) { onClip(.folder, targetFiles()) }
        @objc private func finderMenu(_ sender: Any?) { onClip(.finder, targetFiles()) }
        @objc private func shareMenu(_ sender: Any?) { onShare(targetFiles()) }
        @objc private func exportMenu(_ sender: Any?) { onExport(targetFiles()) }

        @objc private func addToGroup(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            onAddToGroup(name, targetFiles())
        }

        @objc private func newGroup(_ sender: Any?) { onNewGroup(targetFiles()) }
        @objc private func trashMenu(_ sender: Any?) { onLibrary(.trash, targetFiles()) }
        @objc private func purgeMenu(_ sender: Any?) { onLibrary(.purge, targetFiles()) }
        @objc private func restoreMenu(_ sender: Any?) { onLibrary(.restore, targetFiles()) }
        @objc private func removeAlbumMenu(_ sender: Any?) { onLibrary(.removeFromAlbum, targetFiles()) }
        @objc private func emptyTrashMenu(_ sender: Any?) { onLibrary(.emptyTrash, targetFiles()) }
        @objc private func newAlbumMenu(_ sender: Any?) { onLibrary(.newAlbum, targetFiles()) }
        @objc private func addAlbumMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSNumber else { return }
            onLibrary(.add(id.int64Value), targetFiles())
        }
        @objc private func moveAlbumMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSNumber else { return }
            onLibrary(.move(id.int64Value), targetFiles())
        }

        private func itemSize(width: CGFloat) -> NSSize {
            let inset: CGFloat = 16
            let spacing: CGFloat = 12
            let available = max(thumb, width - inset * 2)
            let columns = max(1, Int((available + spacing) / (thumb + spacing)))
            let itemWidth = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            return NSSize(width: max(itemWidth, 1), height: thumb + 58)
        }

        private func publishSelection() {
            guard let collection else { return }
            var paths: Set<String> = []
            for index in collection.selectionIndexPaths {
                guard let file = file(at: index) else { continue }
                paths.insert(file.path)
            }
            onSelection(paths)
        }

        private func targetFiles() -> [FileRecord] {
            guard let collection else { return [] }
            let selected = collection.selectionIndexPaths
            if let clickedPath, selected.contains(clickedPath) || selected.isEmpty {
                if selected.isEmpty, let file = file(at: clickedPath) { return [file] }
                return selected.sorted().compactMap { file(at: $0) }
            }
            if let clickedPath, let file = file(at: clickedPath) { return [file] }
            return selected.sorted().compactMap { file(at: $0) }
        }

        private func file(at index: IndexPath) -> FileRecord? {
            guard sections.indices.contains(index.section) else { return nil }
            let files = sections[index.section].files
            guard files.indices.contains(index.item) else { return nil }
            return files[index.item]
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            return entry
        }

        private func userScrolled() {
            if adjustingScroll { return }
            publishMonth()
            onScroll(true)
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.onScroll(false)
            }
        }

        private func publishMonth() {
            guard let collection, let clip = collection.enclosingScrollView?.contentView else { return }
            let line = clip.bounds.minY + 1
            var winner: (y: CGFloat, section: Int)?
            let paths = collection.indexPathsForVisibleItems()
            for path in paths {
                guard let frame = flow.layoutAttributesForItem(at: path)?.frame else { continue }
                if frame.maxY < line { continue }
                if frame.minY <= line {
                    if winner == nil || frame.minY > winner!.y {
                        winner = (frame.minY, path.section)
                    }
                }
            }
            if winner == nil {
                for path in paths {
                    guard let y = flow.layoutAttributesForItem(at: path)?.frame.minY else { continue }
                    if winner == nil || y < winner!.y {
                        winner = (y, path.section)
                    }
                }
            }
            // A header can sit above the first cell of its month. Prefer it
            // when the viewport top is still inside that header.
            for section in Set(paths.map(\.section)) {
                let index = IndexPath(item: 0, section: section)
                guard let header = flow.layoutAttributesForSupplementaryView(
                    ofKind: NSCollectionView.elementKindSectionHeader,
                    at: index
                )?.frame else { continue }
                if header.minY <= line, header.maxY >= line {
                    winner = (header.minY, section)
                }
            }
            guard let winner, sections.indices.contains(winner.section) else { return }
            let month = sections[winner.section].month
            guard month != lastMonth else { return }
            lastMonth = month
            onVisibleMonth(month)
        }
    }
}

final class MonthScrollView: NSScrollView {
    var collection: NSCollectionView? { documentView as? NSCollectionView }
    var onLayout: (() -> Void)?
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class MonthHeader: NSView, NSCollectionViewElement {
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        count.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(count)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(month: Int, count: Int) {
        title.stringValue = month == 0 ? "Без даты" : CaptureCalendar.names[month - 1]
        self.count.stringValue = "\(count)"
    }

    override func prepareForReuse() {
        title.stringValue = ""
        count.stringValue = ""
    }
}

final class MonthItem: NSCollectionViewItem {
    var onOpen: (() -> Void)?
    var onShift: (() -> Void)?
    private let photo = ThumbWell()
    private let badge = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private var path = ""
    private var loadTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
        photo.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 11)
        nameField.lineBreakMode = .byTruncatingTail
        dateField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dateField.textColor = .secondaryLabelColor
        dateField.lineBreakMode = .byTruncatingTail
        sizeField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeField.textColor = .secondaryLabelColor
        for field in [nameField, dateField, sizeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(field)
        }
        container.addSubview(photo)
        let symbol = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        badge.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbol)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        badge.layer?.cornerRadius = 9
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            photo.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            photo.topAnchor.constraint(equalTo: container.topAnchor),
            photo.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -58),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            nameField.topAnchor.constraint(equalTo: photo.bottomAnchor, constant: 4),
            dateField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            dateField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            dateField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            sizeField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            sizeField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            sizeField.topAnchor.constraint(equalTo: dateField.bottomAnchor, constant: 1),
            badge.leadingAnchor.constraint(equalTo: photo.leadingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: photo.bottomAnchor, constant: -6),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    override var isSelected: Bool {
        didSet { updateBorder() }
    }

    func show(_ file: FileRecord, database: LibraryDB?, indexer: Indexer) {
        path = file.path
        nameField.stringValue = file.name
        dateField.stringValue = DateText.string(file.created)
        sizeField.stringValue = ByteText.string(file.size)
        badge.isHidden = !file.isVideo
        view.toolTip = "\(file.name)\n\(DateText.string(file.created))\n\(ByteText.string(file.size))"
        updateBorder()
        loadTask?.cancel()
        if let cached = ThumbMemory.shared.cached(path: file.path) {
            photo.image = cached
            return
        }
        photo.image = nil
        let itemPath = file.path
        loadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, self.path == itemPath else { return }
            while indexer.isPaused() {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, self.path == itemPath else { return }
            }
            guard let database else { return }
            if let image = await Self.loadImage(database, path: itemPath), self.path == itemPath {
                self.photo.image = image
                return
            }
            let queued = indexer.prioritize(itemPath) && indexer.isQueued(itemPath)
            guard queued else { return }
            await ReadyThumbs.shared.wait(itemPath)
            guard !Task.isCancelled, self.path == itemPath else { return }
            if let image = await Self.loadImage(database, path: itemPath), self.path == itemPath {
                self.photo.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        path = ""
        photo.image = nil
        onOpen = nil
        onShift = nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onOpen?()
            return
        }
        if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            onShift?()
            return
        }
        super.mouseDown(with: event)
    }

    private func updateBorder() {
        photo.layer?.borderWidth = isSelected ? 3 : 0
        photo.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private static func loadImage(_ database: LibraryDB, path: String) async -> NSImage? {
        let data = await Task.detached(priority: .utility) { database.thumbJPEG(path) }.value
        guard let data else { return nil }
        return ThumbMemory.shared.image(path: path, data: data)
    }
}

final class ThumbWell: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.06).setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let rect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
