import SwiftUI
import CoreBluetooth

struct ScanListView: View {
    @EnvironmentObject var ble: BleScanner
    @State private var path = NavigationPath()

    // Image Set name in Assets.xcassets
    private let logoAssetName = "AppImage"

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottomLeading) {
                Color.black.ignoresSafeArea()

                List {
                    // Relay recovery: an interrupted DFU leaves the bootloader
                    // advertising the DFU service on every boot. Retry the
                    // flash from here — that IS the recovery path.
                    ForEach(ble.relayBootloaderIds, id: \.self) { bootId in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Relay in recovery mode")
                                        .fontWeight(.semibold)
                                    Text("Firmware update was interrupted")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            if ble.relayDfuInProgress {
                                ProgressView(value: ble.relayDfuProgress)
                                if !ble.relayDfuStateText.isEmpty {
                                    Text(ble.relayDfuStateText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                if let err = ble.relayDfuErrorText, !err.isEmpty {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                Button {
                                    Task { await ble.retryRelayFlash(bootloaderId: bootId) }
                                } label: {
                                    Text("Retry Flash")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    ForEach(ble.devices) { d in
                        let isConnected = ble.connectedDeviceIDs.contains(d.id)
                        let isScanning = ble.isScanning
                        let borderColor = batteryBorderColor(for: d.id)
                        let isFull = (ble.batteryLevel(for: d.id) == .full)
                        let glowRadius: CGFloat = isFull ? 20 : 10
                        let displayName = d.advertisedName ?? d.peripheral.name ?? "Unnamed"
                        let s = ble.sessions[d.id]
                        let showUpdate = isConnected
                            && (s?.servicesDiscovered ?? false)
                            && (s?.hasSmpCharacteristic ?? false)
                            && !(s?.hasConfigService ?? true)


                        Button {
                            // Always navigate
                            path.append(d.id)

                            // Select so DeviceDetailView can use selected-only DFU state, etc.
                            if ble.selected?.id != d.id {
                                ble.select(d)
                            }

                            // Only connect if not already connected/connecting
                            if !ble.connectedDeviceIDs.contains(d.id) &&
                               !ble.connectingDeviceIDs.contains(d.id) {
                                ble.connectSelected()
                            }
                        } label: {
                            DeviceCard(
                                name: displayName,
                                rssi: d.rssi,
                                isConnected: isConnected,
                                isScanning: isScanning,
                                glowColor: borderColor,
                                glowRadius: glowRadius,
                                iconAssetName: iconName(for: displayName),
                                showUpdate: showUpdate
                            )
                        }

                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                    }

                    Color.clear
                        .frame(height: 96)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)

                HStack(spacing: 32) {
                    findDevicesButton
                        .frame(maxWidth: .infinity)
                    optionsButton
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, alignment: .center, spacing: 0) {
                logoHeader
            }
            .navigationDestination(for: UUID.self) { id in
                DeviceDetailView(deviceId: id)
            }
            .onChange(of: ble.isPoweredOn) { _, poweredOn in
                if !poweredOn, !path.isEmpty {
                    path.removeLast(path.count)
                }
            }
        }
    }

    // MARK: - Header

    private var logoHeader: some View {
        VStack {
            Image(logoAssetName)
                .resizable()
                .scaledToFit()
                .frame(height: 140)
                .padding(.top, 24)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    // MARK: - Find Devices

    private var findDevicesButton: some View {
        Button {
            guard ble.isPoweredOn else { return }

            // ✅ Clear any unconnected devices before a fresh scan
            ble.clearUnconnectedDevicesFromList()

            if ble.isScanning { ble.stopScan() }
            ble.startScan()
        } label: {
            Text("Find Devices")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
        }
        .disabled(!ble.isPoweredOn)
    }
    
    // MARK: - Options Button
    
    private var optionsButton: some View {
        Menu {
            Link(destination: URL(string: "https://www.rarebitofficial.com/order")!) {
                Label("User Manual", systemImage: "book")
            }
            
            Menu {
                Link(destination: URL(string: "https://refsneedlovetoo.com/collections/referee-gear/products/next-generation-buzzer-flags-rarebit-pro-set")!) {
                    Label("RefsNeedLoveToo", systemImage: "heart.fill")
                }
                
                Link(destination: URL(string: "https://thetopref.com/collections/beep-flags/products/rarebit-beep-flags")!) {
                    Label("The Top Ref", systemImage: "star.fill")
                }
            } label: {
                Label("Buy PRO Sets", systemImage: "cart")
            }
            
            Link(destination: URL(string: "https://rarebitofficial.com")!) {
                Label("rareBitOfficial.com", systemImage: "globe")
            }
            
            Link(destination: URL(string: "https://rarebitofficial.com/applewatch")!) {
                Label("Apple Watch", systemImage: "applewatch")
            }
            
            Link(destination: URL(string: "mailto:reply@rarebit.biz")!) {
                Label("Support", systemImage: "envelope.fill")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                Text("Options")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .menuStyle(.automatic)
    }
    
    // Cyan for full, green for high, blue for mid, red for low, yellow for unknown.
    private func batteryBorderColor(for deviceId: UUID) -> Color {
        switch ble.batteryLevel(for: deviceId) {
        case .full: return .green
        case .high: return .cyan
        case .mid:  return .blue
        case .low:  return .red
        case .unknown: return .yellow
        }
    }

    
    private func iconName(for deviceName: String) -> String? {
        if deviceName.localizedCaseInsensitiveContains("Flag") { return "FlagIcon" }
        if deviceName.localizedCaseInsensitiveContains("Receiver") { return "Rx Icon" }
        return nil
    }
}

// MARK: - Device Card

private struct DeviceCard: View {
    let name: String
    let rssi: Int
    let isConnected: Bool
    let isScanning: Bool
    let glowColor: Color
    let glowRadius: CGFloat
    let iconAssetName: String?
    let showUpdate: Bool
    

    private var style: DeviceCardStyle {
        DeviceCardStyler.style(
            isConnected: isConnected,
            isScanning: isScanning,
            rssi: rssi,
            glowColor: glowColor,
            glowRadius: glowRadius
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {

            // LEFT content
            VStack(alignment: .leading, spacing: 8) {

                // RSSI bar only when NOT connected
                if !isConnected {
                    GeometryReader { geo in
                        Capsule()
                            .fill(style.rssiBarColor)
                            .frame(
                                width: max(0, geo.size.width * style.rssiBarFill),
                                height: style.rssiBarHeight
                            )
                            .animation(.easeInOut(duration: 0.25), value: style.rssiBarFill)
                    }
                    .frame(height: style.rssiBarHeight)
                }

                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(style.titleColor)
                    .lineLimit(1)

                // Status badges below name
                if isConnected {
                    HStack(spacing: 8) {
                        Text("CONNECTED")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())

                        if showUpdate {
                            Text("UPDATE!")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.yellow)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 2)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT icon ONLY when connected
            if isConnected, let iconAssetName {
                Image(iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)  // tweak as desired
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(style.borderColor, lineWidth: style.borderWidth)
            
                .shadow(color: style.borderGlowColor.opacity(0.70), radius: style.borderGlowRadius)
                .shadow(color: style.borderGlowColor.opacity(0.40), radius: style.borderGlowRadius * 1.6)
                .shadow(color: style.borderGlowColor.opacity(0.25), radius: style.borderGlowRadius * 2.4)
                .opacity(style.borderWidth > 0 ? 1 : 0)
        }
        
        .shadow(color: style.shadowColor, radius: style.shadowRadius, x: 0, y: style.shadowYOffset)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}


// MARK: - Styling model

private struct DeviceCardStyle {
    var background: AnyView
    var titleColor: Color

    var borderColor: Color
    var borderWidth: CGFloat

    var borderGlowColor: Color
    var borderGlowRadius: CGFloat

    var shadowColor: Color
    var shadowRadius: CGFloat
    var shadowYOffset: CGFloat

    // RSSI bar
    var rssiBarFill: CGFloat
    var rssiBarHeight: CGFloat
    var rssiBarColor: Color
}

// MARK: - Styler

private enum DeviceCardStyler {
    // -10 => bar maxed (1.0)
    // -140 => bar disappears (0.0)
    private static let rssiFull: Double = -10
    private static let rssiEmpty: Double = -80

    static func style(
        isConnected: Bool,
        isScanning: Bool,
        rssi: Int,
        glowColor: Color,
        glowRadius: CGFloat
    ) -> DeviceCardStyle {

        let fill = rssiToFill(Double(rssi))

        if isConnected {
            return DeviceCardStyle(
                background: AnyView(Color(white: 0.12)), // dark gray
                titleColor: .white,
                borderColor: glowColor,
                borderWidth: 2,
                borderGlowColor: glowColor,
                borderGlowRadius: glowRadius,
                shadowColor: Color.black.opacity(0.45),
                shadowRadius: 16,
                shadowYOffset: 10,
        
                // These values won't be used while connected,
                // but we keep them sane for layout consistency
                rssiBarFill: 0,
                rssiBarHeight: 3,
                rssiBarColor: .white

            )
        }
 else {
            // ✅ Not connected (current spec): white card, black text, no border, black RSSI bar
            return DeviceCardStyle(
                background: AnyView(Color.white),
                titleColor: .black,
                borderColor: .clear,
                borderWidth: 0,
                borderGlowColor: .clear,
                borderGlowRadius: 0,
                shadowColor: Color.black.opacity(0.18),
                shadowRadius: 12,
                shadowYOffset: 6,
                rssiBarFill: fill,
                rssiBarHeight: 3,
                rssiBarColor: .black
            )
        }
    }

    private static func rssiToFill(_ rssi: Double) -> CGFloat {
        let clamped = min(max(rssi, rssiEmpty), rssiFull)
        let t = (clamped - rssiEmpty) / (rssiFull - rssiEmpty) // 0..1
        return CGFloat(t)
    }
}

