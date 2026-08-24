import Foundation
import CoreBluetooth
import Combine
import iOSMcuManagerLibrary

// MARK: - Peripheral Session
//This is a change
@MainActor
final class PeripheralSession: ObservableObject {
    enum ConnState: Equatable { case idle, connecting, connected, failed(String) }

    let id: UUID
    weak var peripheral: CBPeripheral?

    // Connection / discovery state
    var connState: ConnState = .idle
    var servicesDiscovered: Bool = false
    var hasSmpService: Bool = false
    var hasSmpCharacteristic: Bool = false
    var hasConfigService: Bool = false
    var hasConfigCharacteristic: Bool = false
    var hasFwVersionCharacteristic: Bool = false
    // Per-device watchdog + disconnect intent
    var connectWatchdog: DispatchWorkItem?
    
    // Per-device disconnect intent
    var manualDisconnectRequested: Bool = false

    // DFU reboot window (used for auto-reconnect + to not treat disconnect as an error)
    var awaitingRebootUntil: Date?

    // Per-device DFU transport (SMP)
    var mcumgrTransport: McuMgrBleTransport?


    // Characteristic handles
    var cfgCharacteristic: CBCharacteristic?
    var fwvCharacteristic: CBCharacteristic?

    // Cached values
    var configByte: UInt8?
    var batteryLevel: BleScanner.BatteryLevel = .unknown
    var firmwareVersion: String?

    // DFU / reboot expectations (per-device)
    
    var lastUpgraded: Bool = false

    init(id: UUID) {
        self.id = id
    }
}


// MARK: - BLE Scanner
@MainActor
final class BleScanner: NSObject, ObservableObject {
    // DFU UI state
    @Published var dfuInProgress = false
    @Published var dfuProgress: Double = 0.0
    @Published var dfuStateText: String = ""
    @Published var dfuErrorText: String?
    @Published var dfuUpgradeState: FirmwareUpgradeState?
    @Published var dfuEffectiveSuccess = false

    // Relay legacy OTA DFU state (docs/relay-dfu-flow.md)
    @Published var relayDfuInProgress = false
    @Published var relayDfuProgress: Double = 0.0
    @Published var relayDfuStateText: String = ""
    @Published var relayDfuErrorText: String?
    @Published var relayUpdateAvailable: Bool?
    @Published var relayLatestVersion: FirmwareVersion?
    /// Relays advertising the legacy DFU service — a device mid-update, or one
    /// stuck in the bootloader after an interrupted flash (recovery path).
    @Published private(set) var relayBootloaderIds: [UUID] = []

    private var bootloaderPeripherals: [UUID: CBPeripheral] = [:]
    private var relayTriggerContinuation: CheckedContinuation<Void, Error>?
    private let relayFlasher = LegacyDfuFlasher()

    @Published var isPoweredOn = false
    @Published var isScanning = false
    @Published var devices: [DiscoveredDevice] = []
    
    // MARK: - Device sessions
    @Published private(set) var sessions: [UUID: PeripheralSession] = [:]

    // UI focus only (NOT used as BLE truth)
    @Published var selectedId: UUID?

    private func session(for id: UUID) -> PeripheralSession {
        if let s = sessions[id] { return s }
        let s = PeripheralSession(id: id)
        sessions[id] = s
        return s
    }

    private func session(for peripheral: CBPeripheral) -> PeripheralSession {
        let s = session(for: peripheral.identifier)
        s.peripheral = peripheral
        return s
    }

    /// Pull selected-only UI convenience flags from the selected session.
    private func syncSelectedUIFromSession() {
        guard let id = selectedId else { return }
        let s = session(for: id)

        // Connection/discovery UI
        servicesDiscovered = s.servicesDiscovered
        hasSmpService = s.hasSmpService
        hasSmpCharacteristic = s.hasSmpCharacteristic

        hasConfigService = s.hasConfigService
        hasConfigCharacteristic = s.hasConfigCharacteristic
        hasFwVersionCharacteristic = s.hasFwVersionCharacteristic

        // Config/version UI
        if let b = s.configByte {
            config = DeviceConfig(byte: b)
        } else {
            config = nil
        }
        firmwareVersion = s.firmwareVersion
    }


    // Selection + connection state
    @Published var selected: DiscoveredDevice?
    @Published var connectionState: ConnectionState = .idle
    @Published var connectingDeviceIDs: Set<UUID> = []
    @Published var connectedDeviceIDs: Set<UUID> = []

    // Discovery results for the selected device
    @Published var servicesDiscovered = false
    @Published var hasSmpService = false
    @Published var hasSmpCharacteristic = false

    // Config service discovery and values
    @Published var hasConfigService = false
    @Published var hasConfigCharacteristic = false
    @Published var hasFwVersionCharacteristic = false
    @Published var config: DeviceConfig?
    @Published var firmwareVersion: String?
    @Published private(set) var batteryLevelById: [UUID: BatteryLevel] = [:]

    
    @Published private(set) var configByteById: [UUID: UInt8] = [:]
    
    // ✅ Session-only color assignment for connected devices
    @Published private(set) var deviceColorIndex: [UUID: Int] = [:]

    private var availableColorIndices: [Int] = [0, 1, 2, 3, 4]

    // Show DFU card only when needed:
    // - If CFG service is not present (older FW), show DFU card (to prompt upgrade)
    // - If CFG service is present and firmwareVersion is parsed as 2.0 (or 0x20), hide DFU card
    // - Otherwise, show DFU card
    // Show DFU card only when we KNOW whether it should be shown.
    // This prevents the "flash" while service discovery / FW version reads are still in flight.
    
    // MARK: - shouldShowDfuCard
    var shouldShowDfuCard: Bool {
        // Only relevant once we are actually connected
//        guard connectionState == .connected else { return false }
//
//        // Wait until CoreBluetooth reports services; otherwise we don't know yet
//        guard servicesDiscovered else { return false }
//
//        // If CFG service is missing AFTER services discovered, this is older FW -> show DFU
//        if !hasConfigService { return true }
//
//        // CFG service exists, so DFU visibility depends on firmwareVersion.
//        // But firmwareVersion arrives asynchronously — hide DFU until we have it to avoid flashing.
//        guard let v = firmwareVersion else { return false }
//
//        // Expect format like "2.0"; parse major.minor
//        let comps = v.split(separator: ".")
//        if let majorStr = comps.first, let major = Int(majorStr) {
//            // If >= 2, hide DFU
//            return major < 2
//        }

        // If parsing fails, be conservative and allow DFU
        return true
    }

    //MARK: HELPERS
    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    
    private var dfuManager: FirmwareUpgradeManager?
    private var dfuController: FirmwareUpgradeController?
    
