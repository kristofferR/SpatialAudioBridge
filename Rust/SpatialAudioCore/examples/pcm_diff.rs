//! Compares a later-starting render with the matching part of a full one: interleaved Float32
//! speaker feeds, `later` aligned to `full` at `offset` sample frames. Reports the frame counts,
//! where `later` is silent, the largest difference after that and the first frame from which both
//! are bit-identical to the end. Fails on unequal lengths or differences beyond the documented
//! startup and rounding bounds. `scripts/compare-iec61937.sh` drives it.
//!
//! usage: pcm_diff <truehd|dtsx> <full.f32le> <later.f32le> <channels> <offset frames> <silent frames>
use std::{env, fs};

fn read(path: &str) -> std::io::Result<Vec<f32>> {
    let bytes = fs::read(path)?;
    if !bytes.len().is_multiple_of(4) {
        return Err(std::io::Error::other("partial Float32 sample"));
    }
    Ok(bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| f32::from_le_bytes(*b))
        .collect())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    let [_, codec, full, later, channels, offset, silence] = args.as_slice() else {
        return Err(
            "usage: pcm_diff <truehd|dtsx> <full.f32le> <later.f32le> <channels> <offset frames> <silent frames>"
                .into(),
        );
    };
    let (channels, offset, silence): (usize, usize, usize) =
        (channels.parse()?, offset.parse()?, silence.parse()?);
    if channels == 0 || !matches!(codec.as_str(), "truehd" | "dtsx") {
        return Err("expected nonzero channels and codec truehd or dtsx".into());
    }
    let (full, later) = (read(full)?, read(later)?);
    if !full.len().is_multiple_of(channels) || !later.len().is_multiple_of(channels) {
        return Err("partial PCM frame".into());
    }
    let (full_frames, later_frames) = (full.len() / channels, later.len() / channels);
    println!(
        "frames: full {full_frames}, later {later_frames}, offset {offset}, full after offset {}",
        full_frames.saturating_sub(offset)
    );
    if offset > full_frames || full_frames - offset != later_frames {
        return Err("aligned PCM frame counts differ".into());
    }
    let aligned = &full[offset * channels..];
    let frames = later_frames;
    let later = later.as_slice();
    let row = |pcm: &[f32], frame: usize| pcm[frame * channels..][..channels].to_vec();
    let silent = (0..frames)
        .take_while(|&f| row(later, f).iter().all(|x| *x == 0.))
        .count();
    let identical_from = (0..frames)
        .rev()
        .take_while(|&f| {
            row(later, f)
                .iter()
                .zip(row(aligned, f))
                .all(|(a, b)| a.to_bits() == b.to_bits())
        })
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
    check(codec, aligned, later, channels, silence)?;
    println!("PCM PASS");
    Ok(())
}

fn check(
    codec: &str,
    aligned: &[f32],
    later: &[f32],
    channels: usize,
    silence: usize,
) -> Result<(), String> {
    // Empirical bounds for the comparisons in docs/validation.md, at 48 kHz. DTS must settle
    // within 150 ms (observed: 21–136 ms), with silent warm-up and at most −30 dBFS
    // settling differences afterward, as in the mid-stream fixture tests. TrueHD allows
    // −39 dBFS for the first 15 ms of held-object startup, then only −90 dBFS float rounding.
    let startup = if codec == "dtsx" { 7_200 } else { 720 };
    if later.len() / channels <= startup {
        return Err("render is too short to check convergence after startup".into());
    }
    for (i, (&a, &b)) in aligned.iter().zip(later).enumerate() {
        let frame = i / channels;
        if !a.is_finite() || !b.is_finite() {
            return Err(format!("non-finite PCM at frame {frame}"));
        }
        let matches = if codec == "dtsx" {
            if frame < silence {
                b == 0.
            } else if frame < startup {
                (a - b).abs() <= 10f32.powf(-30. / 20.)
            } else {
                a.to_bits() == b.to_bits()
            }
        } else {
            let db = if frame < startup { -39. } else { -90. };
            (a - b).abs() <= 10f32.powf(db / 20.)
        };
        if !matches {
            return Err(format!(
                "PCM difference exceeds {codec} bound at frame {frame}, channel {}",
                i % channels
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::check;

    #[test]
    fn dts_requires_an_exact_suffix_after_bounded_startup() {
        let full = vec![0.5; 7_202];
        let mut later = full.clone();
        later[..7_200].fill(0.);
        assert!(check("dtsx", &full, &later, 1, 7_200).is_ok());
        later[7_200] += 1e-6;
        assert!(check("dtsx", &full, &later, 1, 7_200).is_err());
        later.fill(0.);
        assert!(check("dtsx", &full, &later, 1, 7_200).is_err());
    }

    #[test]
    fn dts_requires_silent_warmup_then_bounds_settling_differences() {
        let full = vec![0.5; 7_202 * 2];
        let mut later = full.clone();
        later[..2_048 * 2].fill(0.);
        assert!(check("dtsx", &full, &later, 2, 2_048).is_ok());
        later[100] = 1e-6;
        assert!(check("dtsx", &full, &later, 2, 2_048).is_err());
        later[100] = 0.;
        later[2_048 * 2 + 1] -= 0.01;
        assert!(check("dtsx", &full, &later, 2, 2_048).is_ok());
        later[2_048 * 2 + 1] -= 0.1;
        assert!(check("dtsx", &full, &later, 2, 2_048).is_err());
    }

    #[test]
    fn truehd_bounds_startup_and_rounding_separately() {
        let full = vec![0.; 722];
        let mut later = vec![1e-5; 722];
        later[..720].fill(0.01);
        assert!(check("truehd", &full, &later, 1, 0).is_ok());
        later[720] = 1e-4;
        assert!(check("truehd", &full, &later, 1, 0).is_err());
        later[720] = 0.;
        later[0] = 0.02;
        assert!(check("truehd", &full, &later, 1, 0).is_err());
    }

    #[test]
    fn rejects_short_or_non_finite_comparisons() {
        assert!(check("dtsx", &[0.; 10], &[0.; 10], 1, 1_024).is_err());
        for codec in ["dtsx", "truehd"] {
            for value in [f32::NAN, f32::INFINITY] {
                let mut later = vec![0.; 7_201];
                later[0] = value;
                assert!(check(codec, &vec![0.; 7_201], &later, 1, 0).is_err());
            }
        }
    }
}
