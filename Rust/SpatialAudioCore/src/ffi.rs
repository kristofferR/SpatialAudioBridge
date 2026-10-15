use crate::{
    decode::{Core, Pcm, RecoveryStatistics},
    render::Layout,
};
use std::{
    ffi::{c_char, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
};

pub type PcmCallback = unsafe extern "C" fn(*mut c_void, *const f32, u32, u32, u32) -> i32;
pub struct Handle {
    decoder: Core,
    error: String,
    ended: bool,
}

/// Creates a single-threaded session: codec 1=TrueHD Atmos, 2=DTS:X; layout 12=7.1.4, 16=9.1.6.
#[unsafe(no_mangle)]
pub extern "C" fn sab_create(codec: u32, channels: u32) -> *mut Handle {
    catch_unwind(|| {
        Layout::parse(channels)
            .and_then(|l| Core::new(codec, l))
            .map(|decoder| {
                Box::into_raw(Box::new(Handle {
                    decoder,
                    error: String::new(),
                    ended: false,
                }))
            })
            .unwrap_or(ptr::null_mut())
    })
    .unwrap_or(ptr::null_mut())
}

/// Applies TrueHD dialogue normalisation when `enabled` is nonzero; off by default. Call before
/// the first `sab_push`.
///
/// # Safety
/// `handle` must be a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sab_set_dialogue_normalisation(handle: *mut Handle, enabled: i32) {
    if let Some(handle) = unsafe { handle.as_mut() } {
        handle.decoder.set_dialogue_normalisation(enabled != 0);
    }
}

/// # Safety
/// `handle` must be a live session. `data` must reference `length` bytes. The callback
/// may read PCM only during the call and must not reenter or destroy this session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sab_push(
    handle: *mut Handle,
    data: *const u8,
    length: usize,
    end: i32,
    callback: Option<PcmCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        return -1;
    };
    if handle.ended || !handle.error.is_empty() {
        return -1;
    }
    if length > 65536 || (length != 0 && data.is_null()) || callback.is_none() {
        handle.error = "Invalid input buffer or PCM callback".into();
        return -1;
    }
    let bytes = if length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(data, length) }
    };
    let callback = callback.unwrap();
    let result = catch_unwind(AssertUnwindSafe(|| {
        handle.decoder.push(bytes, end != 0, &mut |pcm: Pcm| {
            if pcm.data.iter().any(|v| !v.is_finite()) {
                return Err("Decoder produced non-finite PCM".into());
            }
            let result = unsafe {
                callback(
                    context,
                    pcm.data.as_ptr(),
                    pcm.frames as u32,
                    pcm.rate,
                    pcm.channels as u32,
                )
            };
            if result == 0 {
                Ok(())
            } else {
                Err("PCM consumer cancelled".into())
            }
        })
    }));
    match result {
        Ok(Ok(())) => {
            handle.ended = end != 0;
            0
        }
        Ok(Err(e)) => {
            handle.error = e;
            -1
        }
        Err(_) => {
            handle.error = "Decoder panic; the session has been stopped".into();
            -1
        }
    }
}

/// Copies a UTF-8 error, including its terminating zero, returning the required capacity.
/// # Safety
/// `handle` must be live; a non-null buffer must reference `capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sab_error(
    handle: *const Handle,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    let bytes = handle.error.as_bytes();
    if capacity > 0 && !buffer.is_null() {
        let n = bytes.len().min(capacity - 1);
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buffer.cast(), n);
            *buffer.add(n) = 0;
        }
    }
    bytes.len() + 1
}

/// Copies cumulative recovery statistics, including after finishing or an error.
/// Returns -1 for a null handle or output pointer, otherwise zero.
/// # Safety
/// Non-null `handle` must be live and `output` must point to writable, aligned storage.
/// Serialize with all other calls on this session; do not call from its PCM callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sab_recovery_statistics(
    handle: *const Handle,
    output: *mut RecoveryStatistics,
) -> i32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    if output.is_null() {
        return -1;
    }
    unsafe { output.write(handle.decoder.recovery_statistics()) };
    0
}

/// # Safety
/// The pointer must be null or a live session created by `sab_create`, destroyed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sab_destroy(handle: *mut Handle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_snapshot_rejects_nulls_and_survives_terminal_error() {
        let mut snapshot = RecoveryStatistics::default();
        unsafe {
            assert_eq!(sab_recovery_statistics(ptr::null(), &mut snapshot), -1);
            let handle = sab_create(1, 12);
            assert!(!handle.is_null());
            assert_eq!(sab_recovery_statistics(handle, ptr::null_mut()), -1);
            assert_eq!(sab_recovery_statistics(handle, &mut snapshot), 0);
            assert_eq!(snapshot, RecoveryStatistics::default());
            assert_eq!(sab_push(handle, ptr::null(), 0, 0, None, ptr::null_mut()), -1);
            assert_eq!(sab_recovery_statistics(handle, &mut snapshot), 0);
            assert_eq!(snapshot, RecoveryStatistics::default());
            sab_destroy(handle);
        }
    }
}
