import Foundation

// MARK: - Models

struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [Asset]
}

struct Asset: Decodable {
    let name: String
    let browser_download_url: String
}

// MARK: - Version Handling

struct FirmwareVersion: Comparable {
    let components: [Int]
    
    init(_ string: String) {
        let cleaned = string.replacingOccurrences(of: "v", with: "")
        self.components = cleaned.split(separator: ".").compactMap { Int($0) }
    }
    
    static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        for (l, r) in zip(lhs.components, rhs.components) {
            if l != r { return l < r }
        }
        return lhs.components.count < rhs.components.count
    }
}

// MARK: - Release Helpers

extension GitHubRelease {
    func firmwareAsset() -> Asset? {
        return assets.first { $0.name.hasSuffix(".bin") }
    }
}

// MARK: - Firmware Service

final class FirmwareService {
    
    static let shared = FirmwareService()
    private init() {}
    
    // Fetch latest release from GitHub
    func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/earp123/rareBit-Flags-Receivers/releases/latest")!
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        
        
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            print("🌐 Status Code:", http.statusCode)
        }

        print("📦 Response Body:")
        print(String(data: data, encoding: .utf8) ?? "nil")
        
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            print("❌ DECODE ERROR:", error)
            throw error
        }
    }
    
    // Check if update is needed
    func checkForUpdate(currentVersion: String) async throws -> (release: GitHubRelease, needsUpdate: Bool) {
        let release = try await fetchLatestRelease()
        
        let latest = FirmwareVersion(release.tag_name)
        let current = FirmwareVersion(currentVersion)
        
        return (release, latest > current)
    }
    
    // Download firmware file
    func downloadFirmware(from asset: Asset) async throws -> URL {
        let urlString = asset.browser_download_url
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        

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