    private var targetImageHash: Data?

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private var central: CBCentralManager!
    // ✅ Per-device characteristic caches (so multi-connected devices don’t fight)
    private var cfgCharacteristicById: [UUID: CBCharacteristic] = [:]
    private var fwvCharacteristicById: [UUID: CBCharacteristic] = [:]
    private var dfuTriggerCharacteristicById: [UUID: CBCharacteristic] = [:]


    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private var isDisconnectedOrFailed: Bool {
        switch connectionState {
        case .idle, .failed: return true
        default: return false
        }
    }
    
    func firmwareVersionById(_ id: UUID) -> String? {
        sessions[id]?.firmwareVersion
    }
    
    func firmwareVersionByteById(_ id: UUID) -> UInt8? {
        guard let session = sessions[id],
              let versionString = session.firmwareVersion else {
            return nil
        }
        
        let version = FirmwareVersion(versionString)
        return version.asByte
    }
    
    /// Check if a firmware update is available for this device
    func checkFirmwareUpdate(for deviceId: UUID, deviceType: RareBitDeviceType) async throws -> (needsUpdate: Bool, latestVersion: FirmwareVersion?) {
        guard let releaseTag = deviceType.releaseTag else {
            throw FirmwareUpdateError.noReleaseTag
        }
        
        guard let versionString = firmwareVersionById(deviceId) else {
            // FWV characteristic missing — old firmware that predates it.
            // Assume an update is needed so the device can be recovered.
            let latest = try await FirmwareService.shared.latestVersion(for: releaseTag)
            print("📱 FWV unreadable for \(deviceType.displayName) — assuming update needed (latest: \(latest))")
            return (true, latest)
        }

        let current = FirmwareVersion(versionString)
        let result = try await FirmwareService.shared.checkForUpdate(tag: releaseTag, currentVersion: versionString)

        print("📱 Update check for \(deviceType.displayName): Current=\(current) Latest=\(result.release.tag_name) NeedsUpdate=\(result.needsUpdate)")

        return (result.needsUpdate, FirmwareVersion(result.release.tag_name))
    }
    
    // MARK: - Relay legacy OTA DFU (docs/relay-dfu-flow.md) — Relay ONLY.
    // PRO Flag / PRO Receiver keep the SMP (McuManager) flow below unchanged.

    /// Update check against the public firmware-releases repo (cached for the
    /// app session). No-op result if the FW version byte isn't readable yet.
    func checkRelayUpdate(for deviceId: UUID, forceRefresh: Bool = false) async {
        guard let current = firmwareVersionByteById(deviceId) else {
            relayUpdateAvailable = nil
            return
        }
        do {
            let (update, needs) = try await RelayDfuService.shared.updateAvailable(currentVersionByte: current, forceRefresh: forceRefresh)
            relayUpdateAvailable = needs
            relayLatestVersion = update.version
            print("[RelayDFU] Check: current=0x\(String(format: "%02X", current)) latest=\(update.manifest.fw_version_byte) needsUpdate=\(needs)")
        } catch {
            print("[RelayDFU] Update check failed: \(error)")
            relayUpdateAvailable = nil
        }
    }

    /// Full update chain: fetch release → SHA-verified download → GATT trigger
    /// (USB-docked only) → legacy DFU flash → reconnect and confirm version.
    func startRelayUpdate(for deviceId: UUID) async {
        guard !relayDfuInProgress else { return }
        relayDfuInProgress = true
        relayDfuErrorText = nil
        relayDfuProgress = 0

        do {
            relayDfuStateText = "Fetching release…"
            let update = try await RelayDfuService.shared.latestUpdate()

            relayDfuStateText = "Downloading \(update.version.map { "v\($0)" } ?? "firmware")…"
            let zip = try await RelayDfuService.shared.downloadVerifiedPackage(update)

            relayDfuStateText = "Rebooting Relay into update mode…"
            // The post-trigger disconnect is expected — widen the reboot window
            // so it isn't reported as a connection failure.
            sessions[deviceId]?.awaitingRebootUntil = Date().addingTimeInterval(30)
            try await writeRelayDfuTrigger(for: deviceId)

            relayDfuStateText = "Waiting for update mode…"
            let target = try await waitForRelayBootloader(timeout: 15)

            try await flashRelay(zipURL: zip, target: target)

            relayDfuStateText = "Verifying…"
            await confirmRelayVersion(deviceId: deviceId, expected: update.manifest.versionByte ?? 0)
            relayDfuStateText = "Updated to \(update.version.map { "v\($0)" } ?? "latest") ✓"
            relayUpdateAvailable = false
        } catch {
            relayDfuErrorText = error.localizedDescription
            relayDfuStateText = ""
        }
        relayDfuInProgress = false
    }

    /// Recovery path: an interrupted DFU leaves the bootloader advertising the
    /// DFU service on every boot. Flash it directly — no trigger needed.
    func retryRelayFlash(bootloaderId: UUID) async {
        guard !relayDfuInProgress else { return }
        relayDfuInProgress = true
        relayDfuErrorText = nil
        relayDfuProgress = 0

        do {
            relayDfuStateText = "Fetching release…"
            let update = try await RelayDfuService.shared.latestUpdate()
            relayDfuStateText = "Downloading…"
            let zip = try await RelayDfuService.shared.downloadVerifiedPackage(update)
            try await flashRelay(zipURL: zip, target: bootloaderId)
            relayDfuStateText = "Recovered — flashed \(update.version.map { "v\($0)" } ?? "") ✓"
        } catch {
            relayDfuErrorText = error.localizedDescription
            relayDfuStateText = ""
        }
        relayDfuInProgress = false
    }

