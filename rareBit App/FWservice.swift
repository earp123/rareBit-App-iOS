import Foundation

// MARK: - Models

struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [Asset]
}

struct Asset: Decodable {
    let name: String
    let url: String                    // API URL — required for private repo downloads
    let browser_download_url: String
}

// MARK: - Version Handling

struct FirmwareVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int  // optional, defaults to 0
    
    /// Initialize from a semantic version string like "2.3" or "v2.3.1" or "PRO_FLAG_v2.3"
    init(_ string: String) {
        // Strip common prefixes and "v"
        let cleaned = string
            .replacingOccurrences(of: "PRO_FLAG_v", with: "")
            .replacingOccurrences(of: "PRO_RX_v", with: "")
            .replacingOccurrences(of: "RXRLY_v", with: "")
            .replacingOccurrences(of: "v", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let components = cleaned.split(separator: ".").compactMap { Int($0) }
        
        self.major = components.count > 0 ? components[0] : 0
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }
    
    /// Initialize from the 1-byte characteristic value
    /// Upper nibble = major version (0-15)
    /// Lower nibble = minor version (0-15)
    init(byte: UInt8) {
        self.major = Int((byte & 0xF0) >> 4)
        self.minor = Int(byte & 0x0F)
        self.patch = 0
    }
    
    /// Initialize directly
    init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    
    /// Encode to 1-byte format (ignores patch)
    /// Returns nil if major or minor > 15
    var asByte: UInt8? {
        guard major <= 15, minor <= 15, major >= 0, minor >= 0 else {
            return nil
        }
        return UInt8((major << 4) | minor)
    }
    
    var description: String {
        if patch > 0 {
            return "\(major).\(minor).\(patch)"
        } else {
            return "\(major).\(minor)"
        }
    }
    
    static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    
    static func == (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        return lhs.major == rhs.major && 
               lhs.minor == rhs.minor && 
               lhs.patch == rhs.patch
    }
}

// MARK: - Release Helpers

extension GitHubRelease {
    func firmwareAsset() -> Asset? {
        return assets.first { $0.name.hasSuffix(".bin") }
    }
}

// MARK: - Firmware Service

enum FirmwareUpdateError: LocalizedError {
    case noReleaseTag
    case versionUnknown
    case noAssetFound
    
    var errorDescription: String? {
        switch self {
        case .noReleaseTag:
            return "This device type does not have a firmware release configured"
        case .versionUnknown:
            return "Could not read current firmware version from device"
        case .noAssetFound:
            return "No firmware binary found in release"
        }
    }
}

final class FirmwareService {
    
    static let shared = FirmwareService()
    private init() {}
    
    private let repoBase = "https://api.github.com/repos/earp123/rareBit-Flags-Receivers"

    // Fetch release by tag from GitHub
    func fetchRelease(tag: String) async throws -> GitHubRelease {
        let url = URL(string: "\(repoBase)/releases/tags/\(tag)")!
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(Secrets.githubPAT)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            print("🌐 Status Code:", http.statusCode)
        }

        print("📦 Response Body:")
        //print(String(data: data, encoding: .utf8) ?? "nil")
        
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            print("❌ DECODE ERROR:", error)
            throw error
        }
    }
    
    // Fetch the latest release matching a tag prefix (e.g., "PRO_FLAG" finds "PRO_FLAG_v2.0")
    func fetchLatestRelease(matching tagPrefix: String) async throws -> GitHubRelease {
        let url = URL(string: "\(repoBase)/releases")!
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(Secrets.githubPAT)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        
        // Find the first release matching the prefix
        guard let matching = releases.first(where: { $0.tag_name.hasPrefix(tagPrefix) }) else {
            throw FirmwareUpdateError.noAssetFound
        }
        
        print("🔍 Found latest release for \(tagPrefix): \(matching.tag_name)")
        return matching
    }
    
    // Check if update is needed (from string version)
    func checkForUpdate(tag: String, currentVersion: String) async throws -> (release: GitHubRelease, needsUpdate: Bool) {
        // Fetch the release (will try exact tag, fallback to prefix if needed)
        let release = try await fetchReleaseWithFallback(tag: tag)
        
        let latest = FirmwareVersion(release.tag_name)
        let current = FirmwareVersion(currentVersion)
        
        print("🔍 Update check: Current=\(current) Latest=\(latest) from tag '\(release.tag_name)'")
        
        return (release, latest > current)
    }
    
    // Check if update is needed (from byte version)
    func checkForUpdate(tag: String, currentVersionByte: UInt8) async throws -> (release: GitHubRelease, needsUpdate: Bool) {
        // Fetch the release (will try exact tag, fallback to prefix if needed)
        let release = try await fetchReleaseWithFallback(tag: tag)
        
        let latest = FirmwareVersion(release.tag_name)
        let current = FirmwareVersion(byte: currentVersionByte)
        
        print("🔍 Version Check: Current=\(current) (\(String(format: "0x%02X", currentVersionByte))) vs Latest=\(latest) from tag '\(release.tag_name)'")
        
        return (release, latest > current)
    }
    
    // Get the latest firmware version for a tag without downloading
    func latestVersion(for tag: String) async throws -> FirmwareVersion {
        let release = try await fetchReleaseWithFallback(tag: tag)
        return FirmwareVersion(release.tag_name)
    }
    
    // Helper: Try exact tag first, fall back to prefix search if not found
    private func fetchReleaseWithFallback(tag: String) async throws -> GitHubRelease {
        do {
            // Try exact tag match first (e.g., "PRO_FLAG_v1.9.0")
            return try await fetchRelease(tag: tag)
        } catch {
            // If exact match fails, try prefix search (e.g., "PRO_FLAG" finds "PRO_FLAG_v1.9.0")
            // This is a safety fallback in case tags are misconfigured
            print("⚠️ Exact tag '\(tag)' not found, trying prefix search...")
            return try await fetchLatestRelease(matching: tag)
        }
    }
    
    // Download firmware file (uses API URL for private repo access)
    func downloadFirmware(from asset: Asset) async throws -> URL {
        guard let url = URL(string: asset.url) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(Secrets.githubPAT)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("⬇️ Download status:", http.statusCode)

        guard http.statusCode == 200 else {
            print("❌ Download failed body:")
            print(String(data: data, encoding: .utf8) ?? "nil")
            throw URLError(.badServerResponse)
        }

        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = docs.appendingPathComponent(asset.name)

        try? fileManager.removeItem(at: destination)
        try data.write(to: destination)

        print("✅ Saved firmware to:", destination)

        return destination
    }
}


