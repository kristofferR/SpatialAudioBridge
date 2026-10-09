use crate::render::{Event, Layout, Renderer, Speaker};
use truehd::{
    process::{
        decode::{DecodedAccessUnit, Decoder},
        extract::Extractor,
        parse::Parser,
    },
    structs::oamd::ObjectAudioMetadataPayload,
    utils::errors::ExtractError,
};

pub struct Pcm {
    pub data: Vec<f32>,
    pub frames: usize,
    pub rate: u32,
    pub channels: usize,
}
pub enum Core {
    TrueHd(Box<TrueHd>),
    Dts(Box<Dts>),
}
impl Core {
    pub fn new(codec: u32, layout: Layout) -> Result<Self, String> {
        match codec {
            1 => Ok(Self::TrueHd(Box::new(TrueHd::new(layout)))),
            2 => Ok(Self::Dts(Box::new(Dts::new(layout)))),
            _ => Err("Unknown input codec".into()),
        }
    }
    pub fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), String> {
        match self {
            Self::TrueHd(d) => d.push(data, end, output),
            Self::Dts(d) => d.push(data, end, output),
        }
    }
}

/// Audio decoded before the first object metadata, at most half a second at 48 kHz.
/// Atmos streams repeat their metadata every few tens of milliseconds.
const MAX_HELD_FRAMES: usize = 24_000;

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
}
impl TrueHd {
    fn new(layout: Layout) -> Self {
        Self {
            extractor: Extractor::default(),
            parser: Parser::default(),
            decoder: Decoder::default(),
            decoded: DecodedAccessUnit::default(),
            renderer: Renderer::new(layout),
            bytes: 0,
            consumed: 0,
            spatial: false,
            held: Vec::new(),
            held_frames: 0,
        }
    }
    fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), String> {
        self.bytes += data.len() as u64;
        self.extractor.push_bytes(data);
        while let Some(frame) = self.extractor.next() {
            let frame = match frame {
                Ok(f) => f,
                Err(ExtractError::InsufficientData) => break,
                Err(e) => return Err(format!("TrueHD framing: {e}")),
            };
            if frame.offset != self.consumed {
                return Err(
                    "TrueHD stream skipped bytes; start at a major sync and supply only this track"
                        .into(),
                );
            }
            self.consumed = frame.offset + frame.as_ref().len() as u64;
            let au = self
                .parser
                .parse(&frame)
                .map_err(|e| format!("TrueHD parsing: {e}"))?;
            if let Some(sync) = &au.major_sync_info
                && sync.substreams < 4
            {
                return Err("This TrueHD stream has no Atmos presentation".into());
            }
            self.decoder
                .decode_presentation_into(&au, 3, &mut self.decoded)
                .map_err(|e| format!("TrueHD decoding: {e}"))?;
            if self.decoded.is_duplicate {
                continue;
            }
            if self.decoded.sampling_frequency != 48_000 {
                return Err("The initial Atmos renderer supports 48 kHz tracks".into());
            }
            let frames = self.decoded.sample_length;
            let input: Vec<Vec<f32>> = (0..self.decoded.channel_count)
                .map(|ch| {
                    (0..frames)
                        .map(|s| self.decoded.pcm_data[s][ch] as f32 / 8_388_608.)
                        .collect()
                })
                .collect();
            if !self.spatial {
                let Some(first) = self.decoded.oamd.first() else {
                    // A stream entered at a later major sync carries its first object metadata
                    // a few access units in. Hold the audio until then so no samples are lost.
                    self.held_frames += frames;
                    if self.held_frames > MAX_HELD_FRAMES {
                        return Err("Atmos presentation has no object metadata within 0.5 s".into());
                    }
                    self.held.push(input);
                    continue;
                };
                // Held audio takes the first known object state.
                set_initial_state(&mut self.renderer, first, self.decoded.channel_count)?;
                self.spatial = true;
                for held in std::mem::take(&mut self.held) {
                    let frames = held.first().map_or(0, Vec::len);
                    output(Pcm {
                        data: self.renderer.render(&held, frames),
                        frames,
                        rate: self.decoded.sampling_frequency,
                        channels: self.renderer.panner.count(),
                    })?;
                }
                self.held_frames = 0;
            }
            for metadata in &self.decoded.oamd {
                schedule_oamd(&mut self.renderer, metadata, self.decoded.channel_count)?;
            }
            output(Pcm {
                data: self.renderer.render(&input, frames),
                frames,
                rate: self.decoded.sampling_frequency,
                channels: self.renderer.panner.count(),
            })?;
        }
        if self.extractor.error_count() != 0 {
            return Err("TrueHD extractor lost synchronization".into());
        }
        if self.bytes - self.consumed > 64 * 1024 {
            return Err("TrueHD sync not found within 64 KiB".into());
        }
        if end && (self.consumed != self.bytes || !self.spatial) {
            return Err("Empty or truncated TrueHD stream".into());
        }
        Ok(())
    }
}