    private func writeRelayDfuTrigger(for deviceId: UUID) async throws {
        guard let ch = dfuTriggerCharacteristicById[deviceId],
              let peripheral = ch.service?.peripheral else {
            // Distinct from ATT 0x03: here the connected GATT table doesn't
            // even contain the trigger characteristic.
            print("[RelayDFU] ❌ Trigger characteristic was never discovered for \(deviceId)")
            throw RelayDfuError.triggerUnavailable
        }
        print("[RelayDFU] Writing 0xA8 to trigger characteristic…")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            relayTriggerContinuation = cont
            peripheral.writeValue(Data([0xA8]), for: ch, type: .withResponse)
        }
    }

    private static func mapTriggerError(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == CBATTErrorDomain else { return error }
        switch ns.code {
        case 0x03: return RelayDfuError.notDocked                                        // Write Not Permitted
        case 0x13: return RelayDfuError.triggerRejected("wrong magic byte")              // Value Not Allowed
        case 0x0D: return RelayDfuError.triggerRejected("payload must be exactly 1 byte") // Invalid Length
        default:   return RelayDfuError.triggerRejected(ns.localizedDescription)
        }
    }

    private func waitForRelayBootloader(timeout: TimeInterval) async throws -> UUID {
        // Bench assumption: one Relay in DFU mode at a time — a bootloader
        // already known from a stuck device is just as valid a target.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let id = relayBootloaderIds.first { return id }
            if isPoweredOn, !isScanning { startScan() }
            try? await Task.sleep(for: .milliseconds(400))
        }
        throw RelayDfuError.bootloaderNotFound
    }

    private func flashRelay(zipURL: URL, target: UUID) async throws {
        stopScan()   // don't fight the DFU library's own central manager
        relayDfuStateText = "Flashing…"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            relayFlasher.onProgress = { [weak self] p in self?.relayDfuProgress = p }
            relayFlasher.onStateText = { [weak self] t in self?.relayDfuStateText = t }
            relayFlasher.onFinish = { [weak self] result in
                self?.relayFlasher.onFinish = nil   // guard against double resume
                cont.resume(with: result)
            }
            do {
                try relayFlasher.flash(zipURL: zipURL, targetIdentifier: target)
            } catch {
                relayFlasher.onFinish = nil
                cont.resume(throwing: error)
            }
        }
        relayBootloaderIds.removeAll { $0 == target }
        bootloaderPeripherals[target] = nil
    }

    /// On completion the bootloader reboots into the new firmware; the device
    /// is still docked, so it re-enters config mode. Let the existing
    /// scan/auto-reconnect machinery pick it up, then check the FW byte
    /// against the manifest. Confirmation failure is a warning, not an error —
    /// the flash itself already succeeded.
    private func confirmRelayVersion(deviceId: UUID, expected: UInt8) async {
        if let s = sessions[deviceId] {
            s.lastUpgraded = true
            s.awaitingRebootUntil = Date().addingTimeInterval(60)
            s.firmwareVersion = nil
        }
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let byte = firmwareVersionByteById(deviceId) {
                if byte == expected {
                    print("[RelayDFU] ✅ Version confirmed: 0x\(String(format: "%02X", byte))")
                    return
                }
                print("[RelayDFU] ⚠️ Version mismatch after flash: got 0x\(String(format: "%02X", byte)) want 0x\(String(format: "%02X", expected))")
                return
            }
            if isPoweredOn, !isScanning { startScan() }
            try? await Task.sleep(for: .seconds(1))
        }
        print("[RelayDFU] ⚠️ Flashed OK but version not confirmed within timeout")
    }

    /// Automatically download and start DFU if update is available
    func autoUpdateIfNeeded(for deviceId: UUID, deviceType: RareBitDeviceType) async throws -> Bool {
        let (needsUpdate, latestVersion) = try await checkFirmwareUpdate(for: deviceId, deviceType: deviceType)
        
        guard needsUpdate else {
            await MainActor.run {
                dfuStateText = "Already up to date (\(latestVersion?.description ?? "unknown"))"
            }
            return false
        }
        
        guard let releaseTag = deviceType.releaseTag else {
            throw FirmwareUpdateError.noReleaseTag
        }
        
        await MainActor.run {
            dfuErrorText = nil
            dfuStateText = "Update available: \(latestVersion?.description ?? "unknown")"
        }
        
        // Fetch and download
        await MainActor.run {
            dfuStateText = "Fetching \(releaseTag) release..."
        }
        let release = try await FirmwareService.shared.fetchRelease(tag: releaseTag)
        
        await MainActor.run {
            dfuStateText = "Locating firmware asset..."
        }
        guard let asset = release.firmwareAsset() else {
            throw FirmwareUpdateError.noAssetFound
        }
        
        await MainActor.run {
            dfuStateText = "Downloading firmware..."
        }
        let fileURL = try await FirmwareService.shared.downloadFirmware(from: asset)
        
        await MainActor.run {
            dfuStateText = "Starting DFU update..."
            startDfuFromURL(for: deviceId, fileURL: fileURL)
        }
        
        return true
    }

    
    func hasSmpReady(_ id: UUID) -> Bool {
        let s = session(for: id)
        return s.hasSmpService && s.hasSmpCharacteristic
    }

    func hasConfigService(_ id: UUID) -> Bool {
        session(for: id).hasConfigService
    }

    
    private func assignColorIfNeeded(for id: UUID) {
        guard deviceColorIndex[id] == nil else { return }
        guard !availableColorIndices.isEmpty else { return } // If >5 devices connect, extras just won't glow-color
        deviceColorIndex[id] = availableColorIndices.removeFirst()
    }

    private func releaseColor(for id: UUID) {
        guard let idx = deviceColorIndex.removeValue(forKey: id) else { return }
        // Put it back at the end (FIFO reuse is fine)
        availableColorIndices.append(idx)
    }

    func colorIndex(for id: UUID) -> Int? {
        deviceColorIndex[id]
    }
    
    func disconnectAll() {
        
        if let p = selected?.peripheral {
            central.cancelPeripheralConnection(p)
        }

        // If you track multiple, loop your connected set:
        for id in connectedDeviceIDs {
            if let p = devices.first(where: { $0.id == id })?.peripheral {
                central.cancelPeripheralConnection(p)
            }
        }
    }


    enum BatteryLevel: String {
        case unknown = "BATTERY_UNKNOWN"
        case low = "BATTERY_LOW"
        case mid = "BATTERY_MID"
        case high = "BATTERY_HIGH"
        case full = "BATTERY_FULL"
    }

    func batteryLevel(for id: UUID) -> BatteryLevel {
        batteryLevelById[id] ?? .unknown
    }
    
    func configByte(for id: UUID) -> UInt8? {
        configByteById[id]
    }

    func deviceConfig(for id: UUID) -> DeviceConfig? {
        guard let b = configByteById[id] else { return nil }
        return DeviceConfig(byte: b)
    }


    //MARK: DeviceConfig
    struct DeviceConfig {
        private(set) var rawByte: UInt8

        var shortPressEnabled: Bool
        var batteryLevel: BatteryLevel
        var shortPressDelay: UInt8

        init(byte: UInt8) {
            self.rawByte = byte

            shortPressEnabled = (byte & 0b0000_0001) != 0

            let topTwo = (byte & 0b1100_0000) >> 6
            switch topTwo {
            case 0: batteryLevel = .low
            case 1: batteryLevel = .mid
            case 2: batteryLevel = .high
            default: batteryLevel = .full
            }

            shortPressDelay = (byte & 0b0011_1100) >> 2
        }

        // ✅ preserves other bits by default
        var bytePreservingOtherBits: UInt8 {
            var b = rawByte
            // short press enable
            if shortPressEnabled { b |= 0b0000_0001 }
            else { b &= 0b1111_1110 }

            // delay bits (2..5)
            let delayMask: UInt8 = 0b0011_1100
            b = (b & ~delayMask) | ((shortPressDelay & 0x0F) << 2)
            return b
        }
    }


    // MARK: - Scan
    // MARK: - Scan timeout
    private var scanStopWorkItem: DispatchWorkItem?
    private let scanTimeoutSeconds: TimeInterval = 12  // tweak as desired


    func startScan() {
        guard isPoweredOn else { return }

        // ✅ Preserve any connected/connecting devices in the list
        let keepIDs = connectedDeviceIDs.union(connectingDeviceIDs)
        devices = devices.filter { keepIDs.contains($0.id) }

        isScanning = true

        print("[BLE] Starting scan for devices with name containing 'rareBit' …")

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        // ✅ Always stop scanning after a timeout
        scanStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isScanning {
                print("[BLE] Scan timeout — stopping scan")
                self.stopScan()
            }
        }
        scanStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: work)
    }



    func stopScan() {
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil

        isScanning = false
        central.stopScan()
        print("[BLE] Stopped scan")
    }

    
    func clearUnconnectedDevicesFromList() {
        let keepIDs = connectedDeviceIDs.union(connectingDeviceIDs)
        devices.removeAll { !keepIDs.contains($0.id) }
    }


    // MARK: - Selection

    func select(_ device: DiscoveredDevice) {
        selected = device
        selectedId = device.id

        print("[BLE] Selected device: \(device.advertisedName ?? device.peripheral.name ?? "Unnamed") (\(device.id))")

        // Ensure a session exists + point it at this peripheral
        let s = session(for: device.id)
        s.peripheral = device.peripheral
        device.peripheral.delegate = self

        // Update the selected-only UI flags from the session instead of resetting globals blindly
        syncSelectedUIFromSession()

    }


    // MARK: - Connection

    func connectSelected() {
        guard let id = selected?.id else { return }
        focusDevice(id)
        connect(deviceId: id)
    }

    
    // MARK: - Focus / connect / disconnect

    func focusDevice(_ id: UUID) {
        selectedId = id
        if let d = devices.first(where: { $0.id == id }) {
            selected = d
            let s = session(for: id)
            s.peripheral = d.peripheral
            d.peripheral.delegate = self
        }
        syncSelectedUIFromSession()
    }


    func connect(deviceId id: UUID) {
        guard isPoweredOn else {
            if selectedId == id { connectionState = .failed("Bluetooth is off") }
            return
        }

        // Ensure session exists and has a peripheral reference
        let s = session(for: id)

        // Prefer the DiscoveredDevice peripheral if we have it
        if s.peripheral == nil, let p = devices.first(where: { $0.id == id })?.peripheral {
            s.peripheral = p
        }

        guard let p = s.peripheral else {
            if selectedId == id { connectionState = .failed("No peripheral for \(id)") }
            return
        }

        // If already connected at OS level, adopt into the session and discover
        if adoptIfAlreadyConnected(prefer: id) {
            return
        }

        if isScanning { stopScan() }

        p.delegate = self
        s.connState = .connecting
        connectingDeviceIDs.insert(id)

        if selectedId == id { connectionState = .connecting }

        s.manualDisconnectRequested = false

        print("[BLE] Connecting to \(id)…")
        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])

        startConnectWatchdog(for: id)
    }

    func disconnect(deviceId id: UUID, manual: Bool = true) {
        let s = session(for: id)

        // Record intent
        s.manualDisconnectRequested = manual

        if manual {
            // User intent: not a DFU reboot
            s.lastUpgraded = false
            s.awaitingRebootUntil = nil
        }

        if let p = s.peripheral {
            central.cancelPeripheralConnection(p)
        }

        connectingDeviceIDs.remove(id)
        connectedDeviceIDs.remove(id)
        releaseColor(for: id)

        if selectedId == id {
            connectionState = .idle
            syncSelectedUIFromSession()
        }
    }
    
    func isAwaitingReboot(deviceId: UUID) -> Bool {
        let s = session(for: deviceId)
        guard let until = s.awaitingRebootUntil else { return false }
        return Date() <= until
    }

    
    @MainActor
    func adoptIfAlreadyConnected(prefer id: UUID) -> Bool {
        guard isPoweredOn else { return false }

        // Use the most universal service your devices expose
        let connected = central.retrieveConnectedPeripherals(withServices: [SmpUuids.service])

        guard let p = connected.first(where: { $0.identifier == id }) else {
            return false
        }

        // Adopt the peripheral into THIS process
        p.delegate = self
        

        // Also keep the selected DiscoveredDevice in sync (so RSSI/name usage remains consistent)
        if let idx = devices.firstIndex(where: { $0.id == id }) {
            selected = devices[idx]
        } else {
            let placeholder = DiscoveredDevice(
                id: id,
                peripheral: p,
                advertisedName: p.name ?? "Unnamed",
                rssi: 0
            )
            devices.append(placeholder)
            selected = placeholder
        }

        // Mark state and run discovery (this is what gets you out of the dead path)
        connectionState = .connected

        servicesDiscovered = false
        hasSmpService = false
        hasSmpCharacteristic = false
        hasConfigService = false
        hasConfigCharacteristic = false
        hasFwVersionCharacteristic = false
        config = nil
        firmwareVersion = nil

        print("[BLE] Adopted existing OS connection; discovering services…")
        p.discoverServices([SmpUuids.service, cfgUuids.service])

        connectedDeviceIDs.insert(id)
        assignColorIfNeeded(for: id)
        if batteryLevelById[p.identifier] == nil {
            batteryLevelById[p.identifier] = .unknown
        }


        return true
    }

    
    @MainActor
    func refreshConnectedPeripherals() {
        guard isPoweredOn else { return }

        // Any service UUID that uniquely identifies your devices.
        // If some devices don't have CFG, SMP is the best anchor.
        let serviceUUIDs: [CBUUID] = [SmpUuids.service]

        let connected = central.retrieveConnectedPeripherals(withServices: serviceUUIDs)
        let ids = Set(connected.map { $0.identifier })

        // Update UI truth
        connectedDeviceIDs = ids

        // Ensure each connected peripheral has an assigned color and appears in your list.
        for p in connected {
            assignColorIfNeeded(for: p.identifier)

            // If you don't already have it in `devices`, insert a placeholder so the UI can show it.
            if !devices.contains(where: { $0.id == p.identifier }) {
                let placeholder = DiscoveredDevice(
                    id: p.identifier,
                    peripheral: p,
                    advertisedName: p.name ?? "Unnamed",
                    rssi: 0
                )
                devices.append(placeholder)
            }
        }

        // Optional: clean up stale connected IDs that no longer exist in OS list (already done by assignment above)
        print("[BLE] Refreshed connected peripherals: \(ids.count)")
    }


    
    func startConnectWatchdog(for id: UUID) {
        let s = session(for: id)

        s.connectWatchdog?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let s = self.session(for: id)

            // If still connecting OR connected but not discovered, we’re stuck.
            let stuckConnecting = self.connectingDeviceIDs.contains(id)
            let stuckNoDiscovery = self.connectedDeviceIDs.contains(id) && !s.servicesDiscovered

            guard stuckConnecting || stuckNoDiscovery else { return }

            print("[BLE] Watchdog(\(id)): stuck; cancelling + retrying")

            if let p = s.peripheral {
                self.central.cancelPeripheralConnection(p)
            }
            self.connectingDeviceIDs.remove(id)

            // Try adopt again first
            _ = self.adoptIfAlreadyConnected(prefer: id)

            // If still not connected, reconnect
            if !self.connectedDeviceIDs.contains(id) {
                self.connect(deviceId: id)
            } else if let p = s.peripheral, !s.servicesDiscovered {
                p.discoverServices([SmpUuids.service, cfgUuids.service])
            }
        }

        s.connectWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }


    
    func recoverExistingConnectionIfPossible(prefer deviceId: UUID? = nil) -> Bool {
        guard central.state == .poweredOn else { return false }

        let serviceUUIDs: [CBUUID] = [SmpUuids.service, cfgUuids.service]
        let alreadyConnected = central.retrieveConnectedPeripherals(withServices: serviceUUIDs)

        // If you know which device you want (deviceId), try to match it first.
        let picked: CBPeripheral? = {
            if let deviceId {
                return alreadyConnected.first(where: { $0.identifier == deviceId })
            }
            return alreadyConnected.first
        }()

        guard let p = picked else { return false }

        // ✅ Adopt
        p.delegate = self
        
        connectionState = .connected

        // Make sure your flags start clean, then discover
        servicesDiscovered = false
        hasSmpService = false
        hasSmpCharacteristic = false
        hasConfigService = false
        hasConfigCharacteristic = false
        hasFwVersionCharacteristic = false

        p.discoverServices([SmpUuids.service, cfgUuids.service])
        return true
    }


    func disconnectSelected() {
        guard let id = selectedId else { return }
        disconnect(deviceId: id, manual: true)

        // Optional: if you want the UI to “leave” the detail view on manual disconnect
        selected = nil
    }


    // MARK: - Config Write
    func writeConfig(_ config: DeviceConfig, for deviceId: UUID) {
        // Must be connected for this device
        guard connectedDeviceIDs.contains(deviceId) else { return }

        guard let p = peripheralForId(deviceId) else {
            print("[BLE] writeConfig: no peripheral for \(deviceId)")
            return
        }
        guard let ch = cfgCharacteristicForId(deviceId) else {
            print("[BLE] writeConfig: no CFG characteristic for \(deviceId)")
            return
        }

        // ✅ Choose a base byte that preserves device-reported bits (battery etc.)
        // Prefer characteristic cached value, then our persisted map.
        let baseByte: UInt8? = ch.value?.first ?? configByteById[deviceId]

        // If we don't have any known base, do NOT write — we'd accidentally write 0x00.
        guard var newByte = baseByte else {
            print("[BLE] writeConfig aborted: no base byte yet for \(deviceId)")
            return
        }

        // ✅ Modify ONLY user-controlled bits, preserve everything else
        // short press enable (bit0)
        if config.shortPressEnabled {
            newByte |= 0b0000_0001
        } else {
            newByte &= 0b1111_1110
        }

        // short press delay (bits2..5)
        let delayMask: UInt8 = 0b0011_1100
        newByte = (newByte & ~delayMask) | ((config.shortPressDelay & 0x0F) << 2)

        // Skip if no change
        if let base = baseByte, newByte == base {
            return
        }

        // Prefer write-with-response when supported
        let writeType: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse

        // ✅ Optimistically persist so ScanList + Detail update instantly
        configByteById[deviceId] = newByte
        batteryLevelById[deviceId] = DeviceConfig(byte: newByte).batteryLevel // optional

        // Keep selected convenience var updated if this is selected
        if selected?.id == deviceId {
            self.config = DeviceConfig(byte: newByte)
        }

        p.writeValue(Data([newByte]), for: ch, type: writeType)

        print("[BLE] writeConfig(\(deviceId)) base=0x\(String(format: "%02X", baseByte!)) new=0x\(String(format: "%02X", newByte))")
    }


    // MARK: - PACKING HELPERS
    // Adjust these masks/shifts to match your DeviceConfig layout if different.

    private let CFG_SHORT_PRESS_MASK: UInt8 = 0b0000_0001     // bit0
    private let CFG_DELAY_MASK: UInt8       = 0b0011_1100     // bits2..5
    private let CFG_DELAY_SHIFT: UInt8      = 2               // delay stored in bits2..5

    /// Returns a new config byte with updated short-press enable flag, preserving all other bits.
    private func cfgByteSettingShortPress(_ base: UInt8, enabled: Bool) -> UInt8 {
        let cleared = base & ~CFG_SHORT_PRESS_MASK
        let bit: UInt8 = enabled ? CFG_SHORT_PRESS_MASK : 0
        return cleared | bit
    }

    /// Returns a new config byte with updated short-press delay (0...15), preserving all other bits.
    private func cfgByteSettingDelay(_ base: UInt8, delay: UInt8) -> UInt8 {
        let d = min(delay, 15)
        let cleared = base & ~CFG_DELAY_MASK
        let shifted = (d << CFG_DELAY_SHIFT) & CFG_DELAY_MASK
        return cleared | shifted
    }
    

    func setShortPressEnabled(_ enabled: Bool, for deviceId: UUID) {
        guard connectedDeviceIDs.contains(deviceId) else {
            print("[BLE] setShortPressEnabled: device not in connected set \(deviceId)")
            return
        }

        guard let p = peripheralForId(deviceId) else {
            print("[BLE] setShortPressEnabled: no peripheral for \(deviceId)")
            return
        }

        guard let ch = cfgCharacteristicForId(deviceId) else {
            print("[BLE] setShortPressEnabled: no CFG characteristic for \(deviceId)")
            return
        }

        // ✅ Base byte must come from a real source to preserve battery/unknown bits.
        // Prefer CB's cached value for this characteristic, then our persisted map.
        guard let base = (ch.value?.first ?? configByteById[deviceId]) else {
            print("[BLE] setShortPressEnabled aborted: no base byte yet for \(deviceId)")
            return
        }

        let newByte = cfgByteSettingShortPress(base, enabled: enabled)

        // Skip if no change
        if newByte == base {
            return
        }

        // Prefer write-with-response when available, else without-response
        let writeType: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse

        // ✅ Optimistically persist so ScanList + Detail update instantly
        configByteById[deviceId] = newByte
        batteryLevelById[deviceId] = DeviceConfig(byte: newByte).batteryLevel // optional, keeps glow stable

        if selected?.id == deviceId {
            config = DeviceConfig(byte: newByte)
        }

        p.writeValue(Data([newByte]), for: ch, type: writeType)
        print("[BLE] Wrote CFG(\(deviceId)) base=0x\(String(format: "%02X", base)) new=0x\(String(format: "%02X", newByte)) [shortPress=\(enabled)]")
    }

    func setShortPressDelay(_ delay: UInt8, for deviceId: UUID) {
        guard connectedDeviceIDs.contains(deviceId) else {
            print("[BLE] setShortPressDelay: device not in connected set \(deviceId)")
            return
        }

        guard let p = peripheralForId(deviceId) else {
            print("[BLE] setShortPressDelay: no peripheral for \(deviceId)")
            return
        }

        guard let ch = cfgCharacteristicForId(deviceId) else {
            print("[BLE] setShortPressDelay: no CFG characteristic for \(deviceId)")
            return
        }

        // ✅ Must have a real base byte; never fall back to 0x00.
        guard let base = (ch.value?.first ?? configByteById[deviceId]) else {
            print("[BLE] setShortPressDelay aborted: no base byte yet for \(deviceId)")
            return
        }

        let d = min(delay, 15)
        let newByte = cfgByteSettingDelay(base, delay: d)

        // Skip if no change
        if newByte == base {
            return
        }

        let writeType: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse

        configByteById[deviceId] = newByte
        batteryLevelById[deviceId] = DeviceConfig(byte: newByte).batteryLevel // optional

        if selected?.id == deviceId {
            config = DeviceConfig(byte: newByte)
        }

        p.writeValue(Data([newByte]), for: ch, type: writeType)
        print("[BLE] Wrote CFG(\(deviceId)) base=0x\(String(format: "%02X", base)) new=0x\(String(format: "%02X", newByte)) [delay=\(d)]")
    }
    
    private func peripheralForId(_ id: UUID) -> CBPeripheral? {
        if let p = session(for: id).peripheral { return p }
        return devices.first(where: { $0.id == id })?.peripheral
    }

    private func cfgCharacteristicForId(_ id: UUID) -> CBCharacteristic? {
        if let ch = session(for: id).cfgCharacteristic { return ch }
        return cfgCharacteristicById[id]
    }

    private func fwvCharacteristicForId(_ id: UUID) -> CBCharacteristic? {
        if let ch = session(for: id).fwvCharacteristic { return ch }
        return fwvCharacteristicById[id]
    }
    
    //MARK: FROM URL
    func startDfuFromURL(for deviceId: UUID, fileURL: URL) {
        focusDevice(deviceId)
        selectedId = deviceId

        let s = session(for: deviceId)

        guard s.mcumgrTransport != nil else {
            dfuErrorText = "SMP not ready for this device"
            return
        }

        do {
            let pkg = try McuMgrPackage(from: fileURL)
            targetImageHash = pkg.images.first?.hash

            var config = FirmwareUpgradeConfiguration()
            config.upgradeMode = .confirmOnly
            config.pipelineDepth = 2

            let mgr = FirmwareUpgradeManager(transport: s.mcumgrTransport!, delegate: self)
            dfuManager = mgr

            s.lastUpgraded = true

            dfuInProgress = true
            dfuProgress = 0
            dfuStateText = "Starting OTA…"

            print("[DFU] Starting OTA from file: \(fileURL.lastPathComponent)")

            mgr.start(package: pkg, using: config)

        } catch {
            dfuInProgress = false
            dfuErrorText = "DFU setup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - START DFU
    func startDfu(for deviceId: UUID, resourceName: String, ext: String) {
        focusDevice(deviceId)
        selectedId = deviceId

        let s = session(for: deviceId)

        // Ensure transport exists before proceeding
        guard s.mcumgrTransport != nil else {
            dfuErrorText = "SMP not ready for this device (missing SMP characteristic)."
            return
        }

        // Mark DFU target + reboot window
        s.lastUpgraded = true
        s.manualDisconnectRequested = false
        s.awaitingRebootUntil = Date().addingTimeInterval(360)

        startDfu(resourceName: resourceName, ext: ext)
    }
    
    func startDfu(resourceName: String, ext: String = "bin") {
        dfuErrorText = nil
        dfuEffectiveSuccess = false

        // Target is always the currently focused device
        guard let id = selectedId else {
            dfuErrorText = "No selected device"
            return
        }

        // Connection truth should be per-device, not the global selected-only UI state
        guard connectedDeviceIDs.contains(id) else {
            dfuErrorText = "Not connected"
            return
        }

        let s = session(for: id)

        guard let p = s.peripheral else {
            dfuErrorText = "No peripheral for selected device"
            return
        }
        
        guard let transport = s.mcumgrTransport else {
            dfuErrorText = "SMP not ready (missing transport)"
            return
        }


        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext) else {
            dfuErrorText = "\(resourceName).\(ext) not found in app bundle"
            return
        }

        do {
            let pkg = try McuMgrPackage(from: url)
            targetImageHash = pkg.images.first?.hash

            var config = FirmwareUpgradeConfiguration()
            config.upgradeMode = .confirmOnly
            config.pipelineDepth = 2

            // Manager bound to THIS device’s transport only
            let mgr = FirmwareUpgradeManager(transport: transport, delegate: self)
            dfuManager = mgr

            // Per-device DFU flags (keep global UI flags for now)
            s.lastUpgraded = true
            

            print("[DFU] Starting DFU for device: \(id.uuidString) peripheral=\(p.identifier.uuidString)")

            dfuInProgress = true
            dfuProgress = 0
            dfuStateText = "Starting…"

            mgr.start(package: pkg, using: config)
        } catch {
            dfuInProgress = false
            dfuErrorText = "DFU setup failed: \(error.localizedDescription)"
        }
    }




    func cancelDfu() {
        dfuManager?.cancel()
    }
    
}

