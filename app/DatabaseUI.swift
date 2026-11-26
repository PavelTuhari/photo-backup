import SwiftUI

struct DatabaseBrowser: View {
    let db: LibraryDB
    @State private var tables: [String] = []
    @State private var table = ""
    @State private var preview = QueryResult(columns: [], rows: [], message: "")
    @State private var sql = "SELECT year, COUNT(*) AS files, SUM(size) AS bytes FROM files GROUP BY year ORDER BY year"
    @State private var result = QueryResult(columns: [], rows: [], message: "Запрос ещё не выполнялся")
    @State private var editColumn = ""
    @State private var editRowid = ""
    @State private var editValue = ""
    @State private var editable: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(db.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            HSplitView {
                tableList
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
                VSplitView {
                    tablePreview
                    queryEditor
                }
            }
        }
        .task { reloadTables() }
    }

    private var tableList: some View {
        List(tables, id: \.self, selection: Binding(
            get: { table.isEmpty ? nil : table },
            set: { name in
                table = name ?? ""
                loadPreview()
            }
        )) { name in
            Text(name)
        }
        .listStyle(.sidebar)
    }

    private var tablePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(table.isEmpty ? "Таблица" : table).font(.headline)
                Spacer()
                Button("Обновить") { loadPreview() }
                    .disabled(table.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            resultGrid(preview, editable: true)
            editorBar
        }
    }

    private var queryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Запрос").font(.headline)
                Spacer()
                Button("Выполнить") { runQuery() }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            TextEditor(text: $sql)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            Text(result.message)
                .font(.caption)
                .foregroundStyle(result.message.hasPrefix("Ошибка") ? Color.red : Color.secondary)
            resultGrid(result, editable: false)
        }
        .padding(12)
    }

    private var editorBar: some View {
        HStack(spacing: 8) {
            Text(editColumn.isEmpty ? "Ячейка не выбрана" : editColumn)
                .font(.caption)
                .frame(width: 120, alignment: .leading)
            TextField("rowid", text: $editRowid)
                .frame(width: 80)
            TextField("Значение", text: $editValue)
            Button("Записать") { saveCell() }
                .disabled(!canEdit)
            Button("NULL") {
                editValue = ""
                saveCell(null: true)
            }
            .disabled(!canEdit)
            Button("Удалить строку") { deleteSelectedRow() }
                .disabled(Int64(editRowid) == nil || table.isEmpty)
        }
        .padding(12)
    }

    private var canEdit: Bool {
        !table.isEmpty && editable.contains(editColumn) && Int64(editRowid) != nil
    }

    private func resultGrid(_ data: QueryResult, editable: Bool) -> some View {
        ScrollView([.horizontal, .vertical]) {
            if data.columns.isEmpty {
                Text(data.message.isEmpty ? "Нет строк" : "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow {
                        ForEach(data.columns, id: \.self) { column in
                            Text(column).font(.caption.weight(.semibold))
                        }
                    }
                    ForEach(data.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(data.columns.indices, id: \.self) { column in
                                let value = data.rows[row][column]
                                Text(value)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .frame(maxWidth: 280, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard editable else { return }
                                        pick(row: row, column: column, value: value)
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func reloadTables() {
        tables = db.tableNames()
        if table.isEmpty, let first = tables.first {
            table = first
        }
        loadPreview()
    }

    private func loadPreview() {
        guard !table.isEmpty else { return }
        let names = db.columnNames(table)
        editable = Set(names.filter { $0 != "thumb" })
        preview = db.preview(table: table)
    }

    private func pick(row: Int, column: Int, value: String) {
        guard column < preview.columns.count else { return }
        let name = preview.columns[column]
        if name == "rowid" || name == "thumb_bytes" { return }
        editColumn = name
        if let idColumn = preview.columns.firstIndex(of: "rowid") {
            editRowid = preview.rows[row][idColumn]
        }
        editValue = value == "NULL" ? "" : value
    }

    private func saveCell(null: Bool = false) {
        guard canEdit, let rowid = Int64(editRowid) else { return }
        db.updateCell(table: table, rowid: rowid, column: editColumn, value: null ? nil : editValue)
        loadPreview()
    }

    private func deleteSelectedRow() {
        guard let rowid = Int64(editRowid), !table.isEmpty else { return }
        db.deleteRow(table: table, rowid: rowid)
        loadPreview()
        reloadTables()
    }

    private func runQuery() {
        result = db.run(sql)
        reloadTables()
    }
}
