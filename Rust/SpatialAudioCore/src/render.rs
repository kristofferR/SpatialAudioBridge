//! Speaker gains and the ramped gain mixer.
//!
//! Atmos objects follow the room-coordinate source panner of ETSI TS 103 448, the AC-4
//! consumer object audio renderer, which shares its object metadata model with TrueHD and
//! DD+. DTS:X objects use physical angles over separate constant-power bed and height rings.
use std::{
    collections::VecDeque,
    f32::consts::{FRAC_1_SQRT_2, FRAC_PI_2},
};

pub const MAX_CHANNELS: usize = 16;
pub type Gains = [f32; MAX_CHANNELS];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Layout {
    SevenOneFour = 12,
    NineOneSix = 16,
}

impl Layout {
    pub fn parse(value: u32) -> Result<Self, String> {
        match value {
            12 => Ok(Self::SevenOneFour),
            16 => Ok(Self::NineOneSix),
            _ => Err("Unsupported output layout".into()),
        }
    }
    pub fn count(self) -> usize {
        self as usize
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Speaker {
    L,
    R,
    C,
    Lfe,
    Ls,
    Rs,
    Lb,
    Rb,
    Lw,
    Rw,
    Tfl,
    Tfr,
    Tsl,
    Tsr,
    Tbl,
    Tbr,
    Tc,
    Tfc,
}

// Speaker classes for zone constraints and elevation (TS 103 448 tables 4 and 5).
const FRONT: u8 = 1;
const CENTRE: u8 = 2;
const WIDE: u8 = 4;
const SIDE: u8 = 8;
const BACK: u8 = 16;
const ELEVATED: u8 = 32;

impl Speaker {
    /// Physical azimuth in degrees. Positive azimuth is right.
    fn azimuth(self) -> f32 {
        match self {
            Self::L => -30.,
            Self::R => 30.,
            Self::C | Self::Lfe | Self::Tc | Self::Tfc => 0.,
            Self::Ls | Self::Tsl => -90.,
            Self::Rs | Self::Tsr => 90.,
            Self::Lb => -145.,
            Self::Rb => 145.,
            Self::Lw => -60.,
            Self::Rw => 60.,
            Self::Tfl => -45.,
            Self::Tfr => 45.,
            Self::Tbl => -135.,
            Self::Tbr => 135.,
        }
    }

    /// TS 103 448 panner target and zone class, from tables A.5 and A.9.
    fn target(self) -> Option<([f32; 3], u8)> {
        Some(match self {
            Self::L => ([0., 0., 0.], FRONT),
            Self::R => ([1., 0., 0.], FRONT),
            Self::C => ([0.5, 0., 0.], CENTRE),
            Self::Ls => ([0., 0.5, 0.], SIDE),
            Self::Rs => ([1., 0.5, 0.], SIDE),
            Self::Lb => ([0., 1., 0.], BACK),
            Self::Rb => ([1., 1., 0.], BACK),
            Self::Lw => ([0., 0.2929, 0.], WIDE),
            Self::Rw => ([1., 0.2929, 0.], WIDE),
            Self::Tfl => ([0.25, 0.25, 1.], ELEVATED),
            Self::Tfr => ([0.75, 0.25, 1.], ELEVATED),
            Self::Tsl => ([0.25, 0.5, 1.], ELEVATED),
            Self::Tsr => ([0.75, 0.5, 1.], ELEVATED),
            Self::Tbl => ([0.25, 0.75, 1.], ELEVATED),
            Self::Tbr => ([0.75, 0.75, 1.], ELEVATED),
            Self::Tc => ([0.5, 0.5, 1.], ELEVATED),
            Self::Tfc => ([0.5, 0.25, 1.], ELEVATED),
            Self::Lfe => return None,
        })
    }

    fn is_height(self) -> bool {
        self.target().is_some_and(|(_, class)| class == ELEVATED)
    }
}

/// Snap locations: the 22.2 panner targets of TS 103 448 table A.9.
const SNAP_TARGETS: [([f32; 3], u8); 22] = [
    ([0., 0., 0.], FRONT),
    ([1., 0., 0.], FRONT),
    ([0.5, 0., 0.], CENTRE),
    ([0., 0.5, 0.], SIDE),
    ([1., 0.5, 0.], SIDE),
    ([0., 1., 0.], BACK),
    ([1., 1., 0.], BACK),
    ([0.25, 0.25, 1.], ELEVATED),
    ([0.75, 0.25, 1.], ELEVATED),
    ([0.25, 0.75, 1.], ELEVATED),
    ([0.75, 0.75, 1.], ELEVATED),
    ([0.25, 0.5, 1.], ELEVATED),
    ([0.75, 0.5, 1.], ELEVATED),
    ([0.5, 0.25, 1.], ELEVATED),
    ([0.5, 0.75, 1.], ELEVATED),
    ([0.5, 0.5, 1.], ELEVATED),
    ([0., 0., -1.], ELEVATED),
    ([1., 0., -1.], ELEVATED),
    ([0.5, 0., -1.], ELEVATED),
    ([0.5, 1., 0.], BACK),
    ([0., 0.2929, 0.], WIDE),
    ([1., 0.2929, 0.], WIDE),
];

/// Speaker classes excluded by `zone_constraints_idx` and `b_enable_elevation`.
fn excluded(zone: u8, elevation: bool) -> u8 {
    let zone = match zone {
        1 => BACK,
        2 => SIDE | WIDE,
        3 => FRONT | WIDE | SIDE,
        4 => SIDE | WIDE | BACK,
        5 => FRONT | CENTRE | WIDE,
        _ => 0,
    };
    if elevation { zone } else { zone | ELEVATED }
}

/// Mid-layer speakers other than the front three, and top speakers, left after zone
/// constraints. They select the trim configuration (TS 103 448 table 7).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrimLayout {
    pub mid: usize,
    pub top: usize,
}

impl TrimLayout {
    /// Trim configuration index, 8 for full 7.1.4 and 9.1.6.
    pub fn index(self) -> usize {
        let row = match self.mid {
            0 => 0,
            1..=3 => 1,
            _ => 2,
        };
        let column = match self.top {
            0 => 0,
            1..=2 => 3,
            _ => 6,
        };
        row + column
    }

