import SwiftUI
import Foundation
import QuickLook
#if os(macOS)
import AppKit
#endif

#if os(macOS)
private struct QueryPreferredPresentationSizing: PresentationSizing {
    let size: CGSize

    func proposedSize(
        for root: PresentationSizingRoot,
        context: PresentationSizingContext
    ) -> ProposedViewSize {
        ProposedViewSize(size)
    }
}
#endif

private extension View {
    @ViewBuilder
    func queryCustomMenuStyle() -> some View {
#if os(macOS)
        menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
#else
        self
#endif
    }

    @ViewBuilder
    func queryResizableSheet(
        minWidth: CGFloat,
        idealWidth: CGFloat,
        maxWidth: CGFloat,
        minHeight: CGFloat,
        idealHeight: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
#if os(macOS)
        presentationSizing(
            QueryPreferredPresentationSizing(
                size: CGSize(width: idealWidth, height: idealHeight)
            )
        )
            .frame(
                minWidth: minWidth,
                idealWidth: idealWidth,
                maxWidth: maxWidth,
                minHeight: minHeight,
                idealHeight: idealHeight,
                maxHeight: maxHeight
            )
            .windowResizeBehavior(.enabled)
#else
        self
#endif
    }

    @ViewBuilder
    func queryInlineNavigationTitle() -> some View {
#if os(macOS)
        self
#else
        navigationBarTitleDisplayMode(.inline)
#endif
    }

    @ViewBuilder
    func queryPlainTextInput() -> some View {
#if os(macOS)
        self
#else
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#endif
    }

    @ViewBuilder
    func queryDecimalInput() -> some View {
#if os(macOS)
        self
#else
        keyboardType(.decimalPad)
#endif
    }
}

struct TableDetailView: View {
    let title: String
    let selectString: String
    let iconName: String?
    let baseTableName: String?
    let onLoaded: (Date) -> Void
    @State private var table: QueryResultTable?
    @State private var filterText = ""
    @State private var appliedFilterText = ""
    @State private var selectedRowID: UUID?
    @State private var selectedSummaryGroupColumn: String?
    @State private var selectedSummaryValueColumn: String?
    @State private var selectedSummaryAggregation: QuerySummaryAggregation = .sum
    @State private var chartValueColumnNames: [String] = []
    @State private var orderedColumns: [String] = []
    @State private var visibleColumns = Set<String>()
    @State private var summaryContext: QuerySummaryContext?
    @State private var activeSheet: ActiveSheet?
    @State private var columnFilters: [QueryColumnFilter] = []
    @State private var isLoading = false
    @State private var isPreparingSummary = false
    @State private var loadingMessage = "Lade Daten…"
    @State private var errorMessage: String?
    @State private var loadedAt: Date?
    @State private var loadedCacheKey: String?

    private let store = SecureSettingsStore()
    private let responseCache = QueryResultResponseCache()
    private let tablePadding: CGFloat = 16

    init(
        title: String,
        selectString: String,
        iconName: String? = nil,
        baseTableName: String? = nil,
        onLoaded: @escaping (Date) -> Void = { _ in }
    ) {
        self.title = title
        self.selectString = selectString
        self.iconName = iconName
        self.baseTableName = baseTableName
        self.onLoaded = onLoaded
    }

    private var activeFilterCount: Int {
        columnFilters.filter(\.isActive).count
    }

    private var hasSummaryColumns: Bool {
        !(table?.columns.isEmpty ?? true)
    }

    private var activeColumnFilterTags: [QueryColumnFilterTag] {
        columnFilters.compactMap { queryColumnFilterTag(for: $0) }
    }

    private enum ActiveSheet: Identifiable {
        case filters
        case record(UUID)
        case summary

        var id: String {
            switch self {
            case .filters: return "filters"
            case .record: return "record"
            case .summary: return "summary"
            }
        }
    }

