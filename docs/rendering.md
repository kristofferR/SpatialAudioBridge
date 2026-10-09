# Spatial rendering

The renderer produces channel-based 7.1.4 or 9.1.6 PCM. It is a documented approximation for point objects, not a Dolby/DTS reference renderer. Original object metadata is consumed during rendering and is not passed through APAC.

## Separate bed and height tables

Azimuth is zero at the front and positive to the right. Each ring is sorted by azimuth independently; output channels remain in Apple's Atmos layout order.

| Ring | 7.1.4 azimuths | Additional 9.1.6 azimuths |
|---|---|---|
| Bed, excluding LFE | Centre 0°, front ±30°, side ±90°, rear ±145° | Wide ±60° |
| Height | Front ±45°, rear ±135° | Middle ±90° |

Between adjacent targets, normalized angular distance `t` gives gains `cos(t × π/2)` and `sin(t × π/2)`. The rear pair wraps across ±180° using the same rule. This avoids ambiguous triangles and keeps panning continuous at every angular boundary. Missing bed speakers use their physical azimuth on the appropriate ring. Existing bed speakers and decoded DTS:X height channels route directly to the corresponding output channel. Objects never feed LFE.

## Room coordinates

Atmos room positions use `x` from left to right, `y` from rear to front, both in `[-1, 1]`, and `z` from bed to ceiling in `[0, 1]`. Negative heights project onto the bed plane because neither output layout has floor speakers. Extended-precision position offsets are applied before rendering.

Room coordinates are not unit direction vectors. Canonical front corners `[-1, 1]` and `[1, 1]` map to front left/right, side midpoints to surrounds, and rear corners to rear surrounds. Wide anchors use `y = 42/62`. The height ring uses the corresponding ceiling corners and, for 9.1.6, side midpoints. These anchors follow the decoder's published room-coordinate speaker definitions.

The bed ring maps room perimeter angles piecewise onto physical azimuths, preserving these anchors even when a target speaker is absent. Height anchors already share their physical azimuths. This room calibration is independent of the output layout. Interior positions use `r = max(abs(x), abs(y))` and blend power between the perimeter gains and equal power over the ring:

```text
gain[i] = sqrt((1 - r) / ringChannelCount + r × perimeterGain[i]²)
```

The room centre therefore distributes equal power across the ring instead of collapsing to the front centre speaker. This centre distribution and the perimeter mapping are deliberate approximations, not reference-renderer conformance claims.

Vertical position then scales the bed ring by `cos(z × π/2)` and the height ring by `sin(z × π/2)`. Both rings maintain unit power before this blend. A stationary point has unit total gain power; sums of multiple signals and time-domain metadata ramps need not. Metadata ramps interpolate channel gains over the signalled duration plus one sample.

## Metadata boundary

Position, extended precision, object gain, activity, elevation enable, update offsets and gain ramps are implemented. Elevation-disabled objects render at `z = 0`. Inactive object blocks target silence, including when they retain stale object-rendering controls.

A stream entered at a later major sync, after a seek or from a server-side remux, usually carries its first object metadata a few access units in: 7.5–20 ms in measured Blu-ray streams, which then repeat it every 32 ms. The decoder holds up to 0.5 s of audio until that metadata arrives and renders it at the first metadata block's positions. Every sample is kept, so timing is unchanged. A stream without object metadata within 0.5 s is rejected.

The decoder explicitly rejects active objects with nonzero size, snap, zone constraints, screen references or distance controls. It also rejects streams carrying trim metadata, bed distribution, bed downmix metadata or enabled object divergence, alongside ISF and multiple beds. Trim and bed downmix elements are rejected conservatively even if a particular element could be neutral for the requested layout. Hosts should select their existing fallback on these errors.

## DTS:X presentations and polar objects

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

DTS:X objects use physical azimuth, elevation and distance rather than Atmos room coordinates. Physical azimuth drives each ring directly, preserving declared C/L/R angles. The height ring is assumed to sit at 45° elevation. From 0° to 45°, constant-power angular interpolation blends the bed and height rings. Above 45°, height power spreads towards equal power over the height ring, becoming independent of azimuth at 90°. Negative elevations project onto the bed. Distance is clamped to the reference radius `[0, 1]`: nearer objects blend power towards the room centre on the bed, while farther objects retain directional placement without invented distance attenuation. These choices are documented approximations, not DTS reference-renderer behavior.

The first frame uses its declared position immediately. Later position changes interpolate channel gains from the previous frame's target over the decoded frame's sample count, reaching the new target at the final sample. Fixed heights route directly and do not share the object ramp.

Before recombination, `dca::FoldPlan` removes every known spatial contribution from the compatible bed. `dca::FoldRenderer` resolves folds explicitly marked as rendered from object metadata using its own bed reconstruction law and timing; this is independent of the output panner. It cannot reconstruct such folds for a 5.1 reference bed, so that case remains rejected. Explicit 5.1 fold coefficients are supported. Any unresolved fold, unknown presentation, malformed metadata, PCM/metadata count mismatch or inconsistent source role fails explicitly. A presentation change requires a new session. Only lossless DTS-HD carriers at 48 kHz are supported.