    /// Default trim in decibels at a preprocessed position (pseudocode 16).
    pub fn default_db(self, [_, y, z]: [f32; 3]) -> f32 {
        let fraction = |count: usize| (count as f32 / 4.).min(1.);
        let max_trim = (-4.5 + 3. * fraction(self.mid) + 1.5 * fraction(self.top)).min(0.);
        let depth = (y / 0.6).clamp(0., 1.);
        let height = ((z.abs() - 0.2) / 0.8).clamp(0., 1.);
        max_trim * (depth + height).clamp(0., 1.)
    }
}

/// Atmos object metadata in TS 103 448 room coordinates: x from left to right and y from
/// front to back in [0, 1], z from the bed plane to the ceiling in [-1, 1].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Object {
    pub position: [f32; 3],
    /// Width, depth and height in [0, 1].
    pub size: [f32; 3],
    pub divergence: f32,
    pub snap: bool,
    /// `zone_constraints_idx` in [0, 5].
    pub zone: u8,
    pub elevation: bool,
}

impl Object {
    pub fn point(position: [f32; 3]) -> Self {
        Self {
            position,
            size: [0.; 3],
            divergence: 0.,
            snap: false,
            zone: 0,
            elevation: true,
        }
    }
}

struct Target {
    channel: usize,
    azimuth: f32,
}

struct Ring {
    targets: Vec<Target>,
}
impl Ring {
    fn new(speakers: &[Speaker], height: bool) -> Self {
        let mut targets: Vec<_> = speakers
            .iter()
            .enumerate()
            .filter(|(_, speaker)| **speaker != Speaker::Lfe && speaker.is_height() == height)
            .map(|(channel, speaker)| Target {
                channel,
                azimuth: speaker.azimuth(),
            })
            .collect();
        targets.sort_by(|a, b| a.azimuth.total_cmp(&b.azimuth));
        Self { targets }
    }

    // The last interval crosses the rear seam. Use the same interpolation there.
    fn pair(&self, angle: f32) -> (&Target, &Target, f32) {
        let angle = (angle + 180.).rem_euclid(360.) - 180.;
        let next = self.targets.partition_point(|t| t.azimuth <= angle);
        let count = self.targets.len();
        let a = &self.targets[(next + count - 1) % count];
        let b = &self.targets[next % count];
        let span = (b.azimuth - a.azimuth).rem_euclid(360.);
        let offset = (angle - a.azimuth).rem_euclid(360.);
        (a, b, (offset / span).clamp(0., 1.))
    }

    fn angular(&self, azimuth: f32) -> Gains {
        let (a, b, t) = self.pair(azimuth);
        let mut gains = [0.; MAX_CHANNELS];
        gains[a.channel] = (t * FRAC_PI_2).cos().max(0.);
        gains[b.channel] = (t * FRAC_PI_2).sin();
        gains
    }

    /// Equal power over the ring.
    fn equal(&self) -> Gains {
        let mut gains = [0.; MAX_CHANNELS];
        for target in &self.targets {
            gains[target.channel] = (1. / self.targets.len() as f32).sqrt();
        }
        gains
    }
}

