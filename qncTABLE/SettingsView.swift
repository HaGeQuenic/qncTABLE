import SwiftUI

private extension View {
    @ViewBuilder
    func settingsPlainTextInput() -> some View {
#if os(macOS)
        self
#else
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#endif
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SettingsViewModel()
    @State private var isEditingDeviceID = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gerät") {
                    if model.settings.deviceID.isEmpty || isEditingDeviceID {
                        SecureField("Device ID", text: $model.settings.deviceID)
                            .settingsPlainTextInput()
                            .font(.body)
                    } else {
                        HStack {
                            Text("Device ID")
                            Spacer()
                            Text("***")
                                .foregroundStyle(.secondary)
                            Button("Ändern") {
                                model.settings.deviceID = ""
                                isEditingDeviceID = true
                            }
                        }
                    }
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
