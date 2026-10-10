import Foundation

/// Random access to the bytes of a media file.
///
/// Use ``FileByteSource`` for local files and ``HTTPByteSource`` for servers that support
/// HTTP range requests, such as a media server's direct-play URL.
public protocol MediaByteSource: Sendable {
    /// The file's total size in bytes.
    func length() async throws -> Int64
    /// The bytes in `range`. A range ending beyond the file returns the available bytes.
    func read(_ range: Range<Int64>) async throws -> Data
}

/// Reads a local file.
public struct FileByteSource: MediaByteSource {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func length() async throws -> Int64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size else { throw SpatialAudioError.source("Could not read the size of \(url.lastPathComponent)") }
        return size.int64Value
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }
}

/// Reads a file over HTTP with range requests.
public struct HTTPByteSource: MediaByteSource {
    public let url: URL
    public let headers: [String: String]
    private let session: URLSession

    /// `headers` are sent with every request, for example a media server's authorization header.
    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    public func length() async throws -> Int64 {
        let (_, response) = try await request(range: "bytes=0-0")
        // A ranged response reports the full size in Content-Range: bytes 0-0/<length>.
        if let total = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last,
           let length = Int64(total) {
            return length
        }
        throw SpatialAudioError.source("\(url.host() ?? "The server") does not support HTTP range requests")
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        let (data, _) = try await request(range: "bytes=\(range.lowerBound)-\(range.upperBound - 1)")
        return data
    }

    private func request(range: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue(range, forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SpatialAudioError.source("Unexpected response from \(url.host() ?? "the server")")
        }
        // A 200 means the server ignored the range and sent the whole file.
        guard response.statusCode == 206 else {
            throw SpatialAudioError.source("HTTP \(response.statusCode) for a range request to \(url.host() ?? "the server")")
        }
        return (data, response)
    }
}
