import Foundation

/// Serves the video master's subtitle renditions from the loopback address, with Jellyfin's WebVTT time
/// map moved onto the stream's zero-based timeline; see ``HLSPlaylists/removingJellyfinTimestampOffset(in:)``.
/// Other segments, such as IMSC1 in fMP4, pass through unchanged.
@available(macOS 26, iOS 26, tvOS 26, *)
final class SubtitleProxy: @unchecked Sendable {
    private let headers: [String: String]
    private let lock = NSLock()
    private var renditions: [URL] = []
    private var segments: [Int: [URL]] = [:]

    init(headers: [String: String]) { self.headers = headers }

    /// Registers an upstream subtitle playlist and returns its path relative to the master playlist.
    func route(_ playlist: URL) -> String {
        lock.withLock {
            renditions.append(playlist)
            return "subtitles/\(renditions.count - 1).m3u8"
        }
    }

    /// Answers `<rendition>.m3u8` and `<rendition>/<segment>.<extension>` below `subtitles/`.
    func respond(to name: String) async throws -> LoopbackServer.Response {
        let parts = name.split(separator: "/")
        if parts.count == 1, name.hasSuffix(".m3u8"), let rendition = Int(name.dropLast(5)),
           let url = lock.withLock({ renditions.indices.contains(rendition) ? renditions[rendition] : nil }) {
            guard let (data, _, finalURL) = try await fetch(url), let text = String(data: data, encoding: .utf8) else {
                return Self.badGateway
            }
            let playlist = HLSPlaylists.subtitles(rewriting: text, baseURL: finalURL, rendition: rendition)
            lock.withLock { segments[rendition] = playlist.segments }
            return .init(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(playlist.text.utf8))
        }
        if parts.count == 2, let rendition = Int(parts[0]),
           let index = parts[1].split(separator: ".").first.flatMap({ Int($0) }),
           let url = lock.withLock({ segments[rendition].flatMap { $0.indices.contains(index) ? $0[index] : nil } }) {
            guard let (data, contentType, _) = try await fetch(url) else { return Self.badGateway }
            guard let text = String(data: data, encoding: .utf8), text.trimmingPrefix("\u{FEFF}").hasPrefix("WEBVTT") else {
                return .init(status: 200, contentType: contentType ?? "application/octet-stream", body: data)
            }
            return .init(status: 200, contentType: "text/vtt", body: Data(HLSPlaylists.removingJellyfinTimestampOffset(in: text).utf8))
        }
        return .notFound()
    }

    private static let badGateway = LoopbackServer.Response(status: 502, body: Data("The server did not return the subtitles\n".utf8))

    /// The body, content type and final URL of a successful response.
    private func fetch(_ url: URL) async throws -> (Data, String?, URL)? {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return (data, http.value(forHTTPHeaderField: "Content-Type"), http.url ?? url)
    }
}
