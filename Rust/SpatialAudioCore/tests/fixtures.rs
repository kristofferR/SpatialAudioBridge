use spatial_audio_core::{decode::Core, render::Layout};
use std::{env, fs};

fn digest(codec: u32, data: &[u8], chunk: usize) -> (u64, u64, [f64; 16]) {
    let mut decoder = Core::new(codec, Layout::NineOneSix).unwrap();
    let mut frames = 0;
    let mut hash = 0xcbf29ce484222325u64;
    let mut energy = [0.; 16];
    let mut collect = |pcm: spatial_audio_core::decode::Pcm| {
        assert_eq!(pcm.rate, 48000);
        assert_eq!(pcm.channels, 16);
        frames += pcm.frames as u64;
        for (i, value) in pcm.data.iter().enumerate() {
            assert!(value.is_finite());
            energy[i % 16] += (*value as f64).powi(2);
            for byte in value.to_le_bytes() {
                hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
            }
        }
        Ok(())
    };
    for bytes in data.chunks(chunk) {
        decoder.push(bytes, false, &mut collect).unwrap();
    }
    decoder.push(&[], true, &mut collect).unwrap();
    (frames, hash, energy)
}

fn validate(codec: u32, variable: &str) {
    let data = fs::read(env::var(variable).expect("set the fixture path")).unwrap();
    let a = digest(codec, &data, 4096);
    let b = digest(codec, &data, 317);
    assert_eq!(a, b, "input chunk boundaries must not alter PCM or timing");
    assert!(a.0 > 48000);
    assert!(
        a.2[10..].iter().any(|e| *e > 0.),
        "height audio must survive"
    );
    let mut decoder = Core::new(codec, Layout::NineOneSix).unwrap();
    for bytes in data[..data.len() - 1].chunks(4096) {
        decoder.push(bytes, false, &mut |_| Ok(())).unwrap();
    }
    assert!(
        decoder.push(&[], true, &mut |_| Ok(())).is_err(),
        "a partial final access unit must fail"
    );
}

#[test]
#[ignore = "requires SAB_TRUEHD_FIXTURE elementary stream"]
fn truehd_chunk_boundaries_preserve_spatial_audio_and_timing() {
    validate(1, "SAB_TRUEHD_FIXTURE");
}

#[test]
#[ignore = "requires SAB_DTSX_FIXTURE elementary stream"]
fn dtsx_chunk_boundaries_preserve_spatial_audio_and_timing() {
    validate(2, "SAB_DTSX_FIXTURE");
}

/// Byte offset, and samples decoded before it, of the first major sync after `after` samples
/// whose access unit carries no object metadata: what a seek or a server-side remux delivers.
fn later_sync_without_metadata(data: &[u8], after: u64) -> (usize, u64, u64) {
    use truehd::process::{
        decode::{DecodedAccessUnit, Decoder},
        extract::Extractor,
        parse::Parser,
    };
    let mut extractor = Extractor::default();
    let (mut parser, mut decoder, mut decoded) = (
        Parser::default(),
        Decoder::default(),
        DecodedAccessUnit::default(),
    );
    extractor.push_bytes(data);
    let (mut samples, mut found) = (0, None);
    while let Some(Ok(frame)) = extractor.next() {
        let au = parser.parse(&frame).unwrap();
        decoder
            .decode_presentation_into(&au, 3, &mut decoded)
            .unwrap();
        if decoded.is_duplicate {
            continue;
        }
        if found.is_none()
            && samples >= after
            && au.major_sync_info.is_some()
            && decoded.oamd.is_empty()
        {
            found = Some((frame.offset as usize, samples));
        }
        samples += decoded.sample_length as u64;
    }
    let (offset, before) = found.expect("a later major sync without object metadata");
    (offset, before, samples)
}

#[test]
#[ignore = "requires SAB_TRUEHD_FIXTURE elementary stream"]
fn truehd_starts_at_a_later_major_sync_without_losing_samples() {
    let data = fs::read(env::var("SAB_TRUEHD_FIXTURE").expect("set the fixture path")).unwrap();
    let (offset, before, total) = later_sync_without_metadata(&data, 10 * 48_000);
    let a = digest(1, &data[offset..], 4096);
    let b = digest(1, &data[offset..], 317);
    assert_eq!(a, b, "input chunk boundaries must not alter PCM or timing");
    assert_eq!(
        a.0,
        total - before,
        "audio before the first object metadata must be kept"
    );
    assert!(
        a.2[10..].iter().any(|e| *e > 0.),
        "height audio must survive"
    );
}

/// Offset and length of every access unit, and whether it starts at a major sync.
fn access_units(data: &[u8]) -> Vec<(usize, usize, bool)> {
    use truehd::process::{extract::Extractor, parse::Parser};
    let (mut extractor, mut parser) = (Extractor::default(), Parser::default());
    extractor.push_bytes(data);
    let mut units = Vec::new();
    while let Some(Ok(frame)) = extractor.next() {
        let au = parser.parse(&frame).unwrap();
        units.push((
            frame.offset as usize,
            frame.as_ref().len(),
            au.major_sync_info.is_some(),
        ));
    }
    units
}

