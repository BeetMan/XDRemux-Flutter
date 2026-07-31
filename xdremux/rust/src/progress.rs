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
    let slot = if let Some(s) = registry.slots.iter_mut().find(|s| s.handle == handle) {
        s
    } else {
        registry.slots.iter_mut().min_by_key(|s| s.stamp).unwrap()
    };
    *slot = Slot {
        handle,
        stage: 0,
        current: 0,
        total: 0,
        stamp: STAMP.fetch_add(1, Ordering::Relaxed),
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
