//
//  qncTABLEApp.swift
//  qncTABLE
//
//  Created by Harald on 29.08.26.
//

import SwiftUI

@main
struct qncTABLEApp: App {
    init() {
        TableImageDocumentSessionCache.clearDiskCacheAtLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if os(macOS)
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
#endif
    }
}
