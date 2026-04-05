//
//  BLEScanner.swift
//  Watch Receiver
//
//  Created by Sam Rall on 12/24/25.
//

import Foundation
import CoreBluetooth
import SwiftUI
import Combine
import UserNotifications
import WatchKit


// MARK: - Target BLE UUIDs (fill in later)
let TARGET_SERVICE_UUID     = CBUUID(string: "33210001-28d5-4b7b-bad0-7dee1eee1b6d")
let TARGET_NOTIFY_CHAR_UUID = CBUUID(string: "33210002-28d5-4b7b-bad0-7dee1eee1b6d")    // TODO replace

// MARK: - Haptic Presets
enum HapticPreset: Int, CaseIterable {
    case doubleNotification = 0   // two .notification, 650ms gap
    case quadSuccess = 1          // four .success, 300ms gaps
    case tripleFailure = 2        // three .failure, 350ms gaps

    var label: String {
        switch self {
        case .doubleNotification: return "Double"
        case .quadSuccess:        return "Quad"
        case .tripleFailure:      return "Triple"
        }
    }

    var color: Color {
        switch self {
        case .doubleNotification: return .cyan
        case .quadSuccess:        return .yellow
        case .tripleFailure:      return Color(.magenta)
        }
    }

    func next() -> HapticPreset {
        let all = HapticPreset.allCases
        let nextIndex = (self.rawValue + 1) % all.count
        return all[nextIndex]
    }

    @MainActor
    func play() async {
        switch self {
        case .doubleNotification:
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(nanoseconds: 650_000_000)
            WKInterfaceDevice.current().play(.notification)

        case .quadSuccess:
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(nanoseconds: 300_000_000)
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(nanoseconds: 300_000_000)
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(nanoseconds: 300_000_000)
            WKInterfaceDevice.current().play(.success)

        case .tripleFailure:
            WKInterfaceDevice.current().play(.failure)
            try? await Task.sleep(nanoseconds: 350_000_000)
            WKInterfaceDevice.current().play(.failure)
            try? await Task.sleep(nanoseconds: 350_000_000)
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

// MARK: - Scanner Class
@MainActor
final class WatchBLEScanner: NSObject, ObservableObject{
    
    
    private var pendingAutoStartScan: Bool = false
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var central: CBCentralManager!
    private var discovered: [UUID: Device] = [:]
    private var notifyCharacteristic: CBCharacteristic?
    private var isPlayingHaptic: Bool = false
    private let hapticCooldown: UInt64 = 4000_000_000 // 700ms (tune this)
    /// Stop scanning as soon as we find the first matching device.
    var stopAfterFirstMatch: Bool = true
    
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionError: String? = nil
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var discoveredServiceUUIDs: [String] = []
    @Published private(set) var discoveredCharacteristicUUIDs: [String] = []
    @Published private(set) var isActive: Bool = false

    // Link status (from the two MSBs of the notify byte)
    @Published private(set) var flag1Linked: Bool = false
    @Published private(set) var flag2Linked: Bool = false

    // Per-flag haptic assignment
    @Published private(set) var flag1Haptic: HapticPreset = .doubleNotification
    @Published private(set) var flag2Haptic: HapticPreset = .quadSuccess

    func cycleHaptic(for flag: Int) {
        switch flag {
        case 1:
            flag1Haptic = flag1Haptic.next()
            Task { await flag1Haptic.play() }
        case 2:
            flag2Haptic = flag2Haptic.next()
            Task { await flag2Haptic.play() }
        default:
            break
        }
    }



    
    enum ScanState: Equatable {
        case idle
        case waitingForBluetooth
        case scanning
        case stopped
        case error(String)
    }

    struct Device: Identifiable, Equatable, Hashable {
        let id: UUID
        let name: String
        let rssi: Int
        let lastSeen: Date
    }

    /// Case-insensitive substring match on advertised name / peripheral name.
    var nameFilter: String = "rareBit"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }
    
    private func log(_ msg: String) {
        print("BLE ▶︎ \(msg)")
    }

    private func propsString(_ c: CBCharacteristic) -> String {
        var parts: [String] = []
        let p = c.properties
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        if p.contains(.authenticatedSignedWrites) { parts.append("signed") }
        if p.contains(.extendedProperties) { parts.append("ext") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    //MARK: - START SCAN
    func startScan() {
        isConnecting = false
        isConnected = false
        connectionError = nil

        if central.state != .poweredOn {
            pendingAutoStartScan = true
            state = .waitingForBluetooth
            return
        }

        pendingAutoStartScan = false
        devices.removeAll()
        discovered.removeAll()

        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )
    }


    func stopScan() {
        if central.isScanning { central.stopScan() }
        state = .stopped
    }

    func toggleScan() {
        if central.isScanning { stopScan() } else { startScan() }
    }
    //MARK: - CONNECT
    func connect(to deviceID: UUID) {
        guard central.state == .poweredOn else {
            connectionError = "Bluetooth not powered on."
            return
        }
        guard let p = peripheralsByID[deviceID] else {
            connectionError = "Peripheral reference missing. Re-scan."
            return
        }

        connectionError = nil
        isConnecting = true
        isConnected = false

        peripheral = p
        peripheral?.delegate = self

        central.connect(p, options: nil)
    }
    
    // MARK: - Reconnect
    private var reconnectTargetID: UUID?
    private var shouldAutoReconnect: Bool = false

    func connectAndStayConnected(to deviceID: UUID) {
        reconnectTargetID = deviceID
        shouldAutoReconnect = true
        connect(to: deviceID)
    }

    func stopAutoReconnect() {
        shouldAutoReconnect = false
        reconnectTargetID = nil
    }

    private func beginReconnectScan() {
        guard central.state == .poweredOn else {
            log("Reconnect scan requested but Bluetooth not powered on.")
            return
        }

        log("🔎 Reconnect: scanning for target id=\(reconnectTargetID?.uuidString ?? "nil")")

        // Don’t wipe the UI device list here; the detail screen depends on it.
        stopScan()
        state = .scanning

        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    
    private func matchesFilter(advertisedName: String?) -> Bool {
        let filter = nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return true }
        let f = filter.lowercased()

        let name = (advertisedName ?? "").lowercased()
        return name.contains(f)
    }

    private func upsertDevice(id: UUID, name: String, rssi: Int) {
        let dev = Device(id: id, name: name, rssi: rssi, lastSeen: Date())
        discovered[id] = dev

        // Sort: strongest RSSI first, then most recent.
        devices = discovered.values.sorted {
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.lastSeen > $1.lastSeen
        }
    }
    
    @MainActor
    func ensureNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            log("Notification permission granted=\(granted)")
        } catch {
            log("❌ Notification permission error: \(error)")
        }
    }
    
    
//MARK: - postAlert
    @MainActor
    func postAlert(title: String, body: String) async {
        // Foreground: you can also tap immediately.
        //WKInterfaceDevice.current().play(.failure)

        // Background: local notification is the reliable “system delivered” alert
        /*let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(req)
            log("🔔 Local notification queued")
        } catch {
            log("❌ Failed to queue notification: \(error)")
        }*/
    }

    @MainActor
    func handleBluetoothAlertBackgroundWake() async {
        // Keep this lightweight.
        log("⏰ Woke via .bluetoothAlert background task")

        // Optional: you can re-assert subscription here if you want belt-and-suspenders.
        // If your didUpdateValueFor is already firing and posting alerts, you may not need more.
    }

}
// MARK: - CBCentralManagerDelegate
extension WatchBLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.pendingAutoStartScan {
                    self.startScan()
                } else {
                    self.state = .idle
                }
            case .poweredOff:
                self.state = .error("Bluetooth is off.")
            case .unauthorized:
                self.state = .error("Bluetooth unauthorized.")
            case .unsupported:
                self.state = .error("Bluetooth unsupported.")
            case .resetting, .unknown:
                self.state = .waitingForBluetooth
            @unknown default:
                self.state = .error("Bluetooth state unknown.")
            }
        }
    }

