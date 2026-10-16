use crate::{
    limit::Limiter,
    render::{Event, Gains, Layout, Object, Renderer, Speaker, TrimLayout},
};
use truehd::{
    process::{
        decode::{DecodedAccessUnit, Decoder},
        extract::Extractor,
        parse::Parser,
    },
    structs::oamd::{ObjectAudioMetadataPayload, TrimElement},
    utils::errors::ExtractError,
};

pub struct Pcm {
    pub data: Vec<f32>,
    pub frames: usize,
    pub rate: u32,
    pub channels: usize,
}

/// Why a session stopped. Every error ends the session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// Damaged, truncated or misframed input.
    Malformed(String),
    /// Well-formed content this renderer does not render, such as TrueHD without Atmos.
    Unsupported(String),
}
impl Error {
    pub fn message(&self) -> &str {
        match self {
            Self::Malformed(message) | Self::Unsupported(message) => message,
        }
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}
impl std::error::Error for Error {}
impl From<String> for Error {
    fn from(message: String) -> Self {
        Self::Malformed(message)
    }
}
impl From<&str> for Error {
    fn from(message: &str) -> Self {
        Self::Malformed(message.into())
    }
}

/// Concealment accepted by this decoder session, measured in source sample frames, not channels.
/// Includes input before any host-side seek trimming; excludes encoder priming and padding.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RecoveryStatistics {
    pub concealed_frames: u64,
    pub concealment_events: u64,
    pub longest_concealment_frames: u64,
}
/// Decodes and renders one stream, holding the speaker feeds below full scale by default.
pub struct Core {
    source: Source,
    limiter: Option<Limiter>,
}
enum Source {
    TrueHd(Box<TrueHd>),
    Dts(Box<Dts>),
}
impl Core {
    /// Cumulative snapshot; fresh sessions and DTS:X sessions start at zero.
    pub fn recovery_statistics(&self) -> RecoveryStatistics {
        match &self.source {
            Source::TrueHd(decoder) => decoder.recovery,
            Source::Dts(_) => RecoveryStatistics::default(),
        }
    }
    /// Whether the stream has proven spatial: TrueHD with its first object metadata, or a DTS:X
    /// frame rendered with its presentation. Silence before that does not count.
    pub fn is_spatial(&self) -> bool {
        match &self.source {
            Source::TrueHd(decoder) => decoder.spatial,
            Source::Dts(decoder) => decoder.seen,
        }
    }
    pub fn new(codec: u32, layout: Layout) -> Result<Self, Error> {
        let source = match codec {
            1 => Source::TrueHd(Box::new(TrueHd::new(layout))),
            2 => Source::Dts(Box::new(Dts::new(layout))),
            _ => return Err("Unknown input codec".into()),
        };
        Ok(Self {
            source,
            limiter: Some(Limiter::new(layout.count())),
        })
    }
    /// Decodes without peak limiting for measurements of the rendered speaker feeds.
    /// Samples can exceed full scale; use `new` for playback.
    pub fn new_unlimited(codec: u32, layout: Layout) -> Result<Self, Error> {
        let mut core = Self::new(codec, layout)?;
        core.limiter = None;
        Ok(core)
    }
    /// Applies TrueHD dialogue normalisation as an AV receiver does. Off by default, as in Apple
    /// TV's own Atmos playback; DTS:X exposes no dialogue level.
    pub fn set_dialogue_normalisation(&mut self, enabled: bool) {
        if let Source::TrueHd(decoder) = &mut self.source {
            decoder.normalise_dialogue = enabled;
        }
    }
    /// Decodes `data`. With limiting enabled, the last few milliseconds of output wait for the
    /// audio after them, until a call with `end` releases them.
    pub fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), Error> {
        let limiter = &mut self.limiter;
        let mut limited = |pcm: Pcm| match limiter {
            Some(limiter) => limiter.push(pcm, output),
            None => output(pcm),
        };
        match &mut self.source {
            Source::TrueHd(d) => d.push(data, end, &mut limited)?,
            Source::Dts(d) => d.push(data, end, &mut limited)?,
        }
        if end && let Some(limiter) = &mut self.limiter {
            limiter.finish(output)?;
        }
        Ok(())
    }
}

/// Audio decoded before the first object metadata, at most half a second at 48 kHz.
/// Atmos streams repeat their metadata every few tens of milliseconds.
const MAX_HELD_FRAMES: usize = 24_000;

/// FBA streams repeat their major sync at least every 128 access units.
const MAX_SYNC_INTERVAL: usize = 128;

pub struct TrueHd {
    extractor: Extractor,
    parser: Parser,
    decoder: Decoder,
    decoded: DecodedAccessUnit,
    renderer: Renderer,
    bytes: u64,
    consumed: u64,
    spatial: bool,
    held: Vec<Vec<Vec<f32>>>,
    held_frames: usize,
    normalise_dialogue: bool,
    /// Dialogue normalisation gain signalled at the latest major sync, and the gain applied
    /// at the end of the previous access unit.
    dialogue: f32,
    level: Option<f32>,
    /// The error that lost an access unit, and how many access units have been concealed with
    /// silence since, until the stream restarts at its next major sync.
    lost: Option<(String, usize)>,
    /// Length and channel count of the latest decoded access unit.
    unit: Option<(usize, usize)>,
    recovery: RecoveryStatistics,
}

/// The attenuation an AV receiver applies so that dialogue plays at −31 dBFS.
fn dialogue_gain(norm: u8) -> f32 {
    if (1..=31).contains(&norm) {
        10f32.powf((f32::from(norm) - 31.) / 20.)
    } else {
        1.
    }
}