pub struct Panner {
    speakers: Vec<Speaker>,
    bed: Ring,
    height: Ring,
    /// Output channel, TS 103 448 panner target and zone class of each speaker except LFE.
    room: Vec<(usize, [f32; 3], u8)>,
    /// Snap locations in the order TS 103 448 clause 5.1.4.2 breaks ties.
    snap: Vec<([f32; 3], u8)>,
}
impl Panner {
    pub fn new(layout: Layout) -> Self {
        use Speaker::*;
        let speakers = match layout {
            Layout::SevenOneFour => vec![L, R, C, Lfe, Ls, Rs, Lb, Rb, Tfl, Tfr, Tbl, Tbr],
            Layout::NineOneSix => vec![
                L, R, C, Lfe, Ls, Rs, Lb, Rb, Lw, Rw, Tfl, Tfr, Tsl, Tsr, Tbl, Tbr,
            ],
        };
        let room = speakers
            .iter()
            .enumerate()
            .filter_map(|(channel, s)| s.target().map(|(p, class)| (channel, p, class)))
            .collect();
        let mut snap = SNAP_TARGETS.to_vec();
        // Centre, then descending z, descending y and ascending x.
        let first = |p: &[f32; 3]| {
            [[0.5, 0., 0.], [0.5, 0., 1.], [0.5, 0., -1.]]
                .iter()
                .position(|f| f == p)
        };
        snap.sort_by(|(a, _), (b, _)| {
            let rank = |p: &[f32; 3]| first(p).unwrap_or(3);
            rank(a)
                .cmp(&rank(b))
                .then(b[2].total_cmp(&a[2]))
                .then(b[1].total_cmp(&a[1]))
                .then(a[0].total_cmp(&b[0]))
        });
        Self {
            bed: Ring::new(&speakers, false),
            height: Ring::new(&speakers, true),
            speakers,
            room,
            snap,
        }
    }
    pub fn count(&self) -> usize {
        self.speakers.len()
    }

    /// Routes a channel to its speaker, or pans it at the speaker's azimuth when absent.
    pub fn speaker(&self, speaker: Speaker) -> Gains {
        if let Some(index) = self.speakers.iter().position(|s| *s == speaker) {
            let mut result = [0.; MAX_CHANNELS];
            result[index] = 1.;
            result
        } else if speaker == Speaker::Tc {
            self.height.equal()
        } else if speaker.is_height() {
            self.height.angular(speaker.azimuth())
        } else {
            self.bed.angular(speaker.azimuth())
        }
    }

    /// Speaker-anchored routing of an Atmos bed channel (TS 103 448 clause 5.2.5, table 6).
    pub fn bed(&self, speaker: Speaker) -> Gains {
        use Speaker::*;
        let route: &[Speaker] = match speaker {
            s if self.speakers.contains(&s) => return self.speaker(s),
            // The 3/4/4 column plays a wide from the front speaker on its side and a top
            // middle from the front and back tops on its side, each at −3 dB.
            Lw => &[L],
            Rw => &[R],
            Tsl => &[Tfl, Tbl],
            Tsr => &[Tfr, Tbr],
            s => return self.speaker(s),
        };
        let mut gains = [0.; MAX_CHANNELS];
        for target in route {
            gains[self.speakers.iter().position(|s| s == target).unwrap()] = FRAC_1_SQRT_2;
        }
        gains
    }

    /// Metadata preprocessing (TS 103 448 clauses 5.1.3 and 5.1.4): elevation, then snap.
    pub fn preprocess(&self, mut object: Object) -> Object {
        if !object.elevation {
            object.position[2] = 0.;
        }
        if object.snap {
            let excluded = excluded(object.zone, object.elevation);
            let distance = |(p, _): &&([f32; 3], u8)| {
                let d = [0, 1, 2].map(|i| (object.position[i] - p[i]).powi(2));
                d[0] / 16. + 4. * d[1] + 32. * d[2]
            };
            if let Some((position, _)) = self
                .snap
                .iter()
                .filter(|(_, class)| class & excluded == 0)
                .min_by(|a, b| distance(a).total_cmp(&distance(b)))
            {
                object.position = *position;
            }
            object.size = [0.; 3];
            object.divergence = 0.;
        }
        object
    }

    /// Speaker counts selecting an object's trim configuration, after its zone constraints.
    pub fn trim_layout(&self, object: &Object) -> TrimLayout {
        let excluded = excluded(object.zone, object.elevation);
        let count = |classes: u8| {
            let included = |class: &u8| class & classes != 0 && class & excluded == 0;
            self.room
                .iter()
                .filter(|(_, _, class)| included(class))
                .count()
        };
        TrimLayout {
            mid: count(WIDE | SIDE | BACK),
            top: count(ELEVATED),
        }
    }

    /// Source panner (TS 103 448 clause 5.2) for preprocessed metadata.
    pub fn object(&self, object: &Object) -> Gains {
        let excluded = excluded(object.zone, object.elevation);
        let (channels, targets): (Vec<_>, Vec<_>) = self
            .room
            .iter()
            .filter(|(_, _, class)| class & excluded == 0)
            .map(|(channel, position, _)| (*channel, *position))
            .unzip();
        let gains = if object.divergence > 0. {
            divergence(&targets, object)
        } else if object.size.iter().any(|s| *s > 0.) {
            size(&targets, object)
        } else {
            point(&targets, object.position)
        };
        let mut result = [0.; MAX_CHANNELS];
        for (channel, gain) in channels.into_iter().zip(gains) {
            result[channel] = gain;
        }
        result
    }

