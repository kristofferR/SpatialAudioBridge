import Foundation

/// Playlist text for ``APACStream``.
@available(macOS 26, iOS 26, tvOS 26, *)
enum HLSPlaylists {
    /// A VOD media playlist of `segments` fixed-length segments, the last one possibly shorter.
    static func media(totalFrames: Int64, segmentFrames: Int64, rate: Int) -> String {
        let count = Int((totalFrames + segmentFrames - 1) / segmentFrames)
        let target = Int((Double(segmentFrames) / Double(rate)).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"init.mp4\""]
        for index in 0..<count {
            let frames = min(segmentFrames, totalFrames - Int64(index) * segmentFrames)
            lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), Double(frames) / Double(rate)))
            lines.append("seg\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The audio rendition entry for the APAC playlist.
    static func rendition(name: String, language: String?, channels: Int) -> String {
        var attributes = ["TYPE=AUDIO", "GROUP-ID=\"\(audioGroup)\"", "NAME=\"\(quoted(name))\""]
        if let language { attributes.append("LANGUAGE=\"\(quoted(language))\"") }
        attributes += ["DEFAULT=YES", "AUTOSELECT=YES", "CHANNELS=\"\(channels)\"", "URI=\"audio.m3u8\""]
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    static let audioGroup = "spatial-audio"

    /// Rewrites a video multivariant playlist so every variant plays the APAC rendition: other audio
    /// renditions are removed, audio codecs in CODECS are replaced, bandwidth includes the APAC
    /// bitrate and URIs become absolute, because the result is served from the loopback address.
    /// Variants whose URI `includesVariant` rejects are left out, and `subtitleURI` chooses each
    /// subtitle rendition's URI from its absolute upstream URL.
    static func master(rewriting upstream: String, baseURL: URL, rendition: String, codec: String, bitRate: Int,
                       includesVariant: (URL) -> Bool = { _ in true },
                       subtitleURI: (URL) -> String = { $0.absoluteString }) -> String {
        var output: [String] = []
        var variant: String?
        for raw in upstream.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let pending = variant, !line.hasPrefix("#") {
                let uri = absolute(line, baseURL)
                if URL(string: uri).map(includesVariant) ?? true { output += [pending, uri] }
                variant = nil
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                switch attribute("TYPE", in: line) {
                case "AUDIO": continue
                case "SUBTITLES":
                    output.append(replacingURI(in: line) { URL(string: $0, relativeTo: baseURL).map { subtitleURI($0.absoluteURL) } ?? $0 })
                default: output.append(replacingURI(in: line, baseURL))
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                var attributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                // CODECS must list every format once present, so a variant without it keeps none.
                if let upstreamCodecs = attribute("CODECS", in: line) {
                    let codecs = upstreamCodecs.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !isAudioCodec($0) } + [codec]
                    attributes = setting("CODECS", to: "\"\(codecs.joined(separator: ","))\"", in: attributes)
                }
                attributes = setting("AUDIO", to: "\"\(audioGroup)\"", in: attributes)
                for key in ["BANDWIDTH", "AVERAGE-BANDWIDTH"] {
                    if let value = attribute(key, in: line).flatMap(Int.init) {
                        attributes = setting(key, to: String(value + bitRate), in: attributes)
                    }
                }
                variant = "#EXT-X-STREAM-INF:" + attributes
            } else if line.hasPrefix("#"), attribute("URI", in: line) != nil {
                // I-frame and trick-play image playlists, session data and keys.
                output.append(replacingURI(in: line, baseURL))
            } else {
                output.append(line)
            }
            if line == "#EXTM3U" { output.append(rendition) }
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// Rewrites a subtitle media playlist so its whole `.vtt` segments load as `<rendition>/<index>.vtt`
    /// beside it, returning their absolute upstream URLs in order. Every other URI, including encrypted and
    /// byte-range segments, initialization sections and other formats such as IMSC1, becomes absolute and
    /// loads directly.
    static func subtitles(rewriting upstream: String, baseURL: URL, rendition: Int) -> (text: String, segments: [URL]) {
        var output: [String] = []
        var segments: [URL] = []
        var byteRange = false
        var encrypted = false
        for raw in upstream.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-BYTERANGE:") { byteRange = true }
                if line.hasPrefix("#EXT-X-KEY:") { encrypted = attribute("METHOD", in: line) != "NONE" }
                output.append(replacingURI(in: line, baseURL))
            } else if !byteRange, !encrypted, let url = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                      url.pathExtension.lowercased() == "vtt" {
                output.append("\(rendition)/\(segments.count).vtt")
                segments.append(url)
            } else {
                output.append(absolute(line, baseURL))
            }
            if !line.hasPrefix("#") { byteRange = false }
        }
        return (output.joined(separator: "\n") + "\n", segments)
    }

    /// Replaces Jellyfin's WebVTT `X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000`, written for its
    /// MPEG-TS output, with `MPEGTS:0`, so cues count from the start of the timeline that APAC and
    /// stream-copy fMP4 video share instead of arriving 10 s late. Other maps are left as they are.
    static func removingJellyfinTimestampOffset(in segment: String) -> String {
        segment.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.hasPrefix("X-TIMESTAMP-MAP=") else { return String(line) }
            let fields = Set(line.dropFirst("X-TIMESTAMP-MAP=".count).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            guard fields == ["MPEGTS:900000", "LOCAL:00:00:00.000"] else { return String(line) }
            return String(line.replacing("MPEGTS:900000", with: "MPEGTS:0"))
        }.joined(separator: "\n")
    }

    static func isAudioCodec(_ codec: String) -> Bool {
        ["mp4a", "ac-3", "ec-3", "ac-4", "fLaC", "Opus", "opus", "alac", "apac", "dtsc", "dtsx"]
            .contains { codec.hasPrefix($0) }
    }

    /// The value of a playlist attribute, without quotes.
    static func attribute(_ key: String, in line: String) -> String? {
        guard let range = attributeRange(key, in: line) else { return nil }
        let value = line[range]
        return value.hasPrefix("\"") ? String(value.dropFirst().dropLast()) : String(value)
    }

    private static func setting(_ key: String, to value: String, in attributes: String) -> String {
        guard let range = attributeRange(key, in: attributes) else { return attributes + ",\(key)=\(value)" }
        var result = attributes
        result.replaceSubrange(range, with: value)
        return result
    }

    /// The range of an attribute's value, handling quoted values that contain commas.
    private static func attributeRange(_ key: String, in line: String) -> Range<String.Index>? {
        var search = line.startIndex
        while let found = line.range(of: "\(key)=", range: search..<line.endIndex) {
            let before = found.lowerBound == line.startIndex ? nil : line[line.index(before: found.lowerBound)]
            guard before == nil || before == "," || before == ":" else { search = found.upperBound; continue }
            var end = found.upperBound
            if end < line.endIndex, line[end] == "\"" {
                end = line[line.index(after: end)...].firstIndex(of: "\"").map { line.index(after: $0) } ?? line.endIndex
            } else {
                end = line[end...].firstIndex(of: ",") ?? line.endIndex
            }
            return found.upperBound..<end
        }
        return nil
    }

    private static func replacingURI(in line: String, _ baseURL: URL) -> String {
        replacingURI(in: line) { absolute($0, baseURL) }
    }

    private static func replacingURI(in line: String, with transform: (String) -> String) -> String {
        guard let uri = attribute("URI", in: line), let range = attributeRange("URI", in: line) else { return line }
        var result = line
        result.replaceSubrange(range, with: "\"\(transform(uri))\"")
        return result
    }

    private static func absolute(_ uri: String, _ baseURL: URL) -> String {
        URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri
    }

    private static func quoted(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "'") }
}
