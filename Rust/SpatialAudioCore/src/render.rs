//! Speaker rendering in Apple's Atmos channel order. Objects use constant-power VBAP.
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
    fn position(self) -> [f32; 3] {
        let (az, el): (f32, f32) = match self {
            Self::L => (-30., 0.),
            Self::R => (30., 0.),
            Self::C | Self::Lfe => (0., 0.),
            Self::Ls => (-90., 0.),
            Self::Rs => (90., 0.),
            Self::Lb => (-150., 0.),
            Self::Rb => (150., 0.),
            Self::Lw => (-60., 0.),
            Self::Rw => (60., 0.),
            Self::Tfl => (-30., 45.),
            Self::Tfr => (30., 45.),
            Self::Tsl => (-90., 75.),
            Self::Tsr => (90., 75.),
            Self::Tbl => (-150., 45.),
            Self::Tbr => (150., 45.),
            Self::Tc => (0., 90.),
            Self::Tfc => (0., 45.),
        };
        let (a, e) = (az.to_radians(), el.to_radians());
        [a.sin() * e.cos(), a.cos() * e.cos(), e.sin()]
    }
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a.iter().zip(b).map(|(a, b)| a * b).sum()
}
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn normalize(mut p: [f32; 3]) -> [f32; 3] {
    p[2] = p[2].max(0.);
    let n = dot(p, p).sqrt();
    if n < 1e-6 {
        [0., 1., 0.]
    } else {
        p.map(|x| x / n)
    }
}

pub struct Panner {
    speakers: Vec<Speaker>,
    directions: Vec<[f32; 3]>,
    triangles: Vec<[usize; 3]>,
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
        let directions: Vec<_> = speakers.iter().map(|s| s.position()).collect();
        let mut triangles = Vec::new();
        for a in 0..speakers.len() {
            for b in a + 1..speakers.len() {
                for c in b + 1..speakers.len() {
                    if [a, b, c].contains(&3) {
                        continue;
                    }
                    let normal = cross(
                        sub(directions[b], directions[a]),
                        sub(directions[c], directions[a]),
                    );
                    let distances: Vec<_> = directions
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| *i != 3)
                        .map(|(_, p)| dot(normal, sub(*p, directions[a])))
                        .collect();
                    let determinant = dot(directions[a], cross(directions[b], directions[c]));
                    if determinant.abs() > 1e-5
                        && (distances.iter().all(|d| *d >= -1e-5)
                            || distances.iter().all(|d| *d <= 1e-5))
                    {
                        triangles.push([a, b, c]);
                    }
                }
            }
        }
        Self {
            speakers,
            directions,
            triangles,
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
            self.object(speaker.position())
        }
    }
    pub fn object(&self, position: [f32; 3]) -> Gains {
        let p = normalize(position);
        let mut result = [0.; MAX_CHANNELS];
        for (i, dir) in self.directions.iter().enumerate() {
            if i != 3 && dot(p, *dir) > 0.99999 {
                result[i] = 1.;
                return result;
            }
        }
        for &[a, b, c] in &self.triangles {
            let (u, v, w) = (self.directions[a], self.directions[b], self.directions[c]);
            let det = dot(u, cross(v, w));
            let gains = [
                dot(p, cross(v, w)) / det,
                dot(u, cross(p, w)) / det,
                dot(u, cross(v, p)) / det,
            ];
            if gains.iter().all(|g| *g >= -1e-5) {
                let norm = gains.iter().map(|g| g.max(0.).powi(2)).sum::<f32>().sqrt();
                if norm > 1e-6 {
                    for (i, g) in [a, b, c].into_iter().zip(gains) {
                        result[i] = g.max(0.) / norm;
                    }
                    return result;
                }
            }
        }
        // A point below the speaker hull is projected onto the nearest speaker.
        let mut closest: Vec<_> = self
            .directions
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != 3)
            .map(|(i, d)| (i, dot(*d, p)))
            .collect();
        closest.sort_by(|a, b| b.1.total_cmp(&a.1));
        result[closest[0].0] = 1.;
        result
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
    #[test]
    fn panning_is_constant_power_across_the_upper_hemisphere() {
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let p = Panner::new(layout);
            for az in (-180..180).step_by(7) {
                for el in (0..91).step_by(5) {
                    let (a, e) = ((az as f32).to_radians(), (el as f32).to_radians());
                    let g = p.object([a.sin() * e.cos(), a.cos() * e.cos(), e.sin()]);
                    assert!((g.iter().map(|x| x * x).sum::<f32>() - 1.).abs() < 1e-5);
                    assert_eq!(g[3], 0.);
                    if el > 75 {
                        assert!(g[8..p.count()].iter().any(|g| *g > 0.));
                    }
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
