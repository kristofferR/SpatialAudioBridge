//! Compares the lossless DTS compatible bed SAB renders from, before spatial fold subtraction,
//! with FFmpeg's decode of the same DTS-HD MA core and lossless extension, sample for sample.
//!
//! usage: dts_bed <elementary.dts> <reference.s32le> <reference channels, e.g. FL+FR+FC+LFE+BL+BR+SL+SR>
//!
//! The reference is interleaved signed 32-bit PCM in the listed channel order, as FFmpeg writes
//! with `-c:a pcm_s32le -f s32le`. The stream is framed as `decode::Dts` frames it and decoded by
//! the same `dca::HdDecoder::decode_into` call; each bed channel is matched to the reference by the
//! speaker its DTS index declares, never by which reference channel it resembles. Frames the
//! decoder reports pending, and the warm-up frames after them that SAB plays as silence, are
//! counted separately. Every other sample must be identical. A channel that is digital silence, or
//! that also equals another reference channel, leaves its mapping unproven and fails the check.
//! `scripts/compare-dts-bed.sh` drives it.
use std::{env, fs, process::ExitCode};

/// Each DTS bed speaker index SAB routes, the speaker `decode::Dts` routes it to, and the
/// FFmpeg channel FFmpeg's DTS decoder assigns that speaker.
const SPEAKERS: [(usize, &str, &str); 10] = [
    (0, "C", "FC"),
    (1, "L", "FL"),
    (2, "R", "FR"),
    (3, "Ls", "SL"),
    (4, "Rs", "SR"),
    (5, "LFE", "LFE"),
    (7, "Lb", "BL"),
    (8, "Rb", "BR"),
    (9, "Ls", "SL"),
    (10, "Rs", "SR"),
];
/// `decode::DTS_WARMUP_FRAMES`: decoded frames SAB plays as silence after entering a stream.
const WARMUP_FRAMES: usize = 2;
const EXSS_SYNC: [u8; 4] = [0x64, 0x58, 0x20, 0x25];