    /// Polar objects use physical azimuths, with the height ring at 45 degrees.
    /// Above that ring, power spreads towards the overhead centre. Nearer objects
    /// spread towards room centre; distances outside the reference radius project inward.
    pub fn polar(&self, azimuth: f32, elevation: f32, distance: f32) -> Gains {
        let elevation = elevation.clamp(0., 90.);
        let bed = self.bed.angular(azimuth);
        let mut height = self.height.angular(azimuth);
        let overhead = ((elevation - 45.) / 45.).max(0.);
        for target in &self.height.targets {
            height[target.channel] = (overhead / self.height.targets.len() as f32
                + (1. - overhead) * height[target.channel].powi(2))
            .sqrt();
        }
        let vertical = (elevation / 45.).min(1.) * FRAC_PI_2;
        let (height_gain, bed_gain) = (vertical.sin(), vertical.cos().max(0.));
        let centre = self.bed.equal();
        let radius = distance.clamp(0., 1.);
        std::array::from_fn(|i| {
            let directional = bed[i] * bed_gain + height[i] * height_gain;
            (radius * directional.powi(2) + (1. - radius) * centre[i].powi(2)).sqrt()
        })
    }
}

fn sign(value: f32) -> i8 {
    i8::from(value > 0.) - i8::from(value < 0.)
}

/// Gain of the target at `this` along one axis, given the coordinates of the targets that
/// share its plane or row (TS 103 448 pseudocode 4 to 6).
fn axis(this: f32, others: impl Iterator<Item = f32>, position: f32) -> f32 {
    let other = if this >= position {
        others.filter(|v| *v < this).reduce(f32::max)
    } else {
        others.filter(|v| *v > this).reduce(f32::min)
    };
    match other {
        None => 1.,
        Some(other) if sign(other - position) == sign(this - position) => 0.,
        Some(other) => ((this - position) / (other - this) * FRAC_PI_2)
            .cos()
            .max(0.),
    }
}

fn same(a: f32, b: f32) -> bool {
    (a - b).abs() < 0.001
}

fn pan_z(targets: &[[f32; 3]], z: f32) -> Vec<f32> {
    let planes = || targets.iter().map(|t| t[2]);
    targets.iter().map(|t| axis(t[2], planes(), z)).collect()
}

fn pan_y(targets: &[[f32; 3]], y: f32) -> Vec<f32> {
    let gain = |t: &[f32; 3]| {
        let plane = targets.iter().filter(|o| same(o[2], t[2]));
        axis(t[1], plane.map(|o| o[1]), y)
    };
    targets.iter().map(gain).collect()
}

fn pan_x(targets: &[[f32; 3]], x: f32) -> Vec<f32> {
    let gain = |t: &[f32; 3]| {
        let row = targets
            .iter()
            .filter(|o| same(o[2], t[2]) && same(o[1], t[1]));
        axis(t[0], row.map(|o| o[0]), x)
    };
    targets.iter().map(gain).collect()
}

/// Point source panner (pseudocode 3): unit power over at most eight speakers.
fn point(targets: &[[f32; 3]], [x, y, z]: [f32; 3]) -> Vec<f32> {
    let (gx, gy, gz) = (pan_x(targets, x), pan_y(targets, y), pan_z(targets, z));
    (0..targets.len()).map(|j| gx[j] * gy[j] * gz[j]).collect()
}

fn normalized<T: Into<f64> + Copy>(gains: &[T]) -> Vec<f64> {
    let total = gains
        .iter()
        .map(|g| (*g).into().powi(2))
        .sum::<f64>()
        .sqrt();
    gains
        .iter()
        .map(|g| (*g).into() / total.max(1e-5))
        .collect()
}

/// Divergence panner (pseudocode 15): two sources spread along x, kept inside the room.
fn divergence(targets: &[[f32; 3]], object: &Object) -> Vec<f32> {
    let [x, y, z] = object.position;
    let spread = object.divergence.min(1. - (x - 0.5).abs() * 2.);
    let (left, right) = (
        pan_x(targets, x - spread / 2.),
        pan_x(targets, x + spread / 2.),
    );
    let (gy, gz) = (pan_y(targets, y), pan_z(targets, z));
    let gains: Vec<f32> = (0..targets.len())
        .map(|j| gz[j] * gy[j] * (left[j] + right[j]))
        .collect();
    normalized(&gains).into_iter().map(|g| g as f32).collect()
}

