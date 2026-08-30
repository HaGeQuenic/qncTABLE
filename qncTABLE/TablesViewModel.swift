import Foundation
import Combine

@MainActor
final class TablesViewModel: ObservableObject {
    @Published private(set) var tables: [QncTable] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await APIService.shared.fetchTables()
            self.tables = result
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
