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

The decoder explicitly rejects active objects with nonzero size, snap, zone constraints, screen references or distance controls. It also rejects streams carrying trim metadata, bed distribution, bed downmix metadata or enabled object divergence, alongside ISF and multiple beds. Trim and bed downmix elements are rejected conservatively even if a particular element could be neutral for the requested layout. Hosts should select their existing fallback on these errors.

DTS:X support remains limited to the standard four-height presentation and recognized height folds. It does not implement arbitrary moving DTS:X objects or alternate/IMAX presentations.
