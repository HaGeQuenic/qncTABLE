import Foundation
import Combine

struct AppSettings: Codable, Equatable {
    var deviceID: String

    static let `default` = AppSettings(deviceID: "")
}

final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?

    private let store: SecureSettingsStore

    init(store: SecureSettingsStore = SecureSettingsStore(), initial: AppSettings? = nil) {
        self.store = store
        if let initial { self.settings = initial } else {
            self.settings = (try? store.load()) ?? .default
        }
    }

    func save() {
        errorMessage = nil
        isSaving = true
        do {
            try store.save(settings)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

