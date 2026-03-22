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
    @EnvironmentObject var ble: BleScanner
    @Environment(\.dismiss) private var dismiss
    let deviceId: UUID

    
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
                    let glow = batteryGlowColor
                    let isFull = (level == .full)

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(glow, lineWidth: 2)
                        .shadow(color: glow.opacity(isFull ? 0.85 : 0.70), radius: isFull ? 12 : 10)
                        .shadow(color: glow.opacity(isFull ? 0.55 : 0.40), radius: isFull ? 22 : 18)
                        .shadow(color: glow.opacity(isFull ? 0.35 : 0.25), radius: isFull ? 32 : 26)
                }
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

            Spacer()

        }
        .padding()
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let cfg = ble.deviceConfig(for: deviceId) {
                    uiShortPressDelay = Double(cfg.shortPressDelay)
            }
            
            // Ensure this view is the current UI focus device
            ble.focusDevice(deviceId)

            // Only connect if not already connected or connecting
            if !ble.connectedDeviceIDs.contains(deviceId) &&
               !ble.connectingDeviceIDs.contains(deviceId) {
                ble.connect(deviceId: deviceId)
            }

        }
        .onChange(of: ble.connectedDeviceIDs) { _, set in
            if set.contains(deviceId) { return }

            // If we're expecting a DFU reboot for THIS device, don't dismiss.
            // (Your BleScanner should expose this helper; see note below.)
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
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ble.connectingDeviceIDs.contains(deviceId) {
                HStack {
                    ProgressView()
                    Text("Connecting…")
                }
            } else if isConnectedToThisDevice {
                EmptyView()
            } else {
                // not connected + not connecting
                EmptyView()
            }
        }
    }


    @ViewBuilder
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ble.connectedDeviceIDs.contains(deviceId) {
                if ble.selectedId == deviceId,
                   ble.hasSmpReady(deviceId) && !ble.hasConfigService(deviceId) {

                    // --- DFU UI (no functionality changes) ---
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
                            Button {
                                Task {
                                    do {
                                        ble.dfuErrorText = nil
                                        ble.dfuStateText = "Step 1: fetching release"
                                        let release = try await FirmwareService.shared.fetchLatestRelease()

                                        ble.dfuStateText = "Step 2: locating asset"
                                        guard let asset = release.firmwareAsset() else {
                                            ble.dfuErrorText = "No firmware asset found"
                                            return
                                        }

                                        ble.dfuStateText = "Step 3: downloading firmware"
                                        let fileURL = try await FirmwareService.shared.downloadFirmware(from: asset)

                                        ble.dfuStateText = "Step 4: starting DFU"
                                        await MainActor.run {
                                            ble.startDfuFromURL(for: deviceId, fileURL: fileURL)
                                        }

                                    } catch {
                                        ble.dfuErrorText = "Button catch: \(error)"
                                    }
                                }
                            } label: {
                                Text("Start DFU")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
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
            } else {
                Text("Connect to discover services and enable DFU.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

}

