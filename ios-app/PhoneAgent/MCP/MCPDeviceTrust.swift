import Foundation

/// Flat trust table: one entry per approved device identity with its last
/// connection time. Presence in the table is the trust grant itself.
struct MCPTrustedDevice: Codable, Equatable, Identifiable, Sendable {
    let identity: String
    var lastConnected: Date
    var id: String { identity }
}

enum MCPDeviceIdentity {
    /// `<host>.local-<client>` when a `.local` name resolved, else `<ip>-<client>`.
    static func make(host: String?, address: String, clientName: String?) -> String {
        let client = clientName?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)
        let origin = host?.lowercased() ?? address
        return origin + "-" + ((client?.isEmpty ?? true) ? "unknown" : String(client!))
    }
}

protocol MCPTrustStorage {
    func load() -> [MCPTrustedDevice]
    func save(_ devices: [MCPTrustedDevice])
}

final class MCPTrustFileStore: MCPTrustStorage {
    private let file: URL
    init(directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PhoneAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        file = root.appendingPathComponent("mcp-trusted-devices-v1.json")
    }
    func load() -> [MCPTrustedDevice] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([MCPTrustedDevice].self, from: data)) ?? []
    }
    func save(_ devices: [MCPTrustedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        // Background MCP use may happen while locked after first unlock.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

final class MCPTrustMemoryStore: MCPTrustStorage {
    var devices: [MCPTrustedDevice] = []
    func load() -> [MCPTrustedDevice] { devices }
    func save(_ devices: [MCPTrustedDevice]) { self.devices = devices }
}
