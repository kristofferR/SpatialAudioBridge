use std::sync::atomic::{AtomicBool, Ordering};

#[no_mangle]
pub extern "C" fn other_rust_value(value: i32) -> i32 {
    *std::hint::black_box(Box::new(value)) + 1
}

struct Dropped<'a>(&'a AtomicBool);

impl Drop for Dropped<'_> {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

// Catch inside this library: no panic may unwind across the C ABI.
#[no_mangle]
pub extern "C" fn other_rust_catches() -> i32 {
    let dropped = AtomicBool::new(false);
    let result = std::panic::catch_unwind(|| {
        let _guard = Dropped(&dropped);
        panic!("mixed-host deliberate panic");
    });
    match result {
        Err(payload) => {
            (payload.downcast_ref::<&str>() == Some(&"mixed-host deliberate panic")
                && dropped.load(Ordering::SeqCst)) as i32
        }
        Ok(()) => 0,
    }
}