    var body: some View {
        Group {
            if let table, !table.isEmpty {
                resultView(table)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(loadingMessage)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(errorMessage).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Keine Daten")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .queryInlineNavigationTitle()
        .overlay {
            if isPreparingSummary {
                QueryResultLoadingOverlay(message: "Bereite Summe vor…")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(sheet)
        }
        .safeAreaInset(edge: .bottom) {
            if shouldShowTableActionBar {
                tableActionBar
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    if let iconName, !iconName.isEmpty {
                        Image(systemName: iconName)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, alignment: .center)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)

                        QueryResultLoadedAtText(loadedAt: loadedAt, font: .caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: columnFilters) { _, _ in
            saveFilterState()
        }
        .onChange(of: selectedSummaryGroupColumn) { _, _ in
            saveSummarySettings()
        }
        .onChange(of: selectedSummaryValueColumn) { _, _ in
            saveSummarySettings()
        }
        .onChange(of: selectedSummaryAggregation) { _, _ in
            saveSummarySettings()
        }
        .onChange(of: visibleColumns) { _, _ in
            saveVisibleColumns()
        }
        .task { await load() }
    }

    private var shouldShowTableActionBar: Bool {
        table != nil && errorMessage == nil && !isLoading
    }

    private var tableActionBar: some View {
        HStack(spacing: 36) {
            tableActionButton(
                systemImage: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                accessibilityLabel: activeFilterCount == 0 ? "Spaltenfilter" : "Spaltenfilter, \(activeFilterCount) aktiv",
                foregroundColor: activeFilterCount == 0 ? .primary : .orange,
                isDisabled: table?.isEmpty ?? true
            ) {
                openFilters()
            }

            tableActionButton(
                systemImage: "sum",
                accessibilityLabel: "Summe",
                isDisabled: !hasSummaryColumns || isPreparingSummary
            ) {
                Task { await openSummary() }
            }

            tableActionButton(
                systemImage: "arrow.clockwise",
                accessibilityLabel: "Neu laden",
                isDisabled: isLoading
            ) {
                Task { await load(forceRefresh: true) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 0.5)
        }
    }

    private func tableActionButton(
        systemImage: String,
        accessibilityLabel: String,
        foregroundColor: Color = .primary,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(foregroundColor)
                .frame(width: 44, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    @MainActor
    private func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }

        let settings = (try? store.load()) ?? .default
        let deviceID = settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else {
            clearLoadedState()
            errorMessage = "DeviceID fehlt. Bitte in den Einstellungen vergeben."
            return
        }

        let cacheKey = tableCacheKey(deviceID: deviceID)
        if !forceRefresh,
           table != nil,
           loadedCacheKey == cacheKey {
            return
        }

        isLoading = true
        loadingMessage = loadingMessage(forceRefresh: forceRefresh, cacheKey: cacheKey)
        errorMessage = nil
        if loadedCacheKey != cacheKey {
            clearLoadedState()
        }
        defer { isLoading = false }
        await Task.yield()

        do {
            let loadedResult = try await loadTableResult(
                forceRefresh: forceRefresh,
                cacheKey: cacheKey,
                deviceID: deviceID
            )
            applyLoadedTable(loadedResult.table, loadedAt: loadedResult.loadedAt, cacheKey: cacheKey)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadingMessage(forceRefresh: Bool, cacheKey: String) -> String {
        if forceRefresh {
            return "Aktualisiere Daten…"
        }

        return responseCache.cachedLoadedAt(for: cacheKey) == nil ? "Lade Daten…" : "Lade gespeicherte Daten…"
    }

    private func loadTableResult(forceRefresh: Bool, cacheKey: String, deviceID: String) async throws -> LoadedTableResult {
        if !forceRefresh, let cachedResult = try await cachedTableResult(cacheKey: cacheKey) {
            return cachedResult
        }

        return try await fetchedTableResult(cacheKey: cacheKey, deviceID: deviceID)
    }

    private func cachedTableResult(cacheKey: String) async throws -> LoadedTableResult? {
        try await Task.detached(priority: .userInitiated) {
            guard let response = QueryResultResponseCache().cachedResponse(for: cacheKey) else {
                return nil
            }

            let table = try await QueryResultTableParser().parse(responseText: response.responseText)
            return LoadedTableResult(table: table, loadedAt: response.loadedAt)
        }.value
    }

    private func fetchedTableResult(cacheKey: String, deviceID: String) async throws -> LoadedTableResult {
        let responseText = try await APIService.shared.fetchRows(selectString: selectString, deviceID: deviceID)
        let fetchedAt = Date()

        return try await Task.detached(priority: .userInitiated) {
            QueryResultResponseCache().save(responseText, for: cacheKey, loadedAt: fetchedAt)
            let table = try await QueryResultTableParser().parse(responseText: responseText)
            return LoadedTableResult(table: table, loadedAt: fetchedAt)
        }.value
    }

    private func clearLoadedState() {
        table = nil
        columnFilters = []
        selectedRowID = nil
        chartValueColumnNames = []
        orderedColumns = []
        visibleColumns = []
        summaryContext = nil
        selectedSummaryGroupColumn = nil
        selectedSummaryValueColumn = nil
        selectedSummaryAggregation = .sum
        activeSheet = nil
        loadedAt = nil
        loadedCacheKey = nil
    }

    private func applyLoadedTable(_ loadedTable: QueryResultTable, loadedAt: Date, cacheKey: String) {
        let displayColumns = storedColumnOrder(for: loadedTable.columns)
        let savedFilterState = storedFilterState()
        let generatedFilters = filters(for: loadedTable, columns: displayColumns)
        table = loadedTable
        orderedColumns = displayColumns
        visibleColumns = storedVisibleColumns(for: displayColumns)
        let chartColumns = chartValueColumns(in: loadedTable)
        chartValueColumnNames = chartColumns
        filterText = savedFilterState?.searchText ?? ""
        appliedFilterText = filterText
        columnFilters = restoredFilters(generatedFilters, from: savedFilterState)
        let summarySettings = storedSummarySettings(displayColumns: displayColumns, valueColumns: chartColumns)
        selectedSummaryGroupColumn = summarySettings.groupColumn
        selectedSummaryValueColumn = summarySettings.valueColumn
        selectedSummaryAggregation = QuerySummaryAggregation(rawValue: summarySettings.aggregation ?? "") ?? .sum
        self.loadedAt = loadedAt
        loadedCacheKey = cacheKey
        onLoaded(loadedAt)
    }

    @ViewBuilder
    private func sheetView(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .filters:
            QueryResultFilterSheet(filters: columnFilters) { filters in
                columnFilters = filters
            }
        case .record(let rowID):
            if let table, let selectedRecord = selectedRecord(in: filteredRows(in: table), rowID: rowID) {
                let displayColumns = displayColumns(in: table)
                QueryResultRecordSheet(
                    title: displayText(for: displayValue(for: selectedRecord.row, columns: displayColumns)),
                    row: selectedRecord.row,
                    baseTableName: baseTableName,
                    columns: displayColumns,
                    columnKinds: columnKindsByName(),
                    positionText: "\(selectedRecord.index + 1) von \(selectedRecord.total)",
                    canGoPrevious: selectedRecord.index > 0,
                    canGoNext: selectedRecord.index < selectedRecord.total - 1,
                    visibleColumns: $visibleColumns,
                    onMoveColumns: moveColumns(fromOffsets:toOffset:),
                    onPrevious: {
                        selectRecord(offset: -1, rows: selectedRecord.rows)
                    },
                    onNext: {
                        selectRecord(offset: 1, rows: selectedRecord.rows)
                    }
                )
            } else if let table, let selectedRecord = selectedRecord(in: table.rows, rowID: rowID) {
                let displayColumns = displayColumns(in: table)
                QueryResultRecordSheet(
                    title: displayText(for: displayValue(for: selectedRecord.row, columns: displayColumns)),
                    row: selectedRecord.row,
                    baseTableName: baseTableName,
                    columns: displayColumns,
                    columnKinds: columnKindsByName(),
                    positionText: "1 von 1",
                    canGoPrevious: false,
                    canGoNext: false,
                    visibleColumns: $visibleColumns,
                    onMoveColumns: moveColumns(fromOffsets:toOffset:),
                    onPrevious: { },
                    onNext: { }
                )
            } else {
                NavigationStack {
                    Text("Der Datensatz ist im aktuellen Filter nicht enthalten.")
                        .foregroundStyle(.secondary)
                        .padding()
                        .navigationTitle("Datensatz")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") {
                                    activeSheet = nil
                                }
                            }
                    }
                }
            }
        case .summary:
            if let summaryContext {
                QueryResultSummaryView(
                    title: title,
                    baseTableName: baseTableName,
                    rows: summaryContext.rows,
                    columns: summaryContext.columns,
                    headlineColumn: summaryContext.headlineColumn,
                    valueColumns: summaryContext.valueColumns,
                    selectedGroupColumn: $selectedSummaryGroupColumn,
                    selectedValueColumn: $selectedSummaryValueColumn,
                    selectedAggregation: $selectedSummaryAggregation,
                    filterText: $filterText,
                    appliedFilterText: $appliedFilterText,
                    columnFilters: $columnFilters,
                    columnKinds: columnKindsByName(),
                    visibleColumns: $visibleColumns,
                    onMoveColumns: moveColumns(fromOffsets:toOffset:),
                    onFilterTextChanged: { text in
                        filterText = text
                        saveFilterState(searchText: text)
                    },
                    onFilterTextApplied: { text in
                        filterText = text
                        saveFilterState(searchText: text)
                    }
                )
            } else {
                QueryResultLoadingOverlay(message: "Bereite Summe vor…")
            }
        }
    }

    private func selectedRecord(in rows: [QueryResultRow], rowID: UUID) -> (row: QueryResultRow, index: Int, total: Int, rows: [QueryResultRow])? {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else {
            return nil
        }

        return (rows[index], index, rows.count, rows)
    }

    private func selectRecord(offset: Int, rows: [QueryResultRow]) {
        guard let selectedRowID, let index = rows.firstIndex(where: { $0.id == selectedRowID }) else {
            return
        }

        let nextIndex = index + offset
        guard rows.indices.contains(nextIndex) else {
            return
        }

        let nextRowID = rows[nextIndex].id
        self.selectedRowID = nextRowID
        activeSheet = .record(nextRowID)
    }

    private func openFilters() {
        activeSheet = .filters
    }

    @MainActor
    private func openSummary() async {
        guard let table else {
            return
        }

        isPreparingSummary = true
        summaryContext = nil
        activeSheet = .summary
        defer { isPreparingSummary = false }
        await Task.yield()

        let displayColumns = displayColumns(in: table)
        let valueColumns = chartValueColumnNames
        guard !displayColumns.isEmpty else {
            activeSheet = nil
            return
        }

        summaryContext = QuerySummaryContext(
            rows: table.rows,
            columns: displayColumns,
            headlineColumn: headlineColumn(in: displayColumns),
            valueColumns: valueColumns
        )

        if selectedSummaryGroupColumn.map(displayColumns.contains) != true {
            selectedSummaryGroupColumn = headlineColumn(in: displayColumns) ?? displayColumns.first
        }

        if selectedSummaryValueColumn.map(valueColumns.contains) != true {
            selectedSummaryValueColumn = valueColumns.first
        }

        if valueColumns.isEmpty, selectedSummaryAggregation == .sum {
            selectedSummaryAggregation = .count
        }
    }

    private func moveColumns(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let table else {
            return
        }

        var columns = displayColumns(in: table)
        columns.move(fromOffsets: source, toOffset: destination)
        orderedColumns = normalizedColumnOrder(columns, availableColumns: table.columns)
        columnFilters = reorderedFilters(columnFilters, columns: orderedColumns)
        chartValueColumnNames = chartValueColumns(in: table)
        saveColumnOrder(orderedColumns)
    }

    private func resultView(_ table: QueryResultTable) -> some View {
        let rows = filteredRows(in: table)
        let rowColumns = tableListColumns(in: table)

        return VStack(spacing: 0) {
            filterBar(
                filteredCount: rows.count,
                totalCount: table.rows.count
            )

            if rows.isEmpty {
                Text("Keine Treffer")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultHeader(rowColumns.isEmpty ? "Ergebnis" : rowColumns.joined(separator: " / "))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                            Button {
                                selectedRowID = row.id
                                activeSheet = .record(row.id)
                            } label: {
                                collapsedRowView(
                                    row,
                                    columns: rowColumns,
                                    rowIndex: rowIndex
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, tablePadding)
                }
            }
        }
    }

    private func filterBar(filteredCount: Int, totalCount: Int) -> some View {
        QueryResultTextFilterBar(
            initialText: filterText,
            appliedText: $appliedFilterText,
            filteredCount: filteredCount,
            totalCount: totalCount,
            filterTags: activeColumnFilterTags,
            horizontalPadding: tablePadding,
            onTextChanged: { text in
                saveFilterState(searchText: text)
            },
            onTextApplied: { text in
                filterText = text
                saveFilterState(searchText: text)
            },
            onRemoveFilter: removeColumnFilter
        )
    }

    private func removeColumnFilter(column: String) {
        guard let index = columnFilters.firstIndex(where: { $0.column == column }) else {
            return
        }

        columnFilters[index].reset()
    }

    private func tableListColumns(in table: QueryResultTable) -> [String] {
        let displayColumns = displayColumns(in: table)
        let selectedColumns = displayColumns.filter { visibleColumns.contains($0) }
        if !selectedColumns.isEmpty {
            return selectedColumns
        }

        if let headlineColumn = headlineColumn(in: displayColumns) {
            return [headlineColumn]
        }

        return Array(displayColumns.prefix(1))
    }

    private func storedVisibleColumns(for availableColumns: [String]) -> Set<String> {
        let availableColumnSet = Set(availableColumns)
        if let savedColumns = UserDefaults.standard.stringArray(forKey: visibleColumnsDefaultsKey) {
            let restoredColumns = Set(savedColumns.filter { availableColumnSet.contains($0) })
            if !restoredColumns.isEmpty {
                return restoredColumns
            }
        }

        return defaultVisibleColumns(in: availableColumns)
    }

    private func defaultVisibleColumns(in columns: [String]) -> Set<String> {
        if let headlineColumn = headlineColumn(in: columns) {
            return [headlineColumn]
        }

        if let firstColumn = columns.first {
            return [firstColumn]
        }

        return []
    }

    private func saveVisibleColumns() {
        guard let table else {
            return
        }

        let selectedColumns = displayColumns(in: table).filter { visibleColumns.contains($0) }
        guard !selectedColumns.isEmpty else {
            return
        }

        UserDefaults.standard.set(selectedColumns, forKey: visibleColumnsDefaultsKey)
    }

    private var visibleColumnsDefaultsKey: String {
        "qncTABLE.visibleColumns." + tableDefaultsIdentifier
    }

    private func resultHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, tablePadding)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: 0.5)
            }
    }

    private func collapsedRowView(_ row: QueryResultRow, columns: [String], rowIndex: Int) -> some View {
        HStack(spacing: 10) {
            collapsedRowValues(row, columns: columns)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, tablePadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 0.5)
        }
    }

    private func collapsedRowValues(_ row: QueryResultRow, columns: [String]) -> some View {
        Group {
            if columns.count == 1, let column = columns.first {
                compactValueView(row.values[column] ?? "")
            } else {
                Text(rowDisplayText(for: row, columns: columns))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rowDisplayText(for row: QueryResultRow, columns: [String]) -> String {
        columns
            .map { column in
                displayText(for: row.values[column] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .map { $0.isEmpty ? " " : $0 }
            .joined(separator: " / ")
    }

    @ViewBuilder
    private func compactValueView(_ value: String) -> some View {
        if let boolean = booleanValue(from: value) {
            Image(systemName: boolean ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(boolean ? Color.green : Color.red)
                .accessibilityLabel(boolean ? "true" : "false")
        } else {
            Text(value.isEmpty ? "Ohne Bezeichnung" : displayText(for: value))
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func headlineColumn(in columns: [String]) -> String? {
        if let nameColumn = columns.first(where: { $0.compare("NAME", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return nameColumn
        }

        return columns.first(where: { $0.compare("COMBO", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
    }

    private func displayValue(for row: QueryResultRow, columns: [String]) -> String {
        displayValue(for: row, headlineColumn: headlineColumn(in: columns), columns: columns)
    }

    private func displayValue(for row: QueryResultRow, headlineColumn: String?, columns: [String]) -> String {
        if let headlineColumn, let value = row.values[headlineColumn]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }

        for column in columns {
            if let value = row.values[column]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        return ""
    }

    private func filteredRows(in table: QueryResultTable) -> [QueryResultRow] {
        queryFilteredRows(
            rows: table.rows,
            columns: displayColumns(in: table),
            appliedFilterText: appliedFilterText,
            columnFilters: columnFilters
        )
    }

    private func filters(for table: QueryResultTable, columns: [String]) -> [QueryColumnFilter] {
        columns.map { column in
            QueryColumnFilter(
                column: column,
                kind: filterKind(for: column, rows: table.rows),
                selectableValues: selectableValues(for: column, rows: table.rows)
            )
        }
    }

    private func selectableValues(for column: String, rows: [QueryResultRow]) -> [String] {
        var seenValues = Set<String>()
        var uniqueValues: [String] = []

        for row in rows {
            let value = selectableValueKey(from: row.values[column] ?? "")
            guard seenValues.insert(value).inserted else {
                continue
            }

            uniqueValues.append(value)
            if uniqueValues.count >= 20 {
                return []
            }
        }

        guard uniqueValues.count > 1 else {
            return []
        }

        return uniqueValues.sorted { first, second in
            selectableValueTitle(first).localizedCaseInsensitiveCompare(selectableValueTitle(second)) == .orderedAscending
        }
    }

    private func chartValueColumns(in table: QueryResultTable) -> [String] {
        displayColumns(in: table).filter { column in
            guard !isPhoneColumn(column) else {
                return false
            }

            let values = typedValues(for: column, rows: table.rows)
            guard !values.isEmpty else {
                return false
            }

            guard !values.allSatisfy({ booleanValue(from: $0) != nil }) else {
                return false
            }

            return numericColumnProfile(from: values).isNumeric
        }
    }

    private func displayColumns(in table: QueryResultTable) -> [String] {
        let preferredColumns = orderedColumns.isEmpty ? table.columns : orderedColumns
        return normalizedColumnOrder(preferredColumns, availableColumns: table.columns)
    }

    private func storedColumnOrder(for availableColumns: [String]) -> [String] {
        guard let savedColumns = UserDefaults.standard.stringArray(forKey: columnOrderDefaultsKey) else {
            return availableColumns
        }

        return normalizedColumnOrder(savedColumns, availableColumns: availableColumns)
    }

    private func saveColumnOrder(_ columns: [String]) {
        UserDefaults.standard.set(columns, forKey: columnOrderDefaultsKey)
    }

    private var columnOrderDefaultsKey: String {
        "qncTABLE.columnOrder." + tableDefaultsIdentifier
    }

    private func normalizedColumnOrder(_ preferredColumns: [String], availableColumns: [String]) -> [String] {
        let availableColumnSet = Set(availableColumns)
        var seenColumns = Set<String>()
        var normalizedColumns: [String] = []

        for column in preferredColumns where availableColumnSet.contains(column) && seenColumns.insert(column).inserted {
            normalizedColumns.append(column)
        }

        for column in availableColumns where seenColumns.insert(column).inserted {
            normalizedColumns.append(column)
        }

        return normalizedColumns
    }

    private func reorderedFilters(_ filters: [QueryColumnFilter], columns: [String]) -> [QueryColumnFilter] {
        let filterByColumn = Dictionary(uniqueKeysWithValues: filters.map { ($0.column, $0) })
        return columns.compactMap { filterByColumn[$0] }
    }

    private func storedFilterState() -> SavedTableFilterState? {
        guard let data = UserDefaults.standard.data(forKey: filterStateDefaultsKey) else {
            return nil
        }

        return try? JSONDecoder().decode(SavedTableFilterState.self, from: data)
    }

    private func restoredFilters(_ filters: [QueryColumnFilter], from savedState: SavedTableFilterState?) -> [QueryColumnFilter] {
        guard let savedState else {
            return filters
        }

        let savedFiltersByColumn = Dictionary(uniqueKeysWithValues: savedState.columnFilters.map { ($0.column, $0) })
        return filters.map { filter in
            guard let savedFilter = savedFiltersByColumn[filter.column] else {
                return filter
            }

            var restoredFilter = filter
            restoredFilter.text = savedFilter.text
            restoredFilter.numberText = savedFilter.numberText
            restoredFilter.numberOperator = QueryNumberFilterOperator(rawValue: savedFilter.numberOperator) ?? filter.numberOperator
            restoredFilter.isEnabled = savedFilter.isEnabled
            restoredFilter.boolValue = savedFilter.boolValue

            let availableValues = Set(filter.selectableValues)
            restoredFilter.selectedValues = Set(savedFilter.selectedValues).intersection(availableValues)
            return restoredFilter
        }
    }

    private func saveFilterState(searchText: String? = nil) {
        guard table != nil else {
            return
        }

        let effectiveSearchText = searchText ?? storedFilterState()?.searchText ?? filterText
        let state = SavedTableFilterState(
            searchText: effectiveSearchText,
            columnFilters: columnFilters.map { SavedColumnFilterState(filter: $0) }
        )

        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        UserDefaults.standard.set(data, forKey: filterStateDefaultsKey)
    }

    private func storedSummarySettings(displayColumns: [String], valueColumns: [String]) -> SavedSummarySettings {
        let defaultGroupColumn = headlineColumn(in: displayColumns) ?? displayColumns.first
        let defaultValueColumn = valueColumns.first
        let defaultAggregation: QuerySummaryAggregation = valueColumns.isEmpty ? .count : .sum
        let defaultSettings = SavedSummarySettings(
            groupColumn: defaultGroupColumn,
            valueColumn: defaultValueColumn,
            aggregation: defaultAggregation.rawValue
        )

        guard let data = UserDefaults.standard.data(forKey: summarySettingsDefaultsKey),
              let savedSettings = try? JSONDecoder().decode(SavedSummarySettings.self, from: data) else {
            return defaultSettings
        }

        let groupColumn = savedSettings.groupColumn.flatMap { displayColumns.contains($0) ? $0 : nil } ?? defaultGroupColumn
        let valueColumn = savedSettings.valueColumn.flatMap { valueColumns.contains($0) ? $0 : nil } ?? defaultValueColumn
        let savedAggregation = QuerySummaryAggregation(rawValue: savedSettings.aggregation ?? "") ?? defaultAggregation
        let aggregation = valueColumns.isEmpty && savedAggregation == .sum ? QuerySummaryAggregation.count : savedAggregation
        return SavedSummarySettings(groupColumn: groupColumn, valueColumn: valueColumn, aggregation: aggregation.rawValue)
    }

    private func saveSummarySettings() {
        guard let table else {
            return
        }

        let displayColumns = displayColumns(in: table)
        let valueColumns = chartValueColumns(in: table)
        guard let selectedSummaryGroupColumn,
              displayColumns.contains(selectedSummaryGroupColumn) else {
            return
        }

        let savedValueColumn = selectedSummaryValueColumn.flatMap { valueColumns.contains($0) ? $0 : nil }
        let settings = SavedSummarySettings(
            groupColumn: selectedSummaryGroupColumn,
            valueColumn: savedValueColumn,
            aggregation: selectedSummaryAggregation.rawValue
        )

        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        UserDefaults.standard.set(data, forKey: summarySettingsDefaultsKey)
    }

    private func columnKindsByName() -> [String: QueryColumnFilterKind] {
        Dictionary(uniqueKeysWithValues: columnFilters.map { ($0.column, $0.kind) })
    }

    private var summarySettingsDefaultsKey: String {
        "qncTABLE.summarySettings." + tableDefaultsIdentifier
    }

    private var filterStateDefaultsKey: String {
        "qncTABLE.filterState." + tableDefaultsIdentifier
    }

    private var tableDefaultsIdentifier: String {
        Data("\(title)\n\(selectString)".utf8).base64EncodedString()
    }

    private func tableCacheKey(deviceID: String) -> String {
        QueryResultResponseCache.cacheKey(deviceID: deviceID, title: title, selectString: selectString)
    }
}

private enum QueryColumnFilterKind: Equatable, Sendable {
    case text
    case number
    case boolean
}

private enum QueryNumberFilterOperator: String, CaseIterable, Identifiable, Sendable {
    case lessThan
    case greaterThan
    case equal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .equal: return "="
        }
    }
}

private struct QueryColumnFilter: Identifiable, Equatable, Sendable {
    let column: String
    let kind: QueryColumnFilterKind
    var text = ""
    var numberText = ""
    var numberOperator: QueryNumberFilterOperator = .greaterThan
    var isEnabled = false
    var boolValue = true
    var selectableValues: [String] = []
    var selectedValues = Set<String>()

    var id: String { column }

    nonisolated var isActive: Bool {
        if !selectedValues.isEmpty {
            return true
        }

        switch kind {
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number:
            return numericValue(from: numberText) != nil
        case .boolean:
            return isEnabled
        }
    }

    mutating func reset() {
        text = ""
        numberText = ""
        numberOperator = .greaterThan
        isEnabled = false
        boolValue = true
        selectedValues.removeAll()
    }

    nonisolated var hasSelectableValues: Bool {
        selectableValues.count > 1 && selectableValues.count < 20
    }
}

private struct SavedTableFilterState: Codable, Equatable {
    let searchText: String
    let columnFilters: [SavedColumnFilterState]
}

private struct SavedColumnFilterState: Codable, Equatable {
    let column: String
    let text: String
    let numberText: String
    let numberOperator: String
    let isEnabled: Bool
    let boolValue: Bool
    let selectedValues: [String]

    init(filter: QueryColumnFilter) {
        column = filter.column
        text = filter.text
        numberText = filter.numberText
        numberOperator = filter.numberOperator.rawValue
        isEnabled = filter.isEnabled
        boolValue = filter.boolValue
        selectedValues = filter.selectedValues.sorted()
    }
}

private struct SavedSummarySettings: Codable, Equatable {
    let groupColumn: String?
    let valueColumn: String?
    let aggregation: String?
}

private struct LoadedTableResult: Sendable {
    let table: QueryResultTable
    let loadedAt: Date
}

private struct QuerySummaryContext {
    let rows: [QueryResultRow]
    let columns: [String]
    let headlineColumn: String?
    let valueColumns: [String]
}

private struct QueryColumnFilterTag: Identifiable, Equatable {
    let column: String
    let title: String

    var id: String { column }
}

private nonisolated func queryFilteredRows(rows: [QueryResultRow], columns: [String], appliedFilterText: String, columnFilters: [QueryColumnFilter]) -> [QueryResultRow] {
    let terms = queryFilterTerms(from: appliedFilterText)
    let activeFilters = columnFilters.filter(\.isActive)

    guard !terms.isEmpty || !activeFilters.isEmpty else {
        return rows
    }

    return rows.filter { row in
        let searchableText = columns
            .flatMap { querySearchableValues(from: row.values[$0] ?? "") }
            .joined(separator: " ")

        let matchesTextFilter = terms.allSatisfy { term in
            searchableText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        let matchesColumnFilters = activeFilters.allSatisfy { filter in
            queryMatchesColumnFilter(filter, row: row)
        }

        return matchesTextFilter && matchesColumnFilters
    }
}

private nonisolated func queryFilterTerms(from text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

private nonisolated func querySearchableValues(from value: String) -> [String] {
    if let formattedValue = formattedDateValue(from: value) {
        return [value, formattedValue]
    }

    if let formattedValue = formattedDecimalValue(from: value) {
        return [value, formattedValue]
    }

    return [value]
}

private nonisolated func queryMatchesColumnFilter(_ filter: QueryColumnFilter, row: QueryResultRow) -> Bool {
    let value = row.values[filter.column] ?? ""
    guard filter.selectedValues.isEmpty || filter.selectedValues.contains(selectableValueKey(from: value)) else {
        return false
    }

    switch filter.kind {
    case .text:
        let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return true
        }

        return querySearchableValues(from: value).contains { searchableValue in
            searchableValue.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    case .number:
        let numberText = filter.numberText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !numberText.isEmpty else {
            return true
        }

        guard let valueNumber = numericValue(from: value),
              let filterNumber = numericValue(from: numberText) else {
            return false
        }

        switch filter.numberOperator {
        case .lessThan:
            return valueNumber < filterNumber
        case .greaterThan:
            return valueNumber > filterNumber
        case .equal:
            return valueNumber == filterNumber
        }
    case .boolean:
        guard filter.isEnabled else {
            return true
        }

        guard let boolean = booleanValue(from: value) else {
            return false
        }

        return boolean == filter.boolValue
    }
}

private func queryColumnFilterTag(for filter: QueryColumnFilter) -> QueryColumnFilterTag? {
    guard filter.isActive else {
        return nil
    }

    var parts: [String] = []
    if !filter.selectedValues.isEmpty {
        parts.append(querySelectedValuesSummary(filter.selectedValues))
    }

    switch filter.kind {
    case .text:
        let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            parts.append("enthält \(text)")
        }
    case .number:
        let numberText = filter.numberText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !numberText.isEmpty {
            parts.append("\(filter.numberOperator.label) \(numberText)")
        }
    case .boolean:
        if filter.isEnabled {
            parts.append(filter.boolValue ? "1" : "0")
        }
    }

    guard !parts.isEmpty else {
        return nil
    }

    return QueryColumnFilterTag(column: filter.column, title: "\(filter.column): \(parts.joined(separator: ", "))")
}

private func querySelectedValuesSummary(_ values: Set<String>) -> String {
    let titles = values
        .map(selectableValueTitle)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    guard titles.count > 2 else {
        return titles.joined(separator: ", ")
    }

    return "\(titles.prefix(2).joined(separator: ", ")) +\(titles.count - 2)"
}

struct QueryResultResponseCache: Sendable {
    struct CachedResponse: Sendable {
        let responseText: String
        let loadedAt: Date
    }

    nonisolated static let maxAge: TimeInterval = 24 * 60 * 60

    nonisolated init() {}

    nonisolated static func cacheKey(deviceID: String, title: String, selectString: String) -> String {
        "\(deviceID)\n\(title)\n\(selectString)"
    }

    nonisolated func isFresh(loadedAt: Date?, now: Date = Date()) -> Bool {
        guard let loadedAt else {
            return false
        }

        return now.timeIntervalSince(loadedAt) < Self.maxAge
    }

    nonisolated func freshResponse(for key: String, now: Date = Date()) -> CachedResponse? {
        guard let response = cachedResponse(for: key),
              isFresh(loadedAt: response.loadedAt, now: now) else {
            return nil
        }

        return response
    }

    nonisolated func cachedResponse(for key: String) -> CachedResponse? {
        guard let url = cacheURL(for: key),
              let loadedAt = cachedLoadedAt(for: key),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let responseText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
        return CachedResponse(responseText: responseText, loadedAt: loadedAt)
    }

    nonisolated func cachedLoadedAt(for key: String) -> Date? {
        guard let url = cacheURL(for: key) else {
            return nil
        }

        return loadedAt(for: url)
    }

    nonisolated func save(_ responseText: String, for key: String, loadedAt: Date = Date()) {
        guard let url = cacheURL(for: key) else {
            return
        }

        let directoryURL = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(responseText.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: loadedAt], ofItemAtPath: url.path)
        } catch {
            return
        }
    }

    private nonisolated func loadedAt(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }

    private nonisolated func cacheURL(for key: String) -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return applicationSupportURL
            .appendingPathComponent("qncTABLE", isDirectory: true)
            .appendingPathComponent("query-result-cache", isDirectory: true)
            .appendingPathComponent(cacheFileName(for: key))
    }

    private nonisolated func cacheFileName(for key: String) -> String {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partialResult, byte in
            (partialResult ^ UInt64(byte)) &* 1_099_511_628_211
        }

        return String(format: "%016llx.cache", hash)
    }
}

struct QueryResultLoadedAtText: View {
    let loadedAt: Date?
    var font: Font = .caption

    var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var label: String {
        guard let loadedAt else {
            return "Noch nicht aktualisiert"
        }

        return "Aktualisiert: \(Self.formatter.string(from: loadedAt))"
    }

    private var color: Color {
        guard let loadedAt else {
            return .secondary
        }

        return QueryResultResponseCache().isFresh(loadedAt: loadedAt) ? .secondary : .red
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}

private struct QueryResultLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct QueryResultInlineLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
    }
}

private struct QueryColumnFilterTagsView: View {
    let filterTags: [QueryColumnFilterTag]
    let onRemoveFilter: (String) -> Void

    var body: some View {
        if !filterTags.isEmpty {
            QueryTagFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(filterTags) { tag in
                    Button {
                        onRemoveFilter(tag.column)
                    } label: {
                        HStack(spacing: 6) {
                            Text(tag.title)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 36)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter \(tag.title) löschen")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
        }
    }
}

private struct QueryColumnSelectionControl: View {
    let title: String
    let placeholder: String
    let systemImage: String
    let columns: [String]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Menu {
                ForEach(columns, id: \.self) { column in
                    if selection == column {
                        Button {
                            selection = column
                        } label: {
                            Label(column, systemImage: "checkmark")
                        }
                    } else {
                        Button(column) {
                            selection = column
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, alignment: .center)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(selection.isEmpty ? placeholder : selection)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                }
            }
            .queryCustomMenuStyle()
            .disabled(columns.isEmpty)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QueryTagFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangedSubviews(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrangedSubviews(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )

        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: min(arrangement.sizes[index].width, bounds.width), height: arrangement.sizes[index].height)
            )
        }
    }

    private func arrangedSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        let proposedWidth = proposal.width
        let maxWidth = max(proposedWidth ?? .greatestFiniteMagnitude, 0)
        let itemProposal = proposedWidth.map { ProposedViewSize(width: $0, height: nil) } ?? .unspecified
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var y: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(itemProposal)
            let shouldWrap = rowWidth > 0 && rowWidth + horizontalSpacing + size.width > maxWidth
            if shouldWrap {
                measuredWidth = max(measuredWidth, rowWidth)
                rowWidth = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            let x = rowWidth == 0 ? 0 : rowWidth + horizontalSpacing
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }

        measuredWidth = max(measuredWidth, rowWidth)
        let width = proposedWidth ?? measuredWidth
        let height = subviews.isEmpty ? 0 : y + rowHeight
        return (CGSize(width: width, height: height), origins, sizes)
    }
}

private struct QueryResultTextFilterBar: View {
    let initialText: String
    @Binding var appliedText: String
    let filteredCount: Int
    let totalCount: Int
    let filterTags: [QueryColumnFilterTag]
    let horizontalPadding: CGFloat
    let onTextChanged: (String) -> Void
    let onTextApplied: (String) -> Void
    let onRemoveFilter: (String) -> Void

    @State private var text: String = ""
    @State private var hasInitializedText = false
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Filter", text: $text)
                    .queryPlainTextInput()

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter löschen")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
            )

            QueryColumnFilterTagsView(filterTags: filterTags, onRemoveFilter: onRemoveFilter)

            Text("\(filteredCount) von \(totalCount) Zeilen")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, horizontalPadding)
        .padding(.bottom, 10)
        .onAppear {
            initializeTextIfNeeded()
        }
        .onChange(of: initialText) { _, newValue in
            guard text != newValue else {
                return
            }

            text = newValue
        }
        .onChange(of: text) { _, newValue in
            onTextChanged(newValue)
            scheduleApply(newValue)
        }
        .onDisappear {
            applyTask?.cancel()
        }
    }

    private func initializeTextIfNeeded() {
        guard !hasInitializedText else {
            return
        }

        text = initialText
        hasInitializedText = true
    }

    private func scheduleApply(_ value: String) {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                appliedText = value
                onTextApplied(value)
            }
        }
    }
}