/// Routes each channel at its first metadata block, for audio decoded before that metadata.
fn set_initial_state(
    renderer: &mut Renderer,
    metadata: &ObjectAudioMetadataPayload,
    channels: usize,
) -> Result<(), String> {
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
) -> Result<(), String> {
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
) -> Result<(), String> {
    let program = &metadata.program_assignment;
    if program.num_isf_objects != 0 || program.bed_assignment.len() > 1 {
        return Err("Atmos ISF and multiple bed instances are not yet supported".into());
    }
    if program.b_bed_chan_distribute {
        return Err("Atmos bed channel distribution is not yet supported".into());
    }
    if metadata.trim_element.is_some() {
        return Err("Atmos trim metadata is not yet supported".into());
    }
    if metadata.bed_object_element.is_some() {
        return Err("Atmos bed downmix metadata is not yet supported".into());
    }
    if metadata
        .extended_object_element
        .as_ref()
        .is_some_and(|extended| {
            extended
                .object_div_block
                .iter()
                .flatten()
                .any(|block| block.b_object_divergence)
        })
    {
        return Err("Atmos object divergence is not yet supported".into());
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
                    .speaker(*bed_speakers.get(index).ok_or("Unknown Atmos bed speaker")?)
            } else {
                let pos = positions
                    .get(channel)
                    .and_then(|v| v.get(block_index))
                    .ok_or("Missing Atmos object position")?;
                if pos.iter().any(|x| !x.is_finite()) {
                    return Err("Invalid Atmos object position".into());
                }
                let info = &block.object_render_info;
                if info.object_size.iter().any(|s| *s != 0.) {
                    return Err("Atmos objects with nonzero size are not yet supported".into());
                }
                if info.b_object_snap {
                    return Err("Atmos object snap is not yet supported".into());
                }
                if info.zone_constraints_idx != 0 {
                    return Err("Atmos object zone constraints are not yet supported".into());
                }
                if info.b_object_use_screen_ref {
                    return Err("Atmos screen-referenced objects are not yet supported".into());
                }
                if info.b_object_distance_specified {
                    return Err("Atmos object distance rendering is not yet supported".into());
                }
                let mut position = pos.map(|v| v as f32);
                if !info.b_enable_elevation {
                    position[2] = 0.;
                }
                renderer.panner.object(position)
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

pub struct Dts {
    buffer: Vec<u8>,
    decoder: dca::HdDecoder,
    renderer: Renderer,
    fold_renderer: dca::FoldRenderer,
    seen: bool,
}
impl Dts {
    fn new(layout: Layout) -> Self {
        Self {
            buffer: vec![],
            decoder: dca::HdDecoder::new(),
            renderer: Renderer::new(layout),
            fold_renderer: dca::FoldRenderer::new(),
            seen: false,
        }
    }
    fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(Pcm) -> Result<(), String>,
    ) -> Result<(), String> {
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
                return Err(
                    "DTS:X requires the complete DTS-HD extension after each core frame".into(),
                );
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
            let frame = match self.decoder.decode(
                &self.buffer[..core_len],
                &self.buffer[core_len..core_len + exss_len],
            ) {
                Ok(f) => Some(f),
                Err(dca::HdError::Pending) => None,
                Err(e) => return Err(format!("DTS-HD decoding: {e:?}")),
            };
            self.buffer.drain(..core_len + exss_len);
            if let Some(frame) = frame {
                let pcm = self.render(frame)?;
                output(pcm)?;
                self.seen = true;
            }
        }
        if self.buffer.len() > 2 * 1024 * 1024 {
            return Err("DTS-HD access unit exceeds 2 MiB".into());
        }
        if end && (!self.buffer.is_empty() || !self.seen) {
            return Err("Empty or truncated DTS-HD stream".into());
        }
        Ok(())
    }
    fn render(&mut self, frame: dca::HdFrame) -> Result<Pcm, String> {
        if !frame.lossless || !frame.x_present {
            return Err("This stream is not lossless DTS:X".into());
        }
        if let Some(e) = frame.x_decode_error {
            return Err(format!("DTS:X extension decoding: {e}"));
        }
        let presentation =
            dca::XPresentation::detect(&frame).ok_or("Unknown DTS:X presentation")?;
        if presentation.is_experimental() {
            return Err(format!(
                "DTS:X {} is experimental upstream and is not enabled",
                presentation.layout_label()
            ));
        }
        let metadata = dca::XMetadata::parse(&frame.x_payload, presentation.feed_count())
            .map_err(|e| format!("DTS:X spatial metadata: {e:?}"))?;
        let frames = frame.bed_sample_count();
        let mut plan = dca::FoldPlan::from_metadata(&metadata);
        self.fold_renderer.apply(&mut plan, &metadata, frames);
        if plan.has_unknown() {
            return Err(
                "DTS:X has an unknown bed fold; refusing to duplicate its height audio".into(),
            );
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
                    _ => return Err(format!("DTS bed speaker {id} is not yet supported")),
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
        let heights = [Tfl, Tfr, Tbl, Tbr];
        for (feed, pcm) in frame.x_samples.iter().enumerate() {
            self.renderer
                .route(input.len(), self.renderer.panner.speaker(heights[feed]));
            input.push(pcm.clone());
        }
        Ok(Pcm {
            data: self.renderer.render(&input, frames),
            frames,
            rate: frame.sample_rate,
            channels: self.renderer.panner.count(),
        })
    }
}

#[cfg(test)]
mod metadata_tests {
    use super::*;
    type Control<T> = (&'static str, fn(&mut T));
    use truehd::structs::oamd::{
        BlockUpdateInfo, ExtendedObjectElement, ExtendedPrecisionPositionBlock, MDUpdateInfo,
        ObjectBasicInfo, ObjectDivergenceBlock, ObjectElement, ObjectInfoBlock, ObjectRenderInfo,
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
    fn render(metadata: &ObjectAudioMetadataPayload) -> Result<Vec<f32>, String> {
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
    fn unsupported_object_controls_fail_explicitly() {
        let cases: [Control<ObjectRenderInfo>; 5] = [
            ("size", |i| i.object_size[0] = 0.1),
            ("snap", |i| i.b_object_snap = true),
            ("zone", |i| i.zone_constraints_idx = 1),
            ("screen", |i| i.b_object_use_screen_ref = true),
            ("distance", |i| {
                i.b_object_distance_specified = true;
                i.distance_factor = Some(2.);
            }),
        ];
        for (name, set) in cases {
            let mut metadata = point();
            set(&mut block(&mut metadata).object_render_info);
            assert!(render(&metadata).unwrap_err().contains(name));
            block(&mut metadata).b_object_not_active = true;
            assert!(render(&metadata).unwrap().iter().all(|g| *g == 0.));
        }
    }

    #[test]
    fn unsupported_program_controls_fail_explicitly() {
        let cases: [Control<ObjectAudioMetadataPayload>; 4] = [
            ("distribution", |m| {
                m.program_assignment.b_bed_chan_distribute = true
            }),
            ("trim", |m| m.trim_element = Some(Default::default())),
            ("downmix", |m| {
                m.bed_object_element = Some(Default::default())
            }),
            ("divergence", |m| {
                m.extended_object_element = Some(ExtendedObjectElement {
                    b_obj_div_block: true,
                    object_div_block: vec![vec![ObjectDivergenceBlock {
                        b_object_divergence: true,
                        object_divergence: 0.5,
                        ..Default::default()
                    }]],
                    ..Default::default()
                })
            }),
        ];
        for (name, set) in cases {
            let mut metadata = point();
            set(&mut metadata);
            assert!(render(&metadata).unwrap_err().contains(name));
        }
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
