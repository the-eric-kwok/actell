import Foundation
import SwiftAgentKit
import UIKit

/// LAN MCP server state: authentication, Streamable HTTP sessions, and tool
/// dispatch onto per-session ActionCoordinators. Transport-agnostic so tests
/// drive it directly; MCPListener feeds it parsed HTTP requests.
@MainActor final class MCPServerModel: ObservableObject {
    static let portDefaultsKey = "mcpServerPort"
    static let loopbackOnlyDefaultsKey = "mcpLoopbackOnly"
    static let enabledDefaultsKey = "mcpServerEnabled"
    static let defaultPort: UInt16 = 27300
    static let sessionIdleTimeout: TimeInterval = 600
    static let failureDelayThreshold = 10

    static let trustRetention: TimeInterval = 7 * 24 * 3600
    static let deviceApprovalTimeout: Duration = .seconds(60)

    struct DeviceRequest: Identifiable, Equatable {
        let identity: String
        let clientVersion: String?
        var id: String { identity }
    }

    @Published private(set) var running = false
    @Published private(set) var statusText = "MCP 服务未开启"
    @Published private(set) var sessionCount = 0
    @Published private(set) var trustedDevices: [MCPTrustedDevice] = []
    /// Head of the pending queue is presented; later identities wait their turn.
    @Published private(set) var deviceRequest: DeviceRequest?
    private var deviceWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var deviceQueue: [DeviceRequest] = []
    private let trustStore: any MCPTrustStorage
    /// Injectable for tests; production performs a bounded `.local` reverse lookup.
    var resolveHost: (String) async -> String? = { await MCPPeer.reverseLookup($0) }
    /// Called when a device needs approval while the app is not frontmost.
    var notifyPendingDevice: @MainActor (String) -> Void = { _ in }

    /// nil while a local agent run owns the device; message explains the refusal.
    var localAgentBusyReason: @MainActor () -> String?
    /// Injectable for tests; defaults to the Keychain-backed credential.
    var loadPassword: () throws -> String? = { try MCPAccessCredential.load() }
    private let makeBridge: @MainActor () throws -> any DeviceBridge
    private let now: () -> Date
    private var listener: MCPListener?
    private var sessions: [String: Session] = [:]
    private var inFlightInputSession: String?
    private var authFailures: [String: Int] = [:]

    @MainActor final class Session {
        let id: String
        let identity: String
        let coordinator: ActionCoordinator
        var initialized = false
        var lastActivity: Date
        var pendingCalls = 0
        init(id: String, identity: String, coordinator: ActionCoordinator, now: Date) {
            self.id = id; self.identity = identity; self.coordinator = coordinator; lastActivity = now
        }
    }

    init(makeBridge: @escaping @MainActor () throws -> any DeviceBridge,
         localAgentBusyReason: @escaping @MainActor () -> String? = { nil },
         trustStore: any MCPTrustStorage = MCPServerModel.defaultTrustStore(),
         now: @escaping () -> Date = Date.init) {
        self.makeBridge = makeBridge
        self.localAgentBusyReason = localAgentBusyReason
        self.trustStore = trustStore
        self.now = now
        trustedDevices = trustStore.load()
        pruneExpiredDevices()
    }

    nonisolated static func defaultTrustStore() -> any MCPTrustStorage {
        (try? MCPTrustFileStore()) ?? MCPTrustMemoryStore()
    }