private struct QueryResultFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filters: [QueryColumnFilter]

    let onApply: ([QueryColumnFilter]) -> Void

    init(filters: [QueryColumnFilter], onApply: @escaping ([QueryColumnFilter]) -> Void) {
        _filters = State(initialValue: filters)
        self.onApply = onApply
    }

    private var activeFilterCount: Int {
        filters.filter(\.isActive).count
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($filters) { $filter in
                    Section(filter.column) {
                        filterEditor(filter: $filter)
                    }
                }
            }
            .navigationTitle("Spaltenfilter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zurücksetzen") {
                        resetFilters()
                    }
                    .disabled(activeFilterCount == 0)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            onApply(filters)
        }
    }

    @ViewBuilder
    private func filterEditor(filter: Binding<QueryColumnFilter>) -> some View {
        switch filter.wrappedValue.kind {
        case .text:
            TextField("Enthält", text: filter.text)
                .queryPlainTextInput()
        case .number:
            Picker("Vergleich", selection: filter.numberOperator) {
                ForEach(QueryNumberFilterOperator.allCases) { comparison in
                    Text(comparison.label).tag(comparison)
                }
            }
            .pickerStyle(.segmented)

            TextField("Wert", text: filter.numberText)
                .queryDecimalInput()
        case .boolean:
            Toggle("Aktiv", isOn: filter.isEnabled)

            if filter.wrappedValue.isEnabled {
                Picker("Wert", selection: filter.boolValue) {
                    Text("1").tag(true)
                    Text("0").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }

        if filter.wrappedValue.hasSelectableValues {
            selectionEditor(filter: filter)
        }
    }

    private func selectionEditor(filter: Binding<QueryColumnFilter>) -> some View {
        DisclosureGroup {
            ForEach(filter.wrappedValue.selectableValues, id: \.self) { value in
                Button {
                    toggleSelectedValue(value, filter: filter)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: filter.wrappedValue.selectedValues.contains(value) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(filter.wrappedValue.selectedValues.contains(value) ? Color.accentColor : Color.secondary)
                            .frame(width: 22)

                        Text(selectableValueTitle(value))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } label: {
            HStack {
                Label("Auswahl", systemImage: "checklist")
                Spacer()
                if !filter.wrappedValue.selectedValues.isEmpty {
                    Text("\(filter.wrappedValue.selectedValues.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggleSelectedValue(_ value: String, filter: Binding<QueryColumnFilter>) {
        var selectedValues = filter.wrappedValue.selectedValues
        if selectedValues.contains(value) {
            selectedValues.remove(value)
        } else {
            selectedValues.insert(value)
        }

        filter.wrappedValue.selectedValues = selectedValues
    }

    private func resetFilters() {
        for index in filters.indices {
            filters[index].reset()
        }
    }
}

private enum QuerySummaryAggregation: String, CaseIterable, Identifiable, Sendable {
    case sum
    case count

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sum: return "Summe"
        case .count: return "Anzahl"
        }
    }

    var systemImage: String {
        switch self {
        case .sum: return "sum"
        case .count: return "number"
        }
    }
}

private struct QuerySummaryEntry: Identifiable {
    let id: String
    let label: String
    let value: Double
    let valueText: String
    let count: Int
    let rows: [QueryResultRow]
}

private struct QuerySummaryTotal: Sendable {
    let value: Double
    let valueText: String
    let count: Int
}

private struct QuerySummaryEntryData: Sendable {
    let id: String
    let label: String
    let value: Double
    let valueText: String
    let count: Int
    let rows: [QueryResultRow]
    let fractionDigitCount: Int
    let order: Int
}

private enum QuerySummarySheet: Identifiable {
    case filters
    case record(UUID)

    var id: String {
        switch self {
        case .filters:
            return "filters"
        case .record:
            return "record"
        }
    }
}

private struct QueryResultSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var summaryEntries: [QuerySummaryEntry] = []
    @State private var summaryTotal: QuerySummaryTotal?
    @State private var summaryFilteredCount = 0
    @State private var isBuildingSummary = true
    @State private var isWaitingForSummaryTextFilter = false
    @State private var isUpdatingSummaryExpansion = false
    @State private var summaryBuildTask: Task<Void, Never>?
    @State private var summaryExpansionTask: Task<Void, Never>?
    @State private var activeSheet: QuerySummarySheet?
    @State private var expandedSummaryIDs = Set<String>()

    let title: String
    let baseTableName: String?
    let rows: [QueryResultRow]
    let columns: [String]
    let headlineColumn: String?
    let valueColumns: [String]
    @Binding var selectedGroupColumn: String?
    @Binding var selectedValueColumn: String?
    @Binding var selectedAggregation: QuerySummaryAggregation
    @Binding var filterText: String
    @Binding var appliedFilterText: String
    @Binding var columnFilters: [QueryColumnFilter]
    let columnKinds: [String: QueryColumnFilterKind]
    @Binding var visibleColumns: Set<String>
    let onMoveColumns: (IndexSet, Int) -> Void
    let onFilterTextChanged: (String) -> Void
    let onFilterTextApplied: (String) -> Void

    private var activeFilterCount: Int {
        columnFilters.filter(\.isActive).count
    }

    private var activeFilterTags: [QueryColumnFilterTag] {
        columnFilters.compactMap { queryColumnFilterTag(for: $0) }
    }

    private var maxSummaryMagnitude: Double {
        max(summaryEntries.map { abs($0.value) }.max() ?? 1, 1)
    }

    private var effectiveGroupColumn: String? {
        if let selectedGroupColumn, columns.contains(selectedGroupColumn) {
            return selectedGroupColumn
        }

        if let headlineColumn, columns.contains(headlineColumn) {
            return headlineColumn
        }

        return columns.first
    }

    private var effectiveValueColumn: String? {
        if let selectedValueColumn, valueColumns.contains(selectedValueColumn) {
            return selectedValueColumn
        }

        return valueColumns.first
    }

    private var groupColumnBinding: Binding<String> {
        Binding(
            get: { effectiveGroupColumn ?? "" },
            set: { selectedGroupColumn = $0 }
        )
    }

    private var valueColumnBinding: Binding<String> {
        Binding(
            get: { effectiveValueColumn ?? "" },
            set: { selectedValueColumn = $0 }
        )
    }

    private var childDisplayColumns: [String] {
        let selectedColumns = columns.filter { visibleColumns.contains($0) }
        if !selectedColumns.isEmpty {
            return selectedColumns
        }

        if let headlineColumn, columns.contains(headlineColumn) {
            return [headlineColumn]
        }

        return Array(columns.prefix(1))
    }

    private var currentSummaryRows: [QueryResultRow] {
        summaryEntries.flatMap(\.rows)
    }

    private var isShowingSummaryLoading: Bool {
        isBuildingSummary || isWaitingForSummaryTextFilter
    }

    private var summaryLoadingMessage: String {
        isWaitingForSummaryTextFilter && !isBuildingSummary ? "Aktualisiere Filter…" : "Erstelle Summe…"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    summaryControls

                    Divider()

                    if isShowingSummaryLoading {
                        QueryResultInlineLoadingView(message: summaryLoadingMessage)
                    } else if summaryEntries.isEmpty {
                        emptyState
                    } else {
                        summaryResults
                    }
                }

                if isUpdatingSummaryExpansion {
                    QueryResultLoadingOverlay(message: "Aktualisiere Gruppe…")
                }
            }
            .navigationTitle("Summe")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activeSheet = .filters
                    } label: {
                        Image(systemName: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(activeFilterCount == 0 ? Color.primary : Color.orange)
                    }
                    .accessibilityLabel(activeFilterCount == 0 ? "Spaltenfilter" : "Spaltenfilter, \(activeFilterCount) aktiv")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .queryResizableSheet(
            minWidth: 720,
            idealWidth: 1_000,
            maxWidth: 2_400,
            minHeight: 520,
            idealHeight: 760,
            maxHeight: 1_800
        )
        .onAppear {
            ensureSelectedColumns()
            rebuildSummaryEntries()
        }
        .onChange(of: selectedGroupColumn) { _, _ in
            rebuildSummaryEntries()
        }
        .onChange(of: selectedValueColumn) { _, _ in
            rebuildSummaryEntries()
        }
        .onChange(of: selectedAggregation) { _, _ in
            rebuildSummaryEntries()
        }
        .onChange(of: appliedFilterText) { _, _ in
            rebuildSummaryEntries()
        }
        .onChange(of: columnFilters) { _, _ in
            rebuildSummaryEntries()
        }
        .onDisappear {
            summaryBuildTask?.cancel()
            summaryExpansionTask?.cancel()
            isWaitingForSummaryTextFilter = false
            isUpdatingSummaryExpansion = false
        }
        .sheet(item: $activeSheet) { sheet in
            summarySheet(sheet)
        }
    }

    private var summaryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
#if os(macOS)
            HStack(alignment: .bottom, spacing: 12) {
                if !columns.isEmpty {
                    QueryColumnSelectionControl(
                        title: "Gruppierung",
                        placeholder: "Gruppierung wählen",
                        systemImage: "rectangle.3.group",
                        columns: columns,
                        selection: groupColumnBinding
                    )
                    .frame(maxWidth: .infinity)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    if !valueColumns.isEmpty {
                        QueryColumnSelectionControl(
                            title: selectedAggregation.title,
                            placeholder: "Summenspalte wählen",
                            systemImage: selectedAggregation.systemImage,
                            columns: valueColumns,
                            selection: valueColumnBinding
                        )
                        .frame(maxWidth: .infinity)
                    }

                    summaryAggregationButton
                }
                .frame(maxWidth: .infinity)
            }
#else
            if !columns.isEmpty {
                QueryColumnSelectionControl(
                    title: "Gruppierung",
                    placeholder: "Gruppierung wählen",
                    systemImage: "rectangle.3.group",
                    columns: columns,
                    selection: groupColumnBinding
                )
            }

            HStack(alignment: .bottom, spacing: 10) {
                if !valueColumns.isEmpty {
                    QueryColumnSelectionControl(
                        title: selectedAggregation.title,
                        placeholder: "Summenspalte wählen",
                        systemImage: selectedAggregation.systemImage,
                        columns: valueColumns,
                        selection: valueColumnBinding
                    )
                }

                summaryAggregationButton
            }
#endif

            QueryResultTextFilterBar(
                initialText: filterText,
                appliedText: $appliedFilterText,
                filteredCount: summaryFilteredCount,
                totalCount: rows.count,
                filterTags: activeFilterTags,
                horizontalPadding: 0,
                onTextChanged: { text in
                    isWaitingForSummaryTextFilter = text != appliedFilterText
                    filterText = text
                    onFilterTextChanged(text)
                },
                onTextApplied: { text in
                    filterText = text
                    onFilterTextApplied(text)
                },
                onRemoveFilter: removeColumnFilter
            )
        }
        .padding()
    }

    private var summaryAggregationButton: some View {
        Menu {
            ForEach(QuerySummaryAggregation.allCases) { aggregation in
                Button {
                    selectedAggregation = aggregation
                } label: {
                    Label(aggregation.title, systemImage: selectedAggregation == aggregation ? "checkmark" : aggregation.systemImage)
                }
                .disabled(aggregation == .sum && valueColumns.isEmpty)
            }
        } label: {
            Image(systemName: selectedAggregation.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 52)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                }
        }
        .queryCustomMenuStyle()
        .buttonStyle(.plain)
        .accessibilityLabel("Berechnung: \(selectedAggregation.title)")
    }

    private var summaryResults: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            summaryHeader

            ForEach(Array(summaryEntries.enumerated()), id: \.element.id) { index, entry in
                summaryRow(entry, rowIndex: index)
            }

            summaryTotalRow
        }
        .padding(.bottom, 16)
    }

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(effectiveGroupColumn ?? "Gruppierung")
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(summaryValueHeader)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 0.5)
        }
    }

    private var summaryValueHeader: String {
        switch selectedAggregation {
        case .sum:
            return effectiveValueColumn ?? "Summe"
        case .count:
            return "Anzahl"
        }
    }

    private func summaryRow(_ entry: QuerySummaryEntry, rowIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpandedSummary(entry.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: expandedSummaryIDs.contains(entry.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.label)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("\(entry.count) Datensätze")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(entry.valueText)
                        .font(.body.monospacedDigit())
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    summaryRowBackground(for: entry, rowIndex: rowIndex)
                }
            }
            .buttonStyle(.plain)

            if expandedSummaryIDs.contains(entry.id) {
                summaryChildRows(entry.rows, groupValue: entry.value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    private var summaryTotalRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "equal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(summaryTotalTitle)
                    .font(.body.weight(.semibold))

                if let summaryTotal {
                    Text("\(formattedIntegerNumber(summaryTotal.count)) Datensätze")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(summaryTotal?.valueText ?? " ")
                .font(.body.monospacedDigit())
                .fontWeight(.bold)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var summaryTotalTitle: String {
        switch selectedAggregation {
        case .sum: return "Gesamtsumme"
        case .count: return "Gesamtanzahl"
        }
    }

    private func summaryChildRows(_ rows: [QueryResultRow], groupValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let childValue = summaryChildValue(for: row)
                Button {
                    activeSheet = .record(row.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(childRowText(for: row, index: index))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, 44)
                    .padding(.trailing, 16)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(alignment: .leading) {
                        summaryChildBarBackground(value: childValue, groupValue: groupValue)
                    }
                }
                .buttonStyle(.plain)

                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func childRowText(for row: QueryResultRow, index: Int) -> String {
        let text = childDisplayColumns
            .map { column in
                displayText(for: row.values[column] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")

        return text.isEmpty ? rowLabel(for: row, headlineColumn: headlineColumn, columns: columns, index: index) : text
    }

    private func summaryRowBackground(for entry: QuerySummaryEntry, rowIndex: Int) -> some View {
        ZStack(alignment: .leading) {
            if !rowIndex.isMultiple(of: 2) {
                Color.secondary.opacity(0.05)
            }

            summaryBarBackground(for: entry)
        }
    }

    private func summaryBarBackground(for entry: QuerySummaryEntry) -> some View {
        GeometryReader { proxy in
            Rectangle()
                .fill((entry.value >= 0 ? Color.green : Color.red).opacity(0.16))
                .frame(width: summaryBarWidth(for: entry.value, availableWidth: proxy.size.width))
        }
        .allowsHitTesting(false)
    }

    private func summaryBarWidth(for value: Double, availableWidth: CGFloat) -> CGFloat {
        guard maxSummaryMagnitude > 0 else {
            return 0
        }

        let ratio = min(abs(value) / maxSummaryMagnitude, 1)
        return availableWidth * CGFloat(ratio)
    }

    private func summaryChildBarBackground(value: Double, groupValue: Double) -> some View {
        GeometryReader { proxy in
            let leadingInset: CGFloat = 44
            let trailingInset: CGFloat = 16
            let availableWidth = max(proxy.size.width - leadingInset - trailingInset, 0)

            Rectangle()
                .fill(Color.gray.opacity(0.16))
                .frame(width: summaryChildBarWidth(value: value, groupValue: groupValue, availableWidth: availableWidth))
                .offset(x: leadingInset)
        }
        .allowsHitTesting(false)
    }

    private func summaryChildBarWidth(value: Double, groupValue: Double, availableWidth: CGFloat) -> CGFloat {
        let baseValue = abs(groupValue)
        guard baseValue > 0 else {
            return 0
        }

        let ratio = min(abs(value) / baseValue, 1)
        return availableWidth * CGFloat(ratio)
    }

    private func summaryChildValue(for row: QueryResultRow) -> Double {
        switch selectedAggregation {
        case .sum:
            guard let valueColumn = effectiveValueColumn else {
                return 0
            }

            return numericValue(from: row.values[valueColumn] ?? "") ?? 0
        case .count:
            return 1
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sum")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Keine Summenwerte")
                .font(.headline)

            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        switch selectedAggregation {
        case .sum:
            return "Wählen Sie eine Gruppierung und eine numerische Spalte mit Daten im aktuellen Filter."
        case .count:
            return "Wählen Sie eine Gruppierung mit Daten im aktuellen Filter."
        }
    }

    @ViewBuilder
    private func summarySheet(_ sheet: QuerySummarySheet) -> some View {
        switch sheet {
        case .filters:
            QueryResultFilterSheet(filters: columnFilters) { filters in
                columnFilters = filters
            }
        case .record(let rowID):
            recordSheet(rowID: rowID)
        }
    }

    private func ensureSelectedColumns() {
        if let effectiveGroupColumn {
            selectedGroupColumn = effectiveGroupColumn
        }

        if let effectiveValueColumn {
            selectedValueColumn = effectiveValueColumn
        }
    }

    private func rebuildSummaryEntries() {
        summaryBuildTask?.cancel()
        isWaitingForSummaryTextFilter = false

        guard let groupColumn = effectiveGroupColumn else {
            summaryEntries = []
            summaryTotal = nil
            summaryFilteredCount = 0
            isBuildingSummary = false
            return
        }

        let valueColumn = effectiveValueColumn
        guard selectedAggregation == .count || valueColumn != nil else {
            summaryEntries = []
            summaryTotal = nil
            summaryFilteredCount = 0
            isBuildingSummary = false
            return
        }

        let rows = rows
        let columns = columns
        let appliedFilterText = appliedFilterText
        let columnFilters = columnFilters
        let aggregation = selectedAggregation
        summaryEntries = []
        summaryTotal = nil
        isBuildingSummary = true
        summaryBuildTask = Task {
            await Task.yield()
            let summaryData = await Task.detached(priority: .userInitiated) {
                let filteredRows = queryFilteredRows(
                    rows: rows,
                    columns: columns,
                    appliedFilterText: appliedFilterText,
                    columnFilters: columnFilters
                )
                let entryData = summaryEntryData(
                    rows: filteredRows,
                    groupColumn: groupColumn,
                    valueColumn: valueColumn,
                    aggregation: aggregation
                )
                return (
                    entryData: entryData,
                    total: summaryTotalData(from: entryData, aggregation: aggregation),
                    filteredCount: filteredRows.count
                )
            }.value

            guard !Task.isCancelled else {
                return
            }

            summaryEntries = summaryData.entryData.map { entry in
                QuerySummaryEntry(
                    id: entry.id,
                    label: entry.label,
                    value: entry.value,
                    valueText: entry.valueText,
                    count: entry.count,
                    rows: entry.rows
                )
            }
            summaryTotal = summaryData.total
            summaryFilteredCount = summaryData.filteredCount
            expandedSummaryIDs.formIntersection(Set(summaryData.entryData.map(\.id)))
            isBuildingSummary = false
            summaryBuildTask = nil
        }
    }

    @ViewBuilder
    private func recordSheet(rowID: UUID) -> some View {
        if let selectedRecord = selectedRecord(rowID: rowID) {
            QueryResultRecordSheet(
                title: rowLabel(for: selectedRecord.row, headlineColumn: headlineColumn, columns: columns, index: selectedRecord.index),
                row: selectedRecord.row,
                baseTableName: baseTableName,
                columns: columns,
                columnKinds: columnKinds,
                positionText: "\(selectedRecord.index + 1) von \(selectedRecord.total)",
                canGoPrevious: selectedRecord.index > 0,
                canGoNext: selectedRecord.index < selectedRecord.total - 1,
                visibleColumns: $visibleColumns,
                onMoveColumns: onMoveColumns,
                onPrevious: {
                    selectRecord(offset: -1, rows: selectedRecord.rows)
                },
                onNext: {
                    selectRecord(offset: 1, rows: selectedRecord.rows)
                }
            )
        } else {
            NavigationStack {
                Text("Der Datensatz ist im aktuellen Filter nicht enthalten.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .navigationTitle("Datensatz")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") {
                                activeSheet = nil
                            }
                        }
                    }
            }
        }
    }

    private func selectedRecord(rowID: UUID) -> (row: QueryResultRow, index: Int, total: Int, rows: [QueryResultRow])? {
        let rows = currentSummaryRows
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else {
            return nil
        }

        return (rows[index], index, rows.count, rows)
    }

    private func selectRecord(offset: Int, rows: [QueryResultRow]) {
        guard case .record(let selectedRecordID) = activeSheet,
              let index = rows.firstIndex(where: { $0.id == selectedRecordID }) else {
            return
        }

        let nextIndex = index + offset
        guard rows.indices.contains(nextIndex) else {
            return
        }

        activeSheet = .record(rows[nextIndex].id)
    }

    private func toggleExpandedSummary(_ id: String) {
        guard !isBuildingSummary else {
            return
        }

        summaryExpansionTask?.cancel()
        isUpdatingSummaryExpansion = true
        summaryExpansionTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                if expandedSummaryIDs.contains(id) {
                    expandedSummaryIDs.remove(id)
                } else {
                    expandedSummaryIDs.insert(id)
                }
            }

            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            isUpdatingSummaryExpansion = false
            summaryExpansionTask = nil
        }
    }

    private func removeColumnFilter(column: String) {
        guard let index = columnFilters.firstIndex(where: { $0.column == column }) else {
            return
        }

        columnFilters[index].reset()
    }
}

private enum QueryChartKind: String, CaseIterable, Identifiable, Sendable {
    case bar
    case pie

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bar: return "Balken"
        case .pie: return "Kuchen"
        }
    }
}