//MARK: - did DISCOVER
    nonisolated func centralManager(_ central: CBCentralManager,
                                   didDiscover peripheral: CBPeripheral,
                                   advertisementData: [String : Any],
                                   rssi RSSI: NSNumber) {

        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let bestName = advName ?? peripheral.name ?? "Unknown"

        Task { @MainActor in
            // Always cache the peripheral reference so we can connect later
            self.peripheralsByID[peripheral.identifier] = peripheral

            // If we’re in reconnect mode, ignore name filter and match exact identifier
            if let target = self.reconnectTargetID {
                guard peripheral.identifier == target else { return }

                self.log("🎯 Reconnect target found: \(bestName) rssi=\(RSSI.intValue) id=\(peripheral.identifier)")
                self.stopScan()
                self.connect(to: target)
                return
            }

            // Otherwise, normal scanning flow (your existing rareBit filter)
            guard self.matchesFilter(advertisedName: bestName) else { return }

            self.log("Discovered: \(bestName) rssi=\(RSSI.intValue) id=\(peripheral.identifier)")
            self.upsertDevice(id: peripheral.identifier, name: bestName, rssi: RSSI.intValue)

            if self.stopAfterFirstMatch {
                self.stopScan()
            }
        }
    }
    
    // MARK: - did CONNECT
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnecting = false
            self.isConnected = true
            self.connectionError = nil

            self.discoveredServiceUUIDs.removeAll()
            self.discoveredCharacteristicUUIDs.removeAll()

            self.log("✅ CONNECTED: \(peripheral.name ?? "Unknown") id=\(peripheral.identifier)")


            self.log("Starting service discovery…")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                   didFailToConnect peripheral: CBPeripheral,
                                   error: Error?) {
        Task { @MainActor in
            self.isConnecting = false
            self.isConnected = false
            let msg = error?.localizedDescription ?? "unknown"
            self.connectionError = msg
            self.log("❌ FAILED TO CONNECT: \(peripheral.name ?? "Unknown") id=\(peripheral.identifier) error=\(msg)")
        }
    }
    
    // MARK: - did DISCONNECT
    nonisolated func centralManager(_ central: CBCentralManager,
                                   didDisconnectPeripheral peripheral: CBPeripheral,
                                   error: Error?) {
        print("BLE ▶︎ didDisconnectPeripheral CALLED for \(peripheral.name ?? "Unknown") id=\(peripheral.identifier) err=\(error?.localizedDescription ?? "none")")

        Task { @MainActor in
            self.isConnecting = false
            self.isConnected = false
            self.isActive = false
            self.flag1Linked = false
            self.flag2Linked = false

            self.log("⚠️ DISCONNECTED. auto=\(self.shouldAutoReconnect) target=\(self.reconnectTargetID?.uuidString ?? "nil")")

            if self.shouldAutoReconnect, self.reconnectTargetID != nil {
                self.log("🔁 Auto-reconnect: starting scan for target…")
                self.beginReconnectScan()
            } else {
                self.log("🔕 Auto-reconnect not starting (not armed)")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension WatchBLEScanner: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.log("❌ didDiscoverServices error: \(error.localizedDescription)")
                self.connectionError = error.localizedDescription
                return
            }

            let services = peripheral.services ?? []
            self.log("Discovered \(services.count) service(s).")

            for s in services {
                let uuidStr = s.uuid.uuidString
                self.discoveredServiceUUIDs.append(uuidStr)
                self.log("  • Service: \(uuidStr)")
            }

            // Discover characteristics for each service
            for s in services {
                self.log("Discovering characteristics for service \(s.uuid.uuidString)…")
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.log("❌ didDiscoverCharacteristics error: \(error.localizedDescription)")
                return
            }

            let chars = service.characteristics ?? []
            self.log("Service \(service.uuid.uuidString) has \(chars.count) characteristic(s).")

            for c in chars {
                self.log("  • Char \(c.uuid.uuidString) props=\(self.propsString(c))")

                if c.uuid == TARGET_NOTIFY_CHAR_UUID {
                    self.notifyCharacteristic = c

                    self.log("🔔 Found notify characteristic, subscribing…")
                    peripheral.setNotifyValue(true, for: c)
                }
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.log("❌ Notify state error: \(error.localizedDescription)")
                return
            }

            if characteristic.isNotifying {
                self.log("✅ NOTIFY ENABLED for \(characteristic.uuid.uuidString)")
                self.isActive = true
                
                // 🔒 Arm auto-reconnect once we’re truly “active”
                self.reconnectTargetID = peripheral.identifier
                self.shouldAutoReconnect = true
                self.log("🧷 Auto-reconnect ARMED for target=\(peripheral.identifier)")
            } else {
                self.log("⚠️ Notify DISABLED for \(characteristic.uuid.uuidString)")
                self.isActive = false
            }
        }
    }
    //MARK: - did UpdateValue
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {

        Task { @MainActor in
            if let error = error {
                self.log("❌ didUpdateValue error: \(error.localizedDescription)")
                return
            }
            guard let data = characteristic.value else { return }
            guard let byte = data.first else { return }

            // --- Parse byte ---
            // Bit 7: Flag 1 linked
            // Bit 6: Flag 2 linked
            // Bits 1..0: Alert source (0x01 = Flag 1, 0x02 = Flag 2, 0x00 = none)
            let linkBits = byte & 0xC0
            let alertBits = byte & 0x03

            self.log("📥 Notify byte: 0x\(String(format: "%02X", byte))  links=0b\(String(linkBits >> 6, radix: 2))  alert=0x\(String(format: "%02X", alertBits))")

            // --- Update link status ---
            self.flag1Linked = (byte & 0x80) != 0
            self.flag2Linked = (byte & 0x40) != 0

            // --- Handle alert (if any) ---
            guard alertBits != 0x00 else {
                self.log("ℹ️ Status update only (no alert)")
                return
            }

            guard !isPlayingHaptic else { return }
            isPlayingHaptic = true

            let preset: HapticPreset
            switch alertBits {
            case 0x01:
                preset = self.flag1Haptic
                self.log("🔵 Flag 1 alert → \(preset.label)")
            case 0x02:
                preset = self.flag2Haptic
                self.log("🔴 Flag 2 alert → \(preset.label)")
            default:
                self.log("⚪️ Unknown alert source: 0x\(String(format: "%02X", alertBits))")
                WKInterfaceDevice.current().play(.click)
                isPlayingHaptic = false
                return
            }

            await preset.play()

            Task {
                try? await Task.sleep(nanoseconds: hapticCooldown)
                await MainActor.run {
                    self.isPlayingHaptic = false
                    self.log("🔓 Haptic re-enabled")
                }
            }
        }
    }

}