impl TrueHd {
    fn new(layout: Layout) -> Self {
        Self {
            extractor: Extractor::default(),
            // Keep validation of unused substreams: skipping them changes damage concealment.
            parser: Parser::default(),
            decoder: Decoder::default(),
            decoded: DecodedAccessUnit::default(),
            renderer: Renderer::new(layout),
            bytes: 0,
            consumed: 0,
            spatial: false,
            held: Vec::new(),
            held_frames: 0,
            normalise_dialogue: false,
            dialogue: 1.,
            level: None,
            lost: None,
            unit: None,
            recovery: RecoveryStatistics::default(),
        }
    }
    fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), Error> {
        self.bytes += data.len() as u64;
        self.extractor.push_bytes(data);
        while let Some(frame) = self.extractor.next() {
            let frame = match frame {
                Ok(f) => f,
                Err(ExtractError::InsufficientData) => break,
                Err(e) => return Err(format!("TrueHD framing: {e}").into()),
            };
            if frame.offset != self.consumed {
                return Err(
                    "TrueHD stream skipped bytes; start at a major sync and supply only this track"
                        .into(),
                );
            }
            self.consumed = frame.offset + frame.as_ref().len() as u64;
            // Access units after a lost one cannot decode before the stream restarts.
            let restarting = match self.lost.take() {
                Some(lost) if !frame.is_major_sync() => {
                    self.lost = Some(lost);
                    self.conceal(output)?;
                    continue;
                }
                lost => lost.map(|(error, _)| error),
            };
            let parsed = self.parser.parse(&frame);
            // Splice records are diagnostic history, not decoder state. Bound them even on errors.
            drop(self.parser.take_branches());
            let au = match parsed {
                Ok(au) => au,
                Err(e) => {
                    self.lose(restarting, format!("TrueHD parsing: {e}"), output)?;
                    continue;
                }
            };
            if let Some(sync) = &au.major_sync_info
                && sync.substreams < 4
            {
                return Err(Error::Unsupported(
                    "This TrueHD stream has no Atmos presentation".into(),
                ));
            }
            if self.normalise_dialogue
                && let Some(extra) = au
                    .major_sync_info
                    .as_ref()
                    .and_then(|sync| sync.channel_meaning.extra_channel_meaning())
            {
                self.dialogue = dialogue_gain(extra.sixteench_dialogue_norm);
            }
            if let Err(e) = self
                .decoder
                .decode_presentation_into(&au, 3, &mut self.decoded)
            {
                self.lose(restarting, format!("TrueHD decoding: {e}"), output)?;
                continue;
            }
            if self.decoded.is_duplicate {
                continue;
            }
            if self.decoded.sampling_frequency != 48_000 {
                return Err(Error::Unsupported(
                    "The initial Atmos renderer supports 48 kHz tracks".into(),
                ));
            }
            let frames = self.decoded.sample_length;
            // A changed dialogue level ramps over one access unit.
            let (from, to) = (self.level.unwrap_or(self.dialogue), self.dialogue);
            self.level = Some(to);
            let input: Vec<Vec<f32>> = (0..self.decoded.channel_count)
                .map(|ch| {
                    (0..frames)
                        .map(|s| {
                            let gain = from + (to - from) * (s + 1) as f32 / frames as f32;
                            self.decoded.pcm_data[s][ch] as f32 / 8_388_608. * gain
                        })
                        .collect()
                })
                .collect();
            self.unit = Some((frames, self.decoded.channel_count));
            self.emit(input, frames, true, output)?;
        }
        if self.extractor.error_count() != 0 {
            return Err("TrueHD extractor lost synchronization".into());
        }
        if self.bytes - self.consumed > 64 * 1024 {
            return Err("TrueHD sync not found within 64 KiB".into());
        }
        // A loss in the final access units was already concealed unit by unit, as mid-stream.
        if end && (self.consumed != self.bytes || !self.spatial) {
            return Err("Empty or truncated TrueHD stream".into());
        }
        Ok(())
    }

    /// Conceals an access unit that failed to parse or decode, and those after it up to the
    /// next major sync, with silence of their length. Discs join clips this way: the access
    /// unit before the join is cut short, and those after it lack the restart they follow. A
    /// failure at that major sync, or none within the longest interval, ends the session; the
    /// stream ending first does not.
    fn lose(
        &mut self,
        restarting: Option<String>,
        error: String,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), Error> {
        if let Some(first) = restarting {
            return Err(first.into());
        }
        if self.unit.is_none() {
            return Err(error.into());
        }
        self.parser.reset_for_next_major_sync();
        self.decoder.reset_for_next_major_sync();
        self.lost = Some((error, 0));
        self.conceal(output)
    }

    /// Writes silence for one lost access unit.
    fn conceal(&mut self, output: &mut impl FnMut(Pcm) -> Result<(), String>) -> Result<(), Error> {
        if let Some((error, count)) = &mut self.lost {
            *count += 1;
            if *count > MAX_SYNC_INTERVAL {
                return Err(error.clone().into());
            }
        }
        let (frames, channels) = self.unit.unwrap_or_default();
        self.emit(vec![vec![0.; frames]; channels], frames, false, output)?;
        if let Some((_, count)) = self.lost.as_ref() {
            self.recovery.concealed_frames += frames as u64;
            if *count == 1 {
                self.recovery.concealment_events += 1;
            }
            self.recovery.longest_concealment_frames = self
                .recovery
                .longest_concealment_frames
                .max(*count as u64 * frames as u64);
        }
        Ok(())
    }

    /// Renders one access unit, with the object metadata just decoded if `metadata` is set.
    fn emit(
        &mut self,
        input: Vec<Vec<f32>>,
        frames: usize,
        metadata: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), Error> {
        let oamd = if metadata {
            self.decoded.oamd.as_slice()
        } else {
            &[]
        };
        if !self.spatial {
            let Some(first) = oamd.first() else {
                // A stream entered at a later major sync carries its first object metadata
                // a few access units in. Hold the audio until then so no samples are lost.
                self.held_frames += frames;
                if self.held_frames > MAX_HELD_FRAMES {
                    // Damage can hide it, and a later sync point may carry it.
                    return Err("Atmos presentation has no object metadata within 0.5 s".into());
                }
                self.held.push(input);
                return Ok(());
            };
            // Held audio takes the first known object state.
            set_initial_state(&mut self.renderer, first, input.len())?;
            self.spatial = true;
            for held in std::mem::take(&mut self.held) {
                let frames = held.first().map_or(0, Vec::len);
                output(Pcm {
                    data: self.renderer.render(&held, frames),
                    frames,
                    rate: 48_000,
                    channels: self.renderer.panner.count(),
                })?;
            }
            self.held_frames = 0;
        }
        for metadata in oamd {
            schedule_oamd(&mut self.renderer, metadata, input.len())?;
        }
        output(Pcm {
            data: self.renderer.render(&input, frames),
            frames,
            rate: 48_000,
            channels: self.renderer.panner.count(),
        })?;
        Ok(())
    }
}

/// Routes each channel at its first metadata block, for audio decoded before that metadata.
fn set_initial_state(
    renderer: &mut Renderer,
    metadata: &ObjectAudioMetadataPayload,
    channels: usize,
) -> Result<(), Error> {
    let mut first = Vec::with_capacity(channels);
    for_each_block(renderer, metadata, channels, |event| {
        if event.block == 0 {
            first.push((event.channel, event.gains));
        }
    })?;
    for (channel, gains) in first {
        renderer.route(channel, gains);
    }
    Ok(())
}

fn schedule_oamd(
    renderer: &mut Renderer,
    metadata: &ObjectAudioMetadataPayload,
    channels: usize,
) -> Result<(), Error> {
    let mut events = Vec::new();
    for_each_block(renderer, metadata, channels, |event| {
        events.push(event.event)
    })?;
    for event in events {
        renderer.event(event);
    }
    Ok(())
}