private struct QueryChartEntry: Identifiable {
    let id: UUID
    let label: String
    let value: Double
    let valueText: String
    let color: Color
}

private struct QueryChartEntryData: Sendable {
    let id: UUID
    let label: String
    let value: Double
    let valueText: String
}

private enum QueryChartSheet: Identifiable {
    case filters
    case record(UUID)

    var id: String {
        switch self {
        case .filters:
            return "filters"
        case .record:
            return "record"
        }
    }
}

private struct QueryResultChartView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chartKind: QueryChartKind = .bar
    @State private var chartEntries: [QueryChartEntry] = []
    @State private var isBuildingChart = true
    @State private var isUpdatingChartPresentation = false
    @State private var chartBuildTask: Task<Void, Never>?
    @State private var chartPresentationTask: Task<Void, Never>?
    @State private var activeSheet: QueryChartSheet?

    let title: String
    let rows: [QueryResultRow]
    let columns: [String]
    let headlineColumn: String?
    let valueColumns: [String]
    @Binding var selectedValueColumn: String?
    let appliedFilterText: String
    @Binding var columnFilters: [QueryColumnFilter]
    let columnKinds: [String: QueryColumnFilterKind]
    @Binding var visibleColumns: Set<String>
    let onMoveColumns: (IndexSet, Int) -> Void

    private let chartPalette: [Color] = [
        .blue, .green, .orange, .pink, .purple, .teal, .indigo, .mint, .cyan, .red
    ]

    private var activeFilterCount: Int {
        columnFilters.filter(\.isActive).count
    }

    private var activeFilterTags: [QueryColumnFilterTag] {
        columnFilters.compactMap { queryColumnFilterTag(for: $0) }
    }

    private var isShowingChartLoading: Bool {
        isBuildingChart || isUpdatingChartPresentation
    }

    private var filteredChartRows: [QueryResultRow] {
        queryFilteredRows(
            rows: rows,
            columns: columns,
            appliedFilterText: appliedFilterText,
            columnFilters: columnFilters
        )
    }

    private var effectiveValueColumn: String? {
        if let selectedValueColumn, valueColumns.contains(selectedValueColumn) {
            return selectedValueColumn
        }

        return valueColumns.first
    }

    private var valueColumnBinding: Binding<String> {
        Binding(
            get: { effectiveValueColumn ?? "" },
            set: { selectedValueColumn = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                chartControls

                Divider()

                if isShowingChartLoading {
                    QueryResultInlineLoadingView(message: "Erstelle Diagramm…")
                } else if chartEntries.isEmpty {
                    emptyState
                } else {
                    switch chartKind {
                    case .bar:
                        QueryBarChartView(entries: chartEntries, onSelectEntry: showRecord(rowID:))
                    case .pie:
                        QueryPieChartView(entries: chartEntries, onSelectEntry: showRecord(rowID:))
                    }
                }
            }
            .navigationTitle("Diagramm")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activeSheet = .filters
                    } label: {
                        Image(systemName: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(activeFilterCount == 0 ? Color.primary : Color.orange)
                    }
                    .accessibilityLabel(activeFilterCount == 0 ? "Spaltenfilter" : "Spaltenfilter, \(activeFilterCount) aktiv")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            ensureSelectedValueColumn()
            rebuildChartEntries()
        }
        .onChange(of: selectedValueColumn) { _, _ in
            rebuildChartEntries()
        }
        .onChange(of: chartKind) { _, _ in
            showChartPresentationLoading()
        }
        .onChange(of: columnFilters) { _, _ in
            rebuildChartEntries()
        }
        .onDisappear {
            chartBuildTask?.cancel()
            chartPresentationTask?.cancel()
        }
        .sheet(item: $activeSheet) { sheet in
            chartSheet(sheet)
        }
    }

    private var chartControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagrammtyp")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Diagrammtyp", selection: $chartKind) {
                    ForEach(QueryChartKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
            }

            if !valueColumns.isEmpty {
                QueryColumnSelectionControl(
                    title: "Wert-Spalte",
                    placeholder: "Wert-Spalte wählen",
                    systemImage: "number",
                    columns: valueColumns,
                    selection: valueColumnBinding
                )
            }

            QueryColumnFilterTagsView(filterTags: activeFilterTags, onRemoveFilter: removeColumnFilter)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Keine darstellbaren Werte")
                .font(.headline)

            Text("Wählen Sie eine numerische Wert-Spalte mit Daten im aktuellen Filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func chartSheet(_ sheet: QueryChartSheet) -> some View {
        switch sheet {
        case .filters:
            QueryResultFilterSheet(filters: columnFilters) { filters in
                columnFilters = filters
            }
        case .record(let rowID):
            recordSheet(rowID: rowID)
        }
    }

    @ViewBuilder
    private func recordSheet(rowID: UUID) -> some View {
        if let selectedRecord = selectedRecord(rowID: rowID) {
            QueryResultRecordSheet(
                title: rowLabel(for: selectedRecord.row, index: selectedRecord.index),
                row: selectedRecord.row,
                baseTableName: nil,
                columns: columns,
                columnKinds: columnKinds,
                positionText: "\(selectedRecord.index + 1) von \(selectedRecord.total)",
                canGoPrevious: selectedRecord.index > 0,
                canGoNext: selectedRecord.index < selectedRecord.total - 1,
                visibleColumns: $visibleColumns,
                onMoveColumns: onMoveColumns,
                onPrevious: {
                    selectRecord(offset: -1, rows: selectedRecord.rows)
                },
                onNext: {
                    selectRecord(offset: 1, rows: selectedRecord.rows)
                }
            )
        } else {
            NavigationStack {
                Text("Der Datensatz ist im aktuellen Filter nicht enthalten.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .navigationTitle("Datensatz")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") {
                                activeSheet = nil
                            }
                        }
                    }
            }
        }
    }

    private func ensureSelectedValueColumn() {
        guard let effectiveValueColumn else {
            return
        }

        selectedValueColumn = effectiveValueColumn
    }

    private func showRecord(rowID: UUID) {
        activeSheet = .record(rowID)
    }

    private func rebuildChartEntries() {
        chartBuildTask?.cancel()
        chartPresentationTask?.cancel()
        isUpdatingChartPresentation = false

        guard let valueColumn = effectiveValueColumn else {
            chartEntries = []
            isBuildingChart = false
            return
        }

        let rows = rows
        let columns = columns
        let headlineColumn = headlineColumn
        let appliedFilterText = appliedFilterText
        let columnFilters = columnFilters
        let palette = chartPalette

        chartEntries = []
        isBuildingChart = true
        chartBuildTask = Task {
            await Task.yield()
            let entryData = await Task.detached(priority: .userInitiated) {
                let filteredRows = queryFilteredRows(
                    rows: rows,
                    columns: columns,
                    appliedFilterText: appliedFilterText,
                    columnFilters: columnFilters
                )
                return chartEntryData(
                    rows: filteredRows,
                    valueColumn: valueColumn,
                    headlineColumn: headlineColumn,
                    columns: columns
                )
            }.value

            guard !Task.isCancelled else {
                return
            }

            chartEntries = entryData.enumerated().map { index, entry in
                QueryChartEntry(
                    id: entry.id,
                    label: entry.label,
                    value: entry.value,
                    valueText: entry.valueText,
                    color: palette[index % palette.count]
                )
            }
            isBuildingChart = false
            chartBuildTask = nil
        }
    }

    private func showChartPresentationLoading() {
        guard !isBuildingChart else {
            return
        }

        chartPresentationTask?.cancel()
        isUpdatingChartPresentation = true
        chartPresentationTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else {
                return
            }

            isUpdatingChartPresentation = false
            chartPresentationTask = nil
        }
    }

    private func selectedRecord(rowID: UUID) -> (row: QueryResultRow, index: Int, total: Int, rows: [QueryResultRow])? {
        let rows = filteredChartRows
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else {
            return nil
        }

        return (rows[index], index, rows.count, rows)
    }

    private func removeColumnFilter(column: String) {
        guard let index = columnFilters.firstIndex(where: { $0.column == column }) else {
            return
        }

        columnFilters[index].reset()
    }

    private func selectRecord(offset: Int, rows: [QueryResultRow]) {
        guard case .record(let selectedRecordID) = activeSheet,
              let index = rows.firstIndex(where: { $0.id == selectedRecordID }) else {
            return
        }

        let nextIndex = index + offset
        guard rows.indices.contains(nextIndex) else {
            return
        }

        activeSheet = .record(rows[nextIndex].id)
    }

    private func rowLabel(for row: QueryResultRow, index: Int) -> String {
        if let headlineColumn,
           let value = row.values[headlineColumn]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return displayText(for: value)
        }

        for column in columns {
            if let value = row.values[column]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return displayText(for: value)
            }
        }

        return "Zeile \(index + 1)"
    }
}

