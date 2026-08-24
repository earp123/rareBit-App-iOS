//
//  RelayDfuService.swift
//  rareBit App
//
//  Relay OTA DFU per docs/relay-dfu-flow.md:
//  GitHub Releases (public repo, manifest.json) → SHA-256-verified dfu package
//  → Nordic legacy DFU flash via NordicDFU.
//

import Foundation
import CryptoKit
import NordicDFU

// MARK: - Manifest

struct RelayDfuManifest: Decodable {
    let product: String
    let tag: String
    let release_tag: String
    let fw_version_byte: String       // e.g. "0x19"
    let dfu_package: String
    let uf2: String
    let dfu_package_sha256: String

    /// High nibble = major, low nibble = minor (0x19 = v1.9)
    var versionByte: UInt8? {
        let hex = fw_version_byte.lowercased().hasPrefix("0x")
            ? String(fw_version_byte.dropFirst(2))
            : fw_version_byte
        return UInt8(hex, radix: 16)
    }
}

struct RelayUpdate {
    let manifest: RelayDfuManifest
    let packageAsset: Asset

    var version: FirmwareVersion? {
        manifest.versionByte.map { FirmwareVersion(byte: $0) }
    }
}

enum RelayDfuError: LocalizedError {
    case manifestMissing
    case wrongProduct(String)
    case badVersionByte
    case packageAssetMissing
    case checksumMismatch
    case notDocked
    case triggerUnavailable
    case triggerRejected(String)
    case bootloaderNotFound
    case flashFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:      return "Release has no manifest.json"
        case .wrongProduct(let p):  return "Release manifest is for '\(p)', not relay"
        case .badVersionByte:       return "Manifest firmware version is malformed"
        case .packageAssetMissing:  return "Release is missing the DFU package"
        case .checksumMismatch:     return "Downloaded package failed SHA-256 verification"
        case .notDocked:            return "Relay rejected the trigger write (ATT 0x03) — its docked check failed. Dock it on USB power."
        case .triggerUnavailable:   return "Relay's GATT table has no update-trigger characteristic (0x2322…0004) — firmware may predate OTA support"
        case .triggerRejected(let m): return "Relay rejected the update trigger: \(m)"
        case .bootloaderNotFound:   return "Relay did not reappear in update mode"
        case .flashFailed(let m):   return "Flashing failed: \(m)"
        }
    }
}

// MARK: - Update check + download

final class RelayDfuService {

    static let shared = RelayDfuService()
    private init() {}

    /// Public repo — unauthenticated, 60 req/hr/IP. Check once per app
    /// session, not on a timer; `cached` enforces that.
    private let latestURL = URL(string:
        "https://api.github.com/repos/earp123/rareBit-firmware-releases/releases/latest")!

    private var cached: RelayUpdate?

    // TODO: when receiver firmware shares this repo, /latest becomes
    // unreliable — switch to listing releases and filtering by tag prefix
    // "relay-" (or manifest product).
    func latestUpdate(forceRefresh: Bool = false) async throws -> RelayUpdate {
        if let cached, !forceRefresh { return cached }

        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        guard let manifestAsset = release.assets.first(where: { $0.name == "manifest.json" }) else {
            throw RelayDfuError.manifestMissing
        }
        let manifestData = try await downloadPublicAsset(manifestAsset)
        let manifest = try JSONDecoder().decode(RelayDfuManifest.self, from: manifestData)

        guard manifest.product == "relay" else { throw RelayDfuError.wrongProduct(manifest.product) }
        guard manifest.versionByte != nil else { throw RelayDfuError.badVersionByte }
        guard let package = release.assets.first(where: { $0.name == manifest.dfu_package }) else {
            throw RelayDfuError.packageAssetMissing
        }

        let update = RelayUpdate(manifest: manifest, packageAsset: package)
        cached = update
        print("[RelayDFU] Latest release: \(release.tag_name) → \(manifest.fw_version_byte)")
        return update
    }

    /// Update available when the release version byte exceeds the device's
    /// FW characteristic byte.
    func updateAvailable(currentVersionByte: UInt8, forceRefresh: Bool = false) async throws -> (update: RelayUpdate, needsUpdate: Bool) {
        let update = try await latestUpdate(forceRefresh: forceRefresh)
        let needs = (update.manifest.versionByte ?? 0) > currentVersionByte
        return (update, needs)
    }

    /// Download the DFU zip and verify SHA-256 against the manifest before
    /// handing it to the flasher.
    func downloadVerifiedPackage(_ update: RelayUpdate) async throws -> URL {
        let data = try await downloadPublicAsset(update.packageAsset)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == update.manifest.dfu_package_sha256.lowercased() else {
            print("[RelayDFU] ❌ SHA mismatch: got \(digest) want \(update.manifest.dfu_package_sha256)")
            throw RelayDfuError.checksumMismatch
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(update.packageAsset.name)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        print("[RelayDFU] ✅ Package verified (\(data.count) bytes) → \(dest.lastPathComponent)")
        return dest
    }

    private func downloadPublicAsset(_ asset: Asset) async throws -> Data {
        guard let url = URL(string: asset.browser_download_url) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Legacy DFU flasher

/// Thin wrapper around NordicDFU for the Relay's OTAFIX bootloader.
/// Feed the release zip unchanged — the library auto-detects the legacy
/// protocol; default settings (PRN on) are correct.
@MainActor
final class LegacyDfuFlasher: NSObject {

    var onProgress: ((Double) -> Void)?
    var onStateText: ((String) -> Void)?
    var onFinish: ((Result<Void, Error>) -> Void)?

    private var controller: DFUServiceController?

    func flash(zipURL: URL, targetIdentifier: UUID) throws {
        let firmware = try DFUFirmware(urlToZipFile: zipURL)
        let initiator = DFUServiceInitiator()   // delegate queues default to main
        initiator.delegate = self
        initiator.progressDelegate = self
        initiator.logger = self
        controller = initiator.with(firmware: firmware).start(targetWithIdentifier: targetIdentifier)
    }

    func abort() {
        _ = controller?.abort()
        controller = nil
    }
}

extension LegacyDfuFlasher: DFUServiceDelegate {
    func dfuStateDidChange(to state: DFUState) {
        onStateText?(state.description)
        if state == .completed {
            controller = nil
            onFinish?(.success(()))
        }
    }

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        print("[RelayDFU] ❌ DFU error \(error): \(message)")
        controller = nil
        onFinish?(.failure(RelayDfuError.flashFailed(message)))
    }
}

extension LegacyDfuFlasher: DFUProgressDelegate {
    func dfuProgressDidChange(for part: Int, outOf totalParts: Int,
                              to progress: Int,
                              currentSpeedBytesPerSecond: Double,
                              avgSpeedBytesPerSecond: Double) {
        onProgress?(Double(progress) / 100.0)
    }
}

extension LegacyDfuFlasher: LoggerDelegate {
    func logWith(_ level: LogLevel, message: String) {
        if level.rawValue >= LogLevel.info.rawValue {
            print("[RelayDFU] \(message)")
        }
    }
}