struct BlockEvent {
    block: usize,
    channel: usize,
    gains: crate::render::Gains,
    event: Event,
}

/// Validates the metadata and yields the target gains of every channel in every update block.
fn for_each_block(
    renderer: &Renderer,
    metadata: &ObjectAudioMetadataPayload,
    channels: usize,
    mut visit: impl FnMut(BlockEvent),
) -> Result<(), Error> {
    let program = &metadata.program_assignment;
    if program.num_isf_objects != 0 || program.bed_assignment.len() > 1 {
        return Err(Error::Unsupported(
            "Atmos ISF and multiple bed instances are not yet supported".into(),
        ));
    }
    if program.b_bed_chan_distribute {
        return Err(Error::Unsupported(
            "Atmos bed channel distribution is not yet supported".into(),
        ));
    }
    if metadata.bed_object_element.is_some() {
        return Err(Error::Unsupported(
            "Atmos bed downmix metadata is not yet supported".into(),
        ));
    }
    let trim = metadata.trim_element.as_ref();
    // `warp_mode` 1 doubles Y before rendering (TS 103 420 table 32). It is the Dolby Atmos
    // Renderer's 5.1 "direct render with warp": with the surrounds at the back, everything
    // behind the room's midpoint plays at a constant level in them. 7.1.4 and 9.1.6 have side
    // and back surrounds, so positions stay as transmitted.
    if trim.is_some_and(|trim| trim.warp_mode > 1) {
        return Err(Error::Unsupported("Reserved Atmos warp mode".into()));
    }
    let element = metadata
        .object_element
        .as_ref()
        .ok_or("Atmos metadata contains no object element")?;
    let update = &element.md_update_info;
    if update.num_obj_info_blocks == 0
        || update.block_update_info.len() != update.num_obj_info_blocks
    {
        return Err("Atmos update block count mismatch".into());
    }
    if metadata.object_count != channels || element.object_data.len() != channels {
        return Err("Atmos PCM / metadata channel count mismatch".into());
    }
    let beds = program
        .bed_assignment
        .first()
        .map(|b| b.to_index_vec())
        .unwrap_or_default();
    let positions = metadata.get_damf_pos();
    let divergence = metadata.extended_object_element.as_ref();
    use Speaker::*;
    let bed_speakers = [
        L, R, C, Lfe, Ls, Rs, Lb, Rb, Tfl, Tfr, Tsl, Tsr, Tbl, Tbr, Lw, Rw, Lfe,
    ];
    for (block_index, timing) in update.block_update_info.iter().enumerate() {
        let sample = renderer.sample
            + metadata.evo_sample_offset
            + update.sample_offset as u64
            + u64::from(timing.block_offset_factor_bits) * 32;
        for channel in 0..channels {
            let block = element.object_data[channel]
                .get(block_index)
                .ok_or("Missing Atmos object block")?;
            let mut gains = if block.b_object_not_active {
                // Inactive blocks can retain stale rendering controls. Their target is silence.
                [0.; crate::render::MAX_CHANNELS]
            } else if block.b_object_in_bed_or_isf {
                let index = *beds.get(channel).ok_or("Atmos bed assignment mismatch")?;
                renderer
                    .panner
                    .bed(*bed_speakers.get(index).ok_or("Unknown Atmos bed speaker")?)
            } else {
                let [x, y, z] = *positions
                    .get(channel)
                    .and_then(|v| v.get(block_index))
                    .ok_or("Missing Atmos object position")?;
                if [x, y, z].iter().any(|x| !x.is_finite()) {
                    return Err("Invalid Atmos object position".into());
                }
                let info = &block.object_render_info;
                if info.b_object_distance_specified {
                    return Err(Error::Unsupported(
                        "Atmos objects outside the room are not yet supported".into(),
                    ));
                }
                if info.zone_constraints_idx > 5 {
                    return Err(Error::Unsupported("Reserved Atmos zone constraint".into()));
                }
                let object = renderer.panner.preprocess(Object {
                    // From DAMF coordinates to TS 103 448 room coordinates.
                    position: [x / 2. + 0.5, 0.5 - y / 2., z].map(|v| v as f32),
                    size: info.object_size.map(|s| s as f32),
                    divergence: divergence
                        .and_then(|e| e.object_div_block.get(channel)?.get(block_index))
                        .filter(|d| d.b_object_divergence)
                        .map_or(0., |d| d.object_divergence as f32),
                    // Screen anchoring assumes the screen spans the front pair, which leaves
                    // positions unchanged, but still disables snap (TS 103 448 clause 5.1.2.2).
                    snap: info.b_object_snap && !info.b_object_use_screen_ref,
                    zone: info.zone_constraints_idx,
                    elevation: info.b_enable_elevation,
                });
                let mut gains = renderer.panner.object(&object);
                let layout = renderer.panner.trim_layout(&object);
                let trim = trim_gain(trim, channel, layout, object.position);
                gains.iter_mut().for_each(|g| *g *= trim);
                gains
            };
            let gain = if block.b_object_not_active || block.object_basic_info.object_gain == -128 {
                0.
            } else {
                10f32.powf(block.object_basic_info.object_gain as f32 / 20.)
            };
            for g in &mut gains {
                *g *= gain;
            }
            visit(BlockEvent {
                block: block_index,
                channel,
                gains,
                event: Event {
                    sample,
                    channel,
                    gains,
                    ramp: timing.ramp_duration as u32,
                },
            });
        }
    }
    Ok(())
}

/// Trim gain of an object at a preprocessed position (TS 103 448 clause 5.3). The configuration
/// follows the speakers left after zone constraints: 8 for the full layouts, where the default
/// trim is 0 dB. Without trim metadata the default trim applies. The centre trim applies only to
/// stereo, and TS 103 448 has no balance control, so balance metadata is ignored.
fn trim_gain(
    trim: Option<&TrimElement>,
    object: usize,
    layout: TrimLayout,
    position: [f32; 3],
) -> f32 {
    let default = layout.default_db(position);
    let decibels = match trim {
        None => default,
        Some(trim) if trim.b_disable_trim.get(object) == Some(&true) => 0.,
        Some(trim) => match (trim.global_trim_mode, &trim.trims[layout.index()]) {
            (1, _) => 0.,
            (2, Some(custom)) if custom.b_disable_trim => 0.,
            (2, Some(custom)) if !custom.b_default_trim => {
                let [_, y, z] = position;
                let surround = custom.trim_surround.unwrap_or(0.) as f32;
                let height = custom.trim_height.unwrap_or(0.) as f32;
                let front_to_back = if y >= 0.5 {
                    surround
                } else {
                    surround * 2. * y
                };
                front_to_back + height * z.abs()
            }
            _ => default,
        },
    };
    10f32.powf(decibels / 20.)
}