private struct QueryBarChartView: View {
    let entries: [QueryChartEntry]
    let onSelectEntry: (UUID) -> Void

    private var maxMagnitude: Double {
        max(entries.map { abs($0.value) }.max() ?? 1, 1)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { entry in
                barRow(entry)
            }
        }
        .padding()
    }

    private func barRow(_ entry: QueryChartEntry) -> some View {
        Button {
            onSelectEntry(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Text(entry.valueText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))

                            Capsule()
                                .fill(entry.value >= 0 ? entry.color : Color.red)
                                .frame(width: barWidth(for: entry.value, availableWidth: proxy.size.width))
                        }
                    }
                    .frame(height: 12)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func barWidth(for value: Double, availableWidth: CGFloat) -> CGFloat {
        let ratio = min(abs(value) / maxMagnitude, 1)
        return max(2, availableWidth * CGFloat(ratio))
    }
}

private struct QueryPieChartView: View {
    let entries: [QueryChartEntry]
    let onSelectEntry: (UUID) -> Void

    private var positiveEntries: [QueryChartEntry] {
        entries.filter { $0.value > 0 }
    }

    private var total: Double {
        positiveEntries.reduce(0) { $0 + $1.value }
    }

    private var slices: [QueryPieSlice] {
        guard total > 0 else {
            return []
        }

        var currentAngle = -90.0
        return positiveEntries.map { entry in
            let angle = entry.value / total * 360
            let slice = QueryPieSlice(
                id: entry.id,
                entry: entry,
                startAngle: .degrees(currentAngle),
                endAngle: .degrees(currentAngle + angle)
            )
            currentAngle += angle
            return slice
        }
    }

