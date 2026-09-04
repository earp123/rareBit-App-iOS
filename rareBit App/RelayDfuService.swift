//
//  RelayDfuService.swift
//  rareBit App
//
//  Firmware release fetching for ALL rareBit products from the public
//  rareBit-firmware-releases repo (manifest.json + SHA-256 verification),
//  plus the Relay's Nordic legacy-DFU flasher.
//
//  Transport per product is unchanged by this layer:
//    flag / rx / rxrly → SMP (McuManager) upload of the verified .bin
//    relay             → legacy DFU flash of the verified dfu zip
//

import Foundation
import CryptoKit
import NordicDFU

// MARK: - Products

enum FirmwareProduct: String, CaseIterable {
    case relay          // XIAO relay — legacy DFU (OTAFIX bootloader)
    case flag           // PRO Flag — SMP
    case rx             // PRO Receiver — SMP
    case rxrly          // PRO Receiver hardware running relay firmware (v10+) — SMP

    /// Release tags are "<product>-v<version>", e.g. "flag-v1.9".
    var tagPrefix: String { "\(rawValue)-v" }
}

// MARK: - Manifest

/// Union of the manifest schemas: relay releases carry dfu_package(+sha)/uf2;
/// SMP releases carry ota_image(+sha)/dfu_package/merged_hex.
struct FirmwareManifest: Decodable {
    let product: String
    let tag: String
    let release_tag: String
    let fw_version_byte: String       // e.g. "0x19", "0xa0"

    let ota_image: String?
    let ota_image_sha256: String?
    let dfu_package: String?
    let dfu_package_sha256: String?
    let uf2: String?
    let merged_hex: String?
    let board: String?

    /// High nibble = major, low nibble = minor (0x1A = v1.10, 0xa0 = v10.0)
    var versionByte: UInt8? {
        let hex = fw_version_byte.lowercased().hasPrefix("0x")
            ? String(fw_version_byte.dropFirst(2))
            : fw_version_byte
        return UInt8(hex, radix: 16)
    }
}

struct FirmwareUpdateRelease {
    let manifest: FirmwareManifest
    let release: GitHubRelease

    var version: FirmwareVersion? {
        manifest.versionByte.map { FirmwareVersion(byte: $0) }
    }
}

enum FirmwareReleaseError: LocalizedError {
    case noReleaseForProduct(String)
    case manifestMissing
    case wrongProduct(want: String, got: String)
    case badVersionByte
    case assetMissing(String)
    case checksumMismatch(String)
    // Relay legacy-DFU specific:
    case notDocked
    case triggerUnavailable
    case triggerRejected(String)
    case bootloaderNotFound
    case flashFailed(String)

    var errorDescription: String? {
        switch self {
        case .noReleaseForProduct(let p): return "No published release found for '\(p)'"
        case .manifestMissing:            return "Release has no manifest.json"
        case .wrongProduct(let w, let g): return "Release manifest is for '\(g)', expected '\(w)'"
        case .badVersionByte:             return "Manifest firmware version is malformed"
        case .assetMissing(let n):        return "Release is missing asset '\(n)'"
        case .checksumMismatch(let n):    return "'\(n)' failed SHA-256 verification"
        case .notDocked:                  return "Relay rejected the trigger write (ATT 0x03) — its docked check failed. Dock it on USB power."
        case .triggerUnavailable:         return "Relay's GATT table has no update-trigger characteristic (0x2322…0004) — firmware may predate OTA support"
        case .triggerRejected(let m):     return "Relay rejected the update trigger: \(m)"
        case .bootloaderNotFound:         return "Relay did not reappear in update mode"
        case .flashFailed(let m):         return "Flashing failed: \(m)"
        }
    }
}

// MARK: - Release service

final class FirmwareReleaseService {

    static let shared = FirmwareReleaseService()
    private init() {}

    /// Public repo — unauthenticated, 60 req/hr/IP. Check once per app
    /// session per product; `cached` enforces that.
    private let releasesURL = URL(string:
        "https://api.github.com/repos/earp123/rareBit-firmware-releases/releases?per_page=30")!

