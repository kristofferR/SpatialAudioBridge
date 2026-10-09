//! Room-coordinate rendering with separate constant-power bed and height rings.
use std::collections::VecDeque;

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

impl Speaker {
    // Physical azimuth and canonical room anchor. Positive azimuth is right.
    fn placement(self) -> (f32, [f32; 3]) {
        match self {
            Self::L => (-30., [-1., 1., 0.]),
            Self::R => (30., [1., 1., 0.]),
            Self::C | Self::Lfe => (0., [0., 1., 0.]),
            Self::Ls => (-90., [-1., 0., 0.]),
            Self::Rs => (90., [1., 0., 0.]),
            Self::Lb => (-145., [-1., -1., 0.]),
            Self::Rb => (145., [1., -1., 0.]),
            Self::Lw => (-60., [-1., 42. / 62., 0.]),
            Self::Rw => (60., [1., 42. / 62., 0.]),
            Self::Tfl => (-45., [-1., 1., 1.]),
            Self::Tfr => (45., [1., 1., 1.]),
            Self::Tsl => (-90., [-1., 0., 1.]),
            Self::Tsr => (90., [1., 0., 1.]),
            Self::Tbl => (-135., [-1., -1., 1.]),
            Self::Tbr => (135., [1., -1., 1.]),
            Self::Tc => (0., [0., 0., 1.]),
            Self::Tfc => (0., [0., 1., 1.]),
        }
    }
}

struct Target {
    channel: usize,
    azimuth: f32,
}

struct Ring {
    targets: Vec<Target>,
    height: bool,
}
impl Ring {
    fn new(speakers: &[Speaker], height: bool) -> Self {
        let mut targets: Vec<_> = speakers
            .iter()
            .enumerate()
            .filter_map(|(channel, speaker)| {
                let (azimuth, room) = speaker.placement();
                (*speaker != Speaker::Lfe && (room[2] > 0.) == height)
                    .then_some(Target { channel, azimuth })
            })
            .collect();
        targets.sort_by(|a, b| a.azimuth.total_cmp(&b.azimuth));
        Self { targets, height }
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
        gains[a.channel] = (t * std::f32::consts::FRAC_PI_2).cos().max(0.);
        gains[b.channel] = (t * std::f32::consts::FRAC_PI_2).sin();
        gains
    }

    fn room(&self, x: f32, y: f32) -> Gains {
        let radius = x.abs().max(y.abs()).clamp(0., 1.);
        let angle = x.atan2(y).to_degrees();
        let azimuth = if self.height {
            angle
        } else {
            bed_azimuth(angle)
        };
        let mut gains = self.angular(azimuth);
        // Interior positions approach equal power over the ring at room centre.
        // This is a defined approximation, not a reference object renderer.
        let centre_power = (1. - radius) / self.targets.len() as f32;
        for target in &self.targets {
            gains[target.channel] = (centre_power + radius * gains[target.channel].powi(2)).sqrt();
        }
        gains
    }
}

// Keep room calibration independent of the output layout, including missing wide channels.
fn bed_azimuth(room_angle: f32) -> f32 {
    let anchors = [
        (0., 0.),
        (45., 30.),
        (1f32.atan2(42. / 62.).to_degrees(), 60.),
        (90., 90.),
        (135., 145.),
        (180., 180.),
    ];
    for pair in anchors.windows(2) {
        let [(a, from), (b, to)] = [pair[0], pair[1]];
        if room_angle.abs() <= b {
            let t = (room_angle.abs() - a) / (b - a);
            return room_angle.signum() * (from + t * (to - from));
        }
    }
    unreachable!("atan2 produces angles within [-180, 180]")
}

