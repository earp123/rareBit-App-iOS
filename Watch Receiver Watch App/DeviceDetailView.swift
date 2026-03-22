import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject var relay: WatchBLEScanner
    let device: WatchBLEScanner.Device

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {

            // Header area
            VStack(alignment: .trailing, spacing: 6) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    .fontWeight(.semibold)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(relay.isConnected ? "Connected" : "Connecting…")
                        .font(.footnote)

                    Text(relay.isActive ? "Active" : "Inactive")
                        .font(.footnote)
                        .foregroundStyle(relay.isActive ? .primary : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Big empty space for future dashboard elements / control knobs
            Spacer(minLength: 12)

            // Subtle placeholder so the space feels intentional
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
                .frame(height: 80)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("")               // removes title text
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !relay.isConnected, !relay.isConnecting else { return }
            relay.connectAndStayConnected(to: device.id)
        }

    }
}
