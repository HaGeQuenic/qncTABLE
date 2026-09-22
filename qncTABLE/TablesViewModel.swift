import Foundation
import Combine

@MainActor
final class TablesViewModel: ObservableObject {
    @Published private(set) var tables: [QncTable] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var vtables: [VTablesRow] = []
    @Published private(set) var entries: [QncTableEntry] = []
    @Published private(set) var overviewLoadedAt: Date?

    private let entriesCache = QncTableEntriesCache()
    private var loadedDeviceID: String?

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }

        let settings = (try? SecureSettingsStore().load()) ?? .default
        let deviceID = settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else {
            self.errorMessage = "DeviceID fehlt. Bitte in den Einstellungen vergeben."
            self.entries = []
            self.vtables = []
            self.tables = []
            overviewLoadedAt = nil
            loadedDeviceID = nil
            return
        }

        if !forceRefresh, loadedDeviceID == deviceID, !entries.isEmpty {
            errorMessage = nil
            return
        }

        if loadedDeviceID != nil, loadedDeviceID != deviceID {
            entries = []
            vtables = []
            tables = []
            overviewLoadedAt = nil
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await loadEntries(deviceID: deviceID, forceRefresh: forceRefresh)
            entries = result.entries
            overviewLoadedAt = result.loadedAt
            loadedDeviceID = deviceID
            vtables = []
            tables = []
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = msg.isEmpty ? "Unbekannter Fehler beim Laden der Tabellen." : msg
            if entries.isEmpty {
                vtables = []
                tables = []
                overviewLoadedAt = nil
            }
        }
    }

    private func loadEntries(deviceID: String, forceRefresh: Bool) async throws -> LoadedTableOverview {
        if !forceRefresh,
           let cachedEntries = entriesCache.cachedEntries(for: deviceID),
           cachedEntries.entries.allSatisfy({ $0.baseTableName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
            return LoadedTableOverview(entries: cachedEntries.entries, loadedAt: cachedEntries.loadedAt)
        }

        let loadedAt = Date()
        let entries = try await QncTablesService.shared.fetchEntries(deviceID: deviceID)
        entriesCache.save(entries, for: deviceID, loadedAt: loadedAt)
        return LoadedTableOverview(entries: entries, loadedAt: loadedAt)
    }
    
    func run(selectString: String, deviceID: String) async throws -> String {
        try await APIService.shared.fetchRows(selectString: selectString, deviceID: deviceID)
    }
}

private struct LoadedTableOverview {
    let entries: [QncTableEntry]
    let loadedAt: Date
}