pub struct Panner {
    speakers: Vec<Speaker>,
    bed: Ring,
    height: Ring,
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
        Self {
            bed: Ring::new(&speakers, false),
            height: Ring::new(&speakers, true),
            speakers,
        }
    }
    pub fn count(&self) -> usize {
        self.speakers.len()
    }
    pub fn speaker(&self, speaker: Speaker) -> Gains {
        if let Some(index) = self.speakers.iter().position(|s| *s == speaker) {
            let mut result = [0.; MAX_CHANNELS];
            result[index] = 1.;
            result
        } else {
            let (azimuth, room) = speaker.placement();
            if speaker == Speaker::Tc {
                self.height.room(0., 0.)
            } else if room[2] > 0. {
                self.height.angular(azimuth)
            } else {
                self.bed.angular(azimuth)
            }
        }
    }
    /// x: left/right, y: rear/front in [-1, 1]; z: bed/ceiling in [0, 1].
    /// Below-bed positions project onto the bed plane (no floor speakers).
    pub fn object(&self, position: [f32; 3]) -> Gains {
        let [x, y, z] = position;
        let bed = self.bed.room(x.clamp(-1., 1.), y.clamp(-1., 1.));
        let height = self.height.room(x.clamp(-1., 1.), y.clamp(-1., 1.));
        let angle = z.clamp(0., 1.) * std::f32::consts::FRAC_PI_2;
        let (height_gain, bed_gain) = (angle.sin(), angle.cos().max(0.));
        std::array::from_fn(|i| bed[i] * bed_gain + height[i] * height_gain)
    }
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
    #[test]
    fn height_does_not_leak_into_lfe_or_bed() {
        let p = Panner::new(Layout::NineOneSix);
        let g = p.speaker(Speaker::Tfl);
        assert_eq!(g[10], 1.);
        assert_eq!(g.iter().filter(|x| **x != 0.).count(), 1);
    }
    fn power(gains: &[f32]) -> f32 {
        gains.iter().map(|g| g * g).sum()
    }
    #[test]
    fn canonical_room_anchors_route_to_the_corresponding_channel() {
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let p = Panner::new(layout);
            for (speaker, position) in [
                (Speaker::L, [-1., 1., 0.]),
                (Speaker::R, [1., 1., 0.]),
                (Speaker::C, [0., 1., 0.]),
                (Speaker::Ls, [-1., 0., 0.]),
                (Speaker::Rs, [1., 0., 0.]),
                (Speaker::Lb, [-1., -1., 0.]),
                (Speaker::Rb, [1., -1., 0.]),
                (Speaker::Tfl, [-1., 1., 1.]),
                (Speaker::Tfr, [1., 1., 1.]),
                (Speaker::Tbl, [-1., -1., 1.]),
                (Speaker::Tbr, [1., -1., 1.]),
            ] {
                let actual = p.object(position);
                let expected = p.speaker(speaker);
                assert!(
                    actual
                        .iter()
                        .zip(expected)
                        .all(|(a, b)| (a - b).abs() < 1e-5),
                    "{speaker:?}"
                );
            }
            if layout == Layout::NineOneSix {
                assert!((p.object([-1., 42. / 62., 0.])[8] - 1.).abs() < 1e-5);
                assert!((p.object([-1., 0., 1.])[12] - 1.).abs() < 1e-5);
            }
        }
    }
    #[test]
    fn angular_midpoints_split_power_and_missing_speakers_stay_on_their_plane() {
        let p = Panner::new(Layout::SevenOneFour);
        let wide = p.speaker(Speaker::Lw);
        assert!((wide[0] - 0.5f32.sqrt()).abs() < 1e-6);
        assert!((wide[4] - 0.5f32.sqrt()).abs() < 1e-6);
        assert_eq!(power(&wide[8..]), 0.);
        let object_wide = p.object([-1., 42. / 62., 0.]);
        assert!(
            object_wide
                .iter()
                .zip(wide)
                .all(|(a, b)| (a - b).abs() < 1e-6)
        );
        let top_side = p.speaker(Speaker::Tsl);
        assert!((top_side[8] - 0.5f32.sqrt()).abs() < 1e-6);
        assert!((top_side[10] - 0.5f32.sqrt()).abs() < 1e-6);
        assert_eq!(power(&top_side[..8]), 0.);
    }
    #[test]
    fn room_depth_and_height_are_preserved() {
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let p = Panner::new(layout);
            let height_start = if layout == Layout::SevenOneFour {
                8
            } else {
                10
            };
            let centre = p.object([0., 0., 0.]);
            assert!((centre[2].powi(2) - 1. / (height_start - 1) as f32).abs() < 1e-6);
            let halfway = p.object([0., 0.5, 0.]);
            assert!(halfway[2] > centre[2] && halfway[2] < 1.);
            let middle = p.object([0.2, -0.4, 0.5]);
            assert!((power(&middle[..height_start]) - 0.5).abs() < 1e-6);
            assert!((power(&middle[height_start..]) - 0.5).abs() < 1e-6);
            assert_eq!(power(&p.object([0.2, -0.4, 1.])[..height_start]), 0.);
            assert_eq!(power(&p.object([0.2, -0.4, -0.5])[height_start..]), 0.);
        }
    }
    #[test]
    fn room_grid_has_unit_power_and_no_lfe() {
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let p = Panner::new(layout);
            for x in -10..=10 {
                for y in -10..=10 {
                    for z in 0..=10 {
                        let g = p.object([x as f32 / 10., y as f32 / 10., z as f32 / 10.]);
                        assert!((power(&g) - 1.).abs() < 1e-5);
                        assert!(g.iter().all(|g| g.is_finite() && *g >= 0.));
                        assert_eq!(g[3], 0.);
                    }
                }
            }
        }
    }
    #[test]
    fn angular_sweeps_are_continuous_including_the_rear_seam() {
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let p = Panner::new(layout);
            for degree in -180..=180 {
                for z in [0., 0.5, 1.] {
                    let sample = |offset: f32| {
                        let a = (degree as f32 + offset).to_radians();
                        let radius = a.sin().abs().max(a.cos().abs());
                        p.object([a.sin() / radius, a.cos() / radius, z])
                    };
                    let before = sample(-0.001);
                    let after = sample(0.001);
                    let difference: f32 =
                        before.iter().zip(after).map(|(a, b)| (a - b).powi(2)).sum();
                    assert!(difference.sqrt() < 0.001, "{layout:?} {degree} {z}");
                }
            }
        }
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
