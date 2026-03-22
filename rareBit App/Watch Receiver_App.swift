//
//  rareBit_AppApp.swift
//  rareBit App
//
//  Created by Sam Rall on 12/23/25.
//

import SwiftUI

@main
struct MyDeviceManagerApp: App {
    @StateObject private var ble = BleScanner()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ScanListView()
                .environmentObject(ble)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { @MainActor in
                    ble.refreshConnectedPeripherals()
                }
            }
        }
    }
}
