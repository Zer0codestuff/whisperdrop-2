import Foundation
import Network

/// Just enough HTTP/1.1 for loopback requests from ModelHost, curl and the replay scripts.
/// One request per connection; bodies need Content-Length.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    struct Form {
        var fields: [String: String] = [:]
        var files: [String: Data] = [:]
    }

    func multipart() -> Form? {
        guard let type = headers["content-type"], type.lowercased().hasPrefix("multipart/form-data"),
              let marker = type.components(separatedBy: "boundary=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")),
              !marker.isEmpty else { return nil }
        let delimiter = Data("--\(marker)".utf8)
        let separator = Data("\r\n\r\n".utf8)
        var form = Form()
        var cursor = body.startIndex
        while let open = body.range(of: delimiter, in: cursor..<body.endIndex) {
            let partStart = open.upperBound
            guard let close = body.range(of: delimiter, in: partStart..<body.endIndex) else { break }
            var part = body[partStart..<close.lowerBound]
            // Each part is "\r\nheaders\r\n\r\ncontent\r\n".
            if part.starts(with: Data("\r\n".utf8)) { part = part.dropFirst(2) }
            if part.suffix(2) == Data("\r\n".utf8) { part = part.dropLast(2) }
            if let split = part.range(of: separator) {
                let head = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
                let content = Data(part[split.upperBound...])
                let disposition = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-disposition") } ?? ""
                if let name = Self.attribute("name", in: disposition) {
                    if Self.attribute("filename", in: disposition) != nil { form.files[name] = content }
                    else { form.fields[name] = String(decoding: content, as: UTF8.self) }
                }
            }
            cursor = close.lowerBound
        }
        return form
    }

    private static func attribute(_ key: String, in header: String) -> String? {
        for item in header.components(separatedBy: ";") {
            let pair = item.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix(key + "=") else { continue }
            return String(pair.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data

    static func json(_ status: Int, _ text: String) -> Self { Self(status: status, body: Data(text.utf8)) }

    static func error(_ status: Int, _ message: String) -> Self {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return Self(status: status, body: body)
    }

    var bytes: Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 411: "Length Required", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "Error"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "parakeet.http", attributes: .concurrent)
    private static let maximumBody = 1 << 30

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("parakeet-server: listener failed: \(error)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), continued: false)
    }

    private func receive(_ connection: NWConnection, buffer: Data, continued: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || buffer.count > 64 * 1024 { connection.cancel() } else { self.receive(connection, buffer: buffer, continued: continued) }
                return
            }
            let lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard requestLine.count >= 2 else { self.send(.error(400, "Malformed request."), on: connection); return }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            if headers["transfer-encoding"] != nil || length < 0 { self.send(.error(411, "Content-Length is required."), on: connection); return }
            if length > Self.maximumBody { self.send(.error(413, "The audio is too large."), on: connection); return }
            let bodyStart = headerEnd.upperBound
            if buffer.count - bodyStart < length {
                if !continued, headers["expect"]?.lowercased() == "100-continue" {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                }
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer, continued: true) }
                return
            }
            let request = HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers,
                                      body: Data(buffer[bodyStart..<bodyStart + length]))
            self.send(self.handler(request), on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