// MARK: - CBCentralManagerDelegate

extension BleScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isPoweredOn = (central.state == .poweredOn)
        print("[BLE] Central state: \(central.state.rawValue)")

        // Optional: auto-stop scan if BLE turns off
        if !isPoweredOn {
            stopScan()
        }
    }
    //MARK: didDiscover
    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Relay bootloader detection — the OTAFIX bootloader advertises the
        // legacy DFU service under a board-specific name, so match the service,
        // never the name. These never join the normal device list.
        let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advServices.contains(legacyDfuUuids.service) {
            if !relayBootloaderIds.contains(peripheral.identifier) {
                print("[RelayDFU] Bootloader advertising: \(peripheral.identifier)")
                relayBootloaderIds.append(peripheral.identifier)
            }
            bootloaderPeripherals[peripheral.identifier] = peripheral
            return
        }

        guard let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, advName.localizedCaseInsensitiveContains("rareBit") else { return }

        // Only list devices meant for this app. Ideal: advertisement carries the
        // config service UUID. Reality (relay-v1.9): firmware only gates the
        // GATT table — the docked advertisement carries NO service UUIDs, and
        // the active one carries only the watch-facing Relay Service.
        // TEMP: accept empty-adv rareBit devices until firmware advertises the
        // config UUID while docked; still reject Relay-Service advertisers.
        let passesServiceFilter = advServices.contains(cfgUuids.service) || advServices.isEmpty
        guard passesServiceFilter else {
            print("[BLE] ⏭ Skipped \(advName): not a config-service advertisement (adv=[\(advServices.map(\.uuidString).joined(separator: ", "))])")
            return
        }

        let nameForFilter = advName
        let rssiValue = RSSI.intValue
        
        guard nameForFilter.localizedCaseInsensitiveContains("rareBit") else {
            return
        }

        let new = DiscoveredDevice(
            id: peripheral.identifier,
            peripheral: peripheral,
            advertisedName: advName,
            rssi: rssiValue
        )

        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx] = new
        } else {
            devices.append(new)
        }
        print("[BLE] Discovered: \(advName) RSSI=\(rssiValue)")

        // Auto-reconnect after DFU reboot (session-based)
        let id = peripheral.identifier
        if let s = sessions[id],
           s.manualDisconnectRequested == false,
           s.lastUpgraded == true,
           let until = s.awaitingRebootUntil,
           Date() <= until,
           isDisconnectedOrFailed {

            print("[DFU] Found rebooted device in scan — reconnecting…")
            select(new)
            connectSelected()
        }

    }
    //MARK: didConnect
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        let s = session(for: peripheral)

        connectingDeviceIDs.remove(id)
        connectedDeviceIDs.insert(id)
        assignColorIfNeeded(for: id)

        s.connState = .connected

        // Only selected drives these single UI vars
        if selectedId == id {
            connectionState = .connected

            // Clear DFU UI state on each fresh connection (selected device only)
            dfuInProgress = false
            dfuProgress = 0
            dfuStateText = ""
            dfuErrorText = nil
            dfuUpgradeState = nil
            dfuEffectiveSuccess = false
        }

        print("[BLE] Connected \(id). Discovering services…")
        peripheral.discoverServices([SmpUuids.service, cfgUuids.service])

        if batteryLevelById[id] == nil {
            batteryLevelById[id] = .unknown
        }
    }

    //MARK: didFailtoConnect
    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectingDeviceIDs.remove(peripheral.identifier)
        connectedDeviceIDs.remove(peripheral.identifier)
        releaseColor(for: peripheral.identifier)
        
        
        print("[BLE] Failed to connect: \(error?.localizedDescription ?? "Unknown")")
        connectionState = .failed(error?.localizedDescription ?? "Failed to connect")
    }
    //MARK: didDisconnectPeripheral
    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        let s = session(for: id)

        session(for: peripheral).connectWatchdog?.cancel()
        connectingDeviceIDs.remove(id)
        connectedDeviceIDs.remove(id)

        batteryLevelById.removeValue(forKey: id)
        cfgCharacteristicById.removeValue(forKey: id)
        fwvCharacteristicById.removeValue(forKey: id)

        s.cfgCharacteristic = nil
        s.fwvCharacteristic = nil
        s.hasSmpCharacteristic = false
        s.hasConfigCharacteristic = false
        s.hasFwVersionCharacteristic = false
        s.servicesDiscovered = false

        print("[BLE] Disconnected \(id): \(error?.localizedDescription ?? "No error")")
        
        let now = Date()
        // DFU reboot expectation is per-device now
        if let until = s.awaitingRebootUntil, now <= until {
            print("[DFU] \(id) disconnected within expected reboot window")
            s.connState = .idle
            if selectedId == id { connectionState = .idle }
        } else if let error {
            s.connState = .failed(error.localizedDescription)
            if selectedId == id { connectionState = .failed(error.localizedDescription) }
        } else {
            s.connState = .idle
            if selectedId == id { connectionState = .idle }
        }


        // Only clear selected UI state if the disconnected device is the one selected
        if selectedId == id {
            syncSelectedUIFromSession()

            // Tear down DFU transport for selected device only
            
            dfuManager = nil
            dfuController = nil
        }

        if isPoweredOn, !isScanning {
            startScan()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleScanner: CBPeripheralDelegate {
    //MARK: didDiscoverServices
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        session(for: peripheral).connectWatchdog?.cancel()

        let id = peripheral.identifier
        let s = session(for: peripheral)

        if let error {
            s.connState = .failed(error.localizedDescription)
            if selectedId == id { connectionState = .failed(error.localizedDescription) }
            return
        }

        s.servicesDiscovered = true
        print("[BLE] Services discovered for \(id): \(peripheral.services?.map { $0.uuid.uuidString } ?? [])")

        let smp = peripheral.services?.first(where: { $0.uuid == SmpUuids.service })
        s.hasSmpService = (smp != nil)
        if let smpService = smp {
            peripheral.discoverCharacteristics([SmpUuids.characteristic], for: smpService)
        }

        let cfg = peripheral.services?.first(where: { $0.uuid == cfgUuids.service })
        s.hasConfigService = (cfg != nil)
        if let cfgService = cfg {
            peripheral.discoverCharacteristics([cfgUuids.cfg_characteristic, cfgUuids.fwv_characteristic, cfgUuids.dfu_trigger_characteristic], for: cfgService)
        }

        if selectedId == id {
            syncSelectedUIFromSession()
        }
    }

//MARK: didDiscoverCharacteristicsFor
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let id = peripheral.identifier
        let s = session(for: peripheral)

        if let error {
            s.connState = .failed(error.localizedDescription)
            if selectedId == id { connectionState = .failed(error.localizedDescription) }
            return
        }

        guard service.uuid == SmpUuids.service || service.uuid == cfgUuids.service else { return }

        if service.uuid == SmpUuids.service {
            let ch = service.characteristics?.first(where: { $0.uuid == SmpUuids.characteristic })
            s.hasSmpCharacteristic = (ch != nil)

            if s.hasSmpCharacteristic {
                // Create per-device transport (THIS is what DFU uses)
                s.mcumgrTransport = McuMgrBleTransport(peripheral)
                print("[BLE] SMP transport ready for \(id)")
            } else {
                s.mcumgrTransport = nil
            }

            if selectedId == id {
                syncSelectedUIFromSession()
            }
        }

        if service.uuid == cfgUuids.service {
            // CFG characteristic
            if let cfgCh = service.characteristics?.first(where: { $0.uuid == cfgUuids.cfg_characteristic }) {
                s.cfgCharacteristic = cfgCh
                s.hasConfigCharacteristic = true

                // keep your existing caches if you still want them
                cfgCharacteristicById[id] = cfgCh

                if cfgCh.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: cfgCh)
                }
                peripheral.readValue(for: cfgCh)

                print("[BLE] CFG characteristic ready for \(id)")
            }

            // DFU trigger characteristic (Relay, USB-docked only)
            if let trigCh = service.characteristics?.first(where: { $0.uuid == cfgUuids.dfu_trigger_characteristic }) {
                dfuTriggerCharacteristicById[id] = trigCh
                print("[RelayDFU] DFU trigger characteristic ready for \(id)")
            }

            // FWV characteristic
            if let fwCh = service.characteristics?.first(where: { $0.uuid == cfgUuids.fwv_characteristic }) {
                s.fwvCharacteristic = fwCh
                s.hasFwVersionCharacteristic = true

                fwvCharacteristicById[id] = fwCh

                peripheral.readValue(for: fwCh)
                print("[BLE] FWV characteristic ready for \(id)")
            }
        }

        if selectedId == id {
            syncSelectedUIFromSession()
        }
    }

    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        
        guard characteristic.uuid == cfgUuids.cfg_characteristic else { return }
        if let error {
            print("Failed to update notify state: \(error.localizedDescription)")
        } else {
            print("Notify state for config is now: \(characteristic.isNotifying)")
            print("[BLE] Notification state updated successfully")
        }
    }
