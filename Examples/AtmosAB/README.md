# Atmos A/B for Apple TV

Small tvOS 26+ player for comparing matched TrueHD → APAC 9.1.6 and Deezy DDP Atmos files. All audio is bundled; no server is needed. AVPlayer plays the converted APAC file, not raw TrueHD.

APAC playback uses the tested Atmos setup:

- Configure `AVAudioSession` for playback/movie playback, enable `supportsMultichannelContent`, and activate the session.
- Register the main `AVPlayer` with `MPNowPlayingSession` and make that session active before playback.
- Attach the library's `AtmosOutputActivator` to the main player. It loops a near-silent E-AC-3/JOC stream in a separate, unmuted player while APAC plays and pauses it with the main player.
- Play DDP directly, without the silent stream.

On the tested Apple TV and receiver route, APAC alone did not trigger Atmos. With this setup, Kris confirmed APAC and DDP both trigger Atmos and sound similar. The APAC encoder settings, media and renderer were unchanged. This observation establishes Atmos activation and an informal listening result; it does not establish correct APAC speaker placement. `AVAudioSession.outputNumberOfChannels`, `renderingMode` and `isSpatialAudioEnabled` were unsuitable Atmos detectors on the tested beta.

The silent stream used in that test was a 2.016-second intro from our own Deezy Helicopter conversion, with decoded compatible-bed peak around −105 dBFS. It is near-silent, not digital zero. The example requires a supplied stream; no sample media is distributed here.

Launch arguments isolate each part of the setup: `--plain-session` omits multichannel content from the audio session, `--without-now-playing` skips `MPNowPlayingSession`, and `--without-silent-atmos` plays APAC alone. The app prints the active combination at launch. Pass them in the Xcode scheme or after the bundle identifier in `xcrun devicectl device process launch`.

## Use

Select a sample and press Play. Switching formats preserves the media timestamp and play/pause state, with a short switching gap. The active format has a green checkmark and outline independent of remote focus. Channel-check buttons jump to the original fixture’s speaker sections.

**Auto mode** chooses a random 20-second section shared by both versions of each pair. It plays TrueHD → APAC first, then DDP at the identical timestamp, and continues in list order. The original four pairs take 2 minutes 40 seconds plus switching gaps. Progress and **Stop Auto** stay visible above the scrolling sample list. Play/Pause pauses and resumes the current excerpt; selecting a sample or format leaves Auto. Starting again chooses new sections.

Keep Apple TV audio on Auto, with Change Format off and Dolby Atmos enabled, and leave receiver volume unchanged between versions. Codec gain/priming and switching gaps make this a listening comparison, not a sample-exact null test.

## Prepare and build

Use macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Supply a folder containing:

```text
helicopter.APAC.mp4             helicopter.DDP.mp4
amaze.APAC.mp4                  amaze.DDP.mp4
natures-fury.APAC.mp4           natures-fury.DDP.mp4
channel-check-7.1.4.APAC.mp4     channel-check-7.1.4.DDP.mp4
silent-atmos.mp4
```

Then install on a paired Apple TV:

```sh
cd Examples/AtmosAB
SAB_DEVELOPMENT_TEAM="YOUR_TEAM_ID" ./build-and-install.sh "DEVICE_ID" "/path/to/prepared/media"
```

Or run `./prepare-media.sh "/path/to/prepared/media"`, generate with `xcodegen generate`, and open the generated project in Xcode. Builds use one job. Media, extra manifests, generated projects, build products and device logs are ignored by Git.

### Plain PCM playback

To hear what players without this library output, also supply `<id>.PCM.mp4` for every sample: the track's own 7.1 presentation decoded to 24-bit PCM. It plays as 7.1 LPCM without the near-silent Atmos stream, so it has no heights. Lossless FLAC in MP4 keeps the files at about half the size of raw PCM, and Apple's decoder maps FFmpeg's 7.1 side and back channels to their speakers:

```sh
ffmpeg -i film.thd -c:a flac -f mp4 film.PCM.mp4
```

### Blind comparison against a baseline

To compare a library change, also supply `<id>.APAC-baseline.mp4` for every sample, converted with the earlier build. Match its level to the new conversion so only the change under test differs, or loudness alone will tell X and Y apart. If the builds process level differently, compensate the baseline with `APACConfiguration.gainDB`: TrueHD dialogue normalisation, for example, attenuates newer conversions by 31 dB less the signalled dialogue level, so a baseline from an earlier build needs that attenuation too. Then compare the two conversion reports' `peakPCM`. The app then offers a third version, and Auto mode becomes a blind test. For each excerpt it plays the DDP reference, then both APAC versions as X and Y in random order, and asks which was closer to the reference. **Replay excerpt** plays all three again. At the end it reveals each assignment and the tally, and prints a `BLIND RESULT` line per excerpt to the device log. With the near-silent stream running for both APAC versions, nothing but the audio tells X and Y apart.

Additional pairs are appended from `Media/extra-samples.json`, a JSON array of `{"id":"movie-id","name":"Movie name"}` entries. Each entry uses `Media/<id>.APAC.mp4` and `Media/<id>.DDP.mp4`. Auto includes every listed pair for 40 seconds per pair plus switching gaps, and requires at least 20 seconds in both files. Keep private movie names and media in the ignored manifest and Media folder.

## Validation

The source matches the local app built and installed on an Apple TV 4K (2nd generation), tvOS 27.2 beta, on 2026-10-10. A complete Auto device run played all eight excerpts in the requested order with matching timestamps, the silent Atmos stream running only for APAC, and playback stopping after the last pair. Stopping during preparation and playback also passed. Later pause/resume validation was interrupted by remote use; pause/resume has not completed an unattended device check. Source media remains the previously validated conversion from the original worktree baseline.

For the focused playback probe, launch with `--auto-probe`; stdout reports each seek and endpoint plus the final check result. `--probe --all-pairs` runs the older route observation probe. Its channel-count readings must not be treated as proof of Atmos output.
