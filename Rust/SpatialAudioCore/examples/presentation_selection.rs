//! Compare parser presentation masks on a complete pinned public vector. Reports only parser
//! wall time, not end-to-end rendering speed; extraction/decoding/equality checks are untimed.
//! Usage: cargo run --release --locked --example presentation_selection -- <public-vector.mlp>
use std::{
    collections::BTreeSet,
    fs,
    time::{Duration, Instant},
};
use truehd::process::{
    PresentationMap,
    decode::{DecodedAccessUnit, Decoder},
    extract::Extractor,
    parse::Parser,
};
fn run(bytes: &[u8], narrow: bool) -> (Vec<String>, BTreeSet<(u8, u8)>, Duration) {
    let mut extractor = Extractor::default();
    extractor.push_bytes(bytes);
    let mut parser = Parser::default();
    if narrow {
        parser.set_required_presentations(&[false, false, false, true]);
    }
    let mut decoder = Decoder::default();
    let mut decoded = DecodedAccessUnit::default();
    let mut observations = Vec::new();
    let mut masks = BTreeSet::new();
    let mut parsing = Duration::ZERO;
    for frame in extractor {
        let frame = match frame {
            Ok(frame) => frame,
            Err(truehd::utils::errors::ExtractError::InsufficientData) => break,
            Err(error) => panic!("public fixture extraction: {error}"),
        };
        let before = Instant::now();
        let parsed = parser.parse(&frame);
        parsing += before.elapsed();
        drop(parser.take_branches());
        let au = parsed.expect("public fixture parsing");
        if let Some(sync) = &au.major_sync_info {
            let map = PresentationMap::with_substream_info(
                sync.substream_info,
                sync.extended_substream_info,
            );
            masks.insert((
                map.substream_mask_by_required_presentations(&[true; 4]),
                map.substream_mask_by_required_presentations(&[false, false, false, true]),
            ));
        }
        decoder
            .decode_presentation_into(&au, 3, &mut decoded)
            .expect("presentation 3 decode");
        let pcm: Vec<_> = decoded.pcm_data[..decoded.sample_length]
            .iter()
            .map(|row| &row[..decoded.channel_count])
            .collect();
        observations.push(format!(
            "{}:{}:{:?}:{}:{}:{}:{:?}:{:?}:{:?}:{:?}:{:?}",
            frame.index,
            au.input_timing,
            parser.hires_output_timing(),
            decoded.sampling_frequency,
            decoded.sample_length,
            decoded.is_duplicate,
            decoded.channel_labels,
            decoded.oamd,
            pcm,
            au.major_sync_info,
            au.extra_data
        ));
    }
    (observations, masks, parsing)
}
fn main() {
    let bytes = fs::read(std::env::args().nth(1).expect("public fixture path")).unwrap();
    let (all, masks, _) = run(&bytes, false);
    let (narrow, _, _) = run(&bytes, true);
    assert!(all == narrow, "PCM/metadata/timing changed");
    let mut times = [Vec::new(), Vec::new()];
    for pass in 0..101 {
        for mode in [pass % 2, 1 - pass % 2] {
            let (_, _, elapsed) = run(&bytes, mode == 1);
            if pass > 0 {
                times[mode].push(elapsed.as_nanos());
            }
        }
    }
    for mode in &mut times {
        mode.sort();
    }
    println!(
        "public_fixture_bytes={} access_units={} masks_all_narrow={masks:?} pcm_metadata_timing_equal=true median_parse_ns_all={} narrow={} passes=100",
        bytes.len(),
        all.len(),
        times[0][50],
        times[1][50]
    );
}
