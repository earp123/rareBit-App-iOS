import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject var relay: WatchBLEScanner
    @EnvironmentObject var workoutManager: WorkoutManager
    let device: WatchBLEScanner.Device

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {

            // Header area
            VStack(alignment: .trailing, spacing: 2) {
                Text(device.name.replacingOccurrences(of: "rareBit ", with: ""))
                    .font(.headline)
                    .lineLimit(1)
                    .fontWeight(.semibold)

                Text(relay.isConnected ? "Connected" : "Connecting…")
                    .font(.footnote)

                Text(relay.isActive ? "Active" : "Inactive")
                    .font(.footnote)
                    .foregroundStyle(relay.isActive ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Flag link status icons
            HStack(spacing: 4) {
                flagIcon(flag: 1, linked: relay.flag1Linked, preset: relay.flag1Haptic)
                flagIcon(flag: 2, linked: relay.flag2Linked, preset: relay.flag2Haptic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .navigationBarBackButtonHidden(true)
        .onAppear {
            if !relay.isConnected, !relay.isConnecting {
                relay.connectAndStayConnected(to: device.id)
            }
            workoutManager.startSession()
        }
    }

    @ViewBuilder
    private func flagIcon(flag: Int, linked: Bool, preset: HapticPreset) -> some View {
        Button {
            relay.cycleHaptic(for: flag)
        } label: {
            Image("FLAG")
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 70)
                .opacity(linked ? 1.0 : 0.15)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(linked ? preset.color : .gray.opacity(0.2), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .disabled(!linked)
    }
}
