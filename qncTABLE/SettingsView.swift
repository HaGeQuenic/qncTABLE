import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Gerät") {
                    TextField("Device ID", text: $model.settings.deviceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body)
                }
                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.save()
                        dismiss()
                    } label: {
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Text("Sichern")
                        }
                    }
                    .disabled(model.isSaving)
                }
            }
        }
        .navigationViewStyle(.columns) // Apple-style navigation appearance
    }
}

#Preview {
    SettingsView()
}
