# ``SpatialAudioPlayback``

Keep Apple TV HDMI output in Dolby Atmos while APAC plays.

## Overview

On the tested Apple TV and receiver, APAC alone never switched the receiver to Atmos. A second, unmuted player looping a near-silent E-AC-3 + JOC (Dolby Atmos) stream did, and a 7.1.4 channel check then played every speaker in its place, including the heights. ``AtmosOutputActivator`` manages that second player so it follows the host's playback.

This module does not link the Rust core, so players can adopt it independently of SpatialAudioBridge. Supply the silent stream: the library does not distribute one. The [Atmos output guide](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/atmos-output.md) explains how to make and verify one.

```swift
try AtmosOutputActivator.configureAudioSession()
let atmos = AtmosOutputActivator(silentAtmosStream: silentAtmosURL)
// Every item plays APAC here. When items also offer other audio, pass a predicate that
// returns true only while the APAC rendition is selected.
atmos.attach(to: player)
```

## Topics

### Activating Atmos output

- ``AtmosOutputActivator``
