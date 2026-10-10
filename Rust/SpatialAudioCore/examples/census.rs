//! Reports which Atmos metadata controls a TrueHD stream uses, or which DTS:X presentation,
//! object positions and bed folds a DTS stream carries, where the renderer first rejects
//! it, and the rendered peak levels in both layouts.
//!
//! usage: census <elementary-stream|-> [...]
use dca::{
    BedFold, FoldPlan, FoldRenderer, HdDecoder, HdError, SourceRole, XMetadata, XPresentation,
};
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
/// `Core` codec identifiers.
const TRUEHD: u32 = 1;
const DTS: u32 = 2;
const TRUEHD_SYNC: [u8; 4] = [0xF8, 0x72, 0x6F, 0xBA];
const DTS_CORE_SYNC: [u8; 4] = [0x7F, 0xFE, 0x80, 0x01];
const DTS_EXSS_SYNC: [u8; 4] = [0x64, 0x58, 0x20, 0x25];

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
    fn new(codec: u32, layout: Layout) -> Self {
        Self {
            layout,
            core: Core::new(codec, layout).unwrap(),
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
    /// Program-level features, counted per metadata payload.
    payload_tally: Tally,
    /// Object features, counted per object block.
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
        let tally = &mut self.payload_tally;
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
        let tally = &mut self.tally;
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

    fn report(&self) {
        println!(
            "duration {:.1} s, {} metadata payloads, {} object blocks",
            self.samples as f64 / RATE,
            self.payloads,
            self.blocks
        );
        report_values(&self.error, &self.values);
        report_tally(&self.payload_tally, self.payloads, "payloads");
        let active = self.tally.0.get("active object block").map_or(0, |t| t.0);
        report_tally(&self.tally, active, "active blocks");
    }
}

/// DCA speaker names by index, up to the bed speakers DTS:X carriers use.
const DCA_SPEAKERS: [&str; 11] = [
    "C", "L", "R", "Ls", "Rs", "LFE", "Cs", "Lsr", "Rsr", "Lss", "Rss",
];

fn dca_speaker(index: usize) -> String {
    DCA_SPEAKERS
        .get(index)
        .map_or_else(|| index.to_string(), |name| name.to_string())
}

struct DtsInspection {
    buffer: Vec<u8>,
    decoder: HdDecoder,
    folds: FoldRenderer,
    presentation: Option<XPresentation>,
    frames: u64,
    seconds: f64,
    /// Azimuth and elevation in half-degrees and distance in 64ths.
    positions: BTreeSet<(i16, i16, u8)>,
    tally: Tally,
    values: BTreeMap<&'static str, BTreeSet<String>>,
    error: Option<String>,
}
impl Default for DtsInspection {
    fn default() -> Self {
        Self {
            buffer: Vec::new(),
            // `HdDecoder::default()` does not set up the lossless decoder.
            decoder: HdDecoder::new(),
            folds: FoldRenderer::new(),
            presentation: None,
            frames: 0,
            seconds: 0.,
            positions: BTreeSet::new(),
            tally: Tally::default(),
            values: BTreeMap::new(),
            error: None,
        }
    }
}
impl DtsInspection {
    fn push(&mut self, data: &[u8]) {
        if self.error.is_some() {
            return;
        }
        self.buffer.extend_from_slice(data);
        while self.buffer.len() >= 18 {
            let header = match dca::parse_header(&self.buffer) {
                Ok(header) => header,
                Err(e) => return self.error = Some(format!("DTS core header: {e}")),
            };
            let core = header.frame_size;
            let Some(next) = self.buffer.get(core..core + 4) else {
                break;
            };
            let mut size = core;
            if next == DTS_EXSS_SYNC {
                let Some(exss) = dca::exss_substream_size(&self.buffer[core..]) else {
                    if self.buffer.len() - core > 64 * 1024 {
                        self.error = Some("invalid DTS-HD extension header".into());
                    }
                    break;
                };
                size += exss;
                if self.buffer.len() < size {
                    break;
                }
            }
            let frame: Vec<u8> = self.buffer.drain(..size).collect();
            self.frame(&frame[..core], &frame[core..]);
            self.frames += 1;
            self.seconds += header.samples_per_channel() as f64 / f64::from(header.sample_rate);
        }
    }

    fn frame(&mut self, core: &[u8], exss: &[u8]) {
        let Self {
            decoder,
            folds,
            presentation: previous,
            seconds: time,
            positions,
            tally,
            values,
            ..
        } = self;
        let time = *time;
        if exss.is_empty() {
            return tally.hit("core only", time);
        }
        tally.hit(format!("{:?} extension", dca::exss_kind(exss)), time);
        let frame = match decoder.decode(core, exss) {
            Ok(frame) => frame,
            Err(HdError::Pending) => return tally.hit("decoder pending", time),
            Err(e) => return tally.hit(format!("decoding error {e:?}"), time),
        };
        let mut value = |name, value: String| values.entry(name).or_default().insert(value);
        value("sample rate", frame.sample_rate.to_string());
        let bed: Vec<_> = (frame.samples.iter().enumerate())
            .filter(|(_, pcm)| pcm.is_some())
            .map(|(index, _)| dca_speaker(index))
            .collect();
        value("bed", bed.join(" "));
        if let Some(e) = frame.xxch_decode_error {
            tally.hit(format!("XXCH error: {e}"), time);
        }
        if !(frame.x_present || frame.x_imax) {
            return tally.hit("no DTS:X extension", time);
        }
        if frame.x_imax {
            tally.hit("IMAX marker", time);
        }
        if let Some(e) = frame.x_decode_error {
            return tally.hit(format!("DTS:X decoding error: {e}"), time);
        }
        let Some(presentation) = XPresentation::detect(&frame) else {
            let feeds = frame.x_samples.len();
            return tally.hit(format!("unknown presentation, {feeds} feeds"), time);
        };
        tally.hit(
            format!("presentation {}", presentation.layout_label()),
            time,
        );
        if previous
            .replace(presentation)
            .is_some_and(|p| p != presentation)
        {
            tally.hit("presentation change", time);
        }
        let metadata = match XMetadata::parse(&frame.x_payload, presentation.feed_count()) {
            Ok(metadata) => metadata,
            Err(e) => return tally.hit(format!("metadata error {e:?}"), time),
        };
        let reference: Vec<_> = (metadata.reference_speakers().iter())
            .map(|&index| dca_speaker(index.into()))
            .collect();
        value("fold reference", reference.join(" "));
        // Each feature counts once per frame.
        let mut features = BTreeSet::new();
        let mut objects = 0;
        for feed in 0..metadata.source_count() {
            let Some(source) = metadata.source(feed) else {
                continue;
            };
            if let SourceRole::Object {
                position,
                centre_height_alternative,
            } = source.role
            {
                objects += 1;
                if centre_height_alternative {
                    features.insert("centre-height alternative");
                }
                if position.elevation_half_degrees > 0 {
                    features.insert("object above ear level");
                }
                if position.elevation_half_degrees < 0 {
                    features.insert("object below ear level");
                }
                if position.azimuth_half_degrees.abs() > 180 {
                    features.insert("object behind the listener");
                }
                if position.distance_64ths != 64 {
                    features.insert("object off the reference distance");
                }
                positions.insert((
                    position.azimuth_half_degrees,
                    position.elevation_half_degrees,
                    position.distance_64ths,
                ));
            }
            features.insert(match source.fold {
                BedFold::Known(_) => "fold stated",
                BedFold::Unknown if metadata.fold_is_direct(feed) => "fold rendered directly",
                BedFold::Unknown if metadata.fold_is_rendered(feed) => "fold rendered",
                BedFold::Unknown => "fold unstated",
            });
        }
        value("objects", objects.to_string());
        for feature in features {
            tally.hit(feature, time);
        }
        let mut plan = FoldPlan::from_metadata(&metadata);
        folds.apply(&mut plan, &metadata, frame.bed_sample_count());
        if plan.has_unknown() {
            tally.hit("unresolved fold", time);
        }
    }

    fn report(&self) {
        println!("duration {:.1} s, {} frames", self.seconds, self.frames);
        report_values(&self.error, &self.values);
        report_tally(&self.tally, self.frames, "frames");
        let degrees = |half: i16| f64::from(half) / 2.;
        if let (Some(low), Some(high)) = (
            self.positions.iter().map(|p| p.1).min(),
            self.positions.iter().map(|p| p.1).max(),
        ) {
            println!(
                "{} distinct object positions, elevation {}° to {}°",
                self.positions.len(),
                degrees(low),
                degrees(high)
            );
        }
    }
}

fn report_values(error: &Option<String>, values: &BTreeMap<&'static str, BTreeSet<String>>) {
    if let Some(e) = error {
        println!("inspection stopped: {e}");
    }
    for (name, values) in values {
        let list: Vec<_> = values.iter().map(String::as_str).collect();
        println!("{name}: {}", list.join(", "));
    }
}

fn report_tally(tally: &Tally, base: u64, unit: &str) {
    for (feature, (count, first)) in &tally.0 {
        let share = 100. * *count as f64 / base.max(1) as f64;
        println!("  {feature}: {count} ({share:.2}% of {unit}), first at {first:.2} s");
    }
}

enum Inspector {
    TrueHd(Box<Inspection>),
    Dts(Box<DtsInspection>),
}

fn census(name: &str, mut input: impl Read) -> io::Result<()> {
    let mut buffer = vec![0; 1 << 16];
    // Begin at a DTS core frame or the first TrueHD major sync: a window cut from a film
    // can start mid-stream.
    let mut chunk = Vec::new();
    let codec = loop {
        let n = input.read(&mut buffer)?;
        chunk.extend_from_slice(&buffer[..n]);
        if chunk.starts_with(&DTS_CORE_SYNC) {
            break DTS;
        }
        if let Some(sync) = chunk.windows(4).position(|w| w == TRUEHD_SYNC) {
            chunk.drain(..sync.saturating_sub(4));
            break TRUEHD;
        }
        if n == 0 {
            println!("== {name}\nno DTS core or TrueHD major sync");
            return Ok(());
        }
    };
    let mut inspector = match codec {
        DTS => Inspector::Dts(Box::default()),
        _ => Inspector::TrueHd(Box::default()),
    };
    let mut renders = [
        Render::new(codec, Layout::SevenOneFour),
        Render::new(codec, Layout::NineOneSix),
    ];
    loop {
        let end = chunk.is_empty();
        match &mut inspector {
            Inspector::TrueHd(inspection) => inspection.push(&chunk),
            Inspector::Dts(inspection) => inspection.push(&chunk),
        }
        for render in &mut renders {
            render.push(&chunk, end);
        }
        if end {
            break;
        }
        let n = input.read(&mut buffer)?;
        chunk.clear();
        chunk.extend_from_slice(&buffer[..n]);
    }
    println!("== {name}");
    match &inspector {
        Inspector::TrueHd(inspection) => inspection.report(),
        Inspector::Dts(inspection) => inspection.report(),
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
