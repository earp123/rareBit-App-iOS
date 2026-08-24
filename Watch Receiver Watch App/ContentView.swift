import SwiftUI

struct ContentView: View {
    @EnvironmentObject var relay: WatchBLEScanner
    @EnvironmentObject var workoutManager: WorkoutManager
    @EnvironmentObject var matchTimer: MatchTimer
    @State private var path: [WatchBLEScanner.Device] = []
    @State private var showPlayback = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 10) {
                if let found = relay.devices.first {
                    VStack(spacing: 6) {
                        Text(found.name.replacingOccurrences(of: "rareBit ", with: ""))
                            .font(.headline)
                            .lineLimit(1)

                        Text("RSSI \(found.rssi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.9), lineWidth: 3)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture {
                        print("BLE ▶︎ connect(to:) called")
                        relay.connect(to: found.id)
                        path.append(found)
                    }

                } else {
                    Text("Searching...")
                        .font(.headline)

                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .padding()
            .onAppear { relay.startScan() }
            .onDisappear { relay.stopScan() }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Playback") {
                        showPlayback = true
                    }
                    .font(.caption2)
                }
            }
            .navigationDestination(isPresented: $showPlayback) {
                TabView {
                    HapticPlaybackView()
                    TimerView()
                }
                .tabViewStyle(.page)
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
                .acknowledgesMatchAlarm()
                .onAppear { workoutManager.startSession() }
                .onDisappear {
                    // Keep the session while the timer runs: it's what gives
                    // background runtime and wrist-raise return-to-app.
                    if matchTimer.state != .running { workoutManager.stopSession() }
                }
            }
            .onChange(of: matchTimer.state) { _, newState in
                if newState == .running { workoutManager.startSession() }
            }
            .navigationDestination(for: WatchBLEScanner.Device.self) { device in
                // Swipeable TabView with device detail and timer
                TabView {
                    DeviceDetailView(device: device)
                        .environmentObject(relay)
                        .environmentObject(workoutManager)

                    TimerView()
                }
                .tabViewStyle(.page)
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
                .acknowledgesMatchAlarm()
            }
        }
    }
}

// MARK: - Alarm acknowledgement

/// While the end-of-interval alarm is sounding, a touch anywhere silences it.
/// Applied to the whole TabView rather than to `TimerView` so it works from
/// either page — the alarm can fire while the user is on the device-detail or
/// playback tab, and they shouldn't have to swipe back to the timer to stop it.
/// The overlay also shields the reset/settings buttons from a panicked tap.
private struct AcknowledgesMatchAlarm: ViewModifier {
    @EnvironmentObject var matchTimer: MatchTimer

    func body(content: Content) -> some View {
        content.overlay {
            if matchTimer.isAlarming {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { matchTimer.acknowledgeAlarm() }
                    .ignoresSafeArea()
            }
        }
    }
}

extension View {
    func acknowledgesMatchAlarm() -> some View {
        modifier(AcknowledgesMatchAlarm())
    }
}
