import Testing
import SpatialAudioBridge

@Test func noticesCoverTheLibraryItsDecodersAndTheRustStandardLibrary() {
    let text = SpatialAudioBridgeNotices.text
    for expected in ["Applies to: SpatialAudioBridge (LICENSE)", "- truehd ", "- dca ", "- oamd ",
                     "dca 0.8.0 (NOTICE-FFmpeg)", "dca 0.8.0 (LGPL-3.0)",
                     "The Rust Standard Library, rustc"] {
        #expect(text.contains(expected), "missing \(expected)")
    }
}
