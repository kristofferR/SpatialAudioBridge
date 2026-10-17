//! Renders an elementary stream through the C interface hosts use, with peak limiting as in
//! playback and uneven input chunks, and prints an expected-output baseline: timing, and each
//! speaker feed's hash, peak, RMS and one-second RMS. `--pcm` also writes the interleaved
//! Float32 output. `--diff` reports how a new baseline differs from an old one, per speaker feed
//! and second, and fails if it does. `scripts/compare-baselines.sh` drives it.
//!
//! usage: baseline <truehd|dtsx> <7.1.4|9.1.6> <stream> [--pcm out.f32le]
//!        baseline --diff <old.txt> <new.txt>
use spatial_audio_core as _;
use std::{
    collections::BTreeMap,
    env,
    ffi::c_void,
    fs::{self, File},
    io::{BufWriter, Write},
    process::ExitCode,
};

unsafe extern "C" {
    fn sab_create(codec: u32, channels: u32) -> *mut c_void;
    fn sab_push(
        handle: *mut c_void,
        data: *const u8,
        length: usize,
        end: i32,
        callback: Option<unsafe extern "C" fn(*mut c_void, *const f32, u32, u32, u32) -> i32>,
        context: *mut c_void,
    ) -> i32;
    fn sab_error(handle: *const c_void, buffer: *mut u8, capacity: usize) -> usize;
    fn sab_destroy(handle: *mut c_void);
}

const RATE: usize = 48_000;
const SEVEN_ONE_FOUR: [&str; 12] = [
    "L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Tfl", "Tfr", "Tbl", "Tbr",
];
const NINE_ONE_SIX: [&str; 16] = [
    "L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Lw", "Rw", "Tfl", "Tfr", "Tsl", "Tsr", "Tbl",
    "Tbr",
];

struct Channel {
    hash: u64,
    peak: f32,
    energy: f64,
    first: Option<u64>,
    windows: Vec<f64>,
}

struct Output {
    channels: Vec<Channel>,
    frames: u64,
    rate: u32,
    hash: u64,
    pcm: Option<BufWriter<File>>,
    error: Option<String>,
}

