//! Atomic progress state shared between conversion threads and FFI polling.
//!
//! The conversion pipeline sets `(stage, current, total)` at key milestones.
//! Dart reads these via `xdremux_read_progress` on a periodic timer from the
//! main isolate, so the UI can show per-file conversion progress.

use std::sync::atomic::{AtomicU32, Ordering};

static STAGE: AtomicU32 = AtomicU32::new(0);
static CURRENT: AtomicU32 = AtomicU32::new(0);
static TOTAL: AtomicU32 = AtomicU32::new(0);

/// Update progress state.  Thread-safe (relaxed — only used for display).
pub fn set_progress(stage: u32, current: u32, total: u32) {
    STAGE.store(stage, Ordering::Relaxed);
    CURRENT.store(current, Ordering::Relaxed);
    TOTAL.store(total, Ordering::Relaxed);
}

/// Read the current progress tuple: `(stage, current, total)`.
///
/// Stage values:
/// - 0: idle / done
/// - 1: extracting metadata
/// - 2: decoding JPEG
/// - 3: encoding HEVC tiles (current = tile index, total = tile count)
/// - 4: assembling output
pub fn read_progress() -> (u32, u32, u32) {
    (
        STAGE.load(Ordering::Relaxed),
        CURRENT.load(Ordering::Relaxed),
        TOTAL.load(Ordering::Relaxed),
    )
}
