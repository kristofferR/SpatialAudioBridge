use spatial_audio_core::render::{Gains, Layout, Object, Panner};
use std::{env, fs::File, io::{BufWriter, Write}};

/// Renders one pink-noise object moving around the room to interleaved Float32 speaker feeds:
/// a lap at ear level through the wide positions, then the same lap at the ceiling through
/// the top middles. The noise is seeded, so 7.1.4 and 9.1.6 renders differ only in panning.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    let layout = match args.get(1).map(String::as_str) {
        Some("7.1.4") => Layout::SevenOneFour,
        Some("9.1.6") => Layout::NineOneSix,
        _ => return Err("usage: object_path <7.1.4|9.1.6> <output.f32le>".into()),
    };
    let output = args.get(2).ok_or("missing output")?;
    let (rate, block) = (48_000usize, 480usize);
    let frames = rate * 41 / 2;
    let channels = layout.count();
    let panner = Panner::new(layout);
    // Each lap: front centre, front left, back left, back right, front right, front centre.
    let corners: [[f32; 2]; 6] = [[0.5, 0.], [0., 0.], [0., 1.], [1., 1.], [1., 0.], [0.5, 0.]];
    let lap = |t: f32, z: f32| -> [f32; 3] {
        let mut distance = t.clamp(0., 1.) * 4.;
        for pair in corners.windows(2) {
            let length = (pair[1][0] - pair[0][0]).hypot(pair[1][1] - pair[0][1]);
            if distance <= length {
                let f = distance / length;
                return [pair[0][0] + (pair[1][0] - pair[0][0]) * f, pair[0][1] + (pair[1][1] - pair[0][1]) * f, z];
            }
            distance -= length;
        }
        [0.5, 0., z]
    };
    // Lead-in, ear-level lap, gap, ceiling lap, tail, in seconds.
    let position = |seconds: f32| -> Option<[f32; 3]> {
        match seconds {
            s if (0.25..10.).contains(&s) => Some(lap((s - 0.25) / 9.75, 0.)),
            s if (10.25..20.).contains(&s) => Some(lap((s - 10.25) / 9.75, 1.)),
            _ => None,
        }
    };
    let gains = |seconds: f32| -> Gains {
        position(seconds).map_or([0.; 16], |p| panner.object(&panner.preprocess(Object::point(p))))
    };
    let mut seed = 0x2545_f491_4f6c_dd1du64;
    let (mut b0, mut b1, mut b2) = (0f32, 0f32, 0f32);
    let mut out = BufWriter::new(File::create(output)?);
    for start in (0..frames).step_by(block) {
        // Interpolate gains across each 10 ms block so the motion is smooth.
        let from = gains(start as f32 / rate as f32);
        let to = gains((start + block) as f32 / rate as f32);
        for i in 0..block.min(frames - start) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let white = (seed >> 40) as f32 / (1u64 << 23) as f32 - 1.;
            b0 = 0.99765 * b0 + white * 0.099_046;
            b1 = 0.963 * b1 + white * 0.296_516_4;
            b2 = 0.57 * b2 + white * 1.052_691_3;
            let pink = (b0 + b1 + b2 + white * 0.1848) * 0.06;
            let f = i as f32 / block as f32;
            for channel in 0..channels {
                let gain = from[channel] + (to[channel] - from[channel]) * f;
                out.write_all(&(pink * gain).to_le_bytes())?;
            }
        }
    }
    out.flush()?;
    println!("{frames} frames, {channels} channels");
    Ok(())
}
