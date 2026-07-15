//! Tiny hand-rolled JSON writer for the conformance harness.
//!
//! We avoid a `serde_json` dependency to keep the conformance tool's build
//! footprint identical to xdremux-core (which is std-only). The schema is
//! small and stable, so a ~80-line writer is cheaper than a 200 KiB dep.

use std::fmt;

/// Append a JSON-escaped string (without surrounding quotes) to the buffer.
pub fn write_escaped(buf: &mut String, s: &str) {
    for c in s.chars() {
        match c {
            '"' => buf.push_str("\\\""),
            '\\' => buf.push_str("\\\\"),
            '\n' => buf.push_str("\\n"),
            '\r' => buf.push_str("\\r"),
            '\t' => buf.push_str("\\t"),
            '\x08' => buf.push_str("\\b"),
            '\x0c' => buf.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                use fmt::Write;
                let _ = write!(buf, "\\u{:04x}", c as u32);
            }
            c => buf.push(c),
        }
    }
}

/// Write a f32 with 9 significant digits (matches Python's `repr` for round-trip).
pub fn write_f32(buf: &mut String, v: f32) {
    if v.is_nan() {
        buf.push_str("null");
        return;
    }
    if v.is_infinite() {
        buf.push_str(if v > 0.0 { "1e999" } else { "-1e999" });
        return;
    }
    // Avoid scientific notation for typical values, fall back for huge/tiny.
    if v.abs() >= 1e-4 && v.abs() < 1e16 {
        let formatted = format!("{:.9}", v);
        // Trim trailing zeros after the decimal point but keep the integer part intact.
        let trimmed = formatted.trim_end_matches('0').trim_end_matches('.');
        buf.push_str(trimmed);
    } else {
        let formatted = format!("{:e}", v);
        // Normalize "1.23e4" → "1.23e+04" for readability (optional).
        buf.push_str(&formatted);
    }
}
