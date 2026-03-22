//
//  Watch_ReceiverApp.swift
//  Watch Receiver Watch App
//
//  Created by Sam Rall on 12/23/25.
//

import SwiftUI

@main
struct Watch_Receiver_Watch_AppApp: App {
    @StateObject private var relay = WatchBLEScanner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(relay)
                .task {
                    // Ask once early; background alerts will depend on this
                    await relay.ensureNotificationPermission()
                }
        }
        .backgroundTask(.bluetoothAlert) {
            // Called when watchOS wakes you due to monitored characteristic activity
            await relay.handleBluetoothAlertBackgroundWake()
        }
    }
}