/// Frames that play as silence when a DTS-HD stream is entered: lossless reconstruction builds on
/// the core's filter history from earlier frames, so the first two decode with audible errors
/// (about 3 dB below the signal in the first, up to −16 dBFS in the second).
const DTS_WARMUP_FRAMES: u8 = 2;

pub struct Dts {
    buffer: Vec<u8>,
    decoder: dca::HdDecoder,
    decoded: dca::HdFrame,
    warmup: u8,
    renderer: Renderer,
    fold_renderer: dca::FoldRenderer,
    presentation: Option<dca::XPresentation>,
    object_gains: [Option<Gains>; dca::MAX_SOURCES],
    seen: bool,
}
impl Dts {
    fn new(layout: Layout) -> Self {
        Self {
            buffer: vec![],
            decoder: dca::HdDecoder::new(),
            decoded: dca::HdFrame::default(),
            warmup: DTS_WARMUP_FRAMES,
            renderer: Renderer::new(layout),
            fold_renderer: dca::FoldRenderer::new(),
            presentation: None,
            object_gains: [None; dca::MAX_SOURCES],
            seen: false,
        }
    }
    fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), Error> {
        self.buffer.extend_from_slice(data);
        loop {
            if self.buffer.len() < 18 {
                break;
            }
            let header = dca::parse_header(&self.buffer)
                .map_err(|e| format!("DTS core header (16-bit big-endian required): {e}"))?;
            let core_len = header.frame_size;
            if self.buffer.len() < core_len + 4 {
                break;
            }
            if self.buffer[core_len..core_len + 4] != [0x64, 0x58, 0x20, 0x25] {
                let message = "DTS:X requires the complete DTS-HD extension after each core frame";
                // Once DTS:X has decoded, a missing extension is damage, not a core-only track.
                return Err(if self.seen {
                    message.into()
                } else {
                    Error::Unsupported(message.into())
                });
            }
            let exss = &self.buffer[core_len..];
            let Some(exss_len) = dca::exss_substream_size(exss) else {
                if exss.len() > 64 * 1024 {
                    return Err("Invalid DTS-HD extension header".into());
                }
                break;
            };
            if self.buffer.len() < core_len + exss_len {
                break;
            }
            let pcm = match self.decoder.decode_into(
                &self.buffer[..core_len],
                &self.buffer[core_len..core_len + exss_len],
                &mut self.decoded,
            ) {
                Ok(()) => {
                    // Lend the frame to rendering, then retain its buffers for the next decode.
                    let frame = std::mem::take(&mut self.decoded);
                    let rendered = self.render(&frame);
                    self.decoded = frame;
                    let mut pcm = rendered?;
                    if self.warmup > 0 {
                        self.warmup -= 1;
                        pcm.data.fill(0.);
                    }
                    self.seen = true;
                    pcm
                }
                // Entered mid-stream, the lossless layer can span frames and yield nothing yet;
                // its duration still plays, as silence, so later audio keeps its time.
                Err(dca::HdError::Pending) => {
                    let frames = header.samples_per_channel();
                    let channels = self.renderer.panner.count();
                    Pcm {
                        data: vec![0.; frames * channels],
                        frames,
                        rate: 48_000,
                        channels,
                    }
                }
                Err(e) => return Err(format!("DTS-HD decoding: {e:?}").into()),
            };
            self.buffer.drain(..core_len + exss_len);
            output(pcm)?;
        }
        if self.buffer.len() > 2 * 1024 * 1024 {
            return Err("DTS-HD access unit exceeds 2 MiB".into());
        }
        if end && (!self.buffer.is_empty() || !self.seen) {
            return Err("Empty or truncated DTS-HD stream".into());
        }
        Ok(())
    }
    fn render(&mut self, frame: &dca::HdFrame) -> Result<Pcm, Error> {
        if !frame.lossless || !(frame.x_present || frame.x_imax) {
            return Err(Error::Unsupported(
                "This stream is not lossless DTS:X".into(),
            ));
        }
        if let Some(e) = frame.x_decode_error {
            return Err(format!("DTS:X extension decoding: {e}").into());
        }
        let presentation = dca::XPresentation::detect(frame)
            .ok_or_else(|| Error::Unsupported("Unknown DTS:X presentation".into()))?;
        let metadata = dca::XMetadata::parse(&frame.x_payload, presentation.feed_count())
            .map_err(|e| format!("DTS:X spatial metadata: {e:?}"))?;
        self.render_spatial(frame, presentation, metadata)
    }

    fn render_spatial(
        &mut self,
        frame: &dca::HdFrame,
        presentation: dca::XPresentation,
        metadata: dca::XMetadata,
    ) -> Result<Pcm, Error> {
        if dca::XPresentation::detect(frame) != Some(presentation) {
            return Err("DTS:X PCM does not match its presentation".into());
        }
        if frame.sample_rate != 48_000 {
            return Err(Error::Unsupported(
                "The DTS:X renderer supports 48 kHz tracks".into(),
            ));
        }
        if self
            .presentation
            .is_some_and(|previous| previous != presentation)
        {
            return Err("DTS:X presentation changed mid-stream".into());
        }
        if metadata.source_count() != presentation.feed_count() {
            return Err("DTS:X PCM / metadata feed count mismatch".into());
        }
        let mut gains = Vec::with_capacity(presentation.feed_count());
        for feed in 0..presentation.feed_count() {
            let source = metadata
                .source(feed)
                .ok_or("Missing DTS:X source metadata")?;
            let gain = match source.role {
                dca::SourceRole::Object { position, .. }
                    if presentation.object_feeds().contains(&feed) =>
                {
                    self.renderer.panner.polar(
                        position.azimuth_degrees() as f32,
                        position.elevation_degrees() as f32,
                        position.distance() as f32,
                    )
                }
                dca::SourceRole::Height(channel)
                    if presentation.fixed_feeds().contains(&feed)
                        && presentation.fixed_channels()
                            [feed - presentation.fixed_feeds().start]
                            == channel =>
                {
                    self.renderer.panner.speaker(dts_spatial_speaker(channel))
                }
                _ => {
                    return Err(Error::Unsupported(
                        "DTS:X source role does not match its presentation".into(),
                    ));
                }
            };
            gains.push(gain);
        }
        let frames = frame.bed_sample_count();
        let mut plan = dca::FoldPlan::from_metadata(&metadata);
        self.fold_renderer.apply(&mut plan, &metadata, frames);
        if plan.has_unknown() {
            return Err(Error::Unsupported(
                "DTS:X has an unknown bed fold; refusing to duplicate its spatial audio".into(),
            ));
        }
        let mut input = Vec::new();
        use Speaker::*;
        for (id, channel) in frame.samples.iter().enumerate() {
            if let Some(pcm) = channel {
                if pcm.len() != frames {
                    return Err("DTS bed sample count mismatch".into());
                }
                let speaker = match id {
                    0 => C,
                    1 => L,
                    2 => R,
                    3 | 9 => Ls,
                    4 | 10 => Rs,
                    5 => Lfe,
                    7 => Lb,
                    8 => Rb,
                    _ => {
                        return Err(Error::Unsupported(format!(
                            "DTS bed speaker {id} is not yet supported"
                        )));
                    }
                };
                let index = input.len();
                self.renderer
                    .route(index, self.renderer.panner.speaker(speaker));
                input.push(
                    pcm.iter()
                        .enumerate()
                        .map(|(s, x)| plan.clean(id, *x, s, &frame.x_samples))
                        .collect(),
                );
            }
        }
        for (feed, pcm) in frame.x_samples.iter().enumerate() {
            let target = gains[feed];
            let channel = input.len();
            if presentation.object_feeds().contains(&feed) {
                let previous = self.object_gains[feed].unwrap_or(target);
                self.renderer.route(channel, previous);
                if previous != target {
                    self.renderer.event(Event {
                        sample: self.renderer.sample,
                        channel,
                        gains: target,
                        ramp: frames as u32 - 1,
                    });
                }
                self.object_gains[feed] = Some(target);
            } else {
                self.renderer.route(channel, target);
            }
            input.push(pcm.clone());
        }
        self.presentation = Some(presentation);
        Ok(Pcm {
            data: self.renderer.render(&input, frames),
            frames,
            rate: frame.sample_rate,
            channels: self.renderer.panner.count(),
        })
    }
}

