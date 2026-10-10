import Foundation
import Network

/// A minimal HTTP/1.1 server on the loopback interface for AVPlayer: GET and HEAD, persistent
/// connections and single byte ranges.
final class LoopbackServer: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var contentType = "text/plain"
        var body = Data()

        static func notFound() -> Response { Response(status: 404, body: Data("Not found\n".utf8)) }
    }

    typealias Handler = @Sendable (_ path: String) async -> Response

    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SpatialAudioBridge.LoopbackServer")
    private let handler: Handler
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(handler: @escaping Handler) async throws {
        let parameters = NWParameters.tcp
        // Accept connections from this device only.
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        self.handler = handler
        // The listener requires its connection handler before it starts.
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let queue = queue
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resumed.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): resumed.resume(throwing: error)
                case .cancelled: resumed.resume(throwing: SpatialAudioError.invalidState("Loopback server cancelled"))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.values.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.forget(connection) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func forget(_ connection: NWConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        // A pipelined request may already be buffered; answer it before waiting for more bytes.
        if let end = buffered.range(of: Data("\r\n\r\n".utf8)) { return answer(connection, buffer: buffered, headEnd: end) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || buffer.count > 64 * 1024 { connection.cancel() } else { self.receive(connection, buffered: buffer) }
                return
            }
            self.answer(connection, buffer: buffer, headEnd: end)
        }
    }

    private func answer(_ connection: NWConnection, buffer: Data, headEnd end: Range<Data.Index>) {
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let remainder = Data(buffer[end.upperBound...])
        let handler = self.handler
        Task {
            let (bytes, keepAlive) = await Self.respond(to: head, handler: handler)
            connection.send(content: bytes, completion: .contentProcessed { error in
                if error == nil, keepAlive { self.receive(connection, buffered: remainder) } else { connection.cancel() }
            })
        }
    }

    /// The response bytes for a request head, and whether to keep the connection open.
    static func respond(to head: String, handler: Handler) async -> (Data, Bool) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let keepAlive = headers["connection"]?.lowercased() != "close"
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD" else {
            return (serialize(Response(status: 405), keepAlive: false, head: false), false)
        }
        let path = String(request[1].split(separator: "?", maxSplits: 1).first ?? "")
        var response = await handler(path)
        var contentRange: String?
        if response.status == 200, let range = headers["range"].flatMap({ byteRange($0, length: response.body.count) }) {
            contentRange = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(response.body.count)"
            response.body = response.body.subdata(in: range)
            response.status = 206
        }
        return (serialize(response, keepAlive: keepAlive, head: request[0] == "HEAD", contentRange: contentRange), keepAlive)
    }

    /// A single `bytes=start-end` or `bytes=start-` range within `length`.
    static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start < length else { return nil }
        let end = parts[1].isEmpty ? length - 1 : min(Int(parts[1]) ?? length - 1, length - 1)
        return end >= start ? start..<end + 1 : nil
    }

    private static func serialize(_ response: Response, keepAlive: Bool, head: Bool, contentRange: String? = nil) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed",
                      500: "Internal Server Error", 504: "Gateway Timeout"][response.status] ?? "Error"
        var lines = ["HTTP/1.1 \(response.status) \(reason)", "Content-Type: \(response.contentType)",
                     "Content-Length: \(response.body.count)", "Accept-Ranges: bytes", "Cache-Control: no-cache",
                     "Connection: \(keepAlive ? "keep-alive" : "close")"]
        if let contentRange { lines.append("Content-Range: \(contentRange)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if !head { data.append(response.body) }
        return data
    }
}

/// Resumes a continuation at most once, for callbacks that can fire repeatedly.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.withLock { defer { continuation = nil }; return continuation }
    }
}
