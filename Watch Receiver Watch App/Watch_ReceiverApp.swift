//
//  Watch_ReceiverApp.swift
//  Watch Receiver Watch App
//

import SwiftUI

@main
struct Watch_Receiver_Watch_AppApp: App {
    @StateObject private var relay = WatchBLEScanner()
    @StateObject private var workoutManager = WorkoutManager()
    @StateObject private var matchTimer = MatchTimer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(relay)
                .environmentObject(workoutManager)
                .environmentObject(matchTimer)
                .task {
                    await workoutManager.requestAuthorization()
                }
        }
        .backgroundTask(.bluetoothAlert) {
            await relay.handleBluetoothAlertBackgroundWake()
        }
    }
}
