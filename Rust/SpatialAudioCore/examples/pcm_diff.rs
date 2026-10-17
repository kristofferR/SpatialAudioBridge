//! Compares a later-starting render with the matching part of a full one: interleaved Float32
//! speaker feeds, `later` aligned to `full` at `offset` sample frames. Reports the frame counts,
//! where `later` is silent, the largest difference after that and the first frame from which both
//! are bit-identical to the end. `scripts/compare-iec61937.sh` drives it.
//!
//! usage: pcm_diff <full.f32le> <later.f32le> <channels> <offset frames>
use std::{env, fs};

fn read(path: &str) -> std::io::Result<Vec<f32>> {
    Ok(fs::read(path)?
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| f32::from_le_bytes(*b))
        .collect())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    let [_, full, later, channels, offset] = args.as_slice() else {
        return Err("usage: pcm_diff <full.f32le> <later.f32le> <channels> <offset frames>".into());
    };
    let (channels, offset): (usize, usize) = (channels.parse()?, offset.parse()?);
    let (full, later) = (read(full)?, read(later)?);
    let (full_frames, later_frames) = (full.len() / channels, later.len() / channels);
    println!(
        "frames: full {full_frames}, later {later_frames}, offset {offset}, full after offset {}",
        full_frames.saturating_sub(offset)
    );
    let aligned = &full[(offset * channels).min(full.len())..];
    let frames = later_frames.min(aligned.len() / channels);
    let later = later.as_slice();
    let row = |pcm: &[f32], frame: usize| pcm[frame * channels..][..channels].to_vec();
    let silent = (0..frames)
        .take_while(|&f| row(later, f).iter().all(|x| *x == 0.))
        .count();
    let identical_from = (0..frames)
        .rev()
        .take_while(|&f| row(later, f) == row(aligned, f))
        .last()
        .unwrap_or(frames);
    let identical = if identical_from == frames {
        "never bit-identical through the end".into()
    } else {
        format!(
            "bit-identical from frame {identical_from} ({:.2} ms) to the end",
            identical_from as f64 / 48.
        )
    };
    println!(
        "later is silent for its first {silent} frames ({:.2} ms); {identical}",
        silent as f64 / 48.
    );
    // The largest difference after the silent start, and after the first half second.
    let (mut largest, mut at, mut settled) = (0f32, 0, 0f32);
    for f in silent..frames {
        for (a, b) in row(later, f).iter().zip(row(aligned, f)) {
            let difference = (a - b).abs();
            if difference > largest {
                (largest, at) = (difference, f);
            }
            if f >= silent + 24_000 {
                settled = settled.max(difference);
            }
        }
    }
    let db = |x: f32| 20. * f64::from(x).max(1e-12).log10();
    println!(
        "largest difference after the silent start: {:.1} dBFS at frame {at}; from 0.5 s after it: {:.1} dBFS",
        db(largest),
        db(settled)
    );
    Ok(())
}
