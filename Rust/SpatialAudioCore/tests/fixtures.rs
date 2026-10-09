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
