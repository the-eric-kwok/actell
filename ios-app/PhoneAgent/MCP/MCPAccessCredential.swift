import Foundation
import CryptoKit

/// Shared access password for the LAN MCP server. Possession of the current
/// password is the full input authorization; rotation revokes every client.
enum MCPAccessCredential {
    static let account = "mcp:accessPassword"
    static let minimumCustomLength = 16

    static let generatedLength = 18
    private static let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz")
    private static let digits = Array("23456789")
    // Header/JSON-safe symbols only: no quotes, backslash or whitespace.
    private static let symbols = Array("!@#$%^&*-_=+?.:;")

    /// 18 mixed-class characters (letters, digits, symbols) ≈ 112 bits of
    /// entropy, rejection-sampled to avoid modulo bias.
    static func generate() -> String {
        let alphabet = letters + digits + symbols
        while true {
            var characters: [Character] = []
            while characters.count < generatedLength {
                var byte: UInt8 = 0
                if SecRandomCopyBytes(kSecRandomDefault, 1, &byte) != errSecSuccess {
                    byte = Array(SHA256.hash(data: Data(UUID().uuidString.utf8))).first ?? 0
                }
                guard byte < alphabet.count * (256 / alphabet.count) else { continue }
                characters.append(alphabet[Int(byte) % alphabet.count])
            }
            let value = String(characters)
            if value.contains(where: letters.contains), value.contains(where: digits.contains),
               value.contains(where: symbols.contains) { return value }
        }
    }

    static func load() throws -> String? { try SecretStore.load(account) }

    @discardableResult
    static func loadOrCreate() throws -> String {
        if let existing = try SecretStore.load(account), !existing.isEmpty { return existing }
        let value = generate()
        try SecretStore.save(value, account: account)
        return value
    }

    static func rotate() throws -> String {
        let value = generate()
        try SecretStore.save(value, account: account)
        return value
    }

    static func setCustom(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCustomLength, trimmed.utf8.count <= 128,
              trimmed.allSatisfy({ !$0.isWhitespace && $0.isASCII }) else {
            throw AppError.invalid("自定义密码需至少 \(minimumCustomLength) 个 ASCII 字符，不含空白，最长 128 字节")
        }
        try SecretStore.save(trimmed, account: account)
    }

    /// Constant-time comparison over fixed-length digests, independent of input length.
    static func matches(presented: String, stored: String) -> Bool {
        let a = SHA256.hash(data: Data(presented.utf8))
        let b = SHA256.hash(data: Data(stored.utf8))
        return a.withUnsafeBytes { left in
            b.withUnsafeBytes { right in
                var difference: UInt8 = 0
                for i in 0..<left.count { difference |= left[i] ^ right[i] }
                return difference == 0
            }
        }
    }
}