    private var cachedReleaseList: [GitHubRelease]?
    private var cached: [FirmwareProduct: FirmwareUpdateRelease] = [:]

    /// Latest release for a product, found by tag prefix and highest version —
    /// NOT /latest, which is meaningless now that products share the repo.
    /// Old-style tags (PRO_FLAG_v1.9.0, RXRLY_v10.0.0…) don't match any
    /// prefix and are ignored.
    func latestRelease(for product: FirmwareProduct, forceRefresh: Bool = false) async throws -> FirmwareUpdateRelease {
        if let hit = cached[product], !forceRefresh { return hit }

        if cachedReleaseList == nil || forceRefresh {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            cachedReleaseList = try JSONDecoder().decode([GitHubRelease].self, from: data)
        }

        let candidates = (cachedReleaseList ?? [])
            .filter { $0.tag_name.hasPrefix(product.tagPrefix) }
        guard let best = candidates.max(by: {
            FirmwareVersion(String($0.tag_name.dropFirst(product.tagPrefix.count)))
                < FirmwareVersion(String($1.tag_name.dropFirst(product.tagPrefix.count)))
        }) else {
            throw FirmwareReleaseError.noReleaseForProduct(product.rawValue)
        }

        guard let manifestAsset = best.assets.first(where: { $0.name == "manifest.json" }) else {
            throw FirmwareReleaseError.manifestMissing
        }
        let manifest = try JSONDecoder().decode(
            FirmwareManifest.self, from: try await downloadAsset(manifestAsset))

        guard manifest.product == product.rawValue else {
            throw FirmwareReleaseError.wrongProduct(want: product.rawValue, got: manifest.product)
        }
        guard manifest.versionByte != nil else { throw FirmwareReleaseError.badVersionByte }

        let update = FirmwareUpdateRelease(manifest: manifest, release: best)
        cached[product] = update
        print("[FW] Latest for \(product.rawValue): \(best.tag_name) → \(manifest.fw_version_byte)")
        return update
    }

    func updateAvailable(for product: FirmwareProduct, currentVersionByte: UInt8,
                         forceRefresh: Bool = false) async throws -> (update: FirmwareUpdateRelease, needsUpdate: Bool) {
        let update = try await latestRelease(for: product, forceRefresh: forceRefresh)
        return (update, (update.manifest.versionByte ?? 0) > currentVersionByte)
    }

    /// Relay: the legacy-DFU zip, verified against dfu_package_sha256.
    func downloadVerifiedPackage(_ update: FirmwareUpdateRelease) async throws -> URL {
        guard let name = update.manifest.dfu_package,
              let sha = update.manifest.dfu_package_sha256 else {
            throw FirmwareReleaseError.assetMissing("dfu_package")
        }
        return try await downloadVerified(named: name, sha256: sha, from: update)
    }

    /// SMP products: the .bin McuManager uploads, verified against ota_image_sha256.
    func downloadVerifiedOtaImage(_ update: FirmwareUpdateRelease) async throws -> URL {
        guard let name = update.manifest.ota_image,
              let sha = update.manifest.ota_image_sha256 else {
            throw FirmwareReleaseError.assetMissing("ota_image")
        }
        return try await downloadVerified(named: name, sha256: sha, from: update)
    }

    private func downloadVerified(named name: String, sha256: String,
                                  from update: FirmwareUpdateRelease) async throws -> URL {
        guard let asset = update.release.assets.first(where: { $0.name == name }) else {
            throw FirmwareReleaseError.assetMissing(name)
        }
        let data = try await downloadAsset(asset)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else {
            print("[FW] ❌ SHA mismatch for \(name): got \(digest) want \(sha256)")
            throw FirmwareReleaseError.checksumMismatch(name)
        }

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        print("[FW] ✅ \(name) verified (\(data.count) bytes)")
        return dest
    }

    private func downloadAsset(_ asset: Asset) async throws -> Data {
        guard let url = URL(string: asset.browser_download_url) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Legacy DFU flasher (Relay only)

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
        onFinish?(.failure(FirmwareReleaseError.flashFailed(message)))
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
