# ``SpatialAudioPlayback``

Keep Apple TV HDMI output in Dolby Atmos while APAC plays.

## Overview

On the tested Apple TV and receiver, APAC alone never switched the receiver to Atmos. A second, unmuted player looping a silent E-AC-3 stream signalled as Dolby Atmos did, and a 7.1.4 channel check then played every speaker in its place, including the heights. ``AtmosOutputActivator`` manages that second player so it follows the host's playback, and bundles the stream.

This module does not link the Rust core, so players can adopt it independently of SpatialAudioBridge. The [Atmos output guide](https://github.com/kristofferR/SpatialAudioBridge/blob/main/docs/atmos-output.md) explains how the stream is made and what was tested.

```swift
try AtmosOutputActivator.configureAudioSession()
let atmos = AtmosOutputActivator()
// Every item plays APAC here. When items also offer other audio, pass a predicate that
// returns true only while the APAC rendition is selected.
atmos.attach(to: player)
```

## Topics

### Activating Atmos output

- ``AtmosOutputActivator``