/// Maps object width to the size panner's scale (pseudocode 7).
fn size_scale(width: f64) -> f64 {
    match width {
        w if w < 1e-5 => 0.,
        w if w <= 0.2 => 1.5 * w,
        w if w <= 0.5 => 7. / 3. * w - 1. / 6.,
        w if w <= 0.75 => 3.2 * w - 0.6,
        w => 4. * w - 1.2,
    }
}

/// Weight of a virtual source at `a` for an object at `b` of size `c` (pseudocode 8).
fn weight(a: f64, b: f64, c: f64) -> f64 {
    if c > 0. {
        10f64.powf(-(1.5 * (a - b) / c).powi(4))
    } else {
        0.
    }
}

/// Distance-based fade near the room boundaries (pseudocode 13).
fn fade(position: f64, size: f64, min: f64) -> f64 {
    let distance = (position - min).min(1. - position);
    if distance < size || distance < 0.2 {
        distance / size.max(0.2)
    } else {
        1.
    }
}

/// Size panner (TS 103 448 clause 5.2.3) for layouts without bottom speakers.
fn size(targets: &[[f32; 3]], object: &Object) -> Vec<f32> {
    const COUNTS: [usize; 3] = [20, 20, 8];
    let [x, y, z] = object.position.map(|p| f64::from(p).max(0.));
    let size = object.size.map(|w| size_scale(w.into()));
    let bound = |axis: usize| size[axis].max(2. / (COUNTS[axis] - 1) as f64);
    let lb = [bound(0), bound(1), bound(2)];

    // Pseudocode 9: effective size and exponent.
    let mut sorted = size;
    sorted.sort_by(|a, b| b.total_cmp(a));
    let effective = 2. / 3. * sorted[0] + 2. / 9. * sorted[1] + 1. / 9. * sorted[2];
    let p = if effective > 0.5 {
        6. - (effective - 0.5) * 4. / 2.3
    } else {
        6.
    };

    // Pseudocode 10: weighted sums over equidistant virtual sources per axis.
    let pans: [&dyn Fn(f32) -> Vec<f32>; 3] =
        [&|v| pan_x(targets, v), &|v| pan_y(targets, v), &|v| {
            pan_z(targets, v)
        }];
    let w: Vec<Vec<f64>> = (0..3)
        .map(|axis| {
            let mut sums = vec![0.; targets.len()];
            for s in 0..COUNTS[axis] {
                let v = s as f64 / (COUNTS[axis] - 1) as f64;
                let weight = weight(v, [x, y, z][axis], lb[axis]);
                for (sum, gain) in sums.iter_mut().zip(pans[axis](v as f32)) {
                    *sum += (f64::from(gain) * weight).powf(p);
                }
            }
            sums
        })
        .collect();
    let inside: Vec<f64> = (0..targets.len())
        .map(|j| (w[0][j] * w[1][j] * w[2][j]).powf(1. / p))
        .collect();
    let inside = normalized(&inside);

    // Pseudocode 11: virtual sources on the six room boundaries, each weighted by the
    // other two axes' sums.
    let mut boundary = vec![0.; targets.len()];
    for axis in 0..3 {
        for at in [0., 1.] {
            let weight = weight(at, [x, y, z][axis], lb[axis]);
            for (j, gain) in pans[axis](at as f32).into_iter().enumerate() {
                let across = w[(axis + 1) % 3][j] * w[(axis + 2) % 3][j];
                boundary[j] += (f64::from(gain) * weight).powf(p) * across;
            }
        }
    }
    let boundary = normalized(&boundary);

    // Pseudocode 12: inside sources fade out towards the walls.
    let out = fade(x, lb[0], 0.) * fade(y, lb[1], 0.) * fade(z, lb[2], 0.);
    let sized: Vec<f64> = (0..targets.len())
        .map(|j| (boundary[j] + out * inside[j]).powf(1. / p))
        .collect();
    let sized = normalized(&sized);

    // Pseudocode 14: small objects crossfade from the point panner.
    let (alpha, beta) = if effective < 0.2 {
        let angle = effective / 0.2 * std::f64::consts::FRAC_PI_2;
        (angle.cos(), angle.sin())
    } else {
        (0., 1.)
    };
    let point = point(targets, object.position);
    let gains: Vec<f64> = (0..targets.len())
        .map(|j| alpha * f64::from(point[j]) + beta * sized[j])
        .collect();
    normalized(&gains).into_iter().map(|g| g as f32).collect()
}

#[derive(Clone)]
pub struct Event {
    pub sample: u64,
    pub channel: usize,
    pub gains: Gains,
    pub ramp: u32,
}
#[derive(Default, Clone)]
struct Route {
    current: Gains,
    target: Gains,
    step: Gains,
    remaining: u32,
}

