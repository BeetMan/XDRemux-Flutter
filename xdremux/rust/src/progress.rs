//! Per-thread progress state shared between conversion workers and FFI polling.
//!
//! Each `xdremux_convert*` call runs on its own thread (Dart `Isolate.run`
//! worker or CLI). Progress is recorded thread-locally, then mirrored into a
//! slot in a global registry keyed by a caller-provided handle, so the UI can
//! poll several concurrent conversions without their progress mixing.
//!
//! Single-conversion behavior is unchanged: `xdremux_read_progress` reads the
//! registry's "most recently active" slot, which is exactly the old global.

use std::cell::Cell;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

const MAX_SLOTS: usize = 8;

#[derive(Clone, Copy, Default)]
struct Slot {
    handle: u32,
    stage: u32,
    current: u32,
    total: u32,
    /// Monotonic stamp of the last write; the "current" slot is the max.
    stamp: u64,
    /// Set by [cancel]; the worker polls it between tiles and aborts.
    cancelled: bool,
}

struct Registry {
    slots: [Slot; MAX_SLOTS],
}

static REGISTRY: Mutex<Option<Registry>> = Mutex::new(None);
static STAMP: AtomicU64 = AtomicU64::new(0);
static NEXT_HANDLE: AtomicU32 = AtomicU32::new(1);

thread_local! {
    static TL_HANDLE: Cell<u32> = const { Cell::new(0) };
}

fn registry() -> std::sync::MutexGuard<'static, Option<Registry>> {
    let mut guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Some(Registry {
            slots: [Slot::default(); MAX_SLOTS],
        });
    }
    guard
}

/// Allocate a progress handle for a new conversion on the calling thread.
/// Returns 0 when the registry is full (progress reporting is then skipped).
pub fn begin_progress() -> u32 {
    begin_progress_with(NEXT_HANDLE.fetch_add(1, Ordering::Relaxed))
}

/// Claim [handle] for the calling thread, creating/reusing a registry slot.
/// The handle may come from another thread (the UI picks it before spawning
/// the worker), so collisions are resolved by clearing the previous slot.
pub fn begin_progress_with(handle: u32) -> u32 {
    if handle == 0 {
        return 0;
    }
    let mut guard = registry();
    let registry = guard.as_mut().unwrap();
    // Reuse the slot for this handle if present, else the least-recently
    // written one.
    // A cancel issued by the UI before the worker claimed the handle must
    // survive the claim (the UI allocates the handle first, then spawns).
    let (slot, cancelled) =
        if let Some(s) = registry.slots.iter_mut().find(|s| s.handle == handle) {
            let c = s.cancelled;
            (s, c)
        } else {
            (registry.slots.iter_mut().min_by_key(|s| s.stamp).unwrap(), false)
        };
    *slot = Slot {
        handle,
        stage: 0,
        current: 0,
        total: 0,
        stamp: STAMP.fetch_add(1, Ordering::Relaxed),
        cancelled,
    };
    TL_HANDLE.with(|h| h.set(handle));
    handle
}

/// Release the calling thread's progress handle and clear its slot.
pub fn end_progress() {
    end_progress_with(TL_HANDLE.with(|h| {
        let v = h.get();
        h.set(0);
        v
    }));
}

/// Release [handle]'s slot. Safe to call from any thread (the UI releases
/// handles it allocated once the worker reports completion).
pub fn end_progress_with(handle: u32) {
    if handle == 0 {
        return;
    }
    TL_HANDLE.with(|h| {
        if h.get() == handle {
            h.set(0);
        }
    });
    let mut guard = registry();
    if let Some(registry) = guard.as_mut() {
        if let Some(slot) = registry.slots.iter_mut().find(|s| s.handle == handle) {
            *slot = Slot::default();
        }
    }
}

/// Update progress state for the calling thread's handle. Thread-safe.
pub fn set_progress(stage: u32, current: u32, total: u32) {
    let handle = TL_HANDLE.with(|h| h.get());
    set_progress_for(handle, stage, current, total);
}

/// Update progress state for an explicit handle (used by the prepare/assemble
/// FFI split where the tile-encoding loop runs outside Rust). Thread-safe.
pub fn set_progress_for(handle: u32, stage: u32, current: u32, total: u32) {
    if handle == 0 {
        return;
    }
    let mut guard = registry();
    if let Some(registry) = guard.as_mut() {
        if let Some(slot) = registry.slots.iter_mut().find(|s| s.handle == handle) {
            slot.stage = stage;
            slot.current = current;
            slot.total = total;
            slot.stamp = STAMP.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Ask the conversion bound to [handle] to stop at its next check point.
/// Safe from any thread; unknown handles are ignored. The worker returns a
/// failed report whose message is [CANCELLED_MESSAGE].
pub fn cancel(handle: u32) {
    if handle == 0 {
        return;
    }
    let mut guard = registry();
    if let Some(registry) = guard.as_mut() {
        if let Some(slot) = registry.slots.iter_mut().find(|s| s.handle == handle) {
            slot.cancelled = true;
        }
    }
}

/// Error message carried by a conversion that stopped on [cancel].
pub const CANCELLED_MESSAGE: &str = "conversion cancelled";

/// The calling thread's handle (0 when none). Worker threads spawned by a
/// conversion have no handle of their own; they capture this value and poll
/// [is_cancelled_for].
pub fn current_handle() -> u32 {
    TL_HANDLE.with(|h| h.get())
}

/// True when [cancel] was called for the calling thread's handle.
pub fn is_cancelled() -> bool {
    is_cancelled_for(current_handle())
}

/// True when [cancel] was called for [handle].
pub fn is_cancelled_for(handle: u32) -> bool {
    if handle == 0 {
        return false;
    }
    let guard = registry();
    guard
        .as_ref()
        .and_then(|r| r.slots.iter().find(|s| s.handle == handle))
        .map(|s| s.cancelled)
        .unwrap_or(false)
}

/// Check point for long loops: `Err(CANCELLED_MESSAGE)` once cancelled.
pub fn check_cancelled() -> Result<(), String> {
    if is_cancelled() {
        Err(CANCELLED_MESSAGE.to_string())
    } else {
        Ok(())
    }
}

/// Read progress for a specific handle. Returns `(stage, current, total)` or
/// `None` when the handle is unknown.
pub fn read_progress_for(handle: u32) -> Option<(u32, u32, u32)> {
    let guard = registry();
    let registry = guard.as_ref().unwrap();
    registry
        .slots
        .iter()
        .find(|s| s.handle == handle)
        .map(|s| (s.stage, s.current, s.total))
}

/// Read the most recently updated slot — the legacy single-conversion view.
pub fn read_progress() -> (u32, u32, u32) {
    let guard = registry();
    let registry = guard.as_ref().unwrap();
    registry
        .slots
        .iter()
        .filter(|s| s.handle != 0)
        .max_by_key(|s| s.stamp)
        .map(|s| (s.stage, s.current, s.total))
        .unwrap_or((0, 0, 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_before_claim_survives_begin() {
        // UI thread: allocate; worker thread: claim later. Cancel in between.
        let handle = begin_progress();
        cancel(handle);
        begin_progress_with(handle);
        assert!(is_cancelled());
        assert_eq!(check_cancelled(), Err(CANCELLED_MESSAGE.to_string()));
        end_progress();
        assert!(!is_cancelled());
    }

    #[test]
    fn cancel_does_not_leak_into_other_handles() {
        let a = begin_progress();
        let b = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        begin_progress_with(b);
        cancel(a);
        assert!(!is_cancelled(), "thread is bound to b");
        end_progress_with(a);
        end_progress_with(b);
    }
}