#[derive(Default)]
struct Tally {
    samples: u64,
    differing: u64,
    largest: i64,
    energy: f64,
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<bool, Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    let [_, stream, reference, layout] = args.as_slice() else {
        return Err("usage: dts_bed <elementary.dts> <reference.s32le> <FL+FR+...>".into());
    };
    let names: Vec<&str> = layout.split('+').collect();
    let reference: Vec<i32> = fs::read(reference)?
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| i32::from_le_bytes(*b))
        .collect();
    if !reference.len().is_multiple_of(names.len()) {
        return Err("reference length is not a whole number of sample frames".into());
    }
    let reference_frames = reference.len() / names.len();
    let data = fs::read(stream)?;

    let mut decoder = dca::HdDecoder::new();
    let mut frame = dca::HdFrame::default();
    let (mut offset, mut position, mut index) = (0, 0, 0);
    let (mut pending, mut decoded, mut startup) = (0, 0, 0);
    let mut mask = None;
    let mut columns: Vec<(usize, usize)> = Vec::new();
    let mut tallies: Vec<Tally> = Vec::new();
    let mut identical: Vec<Vec<bool>> = Vec::new();
    let mut startup_differing = 0u64;
    let mut first_difference = None;
    while offset < data.len() {
        let rest = &data[offset..];
        let header = dca::parse_header(rest).map_err(|e| format!("frame {index}: {e:?}"))?;
        let core = header.frame_size;
        if rest.len() < core + 4 || rest[core..core + 4] != EXSS_SYNC {
            return Err(format!("frame {index} has no DTS-HD extension after its core").into());
        }
        let exss = dca::exss_substream_size(&rest[core..])
            .filter(|n| core + n <= rest.len())
            .ok_or(format!("frame {index} has a truncated extension"))?;
        let length = match decoder.decode_into(&rest[..core], &rest[core..core + exss], &mut frame)
        {
            Ok(()) => {
                if !frame.lossless {
                    return Err(format!("frame {index} is not lossless").into());
                }
                let active: Vec<usize> = (0..frame.samples.len())
                    .filter(|i| frame.samples[*i].is_some())
                    .collect();
                if mask.is_none() {
                    columns = map_speakers(&active, &names)?;
                    tallies = columns.iter().map(|_| Tally::default()).collect();
                    report_mapping(&frame, &columns, &names);
                    mask = Some(active);
                } else if mask.as_ref() != Some(&active) {
                    return Err(format!("frame {index} changes the bed's speakers").into());
                }
                let length = frame.bed_sample_count();
                if position + length > reference_frames {
                    return Err(format!("the reference ends inside frame {index}").into());
                }
                let warming = decoded < WARMUP_FRAMES;
                decoded += 1;
                startup += usize::from(warming);
                if identical.is_empty() {
                    identical = vec![vec![true; names.len()]; columns.len()];
                }
                for (column, &(speaker, reference_column)) in columns.iter().enumerate() {
                    let pcm = frame.samples[speaker]
                        .as_ref()
                        .ok_or("missing bed channel")?;
                    if pcm.len() != length {
                        return Err(format!("frame {index}: uneven bed channel lengths").into());
                    }
                    for (s, &x) in pcm.iter().enumerate() {
                        // The decoder's floats are 24-bit integers over 2^23, so this is exact.
                        let ours = (f64::from(x) * 2_147_483_648.) as i64;
                        if ours as f64 != f64::from(x) * 2_147_483_648. {
                            return Err(format!("frame {index}: a sample is not 24-bit").into());
                        }
                        let row = &reference[(position + s) * names.len()..][..names.len()];
                        let theirs = i64::from(row[reference_column]);
                        if warming {
                            startup_differing += u64::from(ours != theirs);
                            continue;
                        }
                        // Track which other reference channels this one also matches, which
                        // would leave the mapping unproven.
                        for (other, &value) in identical[column].iter_mut().zip(row) {
                            *other &= ours == i64::from(value);
                        }
                        let tally = &mut tallies[column];
                        tally.samples += 1;
                        tally.energy += (theirs as f64 / 2_147_483_648.).powi(2);
                        if ours != theirs {
                            tally.differing += 1;
                            tally.largest = tally.largest.max(((ours - theirs) >> 8).abs());
                            first_difference.get_or_insert((index, position + s, column));
                        }
                    }
                }
                length
            }
            Err(dca::HdError::Pending) => {
                // SAB plays a pending frame's duration as silence.
                pending += 1;
                header.samples_per_channel()
            }
            Err(e) => return Err(format!("frame {index}: {e:?}").into()),
        };
        position += length;
        offset += core + exss;
        index += 1;
    }

    println!(
        "frames {index}: {pending} pending, {startup} warm-up, {} compared; sample frames: SAB {position}, reference {reference_frames}",
        decoded - startup
    );
    println!("warm-up samples differing: {startup_differing}");
    println!("channel  reference  compared  rms_dBFS  differing  largest_lsb24");
    for (&(speaker, column), tally) in columns.iter().zip(&tallies) {
        let rms = (tally.energy / tally.samples.max(1) as f64).sqrt();
        println!(
            "{:<7}  {:<9}  {:>8}  {:>8.1}  {:>9}  {:>13}",
            speaker_name(speaker),
            names[column],
            tally.samples,
            20. * rms.max(1e-12).log10(),
            tally.differing,
            tally.largest
        );
    }
    let mut ok = true;
    if position != reference_frames {
        println!("FAIL: sample counts differ");
        ok = false;
    }
    if let Some((frame, sample, column)) = first_difference {
        println!(
            "FAIL: first difference in frame {frame}, sample frame {sample}, {}",
            speaker_name(columns[column].0)
        );
        ok = false;
    }
    for (column, &(speaker, mapped)) in columns.iter().enumerate() {
        if tallies[column].energy == 0. {
            println!(
                "INCONCLUSIVE: {} is digital silence; choose a non-silent excerpt",
                speaker_name(speaker)
            );
            ok = false;
            continue;
        }
        let others: Vec<&str> = (0..names.len())
            .filter(|&c| c != mapped && identical.get(column).is_some_and(|row| row[c]))
            .map(|c| names[c])
            .collect();
        if !others.is_empty() {
            println!(
                "INCONCLUSIVE: {} also equals the reference's {}",
                speaker_name(speaker),
                others.join(", ")
            );
            ok = false;
        }
    }
    if decoded <= startup {
        println!("FAIL: no frame was compared");
        ok = false;
    }
    if ok {
        println!("PASS: bit-exact");
    }
    Ok(ok)
}

/// Pairs each active DTS bed speaker with the reference channel its declared speaker names.
/// The reference must name exactly the active speakers, each once.
fn map_speakers(active: &[usize], names: &[&str]) -> Result<Vec<(usize, usize)>, String> {
    let mut columns = Vec::new();
    for &speaker in active {
        let (_, _, name) = SPEAKERS
            .iter()
            .find(|(index, ..)| *index == speaker)
            .ok_or(format!("SAB does not route DTS bed speaker {speaker}"))?;
        let column = names
            .iter()
            .position(|n| n == name)
            .ok_or(format!("the reference has no {name} channel"))?;
        if columns.iter().any(|(_, c)| *c == column) {
            return Err(format!("two bed speakers map to the reference's {name}"));
        }
        columns.push((speaker, column));
    }
    if columns.len() != names.len() {
        return Err(format!(
            "the bed has {} channels, the reference {}",
            columns.len(),
            names.len()
        ));
    }
    Ok(columns)
}

fn speaker_name(speaker: usize) -> &'static str {
    SPEAKERS
        .iter()
        .find(|(index, ..)| *index == speaker)
        .map_or("?", |(_, name, _)| name)
}

fn report_mapping(frame: &dca::HdFrame, columns: &[(usize, usize)], names: &[&str]) {
    let pairs: Vec<String> = columns
        .iter()
        .map(|&(speaker, column)| format!("{speaker}:{}={}", speaker_name(speaker), names[column]))
        .collect();
    println!(
        "bed: output mask {:#x}, coded mask {:#x}, {} Hz, DTS:X {}; mapping {}",
        frame.output_mask,
        frame.coded_mask,
        frame.sample_rate,
        if frame.x_imax {
            "IMAX"
        } else if frame.x_present {
            "standard"
        } else {
            "absent"
        },
        pairs.join(" ")
    );
}
