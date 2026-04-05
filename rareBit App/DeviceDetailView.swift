//
//  DeviceDetailView.swift
//  rareBit App
//
//  Created by Sam Rall on 12/23/25.
//

import SwiftUI
import CoreBluetooth

struct DeviceDetailView: View {
    //temporary add to onAppear
    @State private var uiShortPressDelay: Double = 0
    @State private var relayCardExpanded = false
    @State private var showRelayConfirmation = false
    @State private var showRevertConfirmation = false
    @State private var updateAvailable: Bool? = nil
    @State private var latestFirmwareVersion: FirmwareVersion? = nil
    @State private var checkingForUpdate = false
    @State private var forceShowDfu = false  // Developer option
    @State private var longPressTimer: Timer?
    
    // Consolidated loading state
    @State private var viewState: ViewState = .loading
    
    @EnvironmentObject var ble: BleScanner
    @Environment(\.dismiss) private var dismiss
    let deviceId: UUID
    
    enum ViewState {
        case loading
        case ready
        case error(String)
    }

    
    private var deviceType: RareBitDeviceType {
        RareBitDeviceType.from(advertisedName: device?.advertisedName)
    }


    var device: DiscoveredDevice? {
        ble.devices.first(where: { $0.id == deviceId })
    }
    
    @ViewBuilder
    private func infoBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        Group {
            switch viewState {
            case .loading:
                loadingView
            case .ready:
                contentView
            case .error(let message):
                errorView(message: message)
            }
        }
        .padding()
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            initializeView()
        }
        .onChange(of: ble.connectedDeviceIDs) { _, set in
            if set.contains(deviceId) { return }

            // If we're expecting a DFU reboot for THIS device, don't dismiss.
            if ble.isAwaitingReboot(deviceId: deviceId) {
                return
            }

            dismiss()
        }
        .onChange(of: ble.isPoweredOn) { _, poweredOn in
            if !poweredOn {
                dismiss()
            }
        }
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading device information...")
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        VStack(spacing: 16) {
            let rawName = device?.advertisedName ?? device?.peripheral.name ?? "Unnamed"
            let name = displayName(rawName)
            let icon = iconName(for: rawName)

            HStack(alignment: .top, spacing: 12) {
                if let icon {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }

                Text(name)
                    .font(.title2)
                    .bold()
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isConnectedToThisDevice {
                    let level = ble.batteryLevel(for: deviceId)

                    if level != .unknown {
                        let glow = batteryGlowColor
                        let isFull = (level == .full)

                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(glow, lineWidth: 2)
                            .shadow(color: glow.opacity(isFull ? 0.85 : 0.70), radius: isFull ? 12 : 10)
                            .shadow(color: glow.opacity(isFull ? 0.55 : 0.40), radius: isFull ? 22 : 18)
                            .shadow(color: glow.opacity(isFull ? 0.35 : 0.25), radius: isFull ? 32 : 26)
                    }
                }
            }
            .onLongPressGesture(minimumDuration: 3.0) {
                // Developer mode: long press enables DFU card
                forceShowDfu = true
            }
            if ble.selectedId == deviceId, !ble.dfuStateText.isEmpty {
                Text(ble.dfuStateText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            connectionSection
            
            discoverySection
            
            // MARK: - Revert Relay to Receiver Card
            if isReceiverWithRelayFirmware && isConnectedToThisDevice {
                revertRelayCard
            }
            
            if hasConfigServiceForThisDevice {
                configurationSection

                // --- Expandable Settings Info (only when Config service exists) ---
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {

                            Text("For information only! Features described below will be introduced in firmware 2v0.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 8) {
                                infoBlock(
                                    title: "Short Press Delay",
                                    body: """
                Controls a brief delay between a button press and the actual page alert transmission. This can reduce nuisance alerts from short, accidental button presses. A delay value of 0 effectively disables the delay (any button press transmits immediately).
                """
                                )

                                infoBlock(
                                    title: "Short Press Alert",
                                    body: """
                With Short Press Alert enabled, button presses shorter than the Short Press Delay value can intentionally send a different, more brief alert type to the Referee. For the additional alert type to occur, both the Flag and Receiver must have Short Press enabled. A Short Press Delay value of 0 effectively disables Short Press Alert.
                """
                                )
                            }

                            Divider().opacity(0.35)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Battery Colors")
                                    .font(.caption)
                                    .fontWeight(.semibold)

                                Text("Red <25% · Blue 25–75% · Cyan >75% · Green 100%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    }
                    .scrollIndicators(.visible)          // or .hidden
                    .frame(maxHeight: 160)               // ✅ tune this (180–280 usually feels right)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SETTINGS NOT IN USE")
                                .font(.footnote)
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                            
                            Text("Tap for details")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                }
                .padding(10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )



            }

            // MARK: - Relay DFU Card (Receiver only)
            if deviceType == .proReceiver && isConnectedToThisDevice {
                relayDfuCard
            }

            Spacer()

        }
    }
    
    // MARK: - Initialization
    
    private func initializeView() {
        Task {
            // If already connected and we have data, skip loading and go straight to ready
            if ble.connectedDeviceIDs.contains(deviceId),
               ble.hasConfigService(deviceId) || ble.hasSmpReady(deviceId) {
                // Already connected with services discovered - show immediately
                if let cfg = ble.deviceConfig(for: deviceId) {
                    uiShortPressDelay = Double(cfg.shortPressDelay)
                }
                
                // Quick check for updates in background if not already done
                if updateAvailable == nil, deviceType.releaseTag != nil {
                    do {
                        let (needsUpdate, latest) = try await ble.checkFirmwareUpdate(for: deviceId, deviceType: deviceType)
                        updateAvailable = needsUpdate
                        latestFirmwareVersion = latest
                    } catch {
                        print("⚠️ Failed to check for updates: \(error)")
                    }
                }
                
                viewState = .ready
                return
            }
            
            // First time connecting - show loading and wait for everything
            ble.focusDevice(deviceId)

            // Only connect if not already connected or connecting
            if !ble.connectedDeviceIDs.contains(deviceId) &&
               !ble.connectingDeviceIDs.contains(deviceId) {
                ble.connect(deviceId: deviceId)
            }
            
            // Wait for connection
            var attempts = 0
            while !ble.connectedDeviceIDs.contains(deviceId) && attempts < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                attempts += 1
            }
            
            guard ble.connectedDeviceIDs.contains(deviceId) else {
                viewState = .error("Failed to connect to device")
                return
            }
            
            // Wait for service discovery and characteristic reads
            // This gives time for SMP, Config, and FW version to be discovered
            try? await Task.sleep(for: .seconds(1.5))
            
            // Load config if available
            if let cfg = ble.deviceConfig(for: deviceId) {
                uiShortPressDelay = Double(cfg.shortPressDelay)
            }
            
            // Check for firmware updates (if applicable)
            if deviceType.releaseTag != nil {
                checkingForUpdate = true
                do {
                    let (needsUpdate, latest) = try await ble.checkFirmwareUpdate(for: deviceId, deviceType: deviceType)
                    updateAvailable = needsUpdate
                    latestFirmwareVersion = latest
                } catch {
                    print("⚠️ Failed to check for updates: \(error)")
                    // Don't fail the whole view, just skip update check
                }
                checkingForUpdate = false
            }
            
            // Mark view as ready
            viewState = .ready
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        // Connection section not needed in ready state - we're already connected
        EmptyView()
    }


    @ViewBuilder
    private var discoverySection: some View {
        // Only show DFU card when appropriate
        if shouldShowDfuCard {
            VStack(alignment: .leading, spacing: 10) {
                // --- Update Status Banner ---
                if let updateAvail = updateAvailable {
                    HStack(spacing: 8) {
                        Image(systemName: updateAvail ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(updateAvail ? .green : .secondary)
                        
                        if updateAvail {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Update Available")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                if let latest = latestFirmwareVersion {
                                    Text("Version \(latest.description)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Up to date")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(10)
                    .background(updateAvail ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // --- DFU UI ---
                VStack(alignment: .leading, spacing: 10) {
                    // Readiness line
                    HStack(spacing: 8) {
                        Image(systemName: ble.dfuInProgress ? "arrow.up.circle.fill" : "arrow.up.circle")
                        Text(ble.dfuInProgress ? "Firmware update in progress" : "Firmware update ready")
                        Spacer()
                        Text("\(Int((ble.dfuProgress * 100).rounded()))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .foregroundStyle(ble.dfuInProgress ? .orange : .primary)

                    // Progress bar
                    ProgressView(value: ble.dfuProgress)
                        .animation(.default, value: ble.dfuProgress)

                    // State + errors
                    if !ble.dfuStateText.isEmpty {
                        Text(ble.dfuStateText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let err = ble.dfuErrorText, !err.isEmpty {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    
                    HStack(spacing: 12) {
                        // Auto Update Button (smart install)
                        Button {
                            Task {
                                do {
                                    ble.dfuErrorText = nil
                                    let didUpdate = try await ble.autoUpdateIfNeeded(for: deviceId, deviceType: deviceType)
                                    if !didUpdate {
                                        print("✅ Device already up to date")
                                    }
                                } catch {
                                    ble.dfuErrorText = "Auto update failed: \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            Text(updateAvailable == true ? "Install Update" : "Update")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(updateAvailable == true ? .green : .blue)
                        .disabled(ble.dfuInProgress || deviceType.releaseTag == nil)
                        
                        // Manual DFU Button
                        Button {
                            Task {
                                do {
                                    ble.dfuErrorText = nil

                                    guard let tag = deviceType.releaseTag else {
                                        ble.dfuErrorText = "No firmware release for this device type"
                                        return
                                    }

                                    ble.dfuStateText = "Step 1: fetching \(tag) release"
                                    let release = try await FirmwareService.shared.fetchRelease(tag: tag)

                                    ble.dfuStateText = "Step 2: locating asset"
                                    guard let asset = release.firmwareAsset() else {
                                        ble.dfuErrorText = "No firmware asset found in \(tag) release"
                                        return
                                    }

                                    ble.dfuStateText = "Step 3: downloading firmware"
                                    let fileURL = try await FirmwareService.shared.downloadFirmware(from: asset)

                                    ble.dfuStateText = "Step 4: starting DFU"
                                    await MainActor.run {
                                        ble.startDfuFromURL(for: deviceId, fileURL: fileURL)
                                    }

                                } catch {
                                    ble.dfuErrorText = "Manual DFU failed: \(error)"
                                }
                            }
                        } label: {
                            Text("Manual")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(ble.dfuInProgress)

                        Button {
                            ble.cancelDfu()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!ble.dfuInProgress)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)

            // ✅ Never force unwrap in SwiftUI view code
            if let cfg = ble.deviceConfig(for: deviceId) {

                HStack(spacing: 8) {
                    Text("Battery: ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(cfg.batteryLevel.rawValue.replacingOccurrences(of: "BATTERY_", with: ""))
                        .font(.subheadline)
                        .bold()
                }

                Toggle("Short Press Alert", isOn: shortPressEnabledBinding)
                    .disabled(!isConnectedToThisDevice)

                if deviceType == .proFlag {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Short Press Delay (ms)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(uiShortPressDelay.rounded(.down)) * 20)")
                                .font(.subheadline)
                                .bold()
                        }

                        Slider(
                            value: $uiShortPressDelay,
                            in: 0...15,
                            step: 1
                        )
                        .disabled(!isConnectedToThisDevice)
                    }
                    .padding(.top, 6)
                }

                if let fw = ble.firmwareVersionById(deviceId) {
                    Text("Firmware: \(fw)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            } else {
                // Config not available yet (or dropped mid-render); show stable UI
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading configuration…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }


    // MARK: - Relay DFU Card

    @ViewBuilder
    private var relayDfuCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    relayCardExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(.orange)

                    Text("Relay")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(relayCardExpanded ? 90 : 0))
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if relayCardExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().opacity(0.3)

                    Text("Flash Relay firmware to this Receiver. This will replace the current Receiver firmware with Relay firmware.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showRelayConfirmation = true
                    } label: {
                        Text("Flash Relay Firmware")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(ble.dfuInProgress)
//                    .onLongPressGesture(minimumDuration: 2.0) {
//                        // Developer mode: long press enables DFU card
//                        forceShowDfu = true
//                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.orange.opacity(relayCardExpanded ? 0.4 : 0.15), lineWidth: 1)
        )
        .alert("Flash Relay Firmware?", isPresented: $showRelayConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") {
                Task {
                    do {
                        ble.dfuErrorText = nil

                        ble.dfuStateText = "Step 1: fetching RXRLY_v10.0 release"
                        let release = try await FirmwareService.shared.fetchRelease(tag: "RXRLY_v10.0")

                        ble.dfuStateText = "Step 2: locating asset"
                        guard let asset = release.firmwareAsset() else {
                            ble.dfuErrorText = "No firmware asset found in RXRLY_v10.0 release"
                            return
                        }

                        ble.dfuStateText = "Step 3: downloading firmware"
                        let fileURL = try await FirmwareService.shared.downloadFirmware(from: asset)

                        ble.dfuStateText = "Step 4: starting DFU"
                        await MainActor.run {
                            ble.startDfuFromURL(for: deviceId, fileURL: fileURL)
                        }
                    } catch {
                        ble.dfuErrorText = "Relay DFU failed: \(error)"
                    }
                }
            }
        } message: {
            Text("This requires an Apple Watch. Flashing Relay firmware will replace the Receiver firmware, and the device will no longer vibrate when alerted. Do you want to continue?")
        }
    }
    
    // MARK: - Revert Relay to Receiver Card
    
    @ViewBuilder
    private var revertRelayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.orange)
                
                Text("Relay Firmware Detected")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Spacer()
            }
            
            Divider().opacity(0.3)
            
            Button {
                showRevertConfirmation = true
            } label: {
                Label("Revert to Receiver Firmware", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(ble.dfuInProgress)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
        .alert("Revert to Receiver Firmware?", isPresented: $showRevertConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") {
                Task {
                    do {
                        ble.dfuErrorText = nil
                        
                        ble.dfuStateText = "Step 1: fetching PRO_RX_v1.8.0 release"
                        let release = try await FirmwareService.shared.fetchRelease(tag: "PRO_RX_v1.8.0")
                        
                        ble.dfuStateText = "Step 2: locating asset"
                        guard let asset = release.firmwareAsset() else {
                            ble.dfuErrorText = "No firmware asset found in PRO_RX_v1.8.0 release"
                            return
                        }
                        
                        ble.dfuStateText = "Step 3: downloading firmware"
                        let fileURL = try await FirmwareService.shared.downloadFirmware(from: asset)
                        
                        ble.dfuStateText = "Step 4: starting DFU"
                        await MainActor.run {
                            ble.startDfuFromURL(for: deviceId, fileURL: fileURL)
                        }
                    } catch {
                        ble.dfuErrorText = "Revert failed: \(error)"
                    }
                }
            }
        } message: {
            Text("Reverting to Receiver firmware will restore vibration alerts but remove Apple Watch functionality. Do you want to continue?")
        }
    }

    // MARK: - Bindings

    private var shortPressEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                ble.deviceConfig(for: deviceId)?.shortPressEnabled ?? false
            },
            set: { newVal in
                ble.setShortPressEnabled(newVal, for: deviceId)
            }
        )
    }

    private func displayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "rareBit", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func iconName(for name: String) -> String? {
        if name.localizedCaseInsensitiveContains("Flag") { return "FlagIcon" }
        if name.localizedCaseInsensitiveContains("Receiver") { return "Rx Icon" }
        return nil
    }
    
    
    
    private var batteryGlowColor: Color {
        switch ble.batteryLevel(for: deviceId) {
        case .full: return .green
        case .high: return .cyan
        case .mid:  return .blue
        case .low:  return .red
        case .unknown: return .yellow
        }
    }

    
    private var isConnectedToThisDevice: Bool {
        ble.connectedDeviceIDs.contains(deviceId)
    }
    
    private var hasConfigServiceForThisDevice: Bool {
        isConnectedToThisDevice && ble.hasConfigService(deviceId)
    }
    
    /// Determine if this is a Receiver device running Relay firmware
    /// Relay firmware is major version 10+ (0xA0+)
    private var isReceiverWithRelayFirmware: Bool {
        guard deviceType == .proReceiver else { return false }
        guard let versionByte = ble.firmwareVersionByteById(deviceId) else { return false }
        let version = FirmwareVersion(byte: versionByte)
        return version.major >= 10  // Relay firmware starts at v10.0 (0xA0)
    }
    
    /// Should show the DFU card?
    /// - Show if update is available
    /// - Hide if up to date (for known device types with release tags)
    /// - Hide if receiver has relay firmware (separate revert card is shown instead)
    /// - Show if developer mode is enabled
    /// - Show for devices with SMP capability (handles old firmware, unknown types, failed checks)
    private var shouldShowDfuCard: Bool {
        // Developer override
        if forceShowDfu {
            return true
        }
        
        // Hide for Receiver with Relay firmware (separate revert card handles this)
        if isReceiverWithRelayFirmware {
            return false
        }
        
        // Show if we're checking for updates (loading state)
        if checkingForUpdate {
            return true
        }
        
        // Show if update is available
        if updateAvailable == true {
            return true
        }
        
        // Hide if explicitly up to date AND device type is known
        // (If device type is unknown, we still want to show DFU for manual updates)
        if updateAvailable == false && deviceType.releaseTag != nil {
            return false
        }
        
        // Show for devices with SMP capability
        // This catches:
        // - Old firmware devices (updateAvailable == nil, no config service)
        // - Unknown device types (updateAvailable == nil, no release tag)
        // - Devices where update check failed
        if isConnectedToThisDevice && ble.hasSmpReady(deviceId) {
            return true
        }
        
        // Default: don't show
        return false
    }

}

