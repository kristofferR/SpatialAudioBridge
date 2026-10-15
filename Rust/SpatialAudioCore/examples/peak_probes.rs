//! Synthetic PCM before and after the production limiter, for Apple's APAC peak experiment.
use spatial_audio_core::decode;
use std::{env, fs, io::Write, path::Path};

// Compile the production implementation without widening the library's API for an experiment.
#[path = "../src/limit.rs"]
mod limit;

const FRAMES: usize = 96_000;

fn write_pcm(path: &Path, samples: &[f32]) -> std::io::Result<()> {
    let mut file = std::io::BufWriter::new(fs::File::create(path)?);
    for sample in samples {
        file.write_all(&sample.to_le_bytes())?;
    }
    file.flush()
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = env::args().nth(1).ok_or("usage: peak_probes OUTPUT_DIRECTORY")?;
    let directory = Path::new(&directory);
    fs::create_dir_all(directory)?;
    for channels in [12, 16] {
        for signal in ["tone1k", "tone8k", "transients", "multichannel"] {
            let mut input = vec![0.; FRAMES * channels];
            for frame in 4_800..FRAMES - 4_800 {
                for channel in 0..channels {
                    let time = frame as f64 / 48_000.;
                    let value = match signal {
                        "tone1k" if channel == 0 => (std::f64::consts::TAU * 1_000. * time).sin() * 2.,
                        "tone8k" if channel == 0 => (std::f64::consts::TAU * 8_000. * time).sin() * 2.,
                        "transients" if frame % 12_000 == 0 => if channel % 2 == 0 { 4. } else { -2. },
                        "multichannel" => {
                            let frequency = if channel == 3 { 60. } else { 211. + channel as f64 * 173. };
                            (std::f64::consts::TAU * frequency * time + channel as f64 * 0.3).sin() * 1.8
                        }
                        _ => 0.,
                    };
                    input[frame * channels + channel] = value as f32;
                }
            }
            let mut limiter = limit::Limiter::new(channels);
            let mut limited = Vec::with_capacity(input.len());
            let mut collect = |pcm: decode::Pcm| {
                limited.extend(pcm.data);
                Ok(())
            };
            for data in input.chunks(317 * channels) {
                limiter.push(decode::Pcm {
                    data: data.to_vec(), frames: data.len() / channels, rate: 48_000, channels,
                }, &mut collect)?;
            }
            limiter.finish(&mut collect)?;
            assert_eq!(input.len(), limited.len());
            assert!(limited.iter().all(|x| x.is_finite() && x.abs() <= 0.988_554));
            write_pcm(&directory.join(format!("{signal}-{channels}-input.f32")), &input)?;
            write_pcm(&directory.join(format!("{signal}-{channels}-limited.f32")), &limited)?;
        }
    }
    Ok(())
}
