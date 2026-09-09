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

    /// Development builds live in the private firmware repo under its older
    /// naming, e.g. "PRO_FLAG_v2.0.0-dev.57". The Relay has no dev channel.
    var devTagPrefix: String? {
        switch self {
        case .flag:  return "PRO_FLAG_"
        case .rx:    return "PRO_RX_"
        case .rxrly: return "RXRLY_"
        case .relay: return nil
        }
    }
}

// MARK: - Channel

/// Which repo a release came from, which decides how its assets are fetched:
/// the public repo serves `browser_download_url` anonymously, the private one
/// needs the asset API URL plus a PAT.
enum ReleaseChannel {
    case stable
    case development
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

    // Development-channel extras. Optional throughout, so public manifests —
    // which carry none of them — keep decoding unchanged.
    let channel: String?
    let build: Int?
    let full_version: String?
    let commit: String?
    let run_url: String?

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
    /// Defaults to stable so every existing construction site is unchanged.
    var channel: ReleaseChannel = .stable

    /// "2.0.0 build 57" for a dev release, else nil. Dev builds share a
    /// pinned version byte, so the build number is the only thing that
    /// distinguishes them.
    var devDescription: String? {
        guard channel == .development else { return nil }
        let v = manifest.full_version ?? version?.description ?? "?"
        let b = manifest.build.map(String.init) ?? "?"
        return "v\(v) (build \(b))"
    }

    var version: FirmwareVersion? {
        manifest.versionByte.map { FirmwareVersion(byte: $0) }
    }
}

enum FirmwareReleaseError: LocalizedError {
    case noReleaseForProduct(String)
    case noDevReleaseForProduct(String)
    case devNotSupported(String)
    case devChannelUnavailable
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
        case .noDevReleaseForProduct:     return "No dev release on 'development' yet"
        case .devNotSupported(let p):     return "'\(p)' has no development channel"
        case .devChannelUnavailable:      return "Development channel is unavailable in this build"
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

#if DEBUG
    /// Private firmware repo — PAT required. Dev builds only; the stable path
    /// never touches this. Debug-only so a Release binary carries no trace of
    /// the private repo, not just none of the token.
    private let devReleasesURL = URL(string:
        "https://api.github.com/repos/earp123/rareBit-Flags-Receivers/releases?per_page=30")!
#endif

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

#if DEBUG
    /// `PRO_FLAG_v2.0.0-dev.57` -> 57. The list arrives newest-first, but
    /// parsing the suffix is what actually orders these — trusting the order
    /// would be an assumption about GitHub, not a guarantee.
    private func devBuildNumber(from tag: String) -> Int? {
        guard let r = tag.range(of: "-dev.") else { return nil }
        return Int(tag[r.upperBound...])
    }

    /// Newest `development`-branch pre-release for a product.
    ///
    /// Deliberately never written into `cached`: dev builds churn, and that
    /// cache feeds the stable update path, which must not see them. A failed
    /// dev fetch therefore can't poison a later stable check.
    func latestDevRelease(for product: FirmwareProduct) async throws -> FirmwareUpdateRelease {
        guard let prefix = product.devTagPrefix else {
            throw FirmwareReleaseError.devNotSupported(product.rawValue)
        }

        var request = URLRequest(url: devReleasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(Secrets.githubPAT)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let candidates = try JSONDecoder().decode([GitHubRelease].self, from: data)
            .filter {
                $0.target_commitish == "development"
                    && $0.prerelease == true
                    && $0.tag_name.hasPrefix(prefix)
            }

        guard let best = candidates.max(by: {
            (devBuildNumber(from: $0.tag_name) ?? -1) < (devBuildNumber(from: $1.tag_name) ?? -1)
        }) else {
            throw FirmwareReleaseError.noDevReleaseForProduct(product.rawValue)
        }

        guard let manifestAsset = best.assets.first(where: { $0.name == "manifest.json" }) else {
            throw FirmwareReleaseError.manifestMissing
        }
        let manifest = try JSONDecoder().decode(
            FirmwareManifest.self,
            from: try await downloadAsset(manifestAsset, channel: .development))

        guard manifest.product == product.rawValue else {
            throw FirmwareReleaseError.wrongProduct(want: product.rawValue, got: manifest.product)
        }
        guard manifest.versionByte != nil else { throw FirmwareReleaseError.badVersionByte }

        print("[FW] dev \(best.tag_name) → \(manifest.fw_version_byte) build \(manifest.build.map(String.init) ?? "?")")
        return FirmwareUpdateRelease(manifest: manifest, release: best, channel: .development)
    }
#endif

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
        let data = try await downloadAsset(asset, channel: update.channel)

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

    /// Private-repo assets must be fetched through the asset API URL with
    /// `Accept: application/octet-stream` — `browser_download_url` 404s on a
    /// private repo. SHA-256 verification upstream is unchanged either way.
    private func downloadAsset(_ asset: Asset, channel: ReleaseChannel = .stable) async throws -> Data {
        let request: URLRequest

        switch channel {
        case .stable:
            guard let url = URL(string: asset.browser_download_url) else { throw URLError(.badURL) }
            request = URLRequest(url: url)

        case .development:
#if DEBUG
            guard let url = URL(string: asset.url) else { throw URLError(.badURL) }
            var r = URLRequest(url: url)
            r.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            r.setValue("Bearer \(Secrets.githubPAT)", forHTTPHeaderField: "Authorization")
            request = r
#else
            // No dev release can exist in a Release build — latestDevRelease
            // isn't compiled — so this is unreachable rather than a fallback.
            throw FirmwareReleaseError.devChannelUnavailable
#endif
        }

        let (data, response) = try await URLSession.shared.data(for: request)
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
