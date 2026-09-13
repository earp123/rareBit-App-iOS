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

            // Per-flag link status, plus the short-press tile
            HStack(spacing: 4) {
                flagIcon(flag: 1, linked: relay.flag1Linked, preset: relay.flag1Haptic)
                flagIcon(flag: 2, linked: relay.flag2Linked, preset: relay.flag2Haptic)
                shortPressIcon
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
                .opacity(linked ? 1.0 : 0.15)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: tileHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(linked ? preset.color : .gray.opacity(0.2), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .disabled(!linked)
    }

    /// Alert 3 — a short press from either flag. Enabled whenever the relay is
    /// active rather than per-flag: the notify byte doesn't say which flag was
    /// pressed, so there's no link state to gate on.
    @ViewBuilder
    private var shortPressIcon: some View {
        Button {
            relay.cycleHaptic(for: 3)
        } label: {
            Image(systemName: "bolt.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .opacity(relay.isActive ? 1.0 : 0.15)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: tileHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(relay.isActive ? relay.shortPressHaptic.color : .gray.opacity(0.2),
                                lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .disabled(!relay.isActive)
    }

    /// Three tiles have to share the width, so they flex rather than sitting at
    /// the fixed 70pt the two flags used to take — 3 x 70 overflows every watch
    /// size. The cap keeps them from ballooning on the larger cases.
    private var tileHeight: CGFloat { 76 }
}
