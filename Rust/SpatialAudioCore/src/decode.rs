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

pub struct TrueHd {
    extractor: Extractor,
    parser: Parser,
    decoder: Decoder,
    decoded: DecodedAccessUnit,
    renderer: Renderer,
    bytes: u64,
    consumed: u64,
    spatial: bool,
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
            if let Some(sync) = &au.major_sync_info && sync.substreams < 4 {
                return Err("This TrueHD stream has no Atmos presentation".into());
            }
            self.decoder
                .decode_presentation_into(&au, 3, &mut self.decoded)
                .map_err(|e| format!("TrueHD decoding: {e}"))?;
            if self.decoded.is_duplicate {
                continue;
            }
            for metadata in &self.decoded.oamd {
                schedule_oamd(&mut self.renderer, metadata, self.decoded.channel_count)?;
                self.spatial = true;
            }
            if !self.spatial {
                return Err(
                    "Atmos presentation has no usable object metadata at its starting sync".into(),
                );
            }
            let frames = self.decoded.sample_length;
            let input: Vec<_> = (0..self.decoded.channel_count)
                .map(|ch| {
                    (0..frames)
                        .map(|s| self.decoded.pcm_data[s][ch] as f32 / 8_388_608.)
                        .collect()
                })
                .collect();
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

fn schedule_oamd(
    renderer: &mut Renderer,
    metadata: &ObjectAudioMetadataPayload,
    channels: usize,
) -> Result<(), String> {
    let program = &metadata.program_assignment;
    if program.num_isf_objects != 0 || program.bed_assignment.len() > 1 {
        return Err("Atmos ISF and multiple bed instances are not yet supported".into());
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
            let mut gains = if block.b_object_in_bed_or_isf {
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
                if block.object_render_info.object_size.iter().any(|s| *s > 0.) {
                    return Err("Atmos objects with nonzero size are not yet supported".into());
                }
                renderer.panner.object(pos.map(|v| v as f32))
            };
            let gain = if block.b_object_not_active || block.object_basic_info.object_gain == -128 {
                0.
            } else {
                10f32.powf(block.object_basic_info.object_gain as f32 / 20.)
            };
            for g in &mut gains {
                *g *= gain;
            }
            renderer.event(Event {
                sample,
                channel,
                gains,
                ramp: timing.ramp_duration as u32,
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