//MARK: didUpdateValueFor
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[BLE] didUpdateValueFor error: \(error.localizedDescription) ch=\(characteristic.uuid)")
            return
        }

        guard let data = characteristic.value, let byte = data.first else { return }

        let id = peripheral.identifier
        let s = session(for: id)

        if characteristic.uuid == cfgUuids.cfg_characteristic {
            let cfg = DeviceConfig(byte: byte)

            s.configByte = byte
            s.batteryLevel = cfg.batteryLevel

            // keep your published maps if you want list UI to read them
            configByteById[id] = byte
            batteryLevelById[id] = cfg.batteryLevel

            print("[BLE] CFG(\(id)) =0x\(String(format: "%02X", byte)) SHPrs=\(cfg.shortPressEnabled) Delay=\((Int(cfg.shortPressDelay) * 20)) Batt=\(cfg.batteryLevel.rawValue)")

            if selectedId == id {
                syncSelectedUIFromSession()
            }
            return
        }

        if characteristic.uuid == cfgUuids.fwv_characteristic {
            let major = Int((byte & 0xF0) >> 4)
            let minor = Int(byte & 0x0F)
            let versionString = "\(major).\(minor)"

            s.firmwareVersion = versionString

            print("[BLE] FWV(\(id)) Raw=0x\(String(format: "%02X", byte)) Parsed=\(versionString)")

            if selectedId == id {
                syncSelectedUIFromSession()
            }
            return
        }
    }


    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {

        if characteristic.uuid == cfgUuids.dfu_trigger_characteristic {
            if let error {
                relayTriggerContinuation?.resume(throwing: Self.mapTriggerError(error))
            } else {
                // Write response received — device reboots into the bootloader
                // ~500 ms from now. The coming disconnect IS the success signal.
                print("[RelayDFU] Trigger accepted")
                relayTriggerContinuation?.resume(returning: ())
            }
            relayTriggerContinuation = nil
            return
        }

        guard characteristic.uuid == cfgUuids.cfg_characteristic else { return }
        if let error {
            print("Config write error: \(error.localizedDescription)")
            // On error, request a fresh read to sync UI with device
            
        } else {
            print("[BLE] CFG write success")
        }
    }
}

