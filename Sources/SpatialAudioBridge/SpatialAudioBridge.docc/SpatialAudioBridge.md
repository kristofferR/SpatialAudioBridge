# ``SpatialAudioBridge``

Convert TrueHD Atmos and DTS:X into Apple Positional Audio Codec (APAC) for native spatial playback on Apple TV.

## Overview

Apple TV cannot decode TrueHD or DTS:X. This library decodes the compressed track, renders its bed, objects and heights into 7.1.4 or 9.1.6 speaker feeds, and encodes those feeds with Apple's APAC encoder. AVFoundation then plays the result through its native spatial path.

Choose the entry point that matches how the host plays media:

| The host… | Use |
|---|---|
| plays video with `AVPlayer` | ``APACStream`` adds APAC as an HLS audio rendition beside the server's video. |
| renders with `AVSampleBufferRenderSynchronizer` | ``SpatialAudioRenderer`` queues APAC sample buffers, without HLS. |
| converts files or builds its own HLS | ``SpatialAudioTranscoder``, ``APACHLSOutput`` or ``APACTrackConverter``. |

Compressed input comes from ``MatroskaFile``, which reads local files or HTTP range requests, or from the host's own demuxer.

On the tested Apple TV and receiver, HDMI output switched to Atmos only while a Dolby Atmos stream played. Pair every playback path with `AtmosOutputActivator` from the SpatialAudioPlayback module.

The guides cover each path in depth: [AVPlayer](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/avplayer.md), [sample buffers](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/sample-buffer-playback.md), [conversion](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/conversion.md), [media servers](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/media-servers.md) and [Atmos output](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/atmos-output.md).

## Topics

### Playing through AVPlayer

- ``APACStream``

### Playing through a render synchronizer

- ``SpatialAudioRenderer``

### Reading Matroska files

- ``MatroskaFile``
- ``MatroskaAudioTrack``
- ``MatroskaPacket``
- ``MatroskaPackets``
- ``MediaByteSource``
- ``FileByteSource``
- ``HTTPByteSource``

### Converting and packaging

- ``SpatialAudioTranscoder``
- ``APACTrackConverter``
- ``APACHLSOutput``
- ``APACDestination``
- ``APACSegment``
- ``APACConversionReport``

### Configuration

- ``APACConfiguration``
- ``SpatialAudioCodec``
- ``SpatialAudioLayout``

### Errors

- ``SpatialAudioError``
