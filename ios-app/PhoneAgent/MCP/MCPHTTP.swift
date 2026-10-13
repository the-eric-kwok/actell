import Foundation

/// Minimal HTTP/1.1 message model for the MCP endpoint. Only POST/DELETE with
/// a Content-Length body are accepted; anything else closes the connection.
enum MCPHTTP {
    static let maxBodyBytes = 1 << 20
    static let maxHeaderBytes = 16 << 10

    struct Request {
        let method: String
        let path: String
        let headers: [String: String] // keys lowercased
        let body: Data
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        static func json(_ status: Int, _ body: Data) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: body)
        }
        static func empty(_ status: Int) -> Response { Response(status: status) }
    }
    enum ParseOutcome {
        case incomplete
        case request(Request, consumed: Int)
        case invalid(String)
    }

    /// Parses one request from the front of `buffer`. Rejects oversized headers
    /// and bodies before buffering them, so hostile input cannot grow memory.
    static func parse(_ buffer: Data) -> ParseOutcome {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .invalid("头部过长") : .incomplete
        }
        guard headerEnd.lowerBound <= maxHeaderBytes else { return .invalid("头部过长") }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("头部编码无效")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid("请求行无效") }
        let method = String(requestLine[0])
        let path = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("头部字段无效") }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid("不支持分块传输") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maxBodyBytes).contains(length) else { return .invalid("请求体超过限制") }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
        return .request(Request(method: method, path: path, headers: headers, body: body), consumed: consumed)
    }

    static func serialize(_ response: Response) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][response.status] ?? "Error"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + response.body
    }
}
