import AppKit
import SwiftUI

// SwiftUI otherwise asks the scroll view how tall the whole table is and
// tries to lay out every row.
final class FixedScroll: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

// AppKit table so a header click reloads rows in place. SwiftUI Table diffs
// every moved identity, and that diff hangs once a few thousand rows have
// been permuted more than a couple of times.
struct HardwareTable: NSViewRepresentable {
    var rows: [RowRef]
    var token: Int
    var column: HardwareColumn
    var descending: Bool
    var selection: Set<String>
    var groups: [PhotoGroup]
    var onSort: (HardwareColumn, Bool) -> Void
    var onSelection: (Set<String>) -> Void
    var onOpen: (Int) -> Void
    var onCopy: ([String]) -> Void
    var onShare: ([String]) -> Void
    var onExport: ([String]) -> Void
    var scrollPath: String?
    var scrollToken: Int
    var onAddToGroup: (String, [String]) -> Void
    var onNewGroup: ([String]) -> Void
    var onScroll: (Bool) -> Void
    var onVisibleMonth: (String, Int) -> Void
    var onClip: (ClipCommand, [String]) -> Void
    var libraryAlbums: [PhotoAlbum] = []
    var inUserAlbum: Bool = false
    var inTrash: Bool = false
    var onLibrary: (LibraryCommand, [String]) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FixedScroll()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let table = NSTableView()
        table.style = .fullWidth
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.backgroundColor = .clear
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))

        let specs: [(HardwareColumn, String, CGFloat, Bool)] = [
            (.name, "Имя", 280, false),
            (.created, "Дата создания", 168, true),
            (.year, "Год", 64, true),
            (.kind, "Тип", 72, false),
            (.size, "Размер", 96, true),
            (.pixels, "Пиксели", 120, true),
        ]
        for spec in specs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0.headerKey))
            column.title = spec.1
            column.width = spec.2
            column.minWidth = min(spec.2, 56)
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.0.headerKey,
                ascending: spec.0 != .created
            )
            let mono = spec.3
            column.headerCell.alignment = mono ? .right : .left
            table.addTableColumn(column)
            context.coordinator.monoColumns.insert(column.identifier)
        }
        if let name = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
            name.resizingMask = .autoresizingMask
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu

        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scroll: scroll, table: table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.groups = groups
        context.coordinator.onSort = onSort
        context.coordinator.onSelection = onSelection
        context.coordinator.onOpen = onOpen
        context.coordinator.onCopy = onCopy
        context.coordinator.onShare = onShare
        context.coordinator.onExport = onExport
        context.coordinator.onAddToGroup = onAddToGroup
        context.coordinator.onNewGroup = onNewGroup
        context.coordinator.onScroll = onScroll
        context.coordinator.onVisibleMonth = onVisibleMonth
        context.coordinator.onClip = onClip
        context.coordinator.libraryAlbums = libraryAlbums
        context.coordinator.inUserAlbum = inUserAlbum
        context.coordinator.inTrash = inTrash
        context.coordinator.onLibrary = onLibrary
        guard let table = scroll.documentView as? NSTableView else { return }
        if context.coordinator.token != token {
            context.coordinator.token = token
            context.coordinator.reload(table, preservingScrollOf: scroll)
        }
        context.coordinator.applySortIndicator(table, column: column, descending: descending)
        context.coordinator.applySelection(table, selection: selection)
        if context.coordinator.appliedScroll != scrollToken {
            context.coordinator.appliedScroll = scrollToken
            if let scrollPath {
                context.coordinator.reveal(scrollPath, in: table)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var rows: [RowRef] = []
        var groups: [PhotoGroup] = []
        var token = -1
        var monoColumns: Set<NSUserInterfaceItemIdentifier> = []
        var onSort: (HardwareColumn, Bool) -> Void = { _, _ in }
        var onSelection: (Set<String>) -> Void = { _ in }
        var onOpen: (Int) -> Void = { _ in }
        var onCopy: ([String]) -> Void = { _ in }
        var onShare: ([String]) -> Void = { _ in }
        var onExport: ([String]) -> Void = { _ in }
        var appliedScroll = -1
        var onAddToGroup: (String, [String]) -> Void = { _, _ in }
        var onNewGroup: ([String]) -> Void = { _ in }
        var onScroll: (Bool) -> Void = { _ in }
        var onVisibleMonth: (String, Int) -> Void = { _, _ in }
        var onClip: (ClipCommand, [String]) -> Void = { _, _ in }
        var libraryAlbums: [PhotoAlbum] = []
        var inUserAlbum = false
        var inTrash = false
        var onLibrary: (LibraryCommand, [String]) -> Void = { _, _ in }
        private var lastVisibleKey: String?

        private weak var table: NSTableView?
        private var observer: NSObjectProtocol?
        private var scrollTimer: Timer?
        private var suppressSort = false
        private var suppressSelection = false
        private var adjustingScroll = false
        private var lastSortKey: String?
        private var lastSortDescending = true

        func attach(scroll: NSScrollView, table: NSTableView) {
            self.table = table
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

        func reload(_ table: NSTableView, preservingScrollOf scroll: NSScrollView) {
            let origin = scroll.contentView.bounds.origin
            suppressSelection = true
            adjustingScroll = true
            table.reloadData()
            scroll.contentView.scroll(to: origin)
            adjustingScroll = false
            suppressSelection = false
        }

        func reveal(_ path: String, in table: NSTableView) {
            guard let row = rows.firstIndex(where: { $0.path == path }),
                  let scroll = table.enclosingScrollView else { return }
            let rowRect = table.rect(ofRow: row)
            let visible = scroll.contentView.bounds.height
            let maxOffset = max(0, table.frame.height - visible)
            var origin = scroll.contentView.bounds.origin
            origin.y = min(max(0, rowRect.minY), maxOffset)
            adjustingScroll = true
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            adjustingScroll = false
            publishVisibleMonth()
        }

        func applySortIndicator(_ table: NSTableView, column: HardwareColumn, descending: Bool) {
            let ascending = !descending
            let current = table.sortDescriptors.first
            if current?.key == column.headerKey, current?.ascending == ascending { return }
            lastSortKey = column.headerKey
            lastSortDescending = descending
            suppressSort = true
            table.sortDescriptors = [NSSortDescriptor(key: column.headerKey, ascending: ascending)]
            suppressSort = false
        }

        func applySelection(_ table: NSTableView, selection: Set<String>) {
            if currentSelection() == selection { return }
            suppressSelection = true
            if selection.isEmpty {
                table.deselectAll(nil)
            } else {
                var indexes = IndexSet()
                for (index, row) in rows.enumerated() where selection.contains(row.path) {
                    indexes.insert(index)
                }
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            suppressSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = makeCell(id, mono: monoColumns.contains(id))
            }
            cell.textField?.stringValue = text(rows[row], column: id.rawValue)
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !suppressSort,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = HardwareColumn(headerKey: key) else { return }
            let descending = !descriptor.ascending
            if lastSortKey == key, lastSortDescending == descending { return }
            lastSortKey = key
            lastSortDescending = descending
            // Leave the header click before sorting, so the table does not
            // reload while AppKit is still inside the click.
            DispatchQueue.main.async { [weak self] in
                self?.onSort(column, descending)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let table = notification.object as? NSTableView else { return }
            onSelection(currentSelection(of: table))
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard rows.indices.contains(row) else { return nil }
            return rows[row].name
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
                suppressSelection = true
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
                suppressSelection = false
                onSelection(currentSelection(of: table))
            }
            let paths = targetPaths()
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

        @objc func openClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            onOpen(table.clickedRow)
        }

        @objc private func openMenu(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard row >= 0 else { return }
            onOpen(row)
        }

        @objc private func copyMenu(_ sender: Any?) { onCopy(targetPaths()) }
        @objc private func nameMenu(_ sender: Any?) { onClip(.name, targetPaths()) }
        @objc private func pathMenu(_ sender: Any?) { onClip(.path, targetPaths()) }
        @objc private func folderMenu(_ sender: Any?) { onClip(.folder, targetPaths()) }
        @objc private func finderMenu(_ sender: Any?) { onClip(.finder, targetPaths()) }
        @objc private func shareMenu(_ sender: Any?) { onShare(targetPaths()) }
        @objc private func exportMenu(_ sender: Any?) { onExport(targetPaths()) }

        @objc private func addToGroup(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            onAddToGroup(name, targetPaths())
        }

        @objc private func newGroup(_ sender: Any?) {
            onNewGroup(targetPaths())
        }

        @objc private func trashMenu(_ sender: Any?) { onLibrary(.trash, targetPaths()) }
        @objc private func purgeMenu(_ sender: Any?) { onLibrary(.purge, targetPaths()) }
        @objc private func restoreMenu(_ sender: Any?) { onLibrary(.restore, targetPaths()) }
        @objc private func removeAlbumMenu(_ sender: Any?) { onLibrary(.removeFromAlbum, targetPaths()) }
        @objc private func emptyTrashMenu(_ sender: Any?) { onLibrary(.emptyTrash, targetPaths()) }
        @objc private func newAlbumMenu(_ sender: Any?) { onLibrary(.newAlbum, targetPaths()) }
        @objc private func addAlbumMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSNumber else { return }
            onLibrary(.add(id.int64Value), targetPaths())
        }
        @objc private func moveAlbumMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSNumber else { return }
            onLibrary(.move(id.int64Value), targetPaths())
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            return entry
        }

        private func targetPaths() -> [String] {
            guard let table else { return [] }
            let indexes = table.selectedRowIndexes
            if indexes.isEmpty, table.clickedRow >= 0, rows.indices.contains(table.clickedRow) {
                return [rows[table.clickedRow].path]
            }
            return indexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }
        }

        private func currentSelection(of table: NSTableView? = nil) -> Set<String> {
            guard let table = table ?? self.table else { return [] }
            var paths: Set<String> = []
            for index in table.selectedRowIndexes where rows.indices.contains(index) {
                paths.insert(rows[index].path)
            }
            return paths
        }

        private func publishVisibleMonth() {
            guard let table else { return }
            let range = table.rows(in: table.visibleRect)
            let row = range.location
            guard range.length > 0, row != NSNotFound, rows.indices.contains(row) else { return }
            guard let month = CaptureCalendar.month(rows[row].created) else { return }
            let key = "\(rows[row].year)-\(month)"
            guard key != lastVisibleKey else { return }
            lastVisibleKey = key
            onVisibleMonth(rows[row].year, month)
        }

        private func userScrolled() {
            if adjustingScroll { return }
            publishVisibleMonth()
            onScroll(true)
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.onScroll(false)
            }
        }

        private func text(_ row: RowRef, column: String) -> String {
            switch column {
            case "name": return row.name
            case "created": return DateText.string(row.created)
            case "year": return row.year
            case "kind": return row.kindName
            case "size": return ByteText.string(row.size)
            case "pixels":
                if row.width > 0, row.height > 0 { return "\(row.width)×\(row.height)" }
                return "—"
            default: return ""
            }
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier, mono: Bool) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = mono
                ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.systemFontSize)
            if mono { text.alignment = .right }
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}
