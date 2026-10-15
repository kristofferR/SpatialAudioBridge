# Spatial rendering

The renderer produces channel-based 7.1.4 or 9.1.6 PCM. Atmos objects follow the source panner of [ETSI TS 103 448](https://www.etsi.org/deliver/etsi_TS/103400_103499/103448/01.01.01_60/ts_103448v010101p.pdf), Dolby's published consumer object renderer for AC-4, which uses the same object metadata model as TrueHD and DD+ ([ETSI TS 103 420](https://www.etsi.org/deliver/etsi_ts/103400_103499/103420/01.02.01_60/ts_103420v010201p.pdf)). This is an implementation of a published specification, not a licensed Dolby renderer, and receivers may render differently. DTS:X objects use a separate physical-angle model. Object metadata is consumed during rendering and is not passed through APAC.

## Atmos objects

### Room coordinates

TS 103 448 places objects in room coordinates: `x` from left (0) to right (1), `y` from front (0) to back (1) and `z` from the bed plane (0) to the ceiling (1). Negative heights are below the bed plane. truehdd reports positions with extended precision applied, in Dolby Atmos Master Format coordinates, which the renderer converts.

### Panner targets

| Speaker | Target (x, y, z) | Speaker | Target (x, y, z) |
|---|---|---|---|
| L, C, R | (0, 0, 0), (0.5, 0, 0), (1, 0, 0) | Tfl, Tfr | (0.25, 0.25, 1), (0.75, 0.25, 1) |
| Lw, Rw (9.1.6) | (0, 0.2929, 0), (1, 0.2929, 0) | Tsl, Tsr (9.1.6) | (0.25, 0.5, 1), (0.75, 0.5, 1) |
| Ls, Rs | (0, 0.5, 0), (1, 0.5, 0) | Tbl, Tbr | (0.25, 0.75, 1), (0.75, 0.75, 1) |
| Lb, Rb | (0, 1, 0), (1, 1, 0) | | |

7.1.4 uses the 3/4/4 table (A.5). TS 103 448 has no 9.1.6 configuration, so its wide and top middle targets come from the 22.2 table (A.9). The targets are panner coordinates rather than physical positions. Ceiling targets are inset from the walls: an object in a ceiling corner plays from the nearest top speaker alone, and one at the ceiling centre from all top speakers equally.

### Point sources

The point panner is separable. It pans between the two planes around the object's `z`, then within each plane between the two rows around its `y`, then within each row between the two speakers around its `x`. Each step splits power with cosine and sine of the normalized distance between the pair. The product of the three gains has unit power over at most eight speakers. A position beyond the outermost row or speaker stays on it, and positions below the bed plane play on the bed because neither layout has floor speakers.

Inside the room this keeps sound near its position. Halfway between the front wall and the listener, an object plays from the centre speaker at −3 dB and the side pair at −6 dB each, with nothing in the rear. At the room centre it plays from the side pair.

### Size, divergence, snap and zones

- **Size** (clause 5.2.3) spreads an object over equally spaced virtual sources (20 across, 20 deep and 8 high), weighted around its position, plus sources on the room boundaries. Inside sources fade out towards the walls, and small objects crossfade from the point panner.
- **Divergence** (5.2.4) splits an object into two sources at `x ± divergence / 2`, narrowing the split so both stay inside the room.
- **Zone constraints** (5.1.3) exclude speaker groups before panning: backs, sides, everything but the centre and backs, everything but the screen, or the screen. 9.1.6 groups the wides with the sides, as the 22.2 table does. Disabling elevation sets `z` to 0 and excludes the top speakers.
- **Snap** (5.1.4) moves an object to the nearest 22.2 target its zone allows, weighting `x`, `y` and `z` distances by 1/16, 4 and 32, and cancels size and divergence. A snap target without a speaker in the output layout, such as the ceiling centre, is panned.
- **Screen anchoring** (5.1.2) needs the screen's size relative to the front speakers, which the library does not know. It assumes the screen spans the front pair, which leaves positions unchanged. Screen-anchored objects still cancel snap.

### Gain, trim and timing

Object gain applies in decibels. Inactive object blocks target silence, including when they retain stale rendering controls.

The trim configuration follows the surround and top speakers left after an object's zone constraints. Both full layouts use configuration 8 (four or more surrounds and more than two top speakers), where the default trim is 0 dB. Excluding speakers selects a smaller configuration: with elevation disabled, for example, configuration 2's default trim lowers rear positions by up to 1.5 dB. The default trim also applies when a stream carries no trim metadata. A custom trim attenuates by the surround trim, scaled by `y` up to the room's midpoint, plus the height trim scaled by `|z|`. Per-object trim disables apply, and the centre trim applies only to stereo. TS 103 448 has no balance control, so balance metadata is ignored.

The trim metadata's `warp_mode` 1 doubles an object's `y` before rendering (TS 103 420 table 32). It records the Dolby Atmos Renderer's 5.1 direct render with warp, later renamed room balance: with the surrounds at the back of the room, everything behind its midpoint plays at a constant level in them. Both output layouts have side and back surrounds, so the renderer leaves positions as transmitted. *Black Hawk Down* signals warp in some scenes; doubling `y` there would move its side surround channel objects to the back speakers. Reserved warp modes are rejected.

Update offsets count in units of 32 samples. Metadata ramps interpolate channel gains over the signalled duration plus one sample. A stationary point has unit total gain power; sums of signals and gain ramps need not.

### Beds

Bed channels are speaker-anchored (clause 5.2.5) and route directly to their speaker. On 7.1.4, the 3/4/4 column of table 6 plays top middle bed channels from the front and back top pairs at −3 dB each, and wides from the front left or right at −3 dB. Objects never feed LFE. All 179 titles in the [library census](validation.md#library-census) had an LFE-only bed, with everything else in 11, 13 or 15 objects.

### Dialogue normalisation

TrueHD signals a dialogue level for the object presentation. An AV receiver decoding TrueHD attenuates by its difference from −31 dB, for example 4 dB at −27. Apple TV's own Atmos playback does not: its render of a Dolby Digital Plus Atmos track plays at the undialnormed level. By default the renderer follows Apple, so converted tracks play at the level of native Atmos content, and TrueHD and DTS:X, whose decoder exposes no dialogue level, are treated alike. Set `APACConfiguration.normalizesDialogue` to attenuate as a receiver does, from each major sync, with a level change ramped over one access unit. `gainDB` scales the output either way.

### Metadata boundary

A stream entered at a later major sync, after a seek or from a server-side remux, usually carries its first object metadata a few access units in: 7.5–20 ms in measured Blu-ray streams, which then repeat it every 32 ms. The decoder holds up to 0.5 s of audio until that metadata arrives and renders it at the first metadata block's positions. Every sample is kept, so timing is unchanged. A stream without object metadata within 0.5 s is rejected.

A DTS-HD stream entered at a later frame needs the core's history from earlier frames for lossless reconstruction. Measured over 120 seeks into five streams, the first decoded frame's error had a median level only 2.7 dB below the signal itself, and the second frame's error still reached −16 dBFS. Those two frames play as silence; the next is within −30 dBFS of a continuous decode and identical within about ten frames. The decoder cannot tell a stream's first frame from a later one, so a conversion from the very start also begins with these 21 ms of silence, where film soundtracks are silent anyway. A frame whose lossless data is still buffering at the entry point, which the decoder reports as pending, plays as silence for its duration, so later audio keeps its time.

The decoder rejects objects outside the room (distance metadata, which TS 103 448 does not render), reserved zone constraints and warp modes, ISF, multiple beds, bed distribution and bed downmix metadata. None of these appeared in the [library census](validation.md#library-census), and of the controls above only warp mode 1, with default trims, did. Hosts should select their existing fallback on these errors.

### Damaged access units

Discs can join two clips partway through a track. The access unit before the join is cut short, and those after it cannot be decoded until the next major sync, because they follow a restart the join removed. The decoder replaces an access unit that fails to parse or decode with silence of its length, and every one after it up to the next major sync, then resumes there. Every sample is kept, so timing is unchanged. Two of 265 Atmos films in the [library census](validation.md#library-census) have such a join, concealing 42.5 ms and 22.5 ms. A failure at that major sync, no major sync within 128 access units, a stream that ends before it, or a failure before any audio has decoded is rejected.

## DTS:X

### Bed and height rings

DTS:X objects and channels absent from the output layout are panned by physical angle. Azimuth is zero at the front and positive to the right. Each ring is sorted by azimuth independently; output channels remain in Apple's Atmos layout order.

| Ring | 7.1.4 azimuths | Additional 9.1.6 azimuths |
|---|---|---|
| Bed, excluding LFE | Centre 0°, front ±30°, side ±90°, rear ±145° | Wide ±60° |
| Height | Front ±45°, rear ±135° | Middle ±90° |

Between adjacent targets, normalized angular distance `t` gives gains `cos(t × π/2)` and `sin(t × π/2)`. The rear pair wraps across ±180° using the same rule. Missing speakers use their physical azimuth on the appropriate ring. Existing speakers and decoded DTS:X height channels route directly to the corresponding output channel.

### Presentations and polar objects

The pinned `dca` decoder classifies the standard four-height presentation and six known alternate presentations. Source roles and positions come from its metadata parser; feed counts alone do not determine the rendered position.

| Presentation | Object/component feeds first | Fixed height feeds last |
|---|---|---|
| Height | 0 | 4 |
| ObjectD0 | 1 | 4 |
| ObjectsD1 | 2 | 4 |
| ObjectsD0 | 3 C/L/R components | 4 |
| ObjectsD3 | 4 | 4 |
| ObjectsD4 | 5 | 4 |
| ObjectOnly | 1, over a 5.1 bed | 0 |

Alternate profiles remain experimental upstream and here. The alternate marker also appears in streams labelled IMAX, but it is not sufficient to identify IMAX branding. The three-component D0 form routes each component at its declared centre/left/right position. A centre-height alternative flag does not override an object's declared position: neither output layout has a centre-height speaker.

DTS:X objects use physical azimuth, elevation and distance rather than room coordinates. Physical azimuth drives each ring directly, preserving declared C/L/R angles. The height ring is assumed to sit at 45° elevation. From 0° to 45°, constant-power angular interpolation blends the bed and height rings. Above 45°, height power spreads towards equal power over the height ring, becoming independent of azimuth at 90°. Negative elevations project onto the bed. Distance is clamped to the reference radius `[0, 1]`: nearer objects blend power towards equal power over the bed, while farther objects retain directional placement without invented distance attenuation. These choices are documented approximations, not DTS reference-renderer behavior.

The first frame uses its declared position immediately. Later position changes interpolate channel gains from the previous frame's target over the decoded frame's sample count, reaching the new target at the final sample. Fixed heights route directly and do not share the object ramp.

Before recombination, `dca::FoldPlan` removes every known spatial contribution from the compatible bed. `dca::FoldRenderer` resolves folds explicitly marked as rendered from object metadata using its own bed reconstruction law and timing; this is independent of the output panner. It cannot reconstruct such folds for a 5.1 reference bed, so that case remains rejected. Explicit 5.1 fold coefficients are supported. Any unresolved fold, unknown presentation, malformed metadata, PCM/metadata count mismatch or inconsistent source role fails explicitly. A presentation change requires a new session. Only lossless DTS-HD carriers at 48 kHz are supported. All eight DTS:X films in the [library census](validation.md#library-census) used the standard four-height presentation in every frame, with every fold stated, so the alternate profiles and object panning above did not apply to any of them.

## Levels

Rendering is linear, and without dialogue normalisation unless `normalizesDialogue` is set. Objects panned into the same speaker add up, so a channel can exceed full scale where the mix's own speaker feeds would not. Before the limiter below, the [library census](validation.md#library-census) found 135 of 265 Atmos tracks above full scale in 7.1.4, the highest at +8.9 dBFS and 39 above +3 dBFS; the centre exceeded it most often, then front left and the front heights. Two of 29 DTS:X films exceeded it, the IMAX presentation by 1.2 dB. Dolby's own 7.1 presentation of the loudest, *Looper*, peaks at −0.02 dBFS. APAC keeps such peaks (tones encoded at +12 dBFS decoded at +12.1 dBFS through Apple's float decoder), but integer PCM on the way to HDMI cannot.

A lookahead peak limiter therefore holds every channel's samples at or below −0.1 dBFS before encoding. One gain applies to all channels, so the balance between speakers holds. It falls linearly over 2 ms to meet a peak exactly and recovers with a 100 ms time constant, returning to exactly 1 about 1.3 s later. Audio with no peak within reach passes bit for bit. Output trails the decoder by 2 ms until the stream ends, so frame counts and timing are unchanged. In the five films that exceeded full scale most, it changed 0.9–7.0% of each film, in 34 to 384 stretches of at most 9.7 s including recovery, reducing the level by up to 9 dB.

This is not a post-codec or reconstructed-peak ceiling. In a [synthetic APAC round trip](validation.md#apac-peak-measurements), multichannel tones limited to −0.1 dBFS decoded with a +0.455 dBFS sample peak at zero added gain. Some limited signals also had intersample peaks before encoding. No fixed margin sufficient for all content, encoder configurations or receiver paths has been established.

`APACConfiguration.gainDB` scales the output after the limiter, so a positive gain can exceed full scale again; the conversion report's `peakPCM` gives the largest encoded sample.
