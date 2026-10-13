import XCTest
@testable import PhoneAgent

/// Deterministic in-process device bridge; `gate` optionally holds tap delivery
/// open so tests can observe cross-session input mutual exclusion.
private actor MCPStubBridge: DeviceBridge {
    var taps = 0
    private var gated = false
    private var release: CheckedContinuation<Void, Never>?
    func setGated(_ value: Bool) { gated = value }
    func releaseTap() { release?.resume(); release = nil }
    func supportsBackgroundExecution(tool: String) async -> Bool { true }
    func approvalContext(imageID: String) async throws -> String { "stub-context" }
    func acceptApproval(imageID: String) async throws {}
    func authorizeTaskInput(imageID: String) async throws {}
    func screenshot() async throws -> FrameImage {
        FrameImage(id: UUID().uuidString, png: Data([0xff, 0xd8, 0xff, 0x00]), width: 100, height: 200, capturedAt: Date(), isDemo: false)
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        if gated { await withCheckedContinuation { release = $0 } }
        taps += 1
    }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {}
    func installedApplications() async throws -> Data { try JSONSerialization.data(withJSONObject: [["name": "Demo", "bundle_id": "com.demo", "version": "1"]]) }
    func systemActionContext() async throws -> String { "stub-system" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {}
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {}
    func stop() async {}
}

@MainActor final class MCPServerTests: XCTestCase {
    private static let password = "unit-test-password-123456"
    private var bridge: MCPStubBridge!
    private var model: MCPServerModel!
    private var currentDate = Date()
    private var trust: MCPTrustMemoryStore!
    private static let trustedIdentity = "10.0.0.9-test-client"

    override func setUp() async throws {
        bridge = MCPStubBridge()
        let shared = bridge!
        currentDate = Date()
        trust = MCPTrustMemoryStore()
        trust.devices = [MCPTrustedDevice(identity: Self.trustedIdentity, lastConnected: currentDate)]
        model = MCPServerModel(makeBridge: { shared }, trustStore: trust, now: { [weak self] in self?.currentDate ?? Date() })
        model.loadPassword = { Self.password }
        model.resolveHost = { _ in nil }
    }

    private func post(_ body: [String: Any], session: String? = nil, password: String? = password,
                      source: String = "10.0.0.9") async -> MCPHTTP.Response {
        var headers: [String: String] = [:]
        if let password { headers["authorization"] = "Bearer " + password }
        if let session { headers["mcp-session-id"] = session }
        let data = try! JSONSerialization.data(withJSONObject: body)
        return await model.handle(MCPHTTP.Request(method: "POST", path: "/mcp", headers: headers, body: data), source: MCPPeer(address: source))
    }
    private func rpc(_ method: String, id: Int = 1, params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }
    private func json(_ response: MCPHTTP.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
    private func openSession() async -> String {
        let response = await post(rpc("initialize", params: ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-client"]]))
        let id = response.headers["Mcp-Session-Id"]!
        _ = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: id)
        return id
    }
    private func callTool(_ name: String, arguments: [String: Any] = [:], session: String) async -> [String: Any] {
        json(await post(rpc("tools/call", params: ["name": name, "arguments": arguments]), session: session))
    }

    func testHandshakeToolListMatchesDeviceTools() async {
        let response = await post(rpc("initialize", params: ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-client"]]))
        XCTAssertEqual(response.status, 200)
        let sessionID = response.headers["Mcp-Session-Id"]
        XCTAssertNotNil(sessionID)
        let result = json(response)["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        _ = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: sessionID)
        let list = json(await post(rpc("tools/list", id: 2), session: sessionID))
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set(MCPToolCatalog.names))
        XCTAssertFalse(tools.contains { $0["name"] as? String == "finish" })
        for tool in tools {
            XCTAssertNotNil((tool["inputSchema"] as? [String: Any])?["type"] as? String)
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
    }

    func testAuthenticationRequired() async {
        let missing = await post(rpc("initialize"), password: nil)
        XCTAssertEqual(missing.status, 401)
        let wrong = await post(rpc("initialize"), password: "wrong-password-abcdef")
        XCTAssertEqual(wrong.status, 401)
        XCTAssertTrue(MCPAccessCredential.matches(presented: Self.password, stored: Self.password))
        XCTAssertFalse(MCPAccessCredential.matches(presented: Self.password + "x", stored: Self.password))
    }

    func testGeneratedPasswordShape() {
        let value = MCPAccessCredential.generate()
        XCTAssertEqual(value.count, MCPAccessCredential.generatedLength)
        XCTAssertTrue(value.contains { $0.isLetter })
        XCTAssertTrue(value.contains { $0.isNumber })
        XCTAssertTrue(value.contains { !$0.isLetter && !$0.isNumber })
        XCTAssertTrue(value.allSatisfy { $0.isASCII && !$0.isWhitespace })
        XCTAssertNotEqual(MCPAccessCredential.generate(), value)
    }

    func testUninitializedAndUnknownCalls() async {
        let orphan = await post(rpc("tools/list"), session: "missing-session")
        XCTAssertEqual(orphan.status, 404)
        let initialize = await post(rpc("initialize", params: ["clientInfo": ["name": "test-client"]]))
        let id = initialize.headers["Mcp-Session-Id"]!
        let early = await post(rpc("tools/call", params: ["name": "wait", "arguments": ["duration_ms": 1]]), session: id)
        XCTAssertEqual(early.status, 400)
        _ = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: id)
        let unknownMethod = json(await post(rpc("bogus/method"), session: id))
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)
        let unknownTool = json(await post(rpc("tools/call", params: ["name": "finish", "arguments": [:]]), session: id))
        XCTAssertEqual((unknownTool["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testMalformedAndHostileInput() async {
        let garbage = await model.handle(MCPHTTP.Request(method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer " + Self.password], body: Data("not json".utf8)), source: MCPPeer(address: "10.0.0.9"))
        XCTAssertEqual(garbage.status, 400)
        let batch = await model.handle(MCPHTTP.Request(method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer " + Self.password], body: Data("[]".utf8)), source: MCPPeer(address: "10.0.0.9"))
        XCTAssertEqual(batch.status, 400)
        let put = await model.handle(MCPHTTP.Request(method: "PUT", path: "/mcp",
            headers: ["authorization": "Bearer " + Self.password], body: Data()), source: MCPPeer(address: "10.0.0.9"))
        XCTAssertEqual(put.status, 405)
        var oversized = Data("POST /mcp HTTP/1.1\r\ncontent-length: \(MCPHTTP.maxBodyBytes + 1)\r\n\r\n".utf8)
        if case .invalid = MCPHTTP.parse(oversized) {} else { XCTFail("超大请求体应被拒绝") }
        oversized = Data(repeating: 0x41, count: MCPHTTP.maxHeaderBytes + 8)
        if case .invalid = MCPHTTP.parse(oversized) {} else { XCTFail("超长头部应被拒绝") }
    }

    func testHTTPRoundTripParsing() {
        let request = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .request(let parsed, let consumed) = MCPHTTP.parse(request) else { return XCTFail("应解析成功") }
        XCTAssertEqual(parsed.method, "POST"); XCTAssertEqual(parsed.body, Data("{}".utf8)); XCTAssertEqual(consumed, request.count)
        if case .incomplete = MCPHTTP.parse(request.prefix(10)) {} else { XCTFail("前缀应判定为不完整") }
        let serialized = MCPHTTP.serialize(.json(200, Data("{}".utf8)))
        XCTAssertTrue(String(decoding: serialized, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
    }

    func testTapRequiresScreenshotReference() async {
        let session = await openSession()
        let result = (await callTool("tap", arguments: ["x": 1, "y": 2, "purpose": "测试"], session: session))["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("坐标参照"), text)
    }

    func testScreenshotThenTapDelivers() async {
        let session = await openSession()
        let screenshot = (await callTool("screenshot", session: session))["result"] as? [String: Any]
        let content = screenshot?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(screenshot?["isError"] as? Bool, false)
        XCTAssertTrue(content.contains { $0["type"] as? String == "image" && ($0["data"] as? String)?.isEmpty == false })
        let metadata = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        XCTAssertTrue(metadata.contains("image_id") && metadata.contains("\"width\":100"), metadata)
        let tap = (await callTool("tap", arguments: ["x": 10, "y": 20, "purpose": "测试"], session: session))["result"] as? [String: Any]
        XCTAssertEqual(tap?["isError"] as? Bool, false)
        let taps = await bridge.taps
        XCTAssertEqual(taps, 1)
    }

    func testLocalAgentBusyRejectsInputAllowsScreenshot() async {
        model.localAgentBusyReason = { "本机 agent 任务正在运行" }
        let session = await openSession()
        _ = await callTool("screenshot", session: session)
        let tap = (await callTool("tap", arguments: ["x": 1, "y": 1, "purpose": "测试"], session: session))["result"] as? [String: Any]
        XCTAssertEqual(tap?["isError"] as? Bool, true)
        XCTAssertTrue((((tap?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("设备忙"))
        let screenshot = (await callTool("screenshot", session: session))["result"] as? [String: Any]
        XCTAssertEqual(screenshot?["isError"] as? Bool, false)
    }

    func testCrossSessionInputMutualExclusion() async {
        let a = await openSession(), b = await openSession()
        _ = await callTool("screenshot", session: a)
        _ = await callTool("screenshot", session: b)
        await bridge.setGated(true)
        let held = Task { await self.callTool("tap", arguments: ["x": 1, "y": 1, "purpose": "测试"], session: a) }
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.hasInFlightInput)
        let refused = (await callTool("tap", arguments: ["x": 1, "y": 1, "purpose": "测试"], session: b))["result"] as? [String: Any]
        XCTAssertEqual(refused?["isError"] as? Bool, true)
        XCTAssertTrue((((refused?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("设备忙"))
        await bridge.releaseTap()
        let first = (await held.value)["result"] as? [String: Any]
        XCTAssertEqual(first?["isError"] as? Bool, false)
        XCTAssertFalse(model.hasInFlightInput)
    }

    func testDeleteAndIdleTimeoutEndSessions() async {
        let session = await openSession()
        let gone = await model.handle(MCPHTTP.Request(method: "DELETE", path: "/mcp",
            headers: ["authorization": "Bearer " + Self.password, "mcp-session-id": session], body: Data()), source: MCPPeer(address: "10.0.0.9"))
        XCTAssertEqual(gone.status, 200)
        let afterDelete = await post(rpc("ping"), session: session)
        XCTAssertEqual(afterDelete.status, 404)
        let idle = await openSession()
        currentDate = currentDate.addingTimeInterval(MCPServerModel.sessionIdleTimeout + 1)
        let afterTimeout = await post(rpc("ping"), session: idle)
        XCTAssertEqual(afterTimeout.status, 404)
    }

    func testStopAllSessionsInvalidatesAndKeepsNoInput() async {
        let session = await openSession()
        _ = await callTool("screenshot", session: session)
        model.stopAllSessions()
        let afterStop = await post(rpc("ping"), session: session)
        XCTAssertEqual(afterStop.status, 404)
        XCTAssertFalse(model.hasInFlightInput)
    }

    // MARK: 设备信任

    private func initialize(client: String, source: String = "10.0.0.9") async -> MCPHTTP.Response {
        await post(rpc("initialize", params: ["clientInfo": ["name": client, "version": "1.0"]]), source: source)
    }
    private func waitForDeviceRequest() async -> MCPServerModel.DeviceRequest? {
        for _ in 0..<100 where model.deviceRequest == nil { try? await Task.sleep(for: .milliseconds(10)) }
        return model.deviceRequest
    }

    func testDeviceIdentityRules() {
        XCTAssertEqual(MCPDeviceIdentity.make(host: "MacBook.local", address: "10.0.0.2", clientName: "claude-code"), "macbook.local-claude-code")
        XCTAssertEqual(MCPDeviceIdentity.make(host: nil, address: "10.0.0.2", clientName: "claude-code"), "10.0.0.2-claude-code")
        XCTAssertEqual(MCPDeviceIdentity.make(host: nil, address: "10.0.0.2", clientName: nil), "10.0.0.2-unknown")
    }

    func testInstructionsReturnedWithinLimit() async {
        let result = json(await initialize(client: "test-client"))["result"] as? [String: Any]
        let text = result?["instructions"] as? String ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThanOrEqual(text.count, MCPInstructions.maxLength)
    }

    func testUntrustedDeviceApprovedOnceThenTrusted() async {
        model.resolveHost = { _ in "laptop.local" }
        let pending = Task { await self.initialize(client: "new-client") }
        let request = await waitForDeviceRequest()
        XCTAssertEqual(request?.identity, "laptop.local-new-client")
        XCTAssertEqual(request?.clientVersion, "1.0")
        model.resolveDevice("laptop.local-new-client", approved: true)
        let approved = await pending.value
        XCTAssertEqual(approved.status, 200)
        XCTAssertNotNil(approved.headers["Mcp-Session-Id"])
        XCTAssertTrue(trust.devices.contains { $0.identity == "laptop.local-new-client" })
        let again = await initialize(client: "new-client")
        XCTAssertEqual(again.status, 200)
        XCTAssertNil(model.deviceRequest)
    }

    func testDeniedDeviceGets403AndIsNotRemembered() async {
        let pending = Task { await self.initialize(client: "intruder", source: "10.0.0.50") }
        _ = await waitForDeviceRequest()
        model.resolveDevice("10.0.0.50-intruder", approved: false)
        let denied = await pending.value
        XCTAssertEqual(denied.status, 403)
        XCTAssertFalse(model.isTrusted("10.0.0.50-intruder"))
        let retry = Task { await self.initialize(client: "intruder", source: "10.0.0.50") }
        let prompt = await waitForDeviceRequest()
        XCTAssertEqual(prompt?.identity, "10.0.0.50-intruder")
        model.resolveDevice("10.0.0.50-intruder", approved: false)
        _ = await retry.value
    }

    func testConcurrentRequestsShareOnePrompt() async {
        let first = Task { await self.initialize(client: "dup", source: "10.0.0.60") }
        _ = await waitForDeviceRequest()
        let second = Task { await self.initialize(client: "dup", source: "10.0.0.60") }
        try? await Task.sleep(for: .milliseconds(50))
        model.resolveDevice("10.0.0.60-dup", approved: true)
        let a = await first.value, b = await second.value
        XCTAssertEqual(a.status, 200); XCTAssertEqual(b.status, 200)
        XCTAssertEqual(trust.devices.filter { $0.identity == "10.0.0.60-dup" }.count, 1)
    }

    func testRemovingDeviceEndsItsSessions() async {
        let session = await openSession()
        model.removeDevice(Self.trustedIdentity)
        let after = await post(rpc("ping"), session: session)
        XCTAssertEqual(after.status, 404)
        XCTAssertFalse(model.isTrusted(Self.trustedIdentity))
    }

    func testDevicesExpireAfterSevenDays() async {
        _ = await openSession()
        currentDate = currentDate.addingTimeInterval(MCPServerModel.trustRetention + 60)
        model.pruneExpiredDevices()
        XCTAssertTrue(model.trustedDevices.isEmpty)
        XCTAssertTrue(trust.devices.isEmpty)
    }

    func testLastConnectedUpdatesOnInitialize() async {
        let start = currentDate
        currentDate = start.addingTimeInterval(3600)
        _ = await openSession()
        XCTAssertEqual(model.trustedDevices.first { $0.identity == Self.trustedIdentity }?.lastConnected, currentDate)
    }

    func testClearTrustedDevicesEndsAllSessions() async {
        let session = await openSession()
        XCTAssertTrue(model.activeIdentities.contains(Self.trustedIdentity))
        model.clearTrustedDevices()
        let after = await post(rpc("ping"), session: session)
        XCTAssertEqual(after.status, 404)
        XCTAssertTrue(model.trustedDevices.isEmpty)
        XCTAssertTrue(model.activeIdentities.isEmpty)
    }
}