fn fnv(hash: &mut u64, bytes: [u8; 4]) {
    for byte in bytes {
        *hash = (*hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
    }
}

unsafe extern "C" fn collect(
    context: *mut c_void,
    data: *const f32,
    frames: u32,
    rate: u32,
    channels: u32,
) -> i32 {
    let output = unsafe { &mut *context.cast::<Output>() };
    let count = output.channels.len();
    if channels as usize != count || (output.rate != 0 && output.rate != rate) {
        output.error = Some("unexpected PCM format".into());
        return 1;
    }
    output.rate = rate;
    let pcm = unsafe { std::slice::from_raw_parts(data, frames as usize * count) };
    for (i, sample) in pcm.chunks_exact(count).enumerate() {
        let frame = output.frames + i as u64;
        let window = frame as usize / RATE;
        for (channel, &x) in output.channels.iter_mut().zip(sample) {
            fnv(&mut channel.hash, x.to_le_bytes());
            fnv(&mut output.hash, x.to_le_bytes());
            channel.peak = channel.peak.max(x.abs());
            channel.energy += f64::from(x).powi(2);
            if x != 0. {
                channel.first.get_or_insert(frame);
            }
            if channel.windows.len() <= window {
                channel.windows.push(0.);
            }
            channel.windows[window] += f64::from(x).powi(2);
        }
    }
    output.frames += u64::from(frames);
    if let Some(file) = &mut output.pcm {
        let bytes: Vec<u8> = pcm.iter().flat_map(|x| x.to_le_bytes()).collect();
        if let Err(e) = file.write_all(&bytes) {
            output.error = Some(e.to_string());
            return 1;
        }
    }
    0
}

fn decibels(power: f64) -> f64 {
    10. * power.max(1e-24).log10()
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
    let usage = "usage: baseline <truehd|dtsx> <7.1.4|9.1.6> <stream> [--pcm out.f32le] | --diff <old> <new>";
    let (codec, layout, stream, pcm) = match args.as_slice() {
        [_, flag, old, new] if flag == "--diff" => {
            return Ok(compare(
                &fs::read_to_string(old)?,
                &fs::read_to_string(new)?,
            ));
        }
        [_, codec, layout, stream] => (codec, layout, stream, None),
        [_, codec, layout, stream, flag, pcm] if flag == "--pcm" => {
            (codec, layout, stream, Some(pcm))
        }
        _ => return Err(usage.into()),
    };
    let codec_id = match codec.as_str() {
        "truehd" => 1,
        "dtsx" => 2,
        _ => return Err(usage.into()),
    };
    let names: &[&str] = match layout.as_str() {
        "7.1.4" => &SEVEN_ONE_FOUR,
        "9.1.6" => &NINE_ONE_SIX,
        _ => return Err(usage.into()),
    };
    let data = fs::read(stream)?;
    let mut output = Output {
        channels: names
            .iter()
            .map(|_| Channel {
                hash: 0xcbf29ce484222325,
                peak: 0.,
                energy: 0.,
                first: None,
                windows: Vec::new(),
            })
            .collect(),
        frames: 0,
        rate: 0,
        hash: 0xcbf29ce484222325,
        pcm: pcm
            .map(|path| File::create(path).map(BufWriter::new))
            .transpose()?,
        error: None,
    };

    let handle = unsafe { sab_create(codec_id, names.len() as u32) };
    if handle.is_null() {
        return Err("sab_create failed".into());
    }
    // Uneven chunks, as a demuxer or network delivers them; the output must not depend on them.
    let (mut offset, mut size, mut result) = (0, 7, 0);
    let context = (&raw mut output).cast::<c_void>();
    while result == 0 {
        let end = (offset + size).min(data.len());
        let last = i32::from(end == data.len());
        result = unsafe {
            sab_push(
                handle,
                data[offset..].as_ptr(),
                end - offset,
                last,
                Some(collect),
                context,
            )
        };
        if last != 0 {
            break;
        }
        offset = end;
        size = size * 13 % 9_973 + 1;
    }
    if result != 0 {
        let mut message = vec![0u8; unsafe { sab_error(handle, std::ptr::null_mut(), 0) }];
        unsafe { sab_error(handle, message.as_mut_ptr(), message.len()) };
        unsafe { sab_destroy(handle) };
        let message = String::from_utf8_lossy(&message[..message.len().saturating_sub(1)]);
        return Err(format!("sab_push failed ({result}): {message}").into());
    }
    unsafe { sab_destroy(handle) };
    if let Some(e) = output.error.take() {
        return Err(e.into());
    }
    if let Some(mut file) = output.pcm.take() {
        file.flush()?;
    }

    print!("{}", format(&output, codec, layout, names));
    Ok(true)
}

fn format(output: &Output, codec: &str, layout: &str, names: &[&str]) -> String {
    let frames = output.frames.max(1) as f64;
    let mut text = format!(
        "codec {codec}\nlayout {layout}\nlimiter on\nrate {}\nframes {}\nduration {:.6}\npcm-fnv1a64 {:016x}\n",
        output.rate,
        output.frames,
        output.frames as f64 / f64::from(output.rate.max(1)),
        output.hash
    );
    text += "# channel name fnv1a64 peak_dBFS rms_dBFS first_nonzero_frame\n";
    for (name, channel) in names.iter().zip(&output.channels) {
        text += &format!(
            "channel {name} {:016x} {:.2} {:.2} {}\n",
            channel.hash,
            decibels(f64::from(channel.peak).powi(2)),
            decibels(channel.energy / frames),
            channel.first.map_or("none".into(), |f| f.to_string())
        );
    }
    text += "# window name rms_dBFS of each second; the last may be partial\n";
    for (name, channel) in names.iter().zip(&output.channels) {
        let windows: Vec<String> = channel
            .windows
            .iter()
            .enumerate()
            .map(|(i, energy)| {
                let length = (output.frames - (i * RATE) as u64).min(RATE as u64);
                format!("{:.2}", decibels(energy / length as f64))
            })
            .collect();
        text += &format!("window {name} {}\n", windows.join(" "));
    }
    text
}

/// Fields after the key on each line, keyed by its first one or two words.
fn fields(text: &str) -> BTreeMap<String, Vec<String>> {
    let mut map = BTreeMap::new();
    for line in text.lines().filter(|l| !l.starts_with('#')) {
        let words: Vec<String> = line.split_whitespace().map(String::from).collect();
        match words.as_slice() {
            [kind, name, rest @ ..] if kind == "channel" || kind == "window" => {
                map.insert(format!("{kind} {name}"), rest.to_vec());
            }
            [key, rest @ ..] => {
                map.insert(key.clone(), rest.to_vec());
            }
            [] => {}
        }
    }
    map
}

/// Prints how `new` differs from `old`, per speaker feed and second, and returns whether they match.
fn compare(old: &str, new: &str) -> bool {
    let (old, new) = (fields(old), fields(new));
    let mut same = true;
    for key in ["codec", "layout", "limiter", "rate", "frames"] {
        if old.get(key) != new.get(key) {
            println!("DIFF {key}: {:?} -> {:?}", old.get(key), new.get(key));
            same = false;
        }
    }
    if old.get("pcm-fnv1a64") == new.get("pcm-fnv1a64") && same {
        println!("SAME: output identical to the baseline");
        return true;
    }
    println!(
        "DIFF channel: peak_dBFS old -> new (delta), rms_dBFS old -> new (delta), seconds whose RMS moved by 0.01 dB or more"
    );
    let number = |v: Option<&String>| v.and_then(|s| s.parse::<f64>().ok());
    for (key, values) in new.iter().filter(|(k, _)| k.starts_with("channel ")) {
        let Some(previous) = old.get(key) else {
            println!("DIFF {key}: not in the baseline");
            continue;
        };
        if previous.first() == values.first() {
            continue;
        }
        let name = &key["channel ".len()..];
        let (peak, old_peak) = (number(values.get(1)), number(previous.get(1)));
        let (rms, old_rms) = (number(values.get(2)), number(previous.get(2)));
        let window = format!("window {name}");
        let moved: Vec<String> = match (old.get(&window), new.get(&window)) {
            (Some(a), Some(b)) => a
                .iter()
                .zip(b)
                .enumerate()
                .filter_map(|(i, (a, b))| {
                    let delta = b.parse::<f64>().ok()? - a.parse::<f64>().ok()?;
                    (delta.abs() >= 0.01).then(|| format!("{i}s:{delta:+.2}"))
                })
                .collect(),
            _ => vec![],
        };
        let delta = |a: Option<f64>, b: Option<f64>| match (a, b) {
            (Some(a), Some(b)) => format!("{a:.2} -> {b:.2} ({:+.2})", b - a),
            _ => "?".into(),
        };
        println!(
            "DIFF {name}: peak {}, rms {}, first nonzero {} -> {}; {}",
            delta(old_peak, peak),
            delta(old_rms, rms),
            previous.get(3).map_or("?", String::as_str),
            values.get(3).map_or("?", String::as_str),
            if moved.is_empty() {
                "no second moved by 0.01 dB".into()
            } else {
                moved.join(" ")
            }
        );
    }
    false
}
