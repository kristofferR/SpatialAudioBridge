import Foundation

/// Serves the whole WebVTT segments of the video master's subtitle renditions from the loopback address,
/// with Jellyfin's time map moved onto the stream's zero-based timeline; see
/// ``HLSPlaylists/removingJellyfinTimestampOffset(in:)``. Like `AVPlayer` with the video playlists, it sends
/// no headers, so the server's URLs must authenticate on their own.
@available(macOS 26, iOS 26, tvOS 26, *)
final class SubtitleProxy: @unchecked Sendable {
    private let lock = NSLock()
    private var renditions: [URL] = []
    private var segments: [Int: [URL]] = [:]

    /// Registers an upstream subtitle playlist and returns its path relative to the master playlist.
    func route(_ playlist: URL) -> String {
        lock.withLock {
            renditions.append(playlist)
            return "subtitles/\(renditions.count - 1).m3u8"
        }
    }

    /// Answers `<rendition>.m3u8` and `<rendition>/<segment>.vtt` below `subtitles/`.
    func respond(to name: String) async throws -> LoopbackServer.Response {
        let parts = name.split(separator: "/")
        if parts.count == 1, name.hasSuffix(".m3u8"), let rendition = Int(name.dropLast(5)),
           let url = lock.withLock({ renditions.indices.contains(rendition) ? renditions[rendition] : nil }) {
            guard let (text, finalURL) = try await fetch(url) else { return Self.badGateway }
            let playlist = HLSPlaylists.subtitles(rewriting: text, baseURL: finalURL, rendition: rendition)
            lock.withLock { segments[rendition] = playlist.segments }
            return .init(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(playlist.text.utf8))
        }
        if parts.count == 2, let rendition = Int(parts[0]), parts[1].hasSuffix(".vtt"),
           let index = Int(parts[1].dropLast(4)),
           let url = lock.withLock({ segments[rendition].flatMap { $0.indices.contains(index) ? $0[index] : nil } }) {
            guard let (text, _) = try await fetch(url) else { return Self.badGateway }
            return .init(status: 200, contentType: "text/vtt", body: Data(HLSPlaylists.removingJellyfinTimestampOffset(in: text).utf8))
        }
        return .notFound()
    }

    private static let badGateway = LoopbackServer.Response(status: 502, body: Data("The server did not return the subtitles\n".utf8))

    private func fetch(_ url: URL) async throws -> (String, URL)? {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, response.url ?? url)
    }
}
