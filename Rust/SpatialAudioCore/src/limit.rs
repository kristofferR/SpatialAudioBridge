use crate::decode::Pcm;
use std::collections::VecDeque;

/// The loudest sample the limiter passes, −0.1 dBFS.
const CEILING: f32 = 0.988_553;
/// Frames over which the gain falls before a peak, 2 ms at 48 kHz.
const LOOKAHEAD: usize = 96;
/// Time constant of the gain's recovery after a peak, 100 ms at 48 kHz.
const RELEASE_FRAMES: f32 = 4_800.;
/// Reduction at which recovery ends, about 1.3 s after a peak.
const RECOVERED: f32 = 1e-6;

/// Keeps rendered speaker feeds at or below `CEILING`. Objects panned into the same speaker add
/// up, so a render can exceed full scale where the mix's own speaker feeds do not. One gain
/// applies to every channel, so the balance between speakers holds; it falls linearly over
/// `LOOKAHEAD` frames to reach a peak exactly and recovers exponentially. Frames with no peak
/// within reach keep a gain of exactly 1 and pass unchanged.
///
/// Output trails input by `LOOKAHEAD - 1` frames until `finish` releases them, so the frame
/// count and timing are unchanged.
pub struct Limiter {
    channels: usize,
    /// Frames rendered but not yet released, interleaved.
    pending: VecDeque<f32>,
    /// The gain each of the latest `LOOKAHEAD` frames needs on its own.
    needed: VecDeque<f32>,
    /// The lowest of `needed` at each of the latest `LOOKAHEAD` frames.
    minima: VecDeque<f32>,
    /// One less the gain. Kept rather than the gain, whose steps near 1 are too coarse for the
    /// release to reach it.
    reduction: f32,
    release: f32,
    rate: u32,
}

impl Limiter {
    pub fn new(channels: usize) -> Self {
        Self {
            channels,
            pending: VecDeque::with_capacity(LOOKAHEAD * channels),
            needed: VecDeque::from(vec![1.; LOOKAHEAD]),
            minima: VecDeque::from(vec![1.; LOOKAHEAD]),
            reduction: 0.,
            release: (-1. / RELEASE_FRAMES).exp(),
            rate: 48_000,
        }
    }

    /// Limits `pcm` and passes on the frames whose gain is now known.
    pub fn push(
        &mut self,
        pcm: Pcm,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), String> {
        self.rate = pcm.rate;
        let mut released = Vec::with_capacity(pcm.data.len());
        for frame in pcm.data.chunks_exact(self.channels) {
            self.pending.extend(frame);
            let peak = frame.iter().fold(0f32, |peak, x| peak.max(x.abs()));
            self.step(peak, false, &mut released);
        }
        self.release(released, output)
    }

    /// Passes on the frames still held back.
    pub fn finish(
        &mut self,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut released = Vec::with_capacity(self.pending.len());
        let frames = self.pending.len() / self.channels;
        if frames > 0 {
            // A short stream has not filled the lookahead yet. Advance with silence until
            // every minimum used for its first frame includes that frame.
            for _ in frames..LOOKAHEAD - 1 {
                self.step(0., false, &mut released);
            }
        }
        while !self.pending.is_empty() {
            self.step(0., true, &mut released);
        }
        self.release(released, output)
    }

    /// Takes the peak of the newest frame and releases the oldest pending frame once the
    /// `LOOKAHEAD` frames from it onwards are known, or at the end.
    fn step(&mut self, peak: f32, end: bool, released: &mut Vec<f32>) {
        self.needed.pop_front();
        self.needed
            .push_back(if peak > CEILING { CEILING / peak } else { 1. });
        self.minima.pop_front();
        self.minima
            .push_back(self.needed.iter().copied().fold(1., f32::min));
        if !end && self.pending.len() < LOOKAHEAD * self.channels {
            return;
        }
        // Every window averaged here includes the released frame, so the gain never exceeds
        // what that frame needs. Cap summation rounding at that frame's required gain.
        let falling = (self.minima.iter().sum::<f32>() / LOOKAHEAD as f32).min(self.needed[0]);
        self.reduction *= self.release;
        if self.reduction < RECOVERED {
            self.reduction = 0.;
        }
        self.reduction = self.reduction.max(1. - falling);
        let gain = falling.min(1. - self.reduction);
        released.extend(self.pending.drain(..self.channels).map(|x| x * gain));
    }

