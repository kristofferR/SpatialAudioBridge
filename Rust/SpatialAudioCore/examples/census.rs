//! Reports which Atmos metadata controls a TrueHD stream uses, where the renderer first
//! rejects it, and the rendered peak levels in both layouts.
//!
//! usage: census <elementary-stream|-> [...]
use spatial_audio_core::{decode::Core, render::Layout};
use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    io::{self, Read},
};
use truehd::{
    process::{
        decode::{DecodedAccessUnit, Decoder},
        extract::Extractor,
        parse::Parser,
    },
    structs::oamd::ObjectAudioMetadataPayload,
    utils::errors::ExtractError,
};

const RATE: f64 = 48_000.;

/// Occurrence count and first time, in seconds, per feature.
#[derive(Default)]
struct Tally(BTreeMap<String, (u64, f64)>);
impl Tally {
    fn hit(&mut self, feature: impl Into<String>, time: f64) {
        self.0.entry(feature.into()).or_insert((0, time)).0 += 1;
    }
}

struct Render {
    layout: Layout,
    core: Core,
    frames: u64,
    peaks: Vec<f32>,
    over: u64,
    error: Option<(String, f64)>,
}
impl Render {
    fn new(layout: Layout) -> Self {
        Self {
            layout,
            core: Core::new(1, layout).unwrap(),
            frames: 0,
            peaks: vec![0.; layout.count()],
            over: 0,
            error: None,
        }
    }
    fn push(&mut self, data: &[u8], end: bool) {
        if self.error.is_some() {
            return;
        }
        let (frames, peaks, over) = (&mut self.frames, &mut self.peaks, &mut self.over);
        let channels = peaks.len();
        let result = self.core.push(data, end, &mut |pcm| {
            *frames += pcm.frames as u64;
            for (i, x) in pcm.data.iter().enumerate() {
                let peak = &mut peaks[i % channels];
                *peak = peak.max(x.abs());
                *over += u64::from(x.abs() > 1.);
            }
            Ok(())
        });
        if let Err(e) = result {
            self.error = Some((e, self.frames as f64 / RATE));
        }
    }
}

#[derive(Default)]
struct Inspection {
    extractor: Extractor,
    parser: Parser,
    decoder: Decoder,
    decoded: DecodedAccessUnit,
    samples: u64,
    payloads: u64,
    blocks: u64,
    tally: Tally,
    values: BTreeMap<&'static str, BTreeSet<String>>,
    error: Option<String>,
}
impl Inspection {
    fn push(&mut self, data: &[u8]) {
        if self.error.is_some() {
            return;
        }
        self.extractor.push_bytes(data);
        while let Some(frame) = self.extractor.next() {
            let frame = match frame {
                Ok(f) => f,
                Err(ExtractError::InsufficientData) => break,
                Err(e) => return self.error = Some(e.to_string()),
            };
            let au = match self.parser.parse(&frame) {
                Ok(au) => au,
                Err(e) => return self.error = Some(e.to_string()),
            };
            if let Some(extra) = au
                .major_sync_info
                .as_ref()
                .and_then(|sync| sync.channel_meaning.extra_channel_meaning())
            {
                let norm = extra.sixteench_dialogue_norm.to_string();
                self.values.entry("dialogue norm").or_default().insert(norm);
            }
            if let Err(e) = self
                .decoder
                .decode_presentation_into(&au, 3, &mut self.decoded)
            {
                return self.error = Some(e.to_string());
            }
            if self.decoded.is_duplicate {
                continue;
            }
            for oamd in std::mem::take(&mut self.decoded.oamd) {
                self.payload(&oamd);
            }
            self.samples += self.decoded.sample_length as u64;
        }
    }

    fn value(&mut self, name: &'static str, value: impl ToString) {
        self.values
            .entry(name)
            .or_default()
            .insert(value.to_string());
    }

