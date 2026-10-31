//! Minimal FFI bindings for x265 (static-linked on Android).
//!
//! Only the subset needed for single-frame HEVC encoding is bound.

#![allow(non_camel_case_types, dead_code)]

use std::os::raw::{c_char, c_int, c_void};

/// Opaque encoder handle.
#[repr(C)]
pub struct x265_encoder {
    _private: [u8; 0],
}

/// Opaque param struct (managed via x265_param_alloc/free/parse).
#[repr(C)]
pub struct x265_param {
    _private: [u8; 0],
}

/// Opaque picture struct (managed via x265_picture_alloc/free/init).
#[repr(C)]
pub struct x265_picture {
    _private: [u8; 0],
}

/// NAL unit output from encoder.
#[repr(C)]
pub struct x265_nal {
    pub nal_type: u32,
    pub size_bytes: u32,
    pub payload: *mut u8,
}

// Color space constants
pub const X265_CSP_I400: c_int = 0;
pub const X265_CSP_I420: c_int = 1;
pub const X265_CSP_I422: c_int = 2;
pub const X265_CSP_I444: c_int = 3;

extern "C" {
    // Param management
    pub fn x265_param_alloc() -> *mut x265_param;
    pub fn x265_param_free(p: *mut x265_param);
    pub fn x265_param_default_preset(
        p: *mut x265_param,
        preset: *const c_char,
        tune: *const c_char,
    ) -> c_int;
    pub fn x265_param_parse(
        p: *mut x265_param,
        name: *const c_char,
        value: *const c_char,
    ) -> c_int;

    // Picture management
    pub fn x265_picture_alloc() -> *mut x265_picture;
    pub fn x265_picture_free(pic: *mut x265_picture);
    pub fn x265_picture_init(param: *mut x265_param, pic: *mut x265_picture);

    // Encoder lifecycle
    pub fn x265_encoder_open_216(p: *mut x265_param) -> *mut x265_encoder;
    pub fn x265_encoder_encode(
        encoder: *mut x265_encoder,
        pp_nal: *mut *mut x265_nal,
        pi_nal: *mut u32,
        pic_in: *mut x265_picture,
        pic_out: *mut x265_picture,
    ) -> c_int;
    pub fn x265_encoder_close(encoder: *mut x265_encoder);
    pub fn x265_cleanup();

    // Our C helpers (x265_helper.c)
    pub fn xdremux_pic_set_planes(
        pic: *mut x265_picture,
        p0: *mut c_void,
        p1: *mut c_void,
        p2: *mut c_void,
        s0: c_int,
        s1: c_int,
        s2: c_int,
    );
    pub fn xdremux_pic_set_pts(pic: *mut x265_picture, pts: i64);
    pub fn xdremux_param_set_basic(
        p: *mut x265_param,
        width: c_int,
        height: c_int,
        bit_depth: c_int,
        total_frames: c_int,
    );

    // x265 profile API
    pub fn x265_param_apply_profile(p: *mut x265_param, profile: *const c_char) -> c_int;
}

/// Optional 10-bit (Main10) bridge. Only compiled/linked when a 10-bit x265
/// archive is present at build time (see build.rs and
/// `docs/research/x265-main10-feasibility-20261025.md`).
#[cfg(xdremux_main10)]
extern "C" {
    /// Returns 1 when the 10-bit encoder table was reachable at link time.
    pub fn xdremux_10bit_available() -> c_int;

    /// Encode one 10-bit 4:2:0 picture from three uint16 planes (samples in
    /// 0..=1023) and store a malloc'd Annex-B stream in `out`/`out_len`.
    pub fn xdremux_encode_10bit_planes(
        p0: *const u16,
        p1: *const u16,
        p2: *const u16,
        width: c_int,
        height: c_int,
        out: *mut *mut u8,
        out_len: *mut c_int,
    ) -> c_int;

    /// [`xdremux_encode_10bit_planes`] that also reports the PSNR of x265's
    /// reconstructed luma against `p0` (used by tests to catch layout bugs).
    pub fn xdremux_encode_10bit_planes_checked(
        p0: *const u16,
        p1: *const u16,
        p2: *const u16,
        width: c_int,
        height: c_int,
        out: *mut *mut u8,
        out_len: *mut c_int,
        luma_psnr: *mut f64,
    ) -> c_int;

    /// Release a stream returned by [`xdremux_encode_10bit_planes`].
    pub fn xdremux_free_stream(buffer: *mut u8);
}