    fn release(
        &self,
        data: Vec<f32>,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), String> {
        if data.is_empty() {
            return Ok(());
        }
        output(Pcm {
            frames: data.len() / self.channels,
            data,
            rate: self.rate,
            channels: self.channels,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limit(input: &[f32], channels: usize, chunk: usize) -> Vec<f32> {
        let mut limiter = Limiter::new(channels);
        let mut output = Vec::new();
        let mut collect = |pcm: Pcm| {
            output.extend(pcm.data);
            Ok(())
        };
        for data in input.chunks(chunk * channels) {
            let pcm = Pcm {
                data: data.to_vec(),
                frames: data.len() / channels,
                rate: 48_000,
                channels,
            };
            limiter.push(pcm, &mut collect).unwrap();
        }
        limiter.finish(&mut collect).unwrap();
        output
    }

    fn tone(frames: usize, channels: usize, level: impl Fn(usize) -> f32) -> Vec<f32> {
        (0..frames * channels)
            .map(|i| level(i / channels) * ((i / channels) as f32 * 0.05 + i as f32).sin())
            .collect()
    }

    #[test]
    fn audio_below_full_scale_passes_unchanged() {
        let input = tone(10_000, 3, |_| 0.98);
        assert_eq!(limit(&input, 3, 4096), input);
        assert_eq!(limit(&input, 3, 1), input);
    }

    #[test]
    fn short_streams_limit_every_peak_without_adding_frames() {
        for frames in 1..=LOOKAHEAD {
            for peak_frame in 0..frames {
                let mut input = vec![0.25; frames * 2];
                input[peak_frame * 2] = 4.;
                input[peak_frame * 2 + 1] = -2.;
                let output = limit(&input, 2, frames);
                assert_eq!(output.len(), input.len());
                assert_eq!(output, limit(&input, 2, 1));
                assert!(
                    output
                        .iter()
                        .all(|x| x.abs() <= CEILING * (1. + f32::EPSILON)),
                    "{frames} frames, peak at {peak_frame}: {output:?}"
                );
                for (before, after) in input
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .zip(output.as_chunks::<2>().0)
                {
                    assert_eq!(after[0] / before[0], after[1] / before[1]);
                }
            }
            let quiet = vec![0.25; frames * 2];
            assert_eq!(limit(&quiet, 2, 1), quiet);
        }
        assert!(limit(&[], 2, 1).is_empty());
    }

    #[test]
    fn peaks_reach_the_ceiling_and_the_rest_keeps_its_level() {
        let channels = 12;
        let burst = 20_000..20_050;
        let input = tone(
            100_000,
            channels,
            |n| if burst.contains(&n) { 4. } else { 0.5 },
        );
        let output = limit(&input, channels, 4096);
        assert_eq!(output.len(), input.len(), "every frame is kept");
        assert_eq!(
            output,
            limit(&input, channels, 7),
            "chunking must not alter the output"
        );
        let peak = output.iter().fold(0f32, |peak, x| peak.max(x.abs()));
        assert!(
            peak <= CEILING * (1. + f32::EPSILON) && peak > 0.98,
            "peak {peak}"
        );
        let frame = |n: usize| n * channels..(n + 1) * channels;
        let before = frame(burst.start - LOOKAHEAD).start;
        assert_eq!(
            output[..before],
            input[..before],
            "audio before the lookahead is untouched"
        );
        let gain = |n: usize| {
            let (o, i) = (&output[frame(n)], &input[frame(n)]);
            o.iter().map(|x| x.abs()).sum::<f32>() / i.iter().map(|x| x.abs()).sum::<f32>()
        };
        assert!(
            gain(burst.end + 4_800) < 0.95,
            "the gain recovers gradually"
        );
        let after = frame(burst.end + 70_000).start;
        assert_eq!(
            output[after..],
            input[after..],
            "and then leaves the audio untouched again"
        );
    }
}