pub struct Renderer {
    pub panner: Panner,
    routes: Vec<Route>,
    events: VecDeque<Event>,
    pub sample: u64,
}
impl Renderer {
    pub fn new(layout: Layout) -> Self {
        Self {
            panner: Panner::new(layout),
            routes: vec![],
            events: VecDeque::new(),
            sample: 0,
        }
    }
    pub fn event(&mut self, event: Event) {
        let i = self
            .events
            .iter()
            .position(|e| e.sample > event.sample)
            .unwrap_or(self.events.len());
        self.events.insert(i, event);
    }
    pub fn route(&mut self, channel: usize, gains: Gains) {
        self.routes
            .resize_with(self.routes.len().max(channel + 1), Route::default);
        self.routes[channel] = Route {
            current: gains,
            target: gains,
            ..Default::default()
        };
    }
    pub fn render(&mut self, input: &[Vec<f32>], frames: usize) -> Vec<f32> {
        self.routes
            .resize_with(self.routes.len().max(input.len()), Route::default);
        let count = self.panner.count();
        let mut out = vec![0.; frames * count];
        for frame in 0..frames {
            while self.events.front().is_some_and(|e| e.sample <= self.sample) {
                let event = self.events.pop_front().unwrap();
                self.routes
                    .resize_with(self.routes.len().max(event.channel + 1), Route::default);
                let route = &mut self.routes[event.channel];
                route.target = event.gains;
                route.remaining = event.ramp + 1;
                if event.ramp == 0 {
                    route.current = event.gains;
                } else {
                    for i in 0..count {
                        route.step[i] =
                            (event.gains[i] - route.current[i]) / (event.ramp + 1) as f32;
                    }
                }
            }
            for (channel, pcm) in input.iter().enumerate() {
                let route = &mut self.routes[channel];
                if route.remaining > 0 {
                    for i in 0..count {
                        route.current[i] += route.step[i];
                    }
                    route.remaining -= 1;
                    if route.remaining == 0 {
                        route.current = route.target;
                    }
                }
                for i in 0..count {
                    out[frame * count + i] += pcm[frame] * route.current[i];
                }
            }
            self.sample += 1;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const M: f32 = FRAC_1_SQRT_2;
    const LAYOUTS: [Layout; 2] = [Layout::SevenOneFour, Layout::NineOneSix];

    fn power(gains: &[f32]) -> f32 {
        gains.iter().map(|g| g * g).sum()
    }
    fn distance(a: &Gains, b: &Gains) -> f32 {
        a.iter()
            .zip(b)
            .map(|(a, b)| (a - b).powi(2))
            .sum::<f32>()
            .sqrt()
    }
    /// Whether `actual` has the listed channel gains and silence elsewhere.
    fn close(actual: &Gains, expected: &[(usize, f32)]) -> bool {
        (0..MAX_CHANNELS).all(|i| {
            let gain = expected
                .iter()
                .find(|(c, _)| *c == i)
                .map_or(0., |(_, g)| *g);
            (actual[i] - gain).abs() < 1e-5
        })
    }
    fn at(p: &Panner, position: [f32; 3]) -> Gains {
        p.object(&Object::point(position))
    }

    #[test]
    fn height_does_not_leak_into_lfe_or_bed() {
        let p = Panner::new(Layout::NineOneSix);
        let g = p.speaker(Speaker::Tfl);
        assert_eq!(g[10], 1.);
        assert_eq!(g.iter().filter(|x| **x != 0.).count(), 1);
    }

    #[test]
    fn panner_targets_route_to_their_own_speaker() {
        for layout in LAYOUTS {
            let p = Panner::new(layout);
            for (channel, position, _) in &p.room {
                assert!(
                    close(&at(&p, *position), &[(*channel, 1.)]),
                    "{layout:?} {position:?}"
                );
            }
        }
    }

    #[test]
    fn interior_positions_pan_between_neighbouring_rows() {
        let p = Panner::new(Layout::SevenOneFour);
        // Halfway from the front wall to the listener: centre and the side pair, no rears.
        assert!(close(
            &at(&p, [0.5, 0.25, 0.]),
            &[(2, M), (4, 0.5), (5, 0.5)]
        ));
        // The room centre plays from the side pair.
        assert!(close(&at(&p, [0.5, 0.5, 0.]), &[(4, M), (5, M)]));
        // 9.1.6 wides form their own row between the front and side rows.
        let p = Panner::new(Layout::NineOneSix);
        assert!(close(&at(&p, [0., 0.2929 / 2., 0.]), &[(0, M), (8, M)]));
    }

    #[test]
    fn ceiling_targets_are_inset_from_the_walls() {
        let p = Panner::new(Layout::SevenOneFour);
        assert!(close(&at(&p, [0., 0., 1.]), &[(8, 1.)]));
        let overhead = [(8, 0.5), (9, 0.5), (10, 0.5), (11, 0.5)];
        assert!(close(&at(&p, [0.5, 0.5, 1.]), &overhead));
        let p = Panner::new(Layout::NineOneSix);
        assert!(close(&at(&p, [0.5, 0.5, 1.]), &[(12, M), (13, M)]));
        let halfway = at(&p, [0.2, 0.4, 0.5]);
        assert!((power(&halfway[..10]) - 0.5).abs() < 1e-5);
        assert!((power(&halfway[10..]) - 0.5).abs() < 1e-5);
        // No layout has floor speakers, so positions below the bed plane play on the bed.
        assert!(close(&at(&p, [0., 0., -0.5]), &[(0, 1.)]));
    }

    #[test]
    fn point_gains_have_unit_power_on_at_most_eight_speakers() {
        for layout in LAYOUTS {
            let p = Panner::new(layout);
            for x in 0..=10 {
                for y in 0..=10 {
                    for z in -2..=10 {
                        let g = at(&p, [x as f32 / 10., y as f32 / 10., z as f32 / 10.]);
                        assert!((power(&g) - 1.).abs() < 1e-5);
                        assert!(g.iter().filter(|g| **g > 1e-6).count() <= 8);
                        assert!(g.iter().all(|g| g.is_finite() && *g >= 0.));
                        assert_eq!(g[3], 0.);
                    }
                }
            }
        }
    }

    #[test]
    fn point_gains_are_continuous() {
        for layout in LAYOUTS {
            let p = Panner::new(layout);
            for x in 0..=20 {
                for y in 0..=20 {
                    for z in [0., 0.3, 1.] {
                        let position = [x as f32 / 20., y as f32 / 20., z];
                        for axis in 0..3 {
                            let mut moved = position;
                            moved[axis] += 1e-4;
                            let step = distance(&at(&p, position), &at(&p, moved));
                            assert!(step < 0.01, "{layout:?} {position:?} {axis}");
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn bed_channels_follow_the_speaker_anchored_table() {
        let p = Panner::new(Layout::SevenOneFour);
        assert!(close(&p.bed(Speaker::Ls), &[(4, 1.)]));
        assert!(close(&p.bed(Speaker::Lw), &[(0, M)]));
        assert!(close(&p.bed(Speaker::Tsr), &[(9, M), (11, M)]));
        assert!(close(
            &Panner::new(Layout::NineOneSix).bed(Speaker::Lw),
            &[(8, 1.)]
        ));
    }

    #[test]
    fn zones_exclude_speakers_from_panning() {
        let p = Panner::new(Layout::SevenOneFour);
        let zoned = |zone, position| {
            p.object(&Object {
                zone,
                ..Object::point(position)
            })
        };
        // Screen only: a rear-left object plays from the front left.
        assert!(close(&zoned(4, [0., 1., 0.]), &[(0, 1.)]));
        // No backs: a rear-right object plays from the right side.
        assert!(close(&zoned(1, [1., 1., 0.]), &[(5, 1.)]));
        // Elevation disabled: the object drops to the bed plane and heights are excluded.
        let low = p.preprocess(Object {
            elevation: false,
            ..Object::point([0., 0., 1.])
        });
        assert!(close(&p.object(&low), &[(0, 1.)]));
    }

    #[test]
    fn trim_configuration_follows_the_speakers_left_after_zone_constraints() {
        let rear = [0., 1., 0.];
        for layout in LAYOUTS {
            let p = Panner::new(layout);
            let full = p.trim_layout(&Object::point(rear));
            assert_eq!(full.index(), 8);
            assert_eq!(full.default_db(rear), 0.);
            // Without heights, configuration 2 trims the rear by 1.5 dB.
            let flat = p.trim_layout(&Object {
                elevation: false,
                ..Object::point(rear)
            });
            assert_eq!(flat.index(), 2);
            assert!((flat.default_db(rear) + 1.5).abs() < 1e-6);
            // Screen only leaves no surrounds: configuration 6 trims the rear by 3 dB.
            let screen = p.trim_layout(&Object {
                zone: 4,
                ..Object::point(rear)
            });
            assert_eq!(screen.index(), 6);
            assert!((screen.default_db(rear) + 3.).abs() < 1e-6);
            assert_eq!(screen.default_db([0.5, 0., 0.]), 0.);
        }
    }

    #[test]
    fn snap_moves_to_the_nearest_allowed_location() {
        let p = Panner::new(Layout::SevenOneFour);
        let snapped = |position, zone, elevation| {
            let object = Object {
                snap: true,
                zone,
                elevation,
                size: [0.5; 3],
                divergence: 0.5,
                ..Object::point(position)
            };
            p.preprocess(object)
        };
        let near_left = snapped([0.1, 0.05, 0.], 0, true);
        assert_eq!(near_left.position, [0., 0., 0.]);
        assert_eq!((near_left.size, near_left.divergence), ([0.; 3], 0.));
        // The overhead centre is a snap location even without a speaker there.
        let overhead = snapped([0.45, 0.55, 0.9], 0, true);
        assert_eq!(overhead.position, [0.5, 0.5, 1.]);
        assert!(close(
            &p.object(&overhead),
            &[(8, 0.5), (9, 0.5), (10, 0.5), (11, 0.5)]
        ));
        // Excluded speakers are not snap locations, and y distance weighs far more than x.
        assert_eq!(snapped([0.1, 0.05, 0.], 5, true).position, [0., 0.5, 0.]);
        assert_eq!(snapped([0.45, 0.55, 0.9], 0, false).position, [0., 0.5, 0.]);
    }

    #[test]
    fn divergence_splits_along_x_within_the_room() {
        let p = Panner::new(Layout::SevenOneFour);
        let diverged = |divergence, position| {
            p.object(&Object {
                divergence,
                ..Object::point(position)
            })
        };
        assert!(close(&diverged(1., [0.5, 0., 0.]), &[(0, M), (1, M)]));
        // Near the right wall the spread shrinks to 0.2: sources at x = 0.8 and x = 1.
        assert!(close(
            &diverged(1., [0.9, 0., 0.]),
            &[(1, 0.951057), (2, 0.309017)]
        ));
    }

    #[test]
    fn size_spreads_symmetrically_and_converges_to_a_point() {
        for layout in LAYOUTS {
            let p = Panner::new(layout);
            let sized = |size, position| {
                p.object(&Object {
                    size,
                    ..Object::point(position)
                })
            };
            for width in [0.05, 0.3, 0.6, 1.] {
                for position in [
                    [0.5, 0.5, 0.],
                    [0.5, 0.1, 0.7],
                    [0.2, 0.8, 0.3],
                    [0., 0., 1.],
                ] {
                    let g = sized([width; 3], position);
                    assert!(
                        (power(&g) - 1.).abs() < 1e-4,
                        "{layout:?} {width} {position:?}"
                    );
                    assert!(g.iter().all(|g| g.is_finite() && *g >= 0.) && g[3] == 0.);
                    if position[0] == 0.5 {
                        let mirrored = sized([width; 3], [0.5, position[1], position[2]]);
                        for (left, right) in [(0, 1), (4, 5), (6, 7)] {
                            assert!((mirrored[left] - mirrored[right]).abs() < 1e-5);
                        }
                    }
                }
            }
            let position = [0.3, 0.2, 0.4];
            assert!(distance(&sized([1e-4; 3], position), &at(&p, position)) < 0.01);
            // A larger object reaches more speakers.
            let active = |g: Gains| g.iter().filter(|g| **g > 0.05).count();
            assert!(active(sized([0.8; 3], position)) > active(sized([0.1; 3], position)));
        }
    }

    #[test]
    fn polar_objects_keep_physical_speaker_angles_and_overhead_symmetry() {
        for layout in LAYOUTS {
            let p = Panner::new(layout);
            for (azimuth, elevation, speaker) in [
                (-30., 0., Speaker::L),
                (30., 0., Speaker::R),
                (0., 0., Speaker::C),
                (-45., 45., Speaker::Tfl),
            ] {
                let gains = p.polar(azimuth, elevation, 1.);
                assert!(
                    gains
                        .iter()
                        .zip(p.speaker(speaker))
                        .all(|(a, b)| (a - b).abs() < 1e-6)
                );
            }
            assert_eq!(p.polar(15., 90., 1.), p.polar(-140., 90., 1.));
            assert_eq!(p.polar(30., 0., 0.), p.bed.equal());
            for azimuth in (-180..=180).step_by(5) {
                for elevation in (-90..=90).step_by(5) {
                    for distance in [0., 0.25, 1., 2.] {
                        let gains = p.polar(azimuth as f32, elevation as f32, distance);
                        assert!((power(&gains) - 1.).abs() < 1e-5);
                        assert_eq!(gains[3], 0.);
                    }
                }
            }
        }
    }

    #[test]
    fn absent_dts_channels_pan_at_their_azimuth_on_their_own_ring() {
        let p = Panner::new(Layout::SevenOneFour);
        assert!(close(&p.speaker(Speaker::Lw), &[(0, M), (4, M)]));
        assert!(close(&p.speaker(Speaker::Tsl), &[(8, M), (10, M)]));
    }

    #[test]
    fn metadata_event_is_sample_accurate_and_ramped() {
        let mut r = Renderer::new(Layout::NineOneSix);
        r.route(0, r.panner.speaker(Speaker::L));
        r.event(Event {
            sample: 2,
            channel: 0,
            gains: r.panner.speaker(Speaker::Tfl),
            ramp: 1,
        });
        let pcm = r.render(&[vec![1.; 5]], 5);
        assert_eq!(pcm[16], 1.);
        assert_eq!(pcm[2 * 16], 0.5);
        assert_eq!(pcm[2 * 16 + 10], 0.5);
        assert_eq!(pcm[3 * 16], 0.);
        assert_eq!(pcm[3 * 16 + 10], 1.);
    }
}
