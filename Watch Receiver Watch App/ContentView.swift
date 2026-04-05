import SwiftUI

struct ContentView: View {
    @EnvironmentObject var relay: WatchBLEScanner
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
                HapticPlaybackView()
            }
            .navigationDestination(for: WatchBLEScanner.Device.self) { device in
                DeviceDetailView(device: device)
                    .environmentObject(relay)
            }
        }
    }
}