extension BleScanner: FirmwareUpgradeDelegate {
    
    private func verifyTargetImagePresentThenMarkSuccess() {
        guard let id = selectedId else { return }
        let s = session(for: id)
        guard let transport = s.mcumgrTransport, let targetHash = targetImageHash else { return }


        let imgMgr = ImageManager(transport: transport)

        imgMgr.list { [weak self] response, error in
            guard let self else { return }
            guard error == nil, let images = response?.images else { return }

            let found = images.contains { Data($0.hash) == targetHash }
            if found {
                Task { @MainActor in
                    self.dfuEffectiveSuccess = true
                    self.dfuStateText = "Update accepted — rebooting…"
                }
            }
        }
    }

    func upgradeDidStart(controller: FirmwareUpgradeController) {
        dfuController = controller
        dfuInProgress = true
        dfuStateText = "Started"
    }

    func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        Task { @MainActor in
            dfuProgress = imageSize > 0 ? Double(bytesSent) / Double(imageSize) : 0
            dfuStateText = "Uploading… \(Int(dfuProgress * 100))%"
        }
    }

    func upgradeStateDidChange(from previousState: FirmwareUpgradeState, to newState: FirmwareUpgradeState) {
        Task { @MainActor in
            self.dfuUpgradeState = newState
            self.dfuStateText = "\(newState)"
        }

        switch newState {
        case .reset:
            // Just before device disconnects and reboots
            print("[DFU] State: reset — device will reboot")
            verifyTargetImagePresentThenMarkSuccess()
            
            // Allow a long reboot window where disconnects are expected
            if let id = selectedId {
                session(for: id).awaitingRebootUntil = Date().addingTimeInterval(360)
                session(for: id).manualDisconnectRequested = false
            }
            
            self.dfuStateText = "Resetting device… awaiting reboot"
        case .success:
            print("[DFU] State: success")
        default:
            print("[DFU] State: \(newState)")
        }
    }


    func upgradeDidComplete() {
        print("[DFU] Upgrade complete — awaiting reboot…")
        dfuInProgress = false
        dfuProgress = 1.0
        dfuStateText = "Complete — device rebooting (this may take a few minutes)…"

        guard let targetId = selectedId else {
            dfuStateText = "Complete — no target id"
            return
        }

        let s = session(for: targetId)
        s.lastUpgraded = true
        s.manualDisconnectRequested = false
        s.awaitingRebootUntil = Date().addingTimeInterval(360)

        // Disconnect WITHOUT marking manual intent
        disconnect(deviceId: targetId, manual: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self else { return }

            // optional scan pulse
            if !self.isScanning {
                self.startScan()
                DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
                    self?.stopScan()
                }
            }

            if let d = self.devices.first(where: { $0.id == targetId }) {
                print("[DFU] Reconnecting to upgraded device")
                self.select(d)
                self.connectSelected()
            } else {
                self.dfuStateText = "Complete — device not found (yet)"
                print("[DFU] Device not found yet; continuing to scan")
            }
        }
    }


    func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        dfuInProgress = false
        dfuStateText = "Failed"
        dfuErrorText = error.localizedDescription
        print("[DFU] Upgrade failed in state \(state): \(error.localizedDescription)")
    }

    func upgradeDidCancel(state: FirmwareUpgradeState) {
        dfuInProgress = false
        dfuStateText = "Canceled"
        print("[DFU] Upgrade canceled in state \(state)")
    }
    
    // Maps FirmwareUpgradeState to a human-readable string
    private func statusString(for state: FirmwareUpgradeState) -> String {
        switch state {
        case .none:
            return "Idle"
        case .requestMcuMgrParameters:
            return "Requesting parameters…"
        case .validate:
            return "Validating…"
        case .upload:
            return "Uploading…"
        case .test:
            return "Testing image…"
        case .confirm:
            return "Confirming image…"
        case .reset:
            return "Resetting device…"
        case .success:
            return "Success"
        case .eraseAppSettings:
            return "Erasing settings…"
        case .resetIntoFirmwareLoader:
            return "Resetting into firmware loader…"
        case .bootloaderInfo:
            return "Reading bootloader info…"
        @unknown default:
            return "Unknown"
        }
    }
}