#[test]
#[ignore = "requires SAB_TRUEHD_FIXTURE elementary stream"]
fn truehd_conceals_damage_until_the_next_major_sync() {
    let data = fs::read(env::var("SAB_TRUEHD_FIXTURE").expect("set the fixture path")).unwrap();
    let units = access_units(&data);
    let damage = |damaged: &[usize]| {
        let mut data = data.clone();
        for &unit in damaged {
            let (offset, length, _) = units[unit];
            data[offset + length / 2] ^= 0xFF;
        }
        data
    };
    let sync = (1050..units.len())
        .find(|&unit| units[unit].2)
        .expect("a later major sync");
    let intact = digest(1, &data, 4096);
    let concealed = damage(&[sync - 50]);
    let a = digest(1, &concealed, 4096);
    assert_eq!(a, digest(1, &concealed, 317));
    assert_ne!(a.1, intact.1, "the damage must be concealed");
    assert_eq!(a.0, intact.0, "concealed access units keep their samples");
    let mut decoder = Core::new(1, Layout::SevenOneFour).unwrap();
    assert!(
        decoder
            .push(&damage(&[sync - 50, sync]), true, &mut |_| Ok(()))
            .is_err(),
        "damage at the major sync that would end concealment must fail"
    );
}

#[test]
#[ignore = "requires SAB_DTSX_ALTERNATE_FIXTURE elementary stream"]
fn alternate_dtsx_profiles_preserve_spatial_audio_and_timing() {
    let variable = "SAB_DTSX_ALTERNATE_FIXTURE";
    let data = fs::read(env::var(variable).expect("set the fixture path")).unwrap();
    let mut decoder = dca::HdDecoder::new();
    let mut offset = 0;
    let mut presentations = std::collections::BTreeMap::new();
    let mut positions = std::collections::BTreeSet::new();
    while offset < data.len() {
        let core_len = dca::parse_header(&data[offset..]).unwrap().frame_size;
        let exss = &data[offset + core_len..];
        let exss_len = dca::exss_substream_size(exss).unwrap();
        match decoder.decode(&data[offset..offset + core_len], &exss[..exss_len]) {
            Ok(frame) => {
                let presentation = dca::XPresentation::detect(&frame).unwrap();
                assert!(
                    presentation.is_experimental(),
                    "expected an alternate profile"
                );
                *presentations
                    .entry(format!("{presentation:?}"))
                    .or_insert(0) += 1;
                let metadata =
                    dca::XMetadata::parse(&frame.x_payload, presentation.feed_count()).unwrap();
                for source in metadata.sources() {
                    if let dca::SourceRole::Object { position, .. } = source.role {
                        positions.insert((
                            position.azimuth_half_degrees,
                            position.elevation_half_degrees,
                            position.distance_64ths,
                        ));
                    }
                }
            }
            Err(dca::HdError::Pending) => (),
            Err(error) => panic!("DTS-HD decoding: {error:?}"),
        }
        offset += core_len + exss_len;
    }
    assert!(!presentations.is_empty());
    assert!(!positions.is_empty());
    println!(
        "alternate presentations={presentations:?}, distinct object positions={}",
        positions.len()
    );
    validate(2, variable);
}

/// The output of a fresh decoder over a DTS-HD stream of `frames` frames, split into them.
fn dts_frames(data: &[u8], frames: usize) -> Vec<Vec<f32>> {
    let mut decoder = Core::new(2, Layout::SevenOneFour).unwrap();
    let mut samples = vec![];
    decoder
        .push(data, true, &mut |pcm| {
            samples.extend(pcm.data);
            Ok(())
        })
        .unwrap();
    assert_eq!(samples.len() % frames, 0, "every frame plays in full");
    samples
        .chunks(samples.len() / frames)
        .map(<[f32]>::to_vec)
        .collect()
}

#[test]
#[ignore = "requires SAB_DTSX_FIXTURE elementary stream"]
fn dtsx_entered_mid_stream_starts_silent_instead_of_distorted() {
    enter_mid_stream("SAB_DTSX_FIXTURE");
}

#[test]
#[ignore = "requires SAB_DTSX_ALTERNATE_FIXTURE elementary stream"]
fn alternate_dtsx_entered_mid_stream_starts_silent_instead_of_distorted() {
    enter_mid_stream("SAB_DTSX_ALTERNATE_FIXTURE");
}

/// Starts a fresh decoder halfway through the stream, as a seek does, and compares it with a
/// continuous decode.
fn enter_mid_stream(variable: &str) {
    let data = fs::read(env::var(variable).expect("set the fixture path")).unwrap();
    let mut offsets = vec![];
    let mut offset = 0;
    while offset < data.len() {
        offsets.push(offset);
        let core_len = dca::parse_header(&data[offset..]).unwrap().frame_size;
        offset += core_len + dca::exss_substream_size(&data[offset + core_len..]).unwrap();
    }
    let whole = dts_frames(&data, offsets.len());
    let entry = offsets.len() / 2;
    let entered = dts_frames(&data[offsets[entry]..], offsets.len() - entry);
    assert_eq!(
        entered[0].len(),
        whole[0].len(),
        "every frame keeps its duration"
    );
    // A frame the lossless layer is still buffering, then two warm-up frames, play as silence.
    let silent = entered
        .iter()
        .take_while(|frame| frame.iter().all(|value| *value == 0.))
        .count();
    assert!((2..=4).contains(&silent), "{silent} silent frames");
    let error = |frame: usize| {
        entered[frame]
            .iter()
            .zip(&whole[entry + frame])
            .map(|(a, b)| (a - b).abs())
            .fold(0f32, f32::max)
    };
    let first = error(silent);
    assert!(
        first < 0.03,
        "the first audible frame is within −30 dBFS: {first}"
    );
    let later = error(silent + 10);
    assert!(later < 1e-4, "the decode has converged: {later}");
}
