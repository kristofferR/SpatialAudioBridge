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
