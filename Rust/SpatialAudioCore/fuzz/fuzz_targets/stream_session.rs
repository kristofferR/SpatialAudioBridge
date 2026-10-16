#![no_main]

use libfuzzer_sys::fuzz_target;
use spatial_audio_core::{decode::Core, render::Layout};
use std::{ffi::c_void, ptr::NonNull, slice};

type Callback = unsafe extern "C" fn(*mut c_void, *const f32, u32, u32, u32) -> i32;

// Exercise the shipped C symbols without making the private Rust FFI module public.
unsafe extern "C" {
    fn sab_create(codec: u32, channels: u32) -> *mut c_void;
    fn sab_set_dialogue_normalisation(handle: *mut c_void, enabled: i32);
    fn sab_push(handle: *mut c_void, data: *const u8, length: usize, end: i32,
                callback: Option<Callback>, context: *mut c_void) -> i32;
    fn sab_error(handle: *const c_void, buffer: *mut u8, capacity: usize) -> usize;
    fn sab_destroy(handle: *mut c_void);
}

struct Session(NonNull<c_void>);
impl Drop for Session {
    fn drop(&mut self) {
        // The target owns this live handle and never reenters it from a callback.
        unsafe { sab_destroy(self.0.as_ptr()) }
    }
}

struct Output {
    channels: usize,
    calls: usize,
    valid: bool,
    cancel: bool,
}

unsafe extern "C" fn pcm(context: *mut c_void, data: *const f32, frames: u32,
                         rate: u32, channels: u32) -> i32 {
    // Do not panic through the C ABI. Record violations for the caller to assert instead.
    let output = unsafe { &mut *context.cast::<Output>() };
    output.calls += 1;
    output.valid &= rate == 48_000 && channels as usize == output.channels
        && frames > 0 && frames <= 48_000 && !data.is_null();
    if output.valid {
        let samples = unsafe { slice::from_raw_parts(data, frames as usize * output.channels) };
        output.valid &= samples.iter().all(|sample| sample.is_finite());
    }
    i32::from(output.cancel || !output.valid)
}

fn error(session: &Session) -> Vec<u8> {
    let required = unsafe { sab_error(session.0.as_ptr(), std::ptr::null_mut(), 0) };
    assert!((1..=65_536).contains(&required), "Unbounded error message");
    let mut message = vec![0xff; required];
    assert_eq!(unsafe { sab_error(session.0.as_ptr(), message.as_mut_ptr(), message.len()) }, required);
    assert_eq!(message.last(), Some(&0));
    assert!(!message.starts_with(b"Decoder panic"), "The C API concealed a decoder panic");
    message
}

fuzz_target!(|input: &[u8]| {
    if input.len() < 4 { return; }
    let flags = input[0];
    let codec = u32::from(flags & 1) + 1;
    let channels = if flags & 2 == 0 { 12 } else { 16 };
    let chunk_size = [1, 17, 317, 4096, 65_536][usize::from(input[1]) % 5];
    let payload = &input[4..input.len().saturating_sub(usize::from(input[2])).max(4)];
    // Repeated input also reaches buffering limits without requiring multi-megabyte corpus files.
    let repeats = [1, 2, 8, 33][usize::from(input[3]) % 4];
    let cancel = flags & 4 != 0;
    let dialogue = flags & 8 != 0;

    // Check the owned PCM shape before the C adapter turns it into a borrowed pointer. Panics
    // here are defects even if the production C boundary would translate them into an error.
    {
        let mut core = Core::new(codec, Layout::parse(channels).unwrap()).unwrap();
        core.set_dialogue_normalisation(dialogue);
        let mut output = |pcm: spatial_audio_core::decode::Pcm| {
            assert_eq!(pcm.rate, 48_000);
            assert_eq!(pcm.channels, channels as usize);
            assert!(pcm.frames > 0 && pcm.frames <= 48_000);
            assert_eq!(pcm.data.len(), pcm.frames * pcm.channels);
            assert!(pcm.data.iter().all(|sample| sample.is_finite()));
            if cancel { Err("fuzz consumer cancelled".into()) } else { Ok(()) }
        };
        let mut failed = false;
        'stream: for _ in 0..repeats {
            for chunk in payload.chunks(chunk_size) {
                if core.push(chunk, false, &mut output).is_err() {
                    failed = true;
                    break 'stream;
                }
            }
        }
        if !failed { let _ = core.push(&[], true, &mut output); }
    }

    let session = Session(NonNull::new(unsafe { sab_create(codec, channels) }).unwrap());
    unsafe { sab_set_dialogue_normalisation(session.0.as_ptr(), i32::from(dialogue)) };
    let mut output = Output { channels: channels as usize, calls: 0, valid: true, cancel };
    let context = (&mut output as *mut Output).cast();
    let push = |bytes: &[u8], end: bool| unsafe {
        sab_push(session.0.as_ptr(), bytes.as_ptr(), bytes.len(), i32::from(end), Some(pcm), context)
    };
    let mut status = 0;
    'stream: for _ in 0..repeats {
        for chunk in payload.chunks(chunk_size) {
            status = push(chunk, false);
            assert!((-3..=0).contains(&status));
            if status != 0 { break 'stream; }
        }
    }
    if status == 0 { status = push(&[], true); }
    assert!((-3..=0).contains(&status));
    assert!(output.valid, "Invalid PCM callback");
    if cancel { assert!(output.calls <= 1, "Output continued after cancellation"); }
    let message = error(&session);
    assert_eq!(message.len() == 1, status == 0);
    let calls = output.calls;
    // Success at EOF and every failure are terminal: neither later input nor another flush
    // may produce more output, clear the error or resume a cancelled consumer.
    // A finished session reports misuse; a failed one repeats its error's kind.
    let terminal = if status == 0 { -1 } else { status };
    assert_eq!(push(&[0], false), terminal);
    assert_eq!(push(&[], true), terminal);
    assert_eq!(error(&session), message);
    assert_eq!(output.calls, calls);
});
