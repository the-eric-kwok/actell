import Foundation
import Network

/// NWListener transport for the MCP server: LAN TCP with Bonjour advertising,
/// cellular prohibited, keep-alive HTTP/1.1 with one request in flight per
/// connection. Hostile or oversized input closes the connection.
final class MCPListener: @unchecked Sendable {
    typealias Handler = @Sendable (MCPHTTP.Request, MCPPeer) async -> MCPHTTP.Response
    private let port: UInt16
    private let loopbackOnly: Bool
    private let serviceName: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "mcp.listener")
    private var listener: NWListener?
    private static let maxConnections = 8
    private static let idleTimeout: TimeInterval = 75
    private var connectionCount = 0

    /// Binding happens asynchronously after start(); failures arrive here, not
    /// as a throw from the constructor. nil means ready; `waiting:` prefixed
    /// messages are transient (e.g. local-network permission pending).
    var onStateChange: (@Sendable (_ failure: String?) -> Void)?

    init(port: UInt16, loopbackOnly: Bool = false, serviceName: String, handler: @escaping Handler) {
        self.port = port; self.loopbackOnly = loopbackOnly; self.serviceName = serviceName; self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        }
        let incoming = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        // Loopback-only listening is deliberately not advertised to the LAN.
        if !loopbackOnly {
            incoming.service = NWListener.Service(name: serviceName, type: "_mcp._tcp")
        }
        incoming.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?(nil)
            case .failed(let error): self?.onStateChange?(error.localizedDescription)
            case .waiting(let error): self?.onStateChange?("waiting:" + error.localizedDescription)
            case .cancelled, .setup: break
            @unknown default: break
            }
        }
        incoming.start(queue: queue)
        listener = incoming
    }

    func stop() {
        listener?.cancel(); listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard connectionCount < Self.maxConnections else { connection.cancel(); return }
        connectionCount += 1
        let source = MCPPeer(endpoint: connection.endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { connection.cancel() }
            if case .cancelled = state { self?.queue.async { self?.connectionCount -= 1 } }
        }
        connection.start(queue: queue)
        receiveLoop(connection, buffer: Data(), source: source)
    }

    private func receiveLoop(_ connection: NWConnection, buffer: Data, source: MCPPeer) {
        switch MCPHTTP.parse(buffer) {
        case .invalid:
            connection.cancel()
        case .request(let request, let consumed):
            let remainder = Data(buffer.dropFirst(consumed))
            Task { [handler] in
                let response = await handler(request, source)
                let close = request.header("connection")?.lowercased() == "close"
                var outgoing = response
                if close { outgoing.headers["Connection"] = "close" }
                connection.send(content: MCPHTTP.serialize(outgoing), completion: .contentProcessed { [weak self] error in
                    if error != nil || close { connection.cancel(); return }
                    self?.queue.async { self?.receiveLoop(connection, buffer: remainder, source: source) }
                })
            }
        case .incomplete:
            guard buffer.count <= MCPHTTP.maxHeaderBytes + MCPHTTP.maxBodyBytes else { connection.cancel(); return }
            // Idle or trickling peers must not hold one of the few connection slots.
            let idle = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: idle)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
                idle.cancel()
                guard let self, error == nil, !complete, let data, !data.isEmpty else { connection.cancel(); return }
                self.receiveLoop(connection, buffer: buffer + data, source: source)
            }
        }
    }
}
