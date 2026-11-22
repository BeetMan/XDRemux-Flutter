//! Panic guards for the C ABI exports.
//!
//! Since Rust 1.81 a panic that unwinds out of an `extern "C"` function
//! aborts the process, so a guarded export catches it inside its own body:
//! the `#[no_mangle]` wrapper runs the real `*_impl` function through
//! [`catch_or`] or [`catch_or_else`] and hands the caller a failure value
//! instead. A photo that trips an out-of-range slice in a parser then fails
//! that one call rather than taking the host app down with it.
//!
//! The guards only catch anything when the core is built with
//! `panic = "unwind"`. `build_ohos.sh` builds the HarmonyOS library that way;
//! the workspace release profile keeps `panic = "abort"` for the other
//! platforms, where a panic still aborts before these helpers see it. The
//! default panic hook has already printed the message and location to stderr
//! by the time a guard returns its failure value.
//!
//! `AssertUnwindSafe` is sound here: the bodies own their working state, which
//! the unwind drops, and the shared progress registry they write tolerates
//! mutex poisoning. The one piece of per-thread state a body leaves behind,
//! the conversion progress binding, is released by [`conversion_panicked`].

use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use crate::categorize::{Classification, ClassificationStatus};
use crate::{progress, ClassificationResult, ConversionResult};

/// Error message carried by [`conversion_panicked`].
pub(crate) const PANIC_MESSAGE: &str = "internal error: core panicked";

/// Run `body`, returning `failure` instead if it panics.
///
/// For failure values that own nothing (a null pointer, `0`, `false`). Use
/// [`catch_or_else`] when the failure value allocates.
pub(crate) fn catch_or<T>(failure: T, body: impl FnOnce() -> T) -> T {
    panic::catch_unwind(AssertUnwindSafe(body)).unwrap_or(failure)
}

/// Run `body`, returning `failure()` instead if it panics. `failure` runs only
/// on that path, so it may allocate or release per-call state.
pub(crate) fn catch_or_else<T>(failure: impl FnOnce() -> T, body: impl FnOnce() -> T) -> T {
    panic::catch_unwind(AssertUnwindSafe(body)).unwrap_or_else(|_| failure())
}

/// Failure value for `xdremux_convert` and `xdremux_convert_with_progress`:
/// `success = false`, null mode and family, zero scales, and an owned
/// [`PANIC_MESSAGE`] that `xdremux_free_result` releases.
///
/// Both bodies bind a progress handle to the calling thread and detach it
/// with `progress::end_progress()` before returning. The unwind skipped that
/// call, so make it here as the normal path does; otherwise a pooled worker
/// thread would carry the stale thread-local handle into its next job.
pub(crate) fn conversion_panicked() -> ConversionResult {
    progress::end_progress();
    ConversionResult {
        success: false,
        mode: ptr::null_mut(),
        family: ptr::null_mut(),
        edr_scale: 0.0,
        gain_map_max: 0.0,
        error_message: crate::ffi_string(Some(PANIC_MESSAGE)),
    }
}

/// Failure value for `xdremux_classify`: the result it already returns for a
/// file it cannot read (status `unreadable-image`; no mode, flags, HDR kind or
/// family). `ClassificationResult` has no error field, and this keeps the
/// status non-null as that export documents. Freed by
/// `xdremux_free_classification_result`.
pub(crate) fn classification_panicked() -> ClassificationResult {
    crate::classification_result(
        Classification {
            raw_user_comment: None,
            tag_flags: None,
            unknown_flags: 0,
            mode: None,
            status: ClassificationStatus::UnreadableImage,
        },
        None,
        None,
    )
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::ffi::{c_char, CStr, CString};

    use super::*;

    #[test]
    fn catch_or_passes_a_normal_return_through() {
        assert_eq!(catch_or(0u8, || 1u8), 1);
        assert!(catch_or(false, || true));
        let report = catch_or(ptr::null_mut(), || CString::new("{}").unwrap().into_raw());
        assert!(!report.is_null());
        crate::xdremux_free_string(report);
    }

    #[test]
    fn catch_or_returns_null_when_a_string_export_panics() {
        // `CString::new(..).unwrap()` on a report that contains a NUL byte.
        let report = catch_or(ptr::null_mut(), || -> *mut c_char {
            CString::new("bad\0report").unwrap().into_raw()
        });
        assert!(report.is_null());
    }

    #[test]
    fn catch_or_returns_zero_when_a_u8_export_panics() {
        // A box header that claims more bytes than the buffer holds: the
        // out-of-range slice a parser hits on a truncated photo.
        let data = [0u8, 0, 0, 64, b'f', b't', b'y', b'p'];
        let declared = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
        assert_eq!(catch_or(0u8, || data[..declared][0]), 0);
    }

    #[test]
    fn catch_or_returns_false_when_a_bool_export_panics() {
        assert!(!catch_or(false, || -> bool { panic!("verifier panicked") }));
    }

    #[test]
    fn catch_or_else_builds_the_failure_only_on_panic() {
        let built = Cell::new(0);
        let failure = || {
            built.set(built.get() + 1);
            0
        };
        assert_eq!(catch_or_else(failure, || 7), 7);
        assert_eq!(built.get(), 0);
        assert_eq!(catch_or_else(failure, || -> i32 { panic!("boom") }), 0);
        assert_eq!(built.get(), 1);
    }

    #[test]
    fn conversion_panicked_returns_an_owned_error_and_detaches_progress() {
        // The UI allocates the handle; the export body claims it on the
        // worker thread and panics before its own `end_progress()`.
        let handle = progress::begin_progress();
        let result = catch_or_else(conversion_panicked, || -> ConversionResult {
            progress::begin_progress_with(handle);
            progress::set_progress(3, 1, 4);
            panic!("tile encoder panicked")
        });
        assert!(!result.success);
        assert!(result.mode.is_null() && result.family.is_null());
        assert_eq!((result.edr_scale, result.gain_map_max), (0.0, 0.0));
        let message = unsafe { CStr::from_ptr(result.error_message) };
        assert_eq!(message.to_str(), Ok(PANIC_MESSAGE));
        assert_eq!(progress::current_handle(), 0, "stale progress handle");
        assert_eq!(progress::read_progress_for(handle), None);
        crate::xdremux_free_result(result);
    }

    #[test]
    fn classification_panicked_matches_the_unreadable_result() {
        let result = catch_or_else(classification_panicked, || -> ClassificationResult {
            panic!("classifier panicked")
        });
        // Same shape as the export's own answer for a path it cannot read.
        let unreadable = crate::xdremux_classify(ptr::null());
        for value in [&result, &unreadable] {
            let status = unsafe { CStr::from_ptr(value.status) };
            assert_eq!(status.to_str(), Ok("unreadable-image"));
            for field in [
                value.mode_key,
                value.folder_name,
                value.raw_user_comment,
                value.hdr_kind,
                value.family,
            ] {
                assert!(field.is_null());
            }
            assert!(!value.has_tag_flags);
            assert_eq!((value.tag_flags, value.unknown_flags), (0, 0));
        }
        crate::xdremux_free_classification_result(result);
        crate::xdremux_free_classification_result(unreadable);
    }
}
