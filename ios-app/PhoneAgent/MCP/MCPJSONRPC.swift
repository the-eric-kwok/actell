import Foundation

/// Minimal JSON-RPC 2.0 model for the MCP server. Batch requests are rejected
/// by the transport layer; ids are echoed verbatim (string or number).
enum JSONRPC {
    enum ID: Sendable, Equatable {
        case string(String), number(Int)
        var jsonValue: Any { switch self { case .string(let s): return s; case .number(let n): return n } }
    }
    struct Request: Sendable {
        let id: ID?
        let method: String
        let params: [String: Any]
        var isNotification: Bool { id == nil }
    }
    struct ErrorObject {
        static let parseError = ErrorObject(code: -32700, message: "Parse error")
        static let invalidRequest = ErrorObject(code: -32600, message: "Invalid Request")
        static let methodNotFound = ErrorObject(code: -32601, message: "Method not found")
        static let invalidParams = ErrorObject(code: -32602, message: "Invalid params")
        let code: Int
        let message: String
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw AppError.protocolViolation("JSON 解析失败")
        }
        guard let dictionary = object as? [String: Any] else {
            // A JSON array is a batch; MCP Streamable HTTP does not require batches here.
            throw AppError.invalid("不支持批量请求")
        }
        guard dictionary["jsonrpc"] as? String == "2.0", let method = dictionary["method"] as? String, !method.isEmpty else {
            throw AppError.invalid("无效的 JSON-RPC 请求")
        }
        var id: ID?
        if let s = dictionary["id"] as? String { id = .string(s) }
        else if let n = dictionary["id"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { id = .number(n.intValue) }
        else if dictionary["id"] != nil, !(dictionary["id"] is NSNull) { throw AppError.invalid("无效的请求 id") }
        let params = dictionary["params"] as? [String: Any] ?? [:]
        return Request(id: id, method: method, params: params)
    }

    static func response(id: ID?, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id?.jsonValue ?? NSNull(), "result": result])
    }
    static func failure(id: ID?, error: ErrorObject) -> Data {
        encode(["jsonrpc": "2.0", "id": id?.jsonValue ?? NSNull(),
                "error": ["code": error.code, "message": error.message]])
    }
    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
