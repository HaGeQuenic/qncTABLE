import SwiftUI

struct TableDetailView: View {
    let tableName: String
    @State private var rows: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let store = SecureSettingsStore()

    var body: some View {
        ScrollView {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Lade Daten…")
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
            } else if rows.isEmpty {
                Text("Keine Daten")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.self) { row in
                        Text(row)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(tableName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Neu laden")
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        rows = []
        let settings = (try? store.load()) ?? .default
        let deviceID = settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else {
            errorMessage = "DeviceID fehlt. Bitte in den Einstellungen vergeben."
            return
        }
        do {
            let text = try await APIService.shared.fetchRows(selectString: tableName, deviceID: deviceID)
            // Assuming fetched text is lines separated by newlines
            self.rows = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { TableDetailView(tableName: "V_User") }
}