fn dts_spatial_speaker(channel: dca::SpatialChannel) -> Speaker {
    match channel {
        dca::SpatialChannel::TopFrontLeft => Speaker::Tfl,
        dca::SpatialChannel::TopFrontRight => Speaker::Tfr,
        dca::SpatialChannel::TopFrontCenter => Speaker::Tfc,
        dca::SpatialChannel::TopSideLeft => Speaker::Tsl,
        dca::SpatialChannel::TopSideRight => Speaker::Tsr,
        dca::SpatialChannel::TopBackLeft => Speaker::Tbl,
        dca::SpatialChannel::TopBackRight => Speaker::Tbr,
        dca::SpatialChannel::WideLeft => Speaker::Lw,
        dca::SpatialChannel::WideRight => Speaker::Rw,
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::*;

    #[test]
    fn concealment_counts_spans_and_stops_at_the_recovery_bound() {
        let mut decoder = TrueHd::new(Layout::SevenOneFour);
        decoder.unit = Some((40, 12));
        let mut discard = |_: Pcm| Ok(());
        decoder.lose(None, "first".into(), &mut discard).unwrap();
        decoder.conceal(&mut discard).unwrap();
        assert_eq!(
            decoder.recovery,
            RecoveryStatistics {
                concealed_frames: 80,
                concealment_events: 1,
                longest_concealment_frames: 80,
            }
        );
        // A separate loss starts a new span without resetting the cumulative snapshot.
        decoder.lost = None;
        decoder.lose(None, "second".into(), &mut discard).unwrap();
        for _ in 1..MAX_SYNC_INTERVAL {
            decoder.conceal(&mut discard).unwrap();
        }
        let before = decoder.recovery;
        assert_eq!(before.concealed_frames, (MAX_SYNC_INTERVAL as u64 + 2) * 40);
        assert_eq!(before.concealment_events, 2);
        assert_eq!(
            before.longest_concealment_frames,
            MAX_SYNC_INTERVAL as u64 * 40
        );
        assert!(decoder.conceal(&mut discard).is_err());
        assert_eq!(
            decoder.recovery, before,
            "rejected concealment is not counted"
        );
        // A stream that ends inside a concealed span keeps its silence instead of failing.
        let mut ending = TrueHd::new(Layout::SevenOneFour);
        ending.unit = Some((40, 12));
        ending.lose(None, "tail".into(), &mut discard).unwrap();
        ending.spatial = true;
        assert!(ending.push(&[], true, &mut discard).is_ok());
        for codec in [1, 2] {
            assert_eq!(
                Core::new(codec, Layout::SevenOneFour)
                    .unwrap()
                    .recovery_statistics(),
                RecoveryStatistics::default()
            );
        }
    }
}

#[cfg(test)]
mod metadata_tests {
    use super::*;
    type Control<T> = (&'static str, fn(&mut T));
    use truehd::structs::oamd::{
        BlockUpdateInfo, ExtendedObjectElement, ExtendedPrecisionPositionBlock, MDUpdateInfo,
        ObjectBasicInfo, ObjectDivergenceBlock, ObjectElement, ObjectInfoBlock, ObjectRenderInfo,
        Trim,
    };

    fn point() -> ObjectAudioMetadataPayload {
        ObjectAudioMetadataPayload {
            object_count: 1,
            object_element: Some(ObjectElement {
                md_update_info: MDUpdateInfo {
                    num_obj_info_blocks: 1,
                    block_update_info: vec![BlockUpdateInfo::default()],
                    ..Default::default()
                },
                object_data: vec![vec![ObjectInfoBlock {
                    object_basic_info: ObjectBasicInfo {
                        object_gain: 0,
                        ..Default::default()
                    },
                    object_render_info: ObjectRenderInfo {
                        pos3d: [0., 0., 1.],
                        ..Default::default()
                    },
                    ..Default::default()
                }]],
                ..Default::default()
            }),
            ..Default::default()
        }
    }
    fn block(metadata: &mut ObjectAudioMetadataPayload) -> &mut ObjectInfoBlock {
        &mut metadata.object_element.as_mut().unwrap().object_data[0][0]
    }
    fn render(metadata: &ObjectAudioMetadataPayload) -> Result<Vec<f32>, Error> {
        let mut renderer = Renderer::new(Layout::NineOneSix);
        schedule_oamd(&mut renderer, metadata, 1)?;
        Ok(renderer.render(&[vec![1.]], 1))
    }

    #[test]
    fn elevation_flag_changes_ceiling_object_to_bed_anchor() {
        let mut metadata = point();
        let elevated = render(&metadata).unwrap();
        assert_eq!(elevated[10], 1.);
        assert_eq!(elevated[..10].iter().sum::<f32>(), 0.);
        block(&mut metadata).object_render_info.b_enable_elevation = false;
        let grounded = render(&metadata).unwrap();
        assert_eq!(grounded[0], 1.);
        assert_eq!(grounded[10..].iter().sum::<f32>(), 0.);
    }

    #[test]
    fn object_controls_reach_the_panner() {
        let rendered = |set: fn(&mut ObjectRenderInfo)| {
            let mut metadata = point();
            set(&mut block(&mut metadata).object_render_info);
            render(&metadata).unwrap()
        };
        // Screen-only zone: a rear-left object plays from the front left alone, with the
        // −3 dB default trim of configuration 6 (no surrounds).
        let zoned = rendered(|i| {
            i.pos3d = [0., 1., 0.];
            i.zone_constraints_idx = 4;
        });
        assert!((zoned[0] - 10f32.powf(-3. / 20.)).abs() < 1e-6);
        assert_eq!(zoned.iter().filter(|g| **g > 0.).count(), 1);
        // Snap moves a nearby object onto the left speaker, unless it is screen-anchored.
        let snapped = rendered(|i| {
            i.pos3d = [0.1, 0.05, 0.];
            i.b_object_snap = true;
        });
        assert_eq!(snapped[0], 1.);
        let anchored = rendered(|i| {
            i.pos3d = [0.1, 0.05, 0.];
            i.b_object_snap = true;
            i.b_object_use_screen_ref = true;
        });
        assert!(anchored[0] < 1. && anchored[2] > 0.);
        // Size spreads the room centre beyond the side pair.
        let sized = rendered(|i| {
            i.pos3d = [0.5, 0.5, 0.];
            i.object_size = [0.5; 3];
        });
        assert!(sized.iter().filter(|g| **g > 0.05).count() > 2);
        // Full divergence of a centre object plays from the front pair.
        let mut metadata = point();
        block(&mut metadata).object_render_info.pos3d = [0.5, 0., 0.];
        metadata.extended_object_element = Some(ExtendedObjectElement {
            b_obj_div_block: true,
            object_div_block: vec![vec![ObjectDivergenceBlock {
                b_object_divergence: true,
                object_divergence: 1.,
                ..Default::default()
            }]],
            ..Default::default()
        });
        let diverged = render(&metadata).unwrap();
        assert!((diverged[0] - std::f32::consts::FRAC_1_SQRT_2).abs() < 1e-6);
        assert!(diverged[2] < 1e-6);
    }

    #[test]
    fn dialogue_normalisation_attenuates_like_a_native_decoder() {
        assert_eq!(dialogue_gain(31), 1.);
        assert!((20. * dialogue_gain(27).log10() + 4.).abs() < 1e-5);
        assert_eq!(dialogue_gain(0), 1.);
    }

    #[test]
    fn custom_trim_attenuates_surround_and_height_positions() {
        let mut metadata = point();
        block(&mut metadata).object_render_info.pos3d = [0., 1., 1.];
        let mut trims: [Option<Trim>; 9] = Default::default();
        trims[8] = Some(Trim {
            b_default_trim: false,
            trim_surround: Some(-6.),
            trim_height: Some(-3.),
            ..Default::default()
        });
        metadata.trim_element = Some(TrimElement {
            global_trim_mode: 2,
            trims,
            ..Default::default()
        });
        let peak =
            |m: &ObjectAudioMetadataPayload| render(m).unwrap().into_iter().fold(0., f32::max);
        assert!((peak(&metadata) - 10f32.powf(-9. / 20.)).abs() < 1e-6);
        let trim = metadata.trim_element.as_mut().unwrap();
        trim.b_disable_trim = vec![true];
        assert_eq!(peak(&metadata), 1.);
        let trim = metadata.trim_element.as_mut().unwrap();
        trim.b_disable_trim.clear();
        trim.trims[8] = Some(Trim::default());
        assert_eq!(peak(&metadata), 1.);
        // Without heights the object uses configuration 2, whose default trim is −1.5 dB at the
        // rear, with or without trim metadata.
        block(&mut metadata).object_render_info.b_enable_elevation = false;
        let flat = 10f32.powf(-1.5 / 20.);
        assert!((peak(&metadata) - flat).abs() < 1e-6);
        metadata.trim_element = None;
        assert!((peak(&metadata) - flat).abs() < 1e-6);
    }

    #[test]
    fn unsupported_object_controls_fail_explicitly() {
        let cases: [Control<ObjectRenderInfo>; 2] = [
            ("outside the room", |i| {
                i.b_object_distance_specified = true;
                i.distance_factor = Some(2.);
            }),
            ("zone", |i| i.zone_constraints_idx = 6),
        ];
        for (name, set) in cases {
            let mut metadata = point();
            set(&mut block(&mut metadata).object_render_info);
            let error = render(&metadata).unwrap_err();
            assert!(error.message().contains(name), "{error}");
            assert!(matches!(error, Error::Unsupported(_)), "{error}");
            block(&mut metadata).b_object_not_active = true;
            assert!(render(&metadata).unwrap().iter().all(|g| *g == 0.));
        }
    }

    #[test]
    fn unsupported_program_controls_fail_explicitly() {
        let cases: [Control<ObjectAudioMetadataPayload>; 3] = [
            ("distribution", |m| {
                m.program_assignment.b_bed_chan_distribute = true
            }),
            ("downmix", |m| {
                m.bed_object_element = Some(Default::default())
            }),
            ("warp mode", |m| {
                m.trim_element = Some(TrimElement {
                    warp_mode: 2,
                    ..Default::default()
                })
            }),
        ];
        for (name, set) in cases {
            let mut metadata = point();
            set(&mut metadata);
            let error = render(&metadata).unwrap_err();
            assert!(error.message().contains(name), "{error}");
            assert!(matches!(error, Error::Unsupported(_)), "{error}");
        }
    }

    #[test]
    fn warp_mode_leaves_side_positions_on_the_side_surrounds() {
        let mut metadata = point();
        block(&mut metadata).object_render_info.pos3d = [0., 0.5, 0.];
        let plain = render(&metadata).unwrap();
        assert_eq!(plain[4], 1.);
        metadata.trim_element = Some(TrimElement {
            warp_mode: 1,
            ..Default::default()
        });
        assert_eq!(render(&metadata).unwrap(), plain);
    }

    #[test]
    fn extended_precision_positions_remain_supported() {
        let mut metadata = point();
        block(&mut metadata).object_render_info.pos3d = [0.5, 0., 0.];
        let initial = render(&metadata).unwrap();
        assert_eq!(initial[2], 1.);
        metadata.extended_object_element = Some(ExtendedObjectElement {
            b_ext_prec_pos_block: true,
            ext_prec_pos_block: vec![vec![ExtendedPrecisionPositionBlock {
                ext_prec_pos3d_x: 0.01,
                ..Default::default()
            }]],
            ..Default::default()
        });
        let moved = render(&metadata).unwrap();
        assert!(moved[1] > initial[1]);
        assert!(moved[2] < initial[2]);
    }
}

#[cfg(test)]
mod dts_tests {
    use super::*;
    use dca::{BedFold, SourceMetadata, SourceRole, SphericalPosition, XMetadata, XPresentation};

    fn position(azimuth: i16, elevation: i16) -> SphericalPosition {
        SphericalPosition {
            azimuth_half_degrees: azimuth * 2,
            elevation_half_degrees: elevation * 2,
            distance_64ths: 64,
        }
    }

    fn metadata(presentation: XPresentation, position: SphericalPosition) -> XMetadata {
        let mut sources = Vec::new();
        for _ in presentation.object_feeds() {
            sources.push(SourceMetadata {
                role: SourceRole::Object {
                    position,
                    centre_height_alternative: true,
                },
                fold: BedFold::Known([0.25, 0., 0., 0., 0., 0., 0., 0.]),
            });
        }
        for &channel in presentation.fixed_channels() {
            sources.push(SourceMetadata {
                role: SourceRole::Height(channel),
                fold: BedFold::Known([0.25, 0., 0., 0., 0., 0., 0., 0.]),
            });
        }
        let mask = if presentation == XPresentation::ObjectOnly {
            dca::REFERENCE_MASK_5_1
        } else {
            dca::REFERENCE_MASK_7_1
        };
        XMetadata::from_sources_on(&sources, mask).unwrap()
    }

    fn frame(
        presentation: XPresentation,
        metadata: &XMetadata,
        amplitudes: &[f32],
        frames: usize,
    ) -> dca::HdFrame {
        let mut frame = dca::HdFrame {
            sample_rate: 48_000,
            lossless: true,
            x_present: presentation == XPresentation::Height,
            x_imax: presentation != XPresentation::Height,
            samples: vec![None; 16],
            x_samples: amplitudes.iter().map(|&a| vec![a; frames]).collect(),
            ..Default::default()
        };
        for &speaker in metadata.reference_speakers() {
            frame.samples[speaker as usize] = Some(vec![0.; frames]);
        }
        for (feed, source) in metadata.sources().enumerate() {
            if let BedFold::Known(fold) = source.fold {
                for (&speaker, gain) in metadata.reference_speakers().iter().zip(fold) {
                    for sample in frame.samples[speaker as usize].as_mut().unwrap() {
                        *sample += amplitudes[feed] * gain;
                    }
                }
            }
        }
        frame
    }

    // dca's Apache-2.0 IMAX metadata test vector, pinned at a717bae.
    // See THIRD-PARTY-NOTICES.md for provenance and retained license.
    const IMAX_COMPONENT_PAYLOAD: [u8; 124] = [
        0xf1, 0x40, 0x00, 0xd0, 0x30, 0x28, 0x4b, 0x04, 0xb0, 0x20, 0x00, 0x01, 0x28, 0x06, 0x83,
        0x3d, 0xfd, 0xe1, 0xe3, 0x3d, 0xfd, 0x91, 0xe3, 0x3d, 0xfe, 0x31, 0xe0, 0x03, 0x00, 0x08,
        0x81, 0xf4, 0xe2, 0x1a, 0xc4, 0x04, 0x7f, 0x40, 0x25, 0xbf, 0xa0, 0x49, 0xbf, 0xa8, 0x81,
        0xbf, 0xb1, 0x01, 0xbf, 0xa0, 0x28, 0x3f, 0x03, 0x34, 0x38, 0x8c, 0x4f, 0x00, 0xb2, 0x7c,
        0x06, 0x08, 0x04, 0x12, 0x67, 0x02, 0x4b, 0xde, 0xf8, 0x05, 0x20, 0x00, 0x00, 0x0b, 0xb4,
        0x08, 0x00, 0x94, 0xa6, 0x80, 0x00, 0x40, 0x00, 0x00, 0x00, 0x02, 0x34, 0x38, 0x8c, 0x4f,
        0x00, 0xc2, 0xc6, 0x03, 0x04, 0x38, 0x00, 0xf1, 0xa3, 0x03, 0xcf, 0xef, 0x7c, 0x02, 0x9c,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xcf, 0xc4, 0x08, 0x00, 0x94, 0xa6, 0x80,
        0x00, 0x40, 0x00, 0x00,
    ];

    #[test]
    fn damaged_spatial_metadata_is_rejected_even_with_an_intact_compatible_bed() {
        let presentation = XPresentation::ObjectsD0;
        let metadata = XMetadata::parse(&IMAX_COMPONENT_PAYLOAD, 7).unwrap();
        let mut frame = frame(presentation, &metadata, &[0.1, 0.2, 0.3, 0., 0., 0., 0.], 8);
        frame.x_payload = IMAX_COMPONENT_PAYLOAD.to_vec();
        let original_bed = frame.samples.clone();
        let original_feeds = frame.x_samples.clone();
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let mut decoder = Dts::new(layout);
            assert_eq!(decoder.render(&frame).unwrap().frames, 8);
            // Remove metadata bytes only; decoded bed/feed samples and presentation stay intact.
            frame.x_payload.truncate(4);
            assert_eq!(XPresentation::detect(&frame), Some(presentation));
            let error = decoder
                .render(&frame)
                .err()
                .expect("damaged metadata must fail");
            assert!(
                error.message().starts_with("DTS:X spatial metadata:"),
                "{error}"
            );
            assert_eq!(frame.samples, original_bed);
            assert_eq!(frame.x_samples, original_feeds);
            frame.x_payload = IMAX_COMPONENT_PAYLOAD.to_vec();
        }
    }

    #[test]
    fn imax_marker_and_parsed_components_route_to_centre_left_right() {
        let presentation = XPresentation::ObjectsD0;
        let metadata = XMetadata::parse(&IMAX_COMPONENT_PAYLOAD, 7).unwrap();
        for (feed, azimuth) in [0., -30., 30.].into_iter().enumerate() {
            let SourceRole::Object { position, .. } = metadata.source(feed).unwrap().role else {
                panic!("IMAX component must be an object");
            };
            assert_eq!(position.azimuth_degrees(), azimuth);
            assert_eq!(position.elevation_degrees(), 0.);
            assert_eq!(position.distance(), 1.);
        }
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            let mut frame = frame(presentation, &metadata, &[0.1, 0.2, 0.3, 0., 0., 0., 0.], 8);
            frame.x_payload = IMAX_COMPONENT_PAYLOAD.to_vec();
            assert!(!frame.x_present && frame.x_imax);
            let pcm = Dts::new(layout).render(&frame).unwrap();
            for sample in pcm.data.chunks_exact(layout.count()) {
                for (i, value) in sample.iter().enumerate() {
                    let expected = match i {
                        0 => 0.2,
                        1 => 0.3,
                        2 => 0.1,
                        _ => 0.,
                    };
                    assert!((value - expected).abs() < 1e-6, "{layout:?}: {sample:?}");
                }
            }
        }
    }

    #[test]
    fn metadata_defined_rendered_folds_are_resolved_before_recombination() {
        let presentation = XPresentation::ObjectD0;
        let mut source = *metadata(presentation, position(30, 0)).source(0).unwrap();
        source.fold = BedFold::Unknown;
        let mut sources: Vec<_> = metadata(presentation, position(30, 0))
            .sources()
            .copied()
            .collect();
        sources[0] = source;
        let mut metadata = XMetadata::from_sources(&sources).unwrap();
        metadata.mark_rendered(0, true);
        let mut plan = dca::FoldPlan::from_metadata(&metadata);
        dca::FoldRenderer::new().apply(&mut plan, &metadata, 8);
        assert!(!plan.has_unknown());
        let mut frame = frame(presentation, &metadata, &[1., 0., 0., 0., 0.], 8);
        for &speaker in metadata.reference_speakers() {
            frame.samples[speaker as usize] = Some(vec![plan.gain(speaker as usize, 0); 8]);
        }
        let pcm = Dts::new(Layout::SevenOneFour)
            .render_spatial(&frame, presentation, metadata)
            .unwrap();
        for sample in pcm.data.as_chunks::<12>().0 {
            for (i, value) in sample.iter().enumerate() {
                let expected = if i == 1 { 1. } else { 0. };
                assert!((value - expected).abs() < 1e-6, "{sample:?}");
            }
        }
    }

    #[test]
    fn all_presentations_remove_folds_and_route_objects_separately_from_heights() {
        use XPresentation::*;
        for layout in [Layout::SevenOneFour, Layout::NineOneSix] {
            for presentation in [
                Height, ObjectD0, ObjectsD1, ObjectsD0, ObjectsD3, ObjectsD4, ObjectOnly,
            ] {
                let metadata = metadata(presentation, position(0, 0));
                let amplitudes: Vec<_> = (1..=presentation.feed_count())
                    .map(|i| i as f32 / 100.)
                    .collect();
                let frame = frame(presentation, &metadata, &amplitudes, 8);
                let pcm = Dts::new(layout)
                    .render_spatial(&frame, presentation, metadata)
                    .unwrap();
                let mut expected = vec![0.; layout.count()];
                expected[2] = amplitudes[presentation.object_feeds()].iter().sum();
                let height_start = if layout == Layout::SevenOneFour {
                    8
                } else {
                    10
                };
                let height_indices = [
                    height_start,
                    height_start + 1,
                    layout.count() - 2,
                    layout.count() - 1,
                ];
                for (feed, index) in presentation.fixed_feeds().zip(height_indices) {
                    expected[index] = amplitudes[feed];
                }
                for sample in pcm.data.chunks_exact(layout.count()) {
                    assert!(
                        sample
                            .iter()
                            .zip(&expected)
                            .all(|(a, b)| (a - b).abs() < 1e-6),
                        "{layout:?} {presentation:?}: {sample:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn moving_objects_ramp_over_the_frame_without_resetting_their_previous_position() {
        let presentation = XPresentation::ObjectOnly;
        let mut decoder = Dts::new(Layout::SevenOneFour);
        let initial = metadata(presentation, position(0, 0));
        decoder
            .render_spatial(
                &frame(presentation, &initial, &[1.], 4),
                presentation,
                initial,
            )
            .unwrap();
        let moved = metadata(presentation, position(30, 0));
        let pcm = decoder
            .render_spatial(&frame(presentation, &moved, &[1.], 4), presentation, moved)
            .unwrap();
        for (i, sample) in pcm.data.as_chunks::<12>().0.iter().enumerate() {
            let right = (i + 1) as f32 / 4.;
            assert!((sample[1] - right).abs() < 1e-6);
            assert!((sample[2] - (1. - right)).abs() < 1e-6);
            assert!(sample[8..].iter().all(|g| *g == 0.));
        }
    }

    #[test]
    fn centre_height_alternative_does_not_override_the_declared_object_position() {
        let presentation = XPresentation::ObjectOnly;
        let metadata = metadata(presentation, position(0, 25));
        let pcm = Dts::new(Layout::SevenOneFour)
            .render_spatial(
                &frame(presentation, &metadata, &[1.], 4),
                presentation,
                metadata,
            )
            .unwrap();
        let sample = &pcm.data[..12];
        assert!(sample[2] > 0. && sample[8] > 0. && sample[9] > 0.);
        assert_eq!(sample[10], 0.);
    }

    #[test]
    fn unknown_folds_and_mismatched_roles_are_rejected() {
        let presentation = XPresentation::ObjectOnly;
        for (role, fold, expected) in [
            (
                SourceRole::Object {
                    position: position(0, 0),
                    centre_height_alternative: false,
                },
                BedFold::Unknown,
                "unknown bed fold",
            ),
            (
                SourceRole::Height(dca::SpatialChannel::TopFrontLeft),
                BedFold::Known([0.; 8]),
                "source role",
            ),
        ] {
            let metadata = XMetadata::from_sources(&[SourceMetadata { role, fold }]).unwrap();
            let error = Dts::new(Layout::SevenOneFour)
                .render_spatial(
                    &frame(presentation, &metadata, &[1.], 4),
                    presentation,
                    metadata,
                )
                .err()
                .unwrap();
            assert!(error.message().contains(expected), "{error}");
            assert!(matches!(error, Error::Unsupported(_)), "{error}");
        }
    }

    #[test]
    fn presentation_changes_require_a_new_session() {
        let mut decoder = Dts::new(Layout::SevenOneFour);
        let initial = metadata(XPresentation::ObjectOnly, position(0, 0));
        decoder
            .render_spatial(
                &frame(XPresentation::ObjectOnly, &initial, &[1.], 4),
                XPresentation::ObjectOnly,
                initial,
            )
            .unwrap();
        let next = metadata(XPresentation::ObjectD0, position(0, 0));
        let error = decoder
            .render_spatial(
                &frame(XPresentation::ObjectD0, &next, &[1.; 5], 4),
                XPresentation::ObjectD0,
                next,
            )
            .err()
            .unwrap();
        assert_eq!(
            error,
            Error::Malformed("DTS:X presentation changed mid-stream".into())
        );
    }
}
