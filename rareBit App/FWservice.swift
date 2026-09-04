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

// NOTE: the old private-repo FirmwareService (PAT-authenticated fetch from
// rareBit-Flags-Receivers by hardcoded release tag) was removed 2026-09-04.
// All products now fetch from the public rareBit-firmware-releases repo via
// FirmwareReleaseService (manifest.json + SHA-256, tag-prefix filtered).


