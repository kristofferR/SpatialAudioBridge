import Testing
import SpatialAudioBridge

@Test func noticesCoverTheLibraryItsDecodersAndTheRustStandardLibrary() {
    let text = SpatialAudioBridgeNotices.text
    for expected in ["Applies to: SpatialAudioBridge (LICENSE)", "- truehd ", "- dca ", "- oamd ",
                     "The Rust Standard Library, rustc"] {
        #expect(text.contains(expected), "missing \(expected)")
    }
}