    var hasInFlightInput: Bool { inFlightInputSession != nil }
    static var configuredPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portDefaultsKey)
        return (1024...65535).contains(stored) ? UInt16(stored) : defaultPort
    }

    // MARK: 服务开关

    func start() {
        guard !running else { return }
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        let password: String
        do { password = try MCPAccessCredential.loadOrCreate() }
        catch { statusText = "访问密码不可用：\(AppError.unavailable("钥匙串读写失败").localizedDescription)"; return }
        _ = password
        let port = Self.configuredPort
        let loopbackOnly = UserDefaults.standard.bool(forKey: Self.loopbackOnlyDefaultsKey)
        let serviceName = UIDevice.current.name
        let incoming = MCPListener(port: port, loopbackOnly: loopbackOnly, serviceName: serviceName) { [weak self] request, source in
            await self?.handle(request, source: source) ?? MCPHTTP.Response.empty(503)
        }
        incoming.onStateChange = { [weak self] failure in
            Task { @MainActor in
                guard let self, self.listener === incoming else { return }
                if let failure, failure.hasPrefix("waiting:") {
                    self.statusText = "监听等待中：\(failure.dropFirst(8))（检查本地网络权限或网络状态）"
                } else if let failure {
                    self.stop(reason: "监听失败：\(failure)（端口可能被占用，请换端口重试）")
                } else {
                    self.statusText = loopbackOnly ? "仅监听本机回环 127.0.0.1:\(port)；不广播 Bonjour"
                                                   : "监听端口 \(port)；Bonjour 已广播为「\(serviceName)._mcp._tcp」"
                }
            }
        }
        do {
            try incoming.start()
            listener = incoming; running = true
            statusText = "正在启动监听（端口 \(port)）…"
        } catch {
            statusText = "启动失败：\(error.localizedDescription)（端口可能被占用）"
        }
    }

    /// Restores the service the user left enabled, e.g. after relaunch.
    func restoreIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) { start() }
    }

    /// User-initiated shutdown; transient restarts (port or scope changes) use stop(reason:).
    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        stop()
    }

    func stop(reason: String = "MCP 服务已关闭") {
        listener?.stop(); listener = nil
        running = false
        statusText = reason
        for identity in Array(deviceWaiters.keys) { resolveDevice(identity, approved: false) }
        let open = sessions.values; sessions = [:]; sessionCount = 0
        inFlightInputSession = nil
        for session in open { Task { await session.coordinator.stop() } }
    }

    func stopAllSessions() {
        let open = sessions.values; sessions = [:]; sessionCount = 0
        inFlightInputSession = nil
        for session in open { Task { await session.coordinator.stop() } }
        if running { statusText = "已停止全部 MCP 会话；服务继续监听" }
    }

    /// Rotation revokes every outstanding credential; in-flight work stops.
    func rotatePassword() throws -> String {
        let value = try MCPAccessCredential.rotate()
        stopAllSessions(); clearTrust()
        return value
    }
    func setCustomPassword(_ value: String) throws {
        try MCPAccessCredential.setCustom(value)
        stopAllSessions(); clearTrust()
    }

    // MARK: 请求处理

    func handle(_ request: MCPHTTP.Request, source: MCPPeer) async -> MCPHTTP.Response {
        sweepIdleSessions()
        pruneExpiredDevices()
        guard await authenticate(request, source: source) else { return .empty(401) }
        switch request.method {
        case "DELETE":
            guard let id = request.header("Mcp-Session-Id"), sessions[id] != nil else { return .empty(404) }
            endSession(id)
            return .empty(200)
        case "POST":
            return await handlePost(request, source: source)
        default:
            return .empty(405)
        }
    }

    private func authenticate(_ request: MCPHTTP.Request, source: MCPPeer) async -> Bool {
        let presented = request.header("Authorization").flatMap { value -> String? in
            value.lowercased().hasPrefix("bearer ") ? String(value.dropFirst(7)) : nil
        }
        guard let stored = try? loadPassword(), !stored.isEmpty,
              let presented, MCPAccessCredential.matches(presented: presented, stored: stored) else {
            authFailures[source.address, default: 0] += 1
            if authFailures.count > 256 { authFailures = [:] }
            if authFailures[source.address, default: 0] >= Self.failureDelayThreshold {
                try? await Task.sleep(for: .seconds(2))
            }
            return false
        }
        authFailures[source.address] = nil
        return true
    }

    private func handlePost(_ request: MCPHTTP.Request, source: MCPPeer) async -> MCPHTTP.Response {
        let rpc: JSONRPC.Request
        do { rpc = try JSONRPC.decodeRequest(request.body) }
        catch {
            let kind: JSONRPC.ErrorObject = (error as? AppError) == .protocolViolation("JSON 解析失败") ? .parseError : .invalidRequest
            return .json(400, JSONRPC.failure(id: nil, error: kind))
        }
        if rpc.method == "initialize" { return await initialize(rpc, source: source) }
        guard let sessionID = request.header("Mcp-Session-Id"), let session = sessions[sessionID] else {
            return .empty(404)
        }
        session.lastActivity = now()
        switch rpc.method {
        case "notifications/initialized":
            session.initialized = true
            return .empty(202)
        case _ where rpc.isNotification:
            return .empty(202)
        case "ping":
            return .json(200, JSONRPC.response(id: rpc.id, result: [:]))
        case "tools/list":
            guard session.initialized else { return protocolError(rpc, "会话未完成初始化") }
            return .json(200, JSONRPC.response(id: rpc.id, result: ["tools": MCPToolCatalog.listPayload()]))
        case "tools/call":
            guard session.initialized else { return protocolError(rpc, "会话未完成初始化") }
            return await callTool(rpc, session: session)
        default:
            return .json(200, JSONRPC.failure(id: rpc.id, error: .methodNotFound))
        }
    }

    private func initialize(_ rpc: JSONRPC.Request, source: MCPPeer) async -> MCPHTTP.Response {
        let requested = rpc.params["protocolVersion"] as? String
        let supported = ["2025-06-18", "2025-03-26"]
        let version = supported.contains(requested ?? "") ? requested! : supported[0]
        let client = rpc.params["clientInfo"] as? [String: Any]
        let host = await resolveHost(source.address)
        let identity = MCPDeviceIdentity.make(host: host, address: source.address, clientName: client?["name"] as? String)
        guard await authorizeDevice(identity, clientVersion: client?["version"] as? String) else {
            return .json(403, JSONRPC.failure(id: rpc.id, error: .init(code: -32001, message: "设备未获授权：请在手机上允许此设备")))
        }
        // Revocation, password rotation or shutdown may land while suspended.
        guard isTrusted(identity) else {
            return .json(403, JSONRPC.failure(id: rpc.id, error: .init(code: -32001, message: "设备授权已失效")))
        }
        touchDevice(identity)
        let id = UUID().uuidString
        let coordinator = ActionCoordinator(
            bridge: makeSessionBridge(), limits: AgentLimits(),
            approve: { _ in true },
            onImage: { _, _ in }, onReceipt: { _ in },
            authorizationMode: .task)
        sessions[id] = Session(id: id, identity: identity, coordinator: coordinator, now: now())
        sessionCount = sessions.count
        var response = MCPHTTP.Response.json(200, JSONRPC.response(id: rpc.id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "Actell", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
            "instructions": MCPInstructions.text,
        ]))
        response.headers["Mcp-Session-Id"] = id
        return response
    }

    private func makeSessionBridge() -> any DeviceBridge {
        (try? makeBridge()) ?? UnavailableBridge()
    }

    private func callTool(_ rpc: JSONRPC.Request, session: Session) async -> MCPHTTP.Response {
        guard let name = rpc.params["name"] as? String, MCPToolCatalog.names.contains(name) else {
            return .json(200, JSONRPC.failure(id: rpc.id, error: .methodNotFound))
        }
        guard session.pendingCalls < 4 else { return toolError(rpc, "该会话在途请求过多；请等待现有调用返回") }
        let arguments = rpc.params["arguments"] as? [String: Any] ?? [:]
        let isInput = MCPToolCatalog.inputNames.contains(name)
        if isInput {
            if let reason = localAgentBusyReason() { return toolError(rpc, "设备忙：\(reason)") }
            guard inFlightInputSession == nil || inFlightInputSession == session.id else {
                return toolError(rpc, "设备忙：另一 MCP 会话正在执行输入动作")
            }
            inFlightInputSession = session.id
        }
        session.pendingCalls += 1
        defer {
            session.pendingCalls -= 1
            if isInput, inFlightInputSession == session.id { inFlightInputSession = nil }
            session.lastActivity = now()
        }
        do {
            let result = try await session.coordinator.execute(name: name, parameters: arguments, callID: UUID().uuidString)
            var content: [[String: Any]] = [["type": "text", "text": result.result]]
            for image in result.images {
                content.append(["type": "image", "data": image.data.base64EncodedString(), "mimeType": image.mimeType])
            }
            return .json(200, JSONRPC.response(id: rpc.id, result: ["content": content, "isError": false]))
        } catch {
            // Bridge/validation failures are ordinary tool results. Public
            // local messages only; never raw remote responses or credentials.
            let message = (error as? AppError)?.localizedDescription ?? "工具执行失败；未自动重试"
            return toolError(rpc, String(message.prefix(1_000)))
        }
    }

    private func toolError(_ rpc: JSONRPC.Request, _ message: String) -> MCPHTTP.Response {
        .json(200, JSONRPC.response(id: rpc.id, result: [
            "content": [["type": "text", "text": message]], "isError": true,
        ]))
    }
    private func protocolError(_ rpc: JSONRPC.Request, _ message: String) -> MCPHTTP.Response {
        .json(400, JSONRPC.failure(id: rpc.id, error: .init(code: -32600, message: message)))
    }

    // MARK: 会话生命周期

    private func endSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        sessionCount = sessions.count
        if inFlightInputSession == id { inFlightInputSession = nil }
        Task { await session.coordinator.stop() }
    }

    /// Idle timeout is resource reclamation only, not an authorization boundary.
    func sweepIdleSessions() {
        let cutoff = now().addingTimeInterval(-Self.sessionIdleTimeout)
        for (id, session) in sessions where session.lastActivity < cutoff && session.pendingCalls == 0 {
            endSession(id)
        }
    }

    // MARK: 设备信任

    /// Identities holding at least one live session; sessionCount publishing
    /// keeps this view-side snapshot fresh.
    var activeIdentities: Set<String> { Set(sessions.values.map(\.identity)) }

    func isTrusted(_ identity: String) -> Bool { trustedDevices.contains { $0.identity == identity } }

    /// Suspends until the owner decides; concurrent requests from one identity
    /// share a single prompt. Denial is not remembered.
    private func authorizeDevice(_ identity: String, clientVersion: String?) async -> Bool {
        if isTrusted(identity) { return true }
        return await withCheckedContinuation { continuation in
            let isNew = deviceWaiters[identity] == nil
            deviceWaiters[identity, default: []].append(continuation)
            guard isNew else { return }
            deviceQueue.append(DeviceRequest(identity: identity, clientVersion: clientVersion))
            presentNextDeviceRequest()
            Task { [weak self] in
                try? await Task.sleep(for: Self.deviceApprovalTimeout)
                self?.resolveDevice(identity, approved: false)
            }
        }
    }

    func resolveDevice(_ identity: String, approved: Bool) {
        guard let waiters = deviceWaiters.removeValue(forKey: identity) else { return }
        deviceQueue.removeAll { $0.identity == identity }
        if approved, !isTrusted(identity) {
            trustedDevices.append(MCPTrustedDevice(identity: identity, lastConnected: now()))
            persistTrust()
        }
        if deviceRequest?.identity == identity { deviceRequest = nil }
        presentNextDeviceRequest()
        for waiter in waiters { waiter.resume(returning: approved) }
    }

    private func presentNextDeviceRequest() {
        guard deviceRequest == nil, let next = deviceQueue.first else { return }
        deviceRequest = next
        notifyPendingDevice(next.identity)
    }

    func removeDevice(_ identity: String) {
        trustedDevices.removeAll { $0.identity == identity }
        persistTrust()
        for (id, session) in sessions where session.identity == identity { endSession(id) }
    }

    /// Revoke every device and end their sessions.
    func clearTrustedDevices() {
        for identity in trustedDevices.map(\.identity) { removeDevice(identity) }
    }

    private func touchDevice(_ identity: String) {
        guard let index = trustedDevices.firstIndex(where: { $0.identity == identity }) else { return }
        trustedDevices[index].lastConnected = now()
        persistTrust()
    }

    func pruneExpiredDevices() {
        let cutoff = now().addingTimeInterval(-Self.trustRetention)
        let expired = trustedDevices.filter { $0.lastConnected < cutoff }.map(\.identity)
        guard !expired.isEmpty else { return }
        for identity in expired { removeDevice(identity) }
    }

    private func clearTrust() {
        for identity in Array(deviceWaiters.keys) { resolveDevice(identity, approved: false) }
        trustedDevices = []
        persistTrust()
    }

    private func persistTrust() {
        trustedDevices.sort { $0.lastConnected > $1.lastConnected }
        trustStore.save(trustedDevices)
    }

}
