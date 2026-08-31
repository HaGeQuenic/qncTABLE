//
//  ContentView.swift
//  qncTABLE
//
//  Created by Harald on 29.08.26.
//

import SwiftUI
import Foundation

struct ContentView: View {
    @State private var showingSettings = false
    @State private var showMissingIDAlert = false
    @State private var deviceID = ""
    @State private var cachedLoadedDates: [String: Date] = [:]
    @StateObject private var tablesVM = TablesViewModel()

    private let store = SecureSettingsStore()
    private let responseCache = QueryResultResponseCache()

    var body: some View {
        NavigationStack {
            Group {
                if tablesVM.isLoading && tablesVM.entries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Lade Tabellen…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = tablesVM.errorMessage, tablesVM.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .imageScale(.large)
                            .foregroundStyle(.orange)
                        Text(error).multilineTextAlignment(.center)
                        Button("Erneut laden") {
                            Task { await reloadTableOverview(forceRefresh: true) }
                        }
                    }
                    .padding()
                } else {
                    tableList
                }
            }
            .navigationTitle("qncTABLE")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reloadTableOverview(forceRefresh: true) }
                    } label: {
                        if tablesVM.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Neu laden")
                    .disabled(tablesVM.isLoading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Einstellungen")
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: handleSettingsDismissed) {
                SettingsView()
            }
            .alert("DeviceID fehlt", isPresented: $showMissingIDAlert) {
                Button("Zu Einstellungen") { showingSettings = true }
                Button("Abbrechen", role: .cancel) { }
            } message: {
                Text("Bitte vergeben Sie eine DeviceID in den Einstellungen.")
            }
            .task {
                await loadTableOverviewIfNeeded()
            }
            .onChange(of: tablesVM.entries) { _, _ in
                refreshCachedLoadedDates()
            }
            .onAppear {
                // Check at launch if DeviceID is missing
                let current = (try? store.load()) ?? .default
                deviceID = current.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
                refreshCachedLoadedDates()
                if deviceID.isEmpty {
                    showMissingIDAlert = true
                    showingSettings = true
                }
            }
        }
    }

    private var tableList: some View {
        List {
            ForEach(tablesVM.entries) { entry in
                NavigationLink {
                    TableDetailView(title: entry.name, selectString: entry.selectString, iconName: entry.iconName)
                } label: {
                    tableRow(entry)
                }
            }
        }
    }

    private func tableRow(_ entry: QncTableEntry) -> some View {
        HStack(spacing: 8) {
            tableIcon(symbol: entry.iconName)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)

                QueryResultLoadedAtText(
                    loadedAt: cachedLoadedAt(for: entry),
                    font: .caption2
                )
            }
        }
    }

    @ViewBuilder
    private func tableIcon(symbol: String?) -> some View {
        if let symbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, alignment: .center)
        } else {
            Color.clear
                .frame(width: 32)
        }
    }

    @MainActor
    private func loadTableOverviewIfNeeded() async {
        await tablesVM.load()
        refreshCachedLoadedDates()
    }

    @MainActor
    private func reloadTableOverview(forceRefresh: Bool) async {
        await tablesVM.load(forceRefresh: forceRefresh)
        refreshCachedLoadedDates()
    }

    private func handleSettingsDismissed() {
        refreshCachedLoadedDates()
        Task { await loadTableOverviewIfNeeded() }
    }

    private func refreshCachedLoadedDates() {
        let current = (try? store.load()) ?? .default
        let currentDeviceID = current.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceID = currentDeviceID

        guard !currentDeviceID.isEmpty else {
            cachedLoadedDates = [:]
            return
        }

        cachedLoadedDates = Dictionary(uniqueKeysWithValues: tablesVM.entries.map { entry in
            let key = QueryResultResponseCache.cacheKey(
                deviceID: currentDeviceID,
                title: entry.name,
                selectString: entry.selectString
            )
            return (key, responseCache.cachedLoadedAt(for: key))
        }.compactMap { key, loadedAt in
            guard let loadedAt else {
                return nil
            }

            return (key, loadedAt)
        })
    }

    private func cachedLoadedAt(for entry: QncTableEntry) -> Date? {
        let currentDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentDeviceID.isEmpty else {
            return nil
        }

        let key = QueryResultResponseCache.cacheKey(
            deviceID: currentDeviceID,
            title: entry.name,
            selectString: entry.selectString
        )
        return cachedLoadedDates[key]
    }
}

#Preview {
    ContentView()
}
