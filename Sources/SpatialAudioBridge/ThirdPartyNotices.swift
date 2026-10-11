import Foundation

/// License notices to show in an app's acknowledgements: SpatialAudioBridge's own license and those of
/// the Rust components and Rust standard library compiled into its core.
///
/// Unlike the rest of the API, this is available on every system the package builds for, because apps
/// ship the core there too.
public enum SpatialAudioBridgeNotices {
    /// The notices as plain text, about 320 KB, with each license text listed once.
    public static var text: String {
        let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt")!
        return try! String(contentsOf: url, encoding: .utf8)
    }
}
