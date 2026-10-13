import Foundation
import Network

/// Connection origin used for rate limiting and device identity.
struct MCPPeer: Sendable, Hashable {
    let address: String

    init(address: String) { self.address = address }
    init(endpoint: NWEndpoint) {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let v4): address = "\(v4)"
            case .ipv6(let v6): address = "\(v6)".components(separatedBy: "%").first ?? "\(v6)"
            case .name(let name, _): address = name
            @unknown default: address = endpoint.debugDescription
            }
        } else {
            address = endpoint.debugDescription
        }
    }

    /// Best-effort reverse lookup; only `.local` names are accepted, since
    /// unicast PTR answers are not meaningful for LAN device identity.
    /// getnameinfo blocks and cannot be cancelled, and a task group would wait
    /// for it; race it against the deadline so the slower side is abandoned.
    static func reverseLookup(_ address: String, timeout: TimeInterval = 2) async -> String? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let name = lookup(address)
                if once.claim() { continuation.resume(returning: name) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func lookup(_ address: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &host, socklen_t(host.count),
                          nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = String(cString: host).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.hasSuffix(".local") ? name : nil
    }
}