    fn payload(&mut self, oamd: &ObjectAudioMetadataPayload) {
        let time = self.samples as f64 / RATE;
        self.payloads += 1;
        self.value("objects", oamd.object_count);
        let program = &oamd.program_assignment;
        if let Some(bed) = program.bed_assignment.first() {
            self.value("bed channels", format!("{:?}", bed.to_index_vec()));
        }
        let tally = &mut self.tally;
        if program.bed_assignment.len() > 1 {
            tally.hit("multiple beds", time);
        }
        if program.num_isf_objects != 0 {
            tally.hit("ISF", time);
        }
        if program.b_bed_chan_distribute {
            tally.hit("bed distribution", time);
        }
        if oamd.bed_object_element.is_some() {
            tally.hit("bed downmix element", time);
        }
        if let Some(trim) = &oamd.trim_element {
            tally.hit("trim element", time);
            tally.hit(format!("trim warp_mode {}", trim.warp_mode), time);
            tally.hit(format!("trim global mode {}", trim.global_trim_mode), time);
            if trim.b_disable_trim.iter().any(|d| *d) {
                tally.hit("trim disabled per object", time);
            }
            // Configuration 8: four or more surrounds and more than two heights.
            match &trim.trims[8] {
                None => {}
                Some(t) if t.b_default_trim => tally.hit("trim cfg8 default", time),
                Some(t) if t.b_disable_trim => tally.hit("trim cfg8 disabled", time),
                Some(t) => {
                    tally.hit("trim cfg8 custom", time);
                    self.values
                        .entry("trim cfg8 custom")
                        .or_default()
                        .insert(format!(
                            "centre {:?} surround {:?} height {:?} balance {:?}/{:?}",
                            t.trim_centre,
                            t.trim_surround,
                            t.trim_height,
                            t.bal3d_y_tb,
                            t.bal3d_y_lis
                        ));
                }
            }
        }
        let Some(element) = &oamd.object_element else {
            return tally.hit("no object element", time);
        };
        let positions = oamd.get_damf_pos();
        let divergence = oamd.extended_object_element.as_ref();
        for (object, blocks) in element.object_data.iter().enumerate() {
            for (index, block) in blocks.iter().enumerate() {
                self.blocks += 1;
                if block.b_object_not_active || block.b_object_in_bed_or_isf {
                    continue;
                }
                tally.hit("active object block", time);
                let info = &block.object_render_info;
                if info.object_size.iter().any(|s| *s != 0.) {
                    tally.hit("size", time);
                    if info.object_size[0] != info.object_size[1]
                        || info.object_size[1] != info.object_size[2]
                    {
                        tally.hit("size per axis", time);
                    }
                }
                if info.b_object_snap {
                    tally.hit("snap", time);
                }
                if info.zone_constraints_idx != 0 {
                    tally.hit(format!("zone {}", info.zone_constraints_idx), time);
                }
                if !info.b_enable_elevation {
                    tally.hit("elevation disabled", time);
                }
                if info.b_object_use_screen_ref {
                    tally.hit("screen reference", time);
                }
                if info.b_object_distance_specified {
                    tally.hit("distance", time);
                }
                if divergence
                    .and_then(|e| e.object_div_block.get(object)?.get(index))
                    .is_some_and(|d| d.b_object_divergence && d.object_divergence > 0.)
                {
                    tally.hit("divergence", time);
                }
                if let Some([x, y, z]) = positions.get(object).and_then(|p| p.get(index)) {
                    // DAMF coordinates: x, y in [-1, 1], z in [-1, 1].
                    if x.abs().max(y.abs()) < 0.95 {
                        tally.hit("inside the room", time);
                    }
                    if *z > 0. {
                        tally.hit("above the bed plane", time);
                    }
                    if *z < 0. {
                        tally.hit("below the bed plane", time);
                    }
                }
            }
        }
    }
}

fn census(name: &str, mut input: impl Read) -> io::Result<()> {
    let mut inspection = Inspection::default();
    let mut renders = [
        Render::new(Layout::SevenOneFour),
        Render::new(Layout::NineOneSix),
    ];
    let mut buffer = vec![0; 1 << 16];
    // A window cut from a film can start mid-stream; begin at its first major sync.
    let mut pending = Vec::new();
    let mut synced = false;
    loop {
        let n = input.read(&mut buffer)?;
        let mut data = &buffer[..n];
        if !synced {
            pending.extend_from_slice(data);
            let Some(sync) = pending
                .windows(4)
                .position(|w| w == [0xF8, 0x72, 0x6F, 0xBA])
            else {
                if n == 0 {
                    break;
                }
                continue;
            };
            synced = true;
            pending.drain(..sync.saturating_sub(4));
            data = &pending[..];
        }
        inspection.push(data);
        for render in &mut renders {
            render.push(data, n == 0);
        }
        if n == 0 {
            break;
        }
    }
    println!("== {name}");
    println!(
        "duration {:.1} s, {} metadata payloads, {} object blocks",
        inspection.samples as f64 / RATE,
        inspection.payloads,
        inspection.blocks
    );
    if let Some(e) = &inspection.error {
        println!("inspection stopped: {e}");
    }
    for (name, values) in &inspection.values {
        let list: Vec<_> = values.iter().map(String::as_str).collect();
        println!("{name}: {}", list.join(", "));
    }
    let active = inspection
        .tally
        .0
        .get("active object block")
        .map_or(0, |t| t.0);
    for (feature, (count, first)) in &inspection.tally.0 {
        let share = 100. * *count as f64 / active.max(1) as f64;
        println!("  {feature}: {count} ({share:.2}% of active blocks), first at {first:.2} s");
    }
    for render in &renders {
        let peaks: Vec<_> = render
            .peaks
            .iter()
            .map(|p| format!("{:.1}", 20. * p.max(1e-9).log10()))
            .collect();
        println!(
            "{:?}: {:.1} s rendered, peak dBFS [{}], {} samples above full scale",
            render.layout,
            render.frames as f64 / RATE,
            peaks.join(" "),
            render.over
        );
        if let Some((error, time)) = &render.error {
            println!("  rejected at {time:.2} s: {error}");
        }
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let paths: Vec<_> = env::args().skip(1).collect();
    if paths.is_empty() {
        eprintln!("usage: census <elementary-stream|-> [...]");
        std::process::exit(2);
    }
    for path in paths {
        if path == "-" {
            census("stdin", io::stdin().lock())?;
        } else {
            census(&path, fs::File::open(&path)?)?;
        }
    }
    Ok(())
}