    var body: some View {
        if slices.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "chart.pie")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("Für Kuchen nur positive Werte")
                    .font(.headline)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 18) {
                QueryPieCanvas(slices: slices, onSelectEntry: onSelectEntry)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.top)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(positiveEntries) { entry in
                        legendRow(entry)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    private func legendRow(_ entry: QueryChartEntry) -> some View {
        Button {
            onSelectEntry(entry.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(entry.color)
                    .frame(width: 10, height: 10)

                Text(entry.label)
                    .font(.subheadline)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(entry.valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct QueryPieCanvas: View {
    let slices: [QueryPieSlice]
    let onSelectEntry: (UUID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let rect = CGRect(
                x: (proxy.size.width - size) / 2,
                y: (proxy.size.height - size) / 2,
                width: size,
                height: size
            )

            ZStack {
                ForEach(slices) { slice in
                    QueryPieSliceShape(startAngle: slice.startAngle, endAngle: slice.endAngle)
                        .fill(slice.entry.color)
                        .contentShape(QueryPieSliceShape(startAngle: slice.startAngle, endAngle: slice.endAngle))
                        .onTapGesture {
                            onSelectEntry(slice.id)
                        }
                }

                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    .frame(width: size, height: size)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

private struct QueryPieSlice: Identifiable {
    let id: UUID
    let entry: QueryChartEntry
    let startAngle: Angle
    let endAngle: Angle
}

private struct QueryPieSliceShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()

        return path
    }
}

private nonisolated func chartEntryData(rows: [QueryResultRow], valueColumn: String, headlineColumn: String?, columns: [String]) -> [QueryChartEntryData] {
    rows.enumerated().compactMap { index, row in
        let rawValue = row.values[valueColumn] ?? ""
        guard let value = numericValue(from: rawValue) else {
            return nil
        }

        return QueryChartEntryData(
            id: row.id,
            label: rowLabel(for: row, headlineColumn: headlineColumn, columns: columns, index: index),
            value: value,
            valueText: displayText(for: rawValue)
        )
    }
}

private nonisolated func summaryEntryData(rows: [QueryResultRow], groupColumn: String, valueColumn: String?, aggregation: QuerySummaryAggregation) -> [QuerySummaryEntryData] {
    var groupedValues: [String: (label: String, value: Double, count: Int, rows: [QueryResultRow], fractionDigitCount: Int, order: Int)] = [:]

    for (index, row) in rows.enumerated() {
        let value: Double
        let fractionDigitCount: Int
        switch aggregation {
        case .sum:
            guard let valueColumn,
                  let parsedNumber = parsedNumericValue(from: row.values[valueColumn] ?? "") else {
                continue
            }

            value = parsedNumber.value
            fractionDigitCount = parsedNumber.fractionDigitCount
        case .count:
            value = 1
            fractionDigitCount = 0
        }

        let groupKey = selectableValueKey(from: row.values[groupColumn] ?? "")
        let label = selectableValueTitle(groupKey)
        if let existingGroup = groupedValues[groupKey] {
            var groupRows = existingGroup.rows
            groupRows.append(row)
            groupedValues[groupKey] = (
                label: existingGroup.label,
                value: existingGroup.value + value,
                count: existingGroup.count + 1,
                rows: groupRows,
                fractionDigitCount: max(existingGroup.fractionDigitCount, fractionDigitCount),
                order: existingGroup.order
            )
        } else {
            groupedValues[groupKey] = (
                label: label,
                value: value,
                count: 1,
                rows: [row],
                fractionDigitCount: fractionDigitCount,
                order: index
            )
        }
    }

    return groupedValues.map { key, group in
        QuerySummaryEntryData(
            id: key,
            label: group.label,
            value: group.value,
            valueText: formattedSummaryValue(group.value, aggregation: aggregation, fractionDigitCount: group.fractionDigitCount),
            count: group.count,
            rows: group.rows,
            fractionDigitCount: group.fractionDigitCount,
            order: group.order
        )
    }
    .sorted { first, second in
        first.order < second.order
    }
}

private nonisolated func summaryTotalData(from entries: [QuerySummaryEntryData], aggregation: QuerySummaryAggregation) -> QuerySummaryTotal {
    let value = entries.reduce(0) { $0 + $1.value }
    let count = entries.reduce(0) { $0 + $1.count }
    let fractionDigitCount = entries.map(\.fractionDigitCount).max() ?? 0

    return QuerySummaryTotal(
        value: value,
        valueText: formattedSummaryValue(value, aggregation: aggregation, fractionDigitCount: fractionDigitCount),
        count: count
    )
}

private nonisolated func formattedSummaryValue(_ value: Double, aggregation: QuerySummaryAggregation, fractionDigitCount: Int = 2) -> String {
    switch aggregation {
    case .sum:
        return formattedDecimalNumber(value, fractionDigitCount: fractionDigitCount)
    case .count:
        return formattedIntegerNumber(Int(value))
    }
}

private nonisolated func rowLabel(for row: QueryResultRow, headlineColumn: String?, columns: [String], index: Int) -> String {
    if let headlineColumn,
       let value = row.values[headlineColumn]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !value.isEmpty {
        return displayText(for: value)
    }

    for column in columns {
        if let value = row.values[column]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return displayText(for: value)
        }
    }

    return "Zeile \(index + 1)"
}

private nonisolated func formattedDecimalNumber(_ value: Double, fractionDigitCount: Int = 2) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = fractionDigitCount
    formatter.maximumFractionDigits = fractionDigitCount

    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private nonisolated func formattedIntegerNumber(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0

    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private struct QueryResultPresentationEditModeModifier: ViewModifier {
    @Binding var isEditing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content
#else
        content.environment(
            \.editMode,
            Binding<EditMode>(
                get: { isEditing ? .active : .inactive },
                set: { isEditing = $0.isEditing }
            )
        )
#endif
    }
}

private struct QueryResultRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingPresentation = false
    @State private var draftVisibleColumns = Set<String>()
    @State private var draftColumns: [String] = []
    @State private var dragOffset: CGFloat = 0
    @State private var transitionOffset: CGFloat = 0
    @State private var transitionOpacity = 1.0
    @State private var pendingNavigationDirection: RecordNavigationDirection?
    @State private var documents: [TableImageDocument] = []
    @State private var documentErrorMessage: String?
    @State private var isLoadingDocuments = false
    @State private var loadedDocumentLookupKey: String?
    @State private var isShowingDocuments = false

    let title: String
    let row: QueryResultRow
    let baseTableName: String?
    let columns: [String]
    let columnKinds: [String: QueryColumnFilterKind]
    let positionText: String
    let canGoPrevious: Bool
    let canGoNext: Bool
    @Binding var visibleColumns: Set<String>
    let onMoveColumns: (IndexSet, Int) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    private let store = SecureSettingsStore()

    private var presentedColumns: [String] {
        isEditingPresentation ? draftColumns : columns
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(presentedColumns, id: \.self) { column in
                    HStack(alignment: .top, spacing: 12) {
                        if isEditingPresentation {
                            Button {
                                toggleVisibleColumn(column)
                            } label: {
                                Image(systemName: draftVisibleColumns.contains(column) ? "checkmark.square.fill" : "square")
                                    .font(.title3)
                                    .foregroundStyle(draftVisibleColumns.contains(column) ? Color.accentColor : Color.secondary)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(draftVisibleColumns.contains(column) ? "\(column) ausblenden" : "\(column) anzeigen")
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(column)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            detailValueView(row.values[column] ?? "", column: column)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background {
                        if visibleColumns.contains(column) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.green.opacity(0.14))
                        }
                    }
                }
                .onMove(perform: moveDraftColumns)
            }
            .modifier(QueryResultPresentationEditModeModifier(isEditing: $isEditingPresentation))
            .offset(x: dragOffset + transitionOffset)
            .opacity(transitionOpacity)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.86), value: dragOffset)
            .onChange(of: row.id) { _, _ in
                animateRecordEntry()
            }
            .simultaneousGesture(recordNavigationGesture)
            .sheet(isPresented: $isShowingDocuments) {
                QueryResultDocumentsSheet(
                    documents: documents,
                    isLoading: isLoadingDocuments,
                    errorMessage: documentErrorMessage
                ) {
                    await loadDocuments(forceRefresh: true)
                }
            }
            .task(id: documentLookupKey) {
                await loadDocuments()
            }
            .navigationTitle(title.isEmpty ? "Datensatz" : title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(positionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditingPresentation ? "Abbrechen" : "Darstellung") {
                        if isEditingPresentation {
                            cancelPresentationEditing()
                        } else {
                            startPresentationEditing()
                        }
                    }
                    .foregroundStyle(isEditingPresentation ? Color.accentColor : Color.primary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        if shouldShowDocumentsButton {
                            recordDocumentsButton
                        }

                        Button("Fertig") {
                            if isEditingPresentation {
                                applyPresentationEditing()
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .queryResizableSheet(
            minWidth: 640,
            idealWidth: 780,
            maxWidth: 2_000,
            minHeight: 480,
            idealHeight: 680,
            maxHeight: 1_600
        )
    }

    private var shouldShowDocumentsButton: Bool {
        documentLookupKey != nil
    }

    private var documentLookupKey: String? {
        guard let baseTableName = trimmedBaseTableName,
              let tableID = recordTableID else {
            return nil
        }

        return "\(baseTableName)\n\(tableID)"
    }

    private var trimmedBaseTableName: String? {
        let trimmedValue = baseTableName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private var recordTableID: String? {
        let trimmedValue = row.value(forColumnName: "ID")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private var documentButtonCountText: String {
        if isLoadingDocuments && documents.isEmpty {
            return "…"
        }

        return formattedIntegerNumber(documents.count)
    }

    private var documentButtonAccessibilityLabel: String {
        if isLoadingDocuments {
            return "Dokumente werden geladen"
        }

        if documentErrorMessage != nil {
            return "Dokumente konnten nicht geladen werden"
        }

        return "\(documents.count) Dokumente"
    }

    private var recordDocumentsButton: some View {
        Button {
            isShowingDocuments = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .symbolRenderingMode(.hierarchical)

                Text(documentButtonCountText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(documentErrorMessage == nil ? Color.primary : Color.orange)
        }
        .disabled(isLoadingDocuments || (documents.isEmpty && documentErrorMessage == nil))
        .accessibilityLabel(documentButtonAccessibilityLabel)
    }

    @MainActor
    private func loadDocuments(forceRefresh: Bool = false) async {
        guard let baseTableName = trimmedBaseTableName,
              let tableID = recordTableID,
              let lookupKey = documentLookupKey else {
            clearDocumentState()
            return
        }

        guard forceRefresh || loadedDocumentLookupKey != lookupKey else {
            return
        }

        let settings = (try? store.load()) ?? .default
        let deviceID = settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else {
            documents = []
            documentErrorMessage = "DeviceID fehlt. Bitte in den Einstellungen vergeben."
            loadedDocumentLookupKey = lookupKey
            return
        }

        isLoadingDocuments = true
        documentErrorMessage = nil
        documents = []
        defer { isLoadingDocuments = false }

        do {
            documents = try await APIService.shared.fetchTableImageDocuments(
                baseTableName: baseTableName,
                tableID: tableID,
                deviceID: deviceID
            )
            loadedDocumentLookupKey = lookupKey
        } catch {
            documents = []
            documentErrorMessage = localizedErrorMessage(error)
            loadedDocumentLookupKey = lookupKey
        }
    }

    private func clearDocumentState() {
        documents = []
        documentErrorMessage = nil
        isLoadingDocuments = false
        loadedDocumentLookupKey = nil
        isShowingDocuments = false
    }

    private func toggleVisibleColumn(_ column: String) {
        if draftVisibleColumns.contains(column) {
            let activeVisibleColumns = draftColumns.filter { draftVisibleColumns.contains($0) }
            guard activeVisibleColumns.count > 1 else {
                return
            }

            draftVisibleColumns.remove(column)
        } else {
            draftVisibleColumns.insert(column)
        }
    }

    private func moveDraftColumns(fromOffsets source: IndexSet, toOffset destination: Int) {
        draftColumns.move(fromOffsets: source, toOffset: destination)
    }

    private func startPresentationEditing() {
        draftVisibleColumns = visibleColumns
        draftColumns = columns
        withAnimation {
            isEditingPresentation = true
        }
    }

    private func cancelPresentationEditing() {
        draftVisibleColumns = visibleColumns
        draftColumns = columns
        withAnimation {
            isEditingPresentation = false
        }
    }

    private func applyPresentationEditing() {
        let selectedColumns = draftColumns.filter { draftVisibleColumns.contains($0) }
        guard !selectedColumns.isEmpty else {
            return
        }

        applyDraftColumnOrder()
        visibleColumns = Set(selectedColumns)
        withAnimation {
            isEditingPresentation = false
        }
    }

    private func applyDraftColumnOrder() {
        var currentColumns = columns

        for targetIndex in draftColumns.indices {
            let column = draftColumns[targetIndex]
            guard let currentIndex = currentColumns.firstIndex(of: column),
                  currentIndex != targetIndex else {
                continue
            }

            let destination = currentIndex < targetIndex ? targetIndex + 1 : targetIndex
            let source = IndexSet(integer: currentIndex)
            onMoveColumns(source, destination)
            currentColumns.move(fromOffsets: source, toOffset: destination)
        }
    }

    private var recordNavigationGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onChanged { value in
                guard !isEditingPresentation else {
                    dragOffset = 0
                    return
                }

                guard pendingNavigationDirection == nil else {
                    return
                }

                let horizontalDistance = value.translation.width
                let verticalDistance = value.translation.height

                guard abs(horizontalDistance) > abs(verticalDistance) * 1.2 else {
                    dragOffset = 0
                    return
                }

                let canNavigate = horizontalDistance < 0 ? canGoNext : canGoPrevious
                dragOffset = horizontalDistance * (canNavigate ? 0.35 : 0.12)
            }
            .onEnded { value in
                guard !isEditingPresentation else {
                    resetDragOffset()
                    return
                }

                let horizontalDistance = value.translation.width
                let verticalDistance = value.translation.height

                guard abs(horizontalDistance) > abs(verticalDistance) * 1.4,
                      abs(horizontalDistance) > 55 else {
                    resetDragOffset()
                    return
                }

                if horizontalDistance < 0, canGoNext {
                    animateRecordExit(.next)
                } else if horizontalDistance > 0, canGoPrevious {
                    animateRecordExit(.previous)
                } else {
                    resetDragOffset()
                }
            }
    }

    private func animateRecordExit(_ direction: RecordNavigationDirection) {
        guard pendingNavigationDirection == nil else {
            return
        }

        pendingNavigationDirection = direction

        withAnimation(.easeInOut(duration: 0.16)) {
            dragOffset = 0
            transitionOffset = direction.exitOffset
            transitionOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            switch direction {
            case .previous:
                onPrevious()
            case .next:
                onNext()
            }
        }
    }

    private func animateRecordEntry() {
        guard let direction = pendingNavigationDirection else {
            return
        }

        dragOffset = 0
        transitionOffset = direction.entryOffset
        transitionOpacity = 0

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                transitionOffset = 0
                transitionOpacity = 1
            }

            pendingNavigationDirection = nil
        }
    }

    private func resetDragOffset() {
        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.86)) {
            dragOffset = 0
            transitionOffset = 0
            transitionOpacity = 1
        }
    }

    @ViewBuilder
    private func detailValueView(_ value: String, column: String) -> some View {
        if columnKinds[column] == .boolean, let boolean = booleanValue(from: value) {
            Image(systemName: boolean ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(boolean ? Color.green : Color.red)
                .imageScale(.large)
                .accessibilityLabel(boolean ? "true" : "false")
        } else if let contactLink = contactLink(from: value, column: column) {
            Link(destination: contactLink.url) {
                Label(contactLink.title, systemImage: contactLink.systemImage)
                    .font(.body)
                    .foregroundStyle(contactLink.color)
                    .lineLimit(2)
            }
            .accessibilityLabel(contactLink.accessibilityLabel)
        } else {
            Text(value.isEmpty ? " " : displayText(for: value))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum QueryDocumentOpenError: LocalizedError {
    case noApplication

    var errorDescription: String? {
        "Für dieses Dokument ist keine Anwendung zum Öffnen verfügbar."
    }
}

@MainActor
final class TableImageDocumentSessionCache {
    static let shared = TableImageDocumentSessionCache()

    private var fileURLs: [String: URL] = [:]

    private init() {}

    func fileURL(for document: TableImageDocument, deviceID: String) async throws -> URL {
        let key = "\(deviceID)\n\(document.oid)"
        if let cachedURL = fileURLs[key], FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        let data = try await APIService.shared.fetchFile(oid: document.oid, deviceID: deviceID)
        let fileURL = try await Task.detached(priority: .userInitiated) {
            try saveTableImageDocumentFile(data: data, document: document)
        }.value
        fileURLs[key] = fileURL
        return fileURL
    }

    nonisolated static func clearDiskCacheAtLaunch() {
        guard let directoryURL = try? tableImageDocumentCacheDirectoryURL(),
              FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }

        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct QueryResultDocumentRow: View {
    let name: String
    let descriptionText: String?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let descriptionText {
                    Text(descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct QueryResultDocumentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    @State private var loadingDocumentID: UUID?
    @State private var downloadErrorMessage: String?
    @State private var isRefreshing = false

    let documents: [TableImageDocument]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () async -> Void

    private let store = SecureSettingsStore()

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Dokumente")
                .queryInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await refreshDocuments() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Dokumente neu laden")
                        .disabled(isLoading || isRefreshing)
                    }
                }
                .quickLookPreview($previewURL)
                .alert("Dokument konnte nicht geöffnet werden", isPresented: downloadErrorBinding) {
                    Button("OK", role: .cancel) {
                        downloadErrorMessage = nil
                    }
                } message: {
                    Text(downloadErrorMessage ?? "")
                }
        }
        .queryResizableSheet(
            minWidth: 640,
            idealWidth: 800,
            maxWidth: 1_800,
            minHeight: 480,
            idealHeight: 650,
            maxHeight: 1_400
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading || isRefreshing {
            QueryResultInlineLoadingView(message: "Lade Dokumente…")
        } else if let errorMessage {
            documentsErrorView(errorMessage)
        } else if documents.isEmpty {
            documentsEmptyView
        } else {
            documentsList
        }
    }

    private var documentsList: some View {
        List {
            ForEach(documents) { document in
                Button {
                    Task { await openDocument(document) }
                } label: {
                    QueryResultDocumentRow(
                        name: document.name.isEmpty ? "Dokument" : displayText(for: document.name),
                        descriptionText: document.beschreibung.isEmpty ? nil : displayText(for: document.beschreibung),
                        isLoading: loadingDocumentID == document.id
                    )
                }
                .buttonStyle(.plain)
                .disabled(loadingDocumentID != nil)
            }
        }
    }

    private func documentsErrorView(_ errorMessage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.large)
                .foregroundStyle(.orange)

            Text(errorMessage)
                .multilineTextAlignment(.center)

            Button("Erneut laden") {
                Task { await refreshDocuments() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var documentsEmptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .imageScale(.large)
                .foregroundStyle(.secondary)

            Text("Keine Dokumente")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var downloadErrorBinding: Binding<Bool> {
        Binding {
            downloadErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                downloadErrorMessage = nil
            }
        }
    }

    @MainActor
    private func refreshDocuments() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        await onRefresh()
    }

    @MainActor
    private func openDocument(_ document: TableImageDocument) async {
        guard loadingDocumentID == nil else {
            return
        }

        let settings = (try? store.load()) ?? .default
        let deviceID = settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else {
            downloadErrorMessage = "DeviceID fehlt. Bitte in den Einstellungen vergeben."
            return
        }

        loadingDocumentID = document.id
        downloadErrorMessage = nil
        defer { loadingDocumentID = nil }

        do {
            let fileURL = try await TableImageDocumentSessionCache.shared.fileURL(
                for: document,
                deviceID: deviceID
            )
#if os(macOS)
            guard NSWorkspace.shared.open(fileURL) else {
                throw QueryDocumentOpenError.noApplication
            }
#else
            previewURL = fileURL
#endif
        } catch {
            downloadErrorMessage = localizedErrorMessage(error)
        }
    }
}

private enum RecordNavigationDirection {
    case previous
    case next

    var exitOffset: CGFloat {
        switch self {
        case .previous:
            return 180
        case .next:
            return -180
        }
    }

    var entryOffset: CGFloat {
        switch self {
        case .previous:
            return -180
        case .next:
            return 180
        }
    }
}

private struct ContactLink {
    let title: String
    let systemImage: String
    let color: Color
    let url: URL
    let accessibilityLabel: String
}

private nonisolated func saveTableImageDocumentFile(data: Data, document: TableImageDocument) throws -> URL {
    do {
        let directoryURL = try tableImageDocumentCacheDirectoryURL()
            .appendingPathComponent(sanitizedFileName(document.oid), isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent(tableImageDocumentFileName(for: document), isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    } catch let error as APIError {
        throw error
    } catch {
        throw APIError.fileWrite(error)
    }
}

private nonisolated func tableImageDocumentCacheDirectoryURL() throws -> URL {
    guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
        throw APIError.invalidURL
    }

    return cachesURL
        .appendingPathComponent("qncTABLE", isDirectory: true)
        .appendingPathComponent("table-image-files", isDirectory: true)
}

private nonisolated func tableImageDocumentFileName(for document: TableImageDocument) -> String {
    let baseName = sanitizedFileName(document.name.isEmpty ? "Dokument" : document.name)
    let fileExtension = normalizedFileExtension(from: document.fileType)
    guard !fileExtension.isEmpty else {
        return baseName
    }

    let existingExtension = (baseName as NSString).pathExtension.lowercased()
    guard existingExtension != fileExtension else {
        return baseName
    }

    return "\(baseName).\(fileExtension)"
}

private nonisolated func sanitizedFileName(_ value: String) -> String {
    let forbiddenCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        .union(.newlines)
    let sanitizedValue = value
        .components(separatedBy: forbiddenCharacters)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !sanitizedValue.isEmpty, sanitizedValue != ".", sanitizedValue != ".." else {
        return "Dokument"
    }

    return sanitizedValue
}

private nonisolated func normalizedFileExtension(from fileType: String) -> String {
    var trimmedValue = fileType
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let lowercasedValue = trimmedValue.lowercased()

    if let mappedExtension = commonFileExtension(for: lowercasedValue) {
        return mappedExtension
    }

    if let slashIndex = trimmedValue.firstIndex(of: "/") {
        trimmedValue = String(trimmedValue[trimmedValue.index(after: slashIndex)...])
    }

    if let plusIndex = trimmedValue.firstIndex(of: "+") {
        trimmedValue = String(trimmedValue[..<plusIndex])
    }

    let allowedCharacters = CharacterSet.alphanumerics
    return trimmedValue.unicodeScalars
        .filter { allowedCharacters.contains($0) }
        .map(String.init)
        .joined()
        .lowercased()
}

private nonisolated func commonFileExtension(for fileType: String) -> String? {
    switch fileType {
    case "application/pdf":
        return "pdf"
    case "image/jpeg":
        return "jpg"
    case "image/png":
        return "png"
    case "image/gif":
        return "gif"
    case "text/plain":
        return "txt"
    case "text/csv":
        return "csv"
    case "application/zip":
        return "zip"
    case "application/msword":
        return "doc"
    case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
        return "docx"
    case "application/vnd.ms-excel":
        return "xls"
    case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
        return "xlsx"
    default:
        return nil
    }
}

private nonisolated func localizedErrorMessage(_ error: Error) -> String {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return message.isEmpty ? "Unbekannter Fehler." : message
}

private struct NumericColumnProfile: Sendable {
    let numericCount: Int
    let nonNumericCount: Int

    nonisolated var isNumeric: Bool {
        let totalCount = numericCount + nonNumericCount
        guard numericCount > 0, totalCount > 0 else {
            return false
        }

        return nonNumericCount == 0 || Double(numericCount) / Double(totalCount) >= 0.8
    }
}

private nonisolated func booleanValue(from value: String) -> Bool? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1":
        return true
    case "false", "0":
        return false
    default:
        return nil
    }
}

private nonisolated func typedValues(for column: String, rows: [QueryResultRow]) -> [String] {
    rows
        .compactMap { $0.values[column]?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !isMissingValue($0) }
}

private nonisolated func numericColumnProfile(from values: [String]) -> NumericColumnProfile {
    values.reduce(into: NumericColumnProfile(numericCount: 0, nonNumericCount: 0)) { profile, value in
        if parsedDate(from: value) != nil {
            profile = NumericColumnProfile(
                numericCount: profile.numericCount,
                nonNumericCount: profile.nonNumericCount + 1
            )
        } else if numericValue(from: value) != nil {
            profile = NumericColumnProfile(
                numericCount: profile.numericCount + 1,
                nonNumericCount: profile.nonNumericCount
            )
        } else {
            profile = NumericColumnProfile(
                numericCount: profile.numericCount,
                nonNumericCount: profile.nonNumericCount + 1
            )
        }
    }
}

private nonisolated func isMissingValue(_ value: String) -> Bool {
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["-", "--", "null", "<null>", "nil", "n/a", "na", "dbnull"].contains(normalizedValue)
}

private nonisolated func filterKind(for column: String, rows: [QueryResultRow]) -> QueryColumnFilterKind {
    if isPhoneColumn(column) {
        return .text
    }

    let values = typedValues(for: column, rows: rows)
    guard !values.isEmpty else {
        return .text
    }

    if values.allSatisfy({ booleanValue(from: $0) != nil }) {
        return .boolean
    }

    if numericColumnProfile(from: values).isNumeric {
        return .number
    }

    return .text
}

private nonisolated func displayText(for value: String) -> String {
    formattedDateValue(from: value) ?? formattedDecimalValue(from: value) ?? value
}

private nonisolated func selectableValueKey(from value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private nonisolated func selectableValueTitle(_ value: String) -> String {
    let title = displayText(for: value)
    return title.isEmpty ? "Leer" : title
}

private nonisolated func formattedDateValue(from value: String) -> String? {
    guard let date = parsedDate(from: value) else {
        return nil
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.dateStyle = .medium
    formatter.timeStyle = hasNonMidnightTime(in: value) ? .short : .none

    return formatter.string(from: date)
}

private nonisolated func parsedDate(from value: String) -> Date? {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard looksLikeDate(trimmedValue) else {
        return nil
    }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: trimmedValue) {
        return date
    }

    isoFormatter.formatOptions = [.withInternetDateTime]
    if let date = isoFormatter.date(from: trimmedValue) {
        return date
    }

    let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
        "dd.MM.yyyy HH:mm:ss",
        "dd.MM.yyyy HH:mm",
        "dd.MM.yyyy",
        "M/d/yyyy h:mm:ss a",
        "M/d/yyyy h:mm a",
        "MM/dd/yyyy HH:mm:ss",
        "MM/dd/yyyy HH:mm",
        "MM/dd/yyyy"
    ]

    for format in dateFormats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmedValue) {
            return date
        }
    }

    return nil
}

private nonisolated func hasNonMidnightTime(in value: String) -> Bool {
    let pattern = #"(?:T|\s)\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:\s?[AP]M)?"#
    guard let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
        return false
    }

    var timePart = String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    if timePart.hasPrefix("T") {
        timePart.removeFirst()
    }

    let lowercasedTimePart = timePart.lowercased()
    let isAM = lowercasedTimePart.hasSuffix("am")
    let isPM = lowercasedTimePart.hasSuffix("pm")
    timePart = timePart
        .replacingOccurrences(of: "AM", with: "", options: .caseInsensitive)
        .replacingOccurrences(of: "PM", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let components = timePart.split(separator: ":", maxSplits: 2).map(String.init)
    guard components.count >= 2 else {
        return false
    }

    var hour = Int(components[0]) ?? 0
    if isAM && hour == 12 {
        hour = 0
    } else if isPM && hour < 12 {
        hour += 12
    }

    let minute = Int(components[1]) ?? 0
    let secondAndFraction = components.count > 2 ? components[2] : "0"
    let secondParts = secondAndFraction.split(separator: ".", maxSplits: 1).map(String.init)
    let second = Int(secondParts.first ?? "0") ?? 0
    let hasFraction = secondParts.dropFirst().first?.contains { $0 != "0" } ?? false

    return hour != 0 || minute != 0 || second != 0 || hasFraction
}

private nonisolated func looksLikeDate(_ value: String) -> Bool {
    let patterns = [
        #"^\d{4}-\d{2}-\d{2}"#,
        #"^\d{1,2}\.\d{1,2}\.\d{4}"#,
        #"^\d{1,2}/\d{1,2}/\d{4}"#
    ]

    return patterns.contains { pattern in
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private nonisolated func formattedDecimalValue(from value: String) -> String? {
    guard let parsedNumber = parsedNumericValue(from: value), parsedNumber.hasDecimalSeparator else {
        return nil
    }

    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = parsedNumber.fractionDigitCount
    formatter.maximumFractionDigits = parsedNumber.fractionDigitCount

    return formatter.string(from: NSNumber(value: parsedNumber.value))
}

private nonisolated func numericValue(from value: String) -> Double? {
    parsedNumericValue(from: value)?.value
}

private nonisolated func parsedNumericValue(from value: String) -> (value: Double, hasDecimalSeparator: Bool, fractionDigitCount: Int)? {
    var trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty, !isMissingValue(trimmedValue) else {
        return nil
    }

    trimmedValue = trimmedValue
        .replacingOccurrences(of: "−", with: "-")
        .replacingOccurrences(of: "–", with: "-")
        .replacingOccurrences(of: "—", with: "-")

    if trimmedValue.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil,
       let candidate = decoratedNumericCandidate(from: trimmedValue) {
        trimmedValue = candidate
    }

    let numericCharacters = CharacterSet(charactersIn: "0123456789.,+-()eE")
    let ignoredCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00a0}\u{202f}'’€$£¥%‰"))
    guard trimmedValue.unicodeScalars.allSatisfy({ numericCharacters.contains($0) || ignoredCharacters.contains($0) }) else {
        return nil
    }

    var compactValue = trimmedValue.unicodeScalars
        .filter { numericCharacters.contains($0) }
        .map(String.init)
        .joined()

    guard compactValue.contains(where: \.isNumber) else {
        return nil
    }

    var isNegative = false
    if compactValue.hasPrefix("("), compactValue.hasSuffix(")") {
        isNegative = true
        compactValue.removeFirst()
        compactValue.removeLast()
    } else if compactValue.contains("(") || compactValue.contains(")") {
        return nil
    }

    if compactValue.hasPrefix("-") {
        isNegative = true
        compactValue.removeFirst()
    }

    if compactValue.hasSuffix("-") {
        isNegative = true
        compactValue.removeLast()
    }

    if compactValue.hasPrefix("+") {
        compactValue.removeFirst()
    }

    if compactValue.hasSuffix("+") {
        compactValue.removeLast()
    }

    let exponentSuffix: String
    if compactValue.contains(where: { $0 == "e" || $0 == "E" }) {
        guard let exponentParts = scientificNotationParts(from: compactValue) else {
            return nil
        }

        compactValue = exponentParts.mantissa
        exponentSuffix = "e\(exponentParts.exponent)"
    } else {
        exponentSuffix = ""
    }

    guard !compactValue.contains("+"),
          !compactValue.contains("-"),
          compactValue.range(of: #"^[0-9.,]+$"#, options: .regularExpression) != nil else {
        return nil
    }

    let decimalSeparator = detectedDecimalSeparator(in: compactValue)
    let hasDecimalSeparator = decimalSeparator != nil
    var fractionDigitCount = 0

    let sign = isNegative ? "-" : ""
    let normalized: String

    if let decimalSeparator, let separatorIndex = compactValue.lastIndex(of: decimalSeparator) {
        let integerPart = compactValue[..<separatorIndex].filter(\.isNumber)
        let fractionPart = compactValue[compactValue.index(after: separatorIndex)...].filter(\.isNumber)
        guard !integerPart.isEmpty, !fractionPart.isEmpty else {
            return nil
        }

        fractionDigitCount = fractionPart.count
        normalized = "\(sign)\(integerPart).\(fractionPart)\(exponentSuffix)"
    } else {
        let digits = compactValue.filter(\.isNumber)
        guard !digits.isEmpty else {
            return nil
        }

        normalized = "\(sign)\(digits)\(exponentSuffix)"
    }

    guard let value = Double(normalized) else {
        return nil
    }

    return (value, hasDecimalSeparator, fractionDigitCount)
}

private nonisolated func decoratedNumericCandidate(from value: String) -> String? {
    let pattern = "\\(?[-+]?\\d(?:[\\d.,'’\\s]*\\d)?(?:[eE][-+]?\\d+)?\\)?"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }

    let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = regex.matches(in: value, range: fullRange).filter { match in
        guard let range = Range(match.range, in: value) else {
            return false
        }

        return value[range].contains(where: \.isNumber)
    }

    guard matches.count == 1,
          let match = matches.first,
          let range = Range(match.range, in: value) else {
        return nil
    }

    let prefix = String(value[..<range.lowerBound])
    let suffix = String(value[range.upperBound...])
    guard isNumericDecoration(prefix), isNumericDecoration(suffix) else {
        return nil
    }

    return String(value[range])
}

private nonisolated func isNumericDecoration(_ value: String) -> Bool {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else {
        return true
    }

    let symbolCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{00a0}\u{202f}'’.€$£¥%‰+-:/()[]{}"))
    if trimmedValue.unicodeScalars.allSatisfy({ symbolCharacters.contains($0) }) {
        return true
    }

    let words = trimmedValue
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)

    guard !words.isEmpty else {
        return false
    }

    return words.allSatisfy(isKnownNumericDecorationWord)
}

private nonisolated func isKnownNumericDecorationWord(_ word: String) -> Bool {
    let knownWords: Set<String> = [
        "eur", "usd", "chf", "gbp", "cad", "aud", "jpy", "cny", "sek", "nok", "dkk", "pln", "czk", "huf", "ron", "bgn", "try", "inr", "brl", "mxn", "zar",
        "kg", "g", "mg", "t", "to", "l", "ml", "m", "mm", "cm", "km", "m2", "m3", "qm", "m²", "m³", "ha",
        "wh", "kwh", "w", "kw", "mw", "h", "std", "min", "sec", "s",
        "stk", "st", "pcs", "pc", "piece", "pieces", "anz", "anzahl", "qty", "unit", "units",
        "percent", "prozent", "pct", "pp", "day", "days", "tag", "tage", "monat", "monate", "jahr", "jahre"
    ]

    return knownWords.contains(word)
}

private nonisolated func scientificNotationParts(from value: String) -> (mantissa: String, exponent: String)? {
    let exponentIndices = value.indices.filter { value[$0] == "e" || value[$0] == "E" }
    guard exponentIndices.count == 1, let exponentIndex = exponentIndices.first else {
        return nil
    }

    let mantissa = String(value[..<exponentIndex])
    let exponent = String(value[value.index(after: exponentIndex)...])
    guard !mantissa.isEmpty,
          exponent.range(of: #"^[+-]?[0-9]+$"#, options: .regularExpression) != nil else {
        return nil
    }

    return (mantissa, exponent)
}

private nonisolated func detectedDecimalSeparator(in value: String) -> Character? {
    let commaCount = value.filter { $0 == "," }.count
    let dotCount = value.filter { $0 == "." }.count

    if commaCount > 0 && dotCount > 0 {
        guard let lastCommaIndex = value.lastIndex(of: ","),
              let lastDotIndex = value.lastIndex(of: ".") else {
            return nil
        }

        return lastCommaIndex > lastDotIndex ? "," : "."
    }

    if commaCount > 0 {
        return detectedSingleSeparator(",", in: value, count: commaCount)
    }

    if dotCount > 0 {
        return detectedSingleSeparator(".", in: value, count: dotCount)
    }

    return nil
}

private nonisolated func detectedSingleSeparator(_ separator: Character, in value: String, count: Int) -> Character? {
    let parts = value.split(separator: separator, omittingEmptySubsequences: false)
    guard parts.count == count + 1,
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
        return nil
    }

    if count == 1 {
        return separator
    }

    let groupingParts = parts.dropFirst()
    if groupingParts.allSatisfy({ $0.count == 3 }) {
        return nil
    }

    return separator
}

private func contactLink(from value: String, column: String) -> ContactLink? {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else {
        return nil
    }

    guard parsedDate(from: trimmedValue) == nil else {
        return nil
    }

    if let email = emailAddress(from: trimmedValue), let url = URL(string: "mailto:\(email)") {
        return ContactLink(
            title: email,
            systemImage: "envelope.fill",
            color: .blue,
            url: url,
            accessibilityLabel: "E-Mail an \(email)"
        )
    }

    guard looksLikePhoneNumber(trimmedValue, isPhoneColumn: isPhoneColumn(column)) else {
        return nil
    }

    let phoneNumber = normalizedPhoneNumber(from: trimmedValue)
    guard phoneNumber.count >= 6, let url = URL(string: "tel:\(phoneNumber)") else {
        return nil
    }

    return ContactLink(
        title: trimmedValue,
        systemImage: "phone.fill",
        color: .green,
        url: url,
        accessibilityLabel: "Anrufen \(trimmedValue)"
    )
}

private func emailAddress(from value: String) -> String? {
    let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    guard let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
        return nil
    }

    return String(value[range])
}

private nonisolated func isPhoneColumn(_ column: String) -> Bool {
    let normalizedColumn = column.lowercased()
    return ["phone", "telefon", "tel", "mobile", "mobil", "handy", "call", "fax"].contains { normalizedColumn.contains($0) }
}

private func looksLikePhoneNumber(_ value: String, isPhoneColumn: Bool = false) -> Bool {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedValue.range(of: #"[A-Za-z]"#, options: .regularExpression) == nil else {
        return false
    }

    guard trimmedValue.range(of: #"^\+?[0-9][0-9\s()./\-]*$"#, options: .regularExpression) != nil else {
        return false
    }

    let digitCount = trimmedValue.filter(\.isNumber).count
    guard digitCount >= 6 && digitCount <= 16 else {
        return false
    }

    if isPhoneColumn {
        return true
    }

    return trimmedValue.hasPrefix("+")
        || trimmedValue.contains("(")
        || trimmedValue.contains(")")
        || trimmedValue.contains("-")
        || trimmedValue.contains("/")
}

private func normalizedPhoneNumber(from value: String) -> String {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmedValue.filter(\.isNumber)

    if trimmedValue.hasPrefix("+") {
        return "+" + digits
    }

    return String(digits)
}

#Preview {
    NavigationStack {
        TableDetailView(title: "V_User", selectString: "select * from [V_User]")
    }
}
