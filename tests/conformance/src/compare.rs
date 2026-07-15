//! `compare` subcommand: diff two inspect JSON files and emit a Markdown
//! report. Numeric comparisons use a configurable tolerance (default 1e-6).
//!
//! The diff is shallow: it walks a fixed set of paths known to be cross-
//! implementation comparison targets. Unknown fields are ignored (the schema
//! may grow; comparisons should remain forward-compatible).

use std::fs;
use std::path::Path;

pub fn run<P1: AsRef<Path>, P2: AsRef<Path>>(
    a: P1,
    b: P2,
    tolerance: f32,
) -> Result<String, String> {
    let ja = fs::read_to_string(a).map_err(|e| format!("cannot read a: {e}"))?;
    let jb = fs::read_to_string(b).map_err(|e| format!("cannot read b: {e}"))?;
    compare_str(&ja, &jb, tolerance)
}

pub fn compare_str<'a>(a_json: &'a str, b_json: &'a str, tolerance: f32) -> Result<String, String> {
    let mut diffs: Vec<String> = Vec::new();
    let mut passes: Vec<String> = Vec::new();

    // Helper: extract a JSON object field by name from a flat document.
    // Our writer produces flat single-level JSON with no nested arrays-of-objects
    // except "tmap_payloads" and "xmp.hdrgm". Use a tiny key-value walker.
    let extract = |s: &'a str, path: &str| -> Option<Extracted<'a>> {
        extract_path(s, path)
    };

    macro_rules! check {
        ($name:expr, $a:expr, $b:expr) => {
            match ($a, $b) {
                (Some(va), Some(vb)) => {
                    if va == vb {
                        passes.push(format!("{}: equal", $name));
                    } else if va.is_fuzzy_eq(&vb, tolerance) {
                        passes.push(format!("{}: ≈equal (|Δ|={:.3e} ≤ {:.0e})", $name, va.distance(&vb), tolerance));
                    } else {
                        diffs.push(format!("{}: {} ≠ {}", $name, va, vb));
                    }
                }
                (Some(v), None) => diffs.push(format!("{}: {} present in A but missing in B", $name, v)),
                (None, Some(v)) => diffs.push(format!("{}: missing in A but {} present in B", $name, v)),
                (None, None) => {}
            }
        };
    }

    // ── Tier 1: numerics ──
    check!("lhdr.mode",       extract(a_json, "lhdr.mode"),       extract(b_json, "lhdr.mode"));
    check!("lhdr.meta_floats",
        extract(a_json, "lhdr.meta_floats"),
        extract(b_json, "lhdr.meta_floats"));
    check!("edr_scale",       extract(a_json, "edr_scale"),       extract(b_json, "edr_scale"));
    check!("family",          extract(a_json, "family"),          extract(b_json, "family"));
    check!(
        "iso_meta.gain_map_max",
        extract(a_json, "iso_meta.gain_map_max"),
        extract(b_json, "iso_meta.gain_map_max")
    );
    check!(
        "iso_meta.hdr_capacity_max",
        extract(a_json, "iso_meta.hdr_capacity_max"),
        extract(b_json, "iso_meta.hdr_capacity_max")
    );
    check!(
        "iso_meta.channel_count",
        extract(a_json, "iso_meta.channel_count"),
        extract(b_json, "iso_meta.channel_count")
    );

    // ── Tier 2: tmap payload MD5s ──
    check!(
        "tmap.apple_62.md5",
        extract(a_json, "tmap_payloads.apple_62.md5"),
        extract(b_json, "tmap_payloads.apple_62.md5")
    );
    check!(
        "tmap.imageio_142.md5",
        extract(a_json, "tmap_payloads.imageio_142.md5"),
        extract(b_json, "tmap_payloads.imageio_142.md5")
    );
    check!(
        "tmap.iso21496.md5",
        extract(a_json, "tmap_payloads.iso21496.md5"),
        extract(b_json, "tmap_payloads.iso21496.md5")
    );

    // ── Tier 1.5: XMP numeric fields ──
    // The XMP gainMapMax is a space-separated list of floats. We compare
    // the parsed numeric vectors rather than the raw text — Python's `str(v)`
    // and Rust's `:.6` produce different precision representations but the
    // f32-parsed values must match.
    check!(
        "xmp.hdrgm.gainMapMax",
        parse_xmp_num_vec(extract(a_json, "xmp.hdrgm.gainMapMax").as_ref()),
        parse_xmp_num_vec(extract(b_json, "xmp.hdrgm.gainMapMax").as_ref())
    );
    check!(
        "xmp.hdrgm.gainMapMin",
        parse_xmp_num_vec(extract(a_json, "xmp.hdrgm.gainMapMin").as_ref()),
        parse_xmp_num_vec(extract(b_json, "xmp.hdrgm.gainMapMin").as_ref())
    );
    check!(
        "xmp.hdrgm.hdrCapacityMax",
        parse_xmp_num(extract(a_json, "xmp.hdrgm.hdrCapacityMax").as_ref()),
        parse_xmp_num(extract(b_json, "xmp.hdrgm.hdrCapacityMax").as_ref())
    );

    // ── Tier 1.5: container_status ──
    check!(
        "lhdr.container_status",
        extract(a_json, "lhdr.container_status"),
        extract(b_json, "lhdr.container_status")
    );

    // ── emit report ──
    let mut out = String::new();
    out.push_str("# Conformance report\n\n");
    out.push_str(&format!("tolerance: {:.0e}\n\n", tolerance));
    out.push_str(&format!("passes: {}\n", passes.len()));
    out.push_str(&format!("differences: {}\n\n", diffs.len()));
    if !passes.is_empty() {
        out.push_str("## Passes\n");
        for p in &passes {
            out.push_str(&format!("- {p}\n"));
        }
        out.push('\n');
    }
    if !diffs.is_empty() {
        out.push_str("## Differences\n");
        for d in &diffs {
            out.push_str(&format!("- {d}\n"));
        }
        out.push('\n');
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Tiny path extractor over flat-ish JSON
// ---------------------------------------------------------------------------

/// Extract a typed value at a dotted path like "lhdr.meta_floats" or
/// "tmap_payloads.apple_62.md5". Supports string / number / bool / null /
/// array-of-numbers values. Returns `None` if the path is missing.
fn extract_path<'a>(json: &'a str, path: &str) -> Option<Extracted<'a>> {
    let mut node = find_object_at_root(json)?;
    for segment in path.split('.') {
        let (new_node, _consumed) = find_in_object(node, segment)?;
        node = new_node;
    }
    Some(parse_extracted(node))
}

/// Find the value of `key` within an object node and return both the value's
/// text and how many bytes were consumed (0 if scalar/leaf).
fn find_in_object<'a>(obj: &'a str, key: &str) -> Option<(&'a str, usize)> {
    // Skip whitespace
    let bytes = obj.as_bytes();
    if bytes.first() != Some(&b'{') {
        return None;
    }
    let mut depth = 0i32;
    let mut i = 0usize;
    let len = bytes.len();
    while i < len {
        match bytes[i] {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return None;
                }
            }
            b'"' if depth == 1 => {
                // Parse key
                let key_start = i + 1;
                let mut j = key_start;
                while j < len && bytes[j] != b'"' {
                    if bytes[j] == b'\\' {
                        j += 2;
                    } else {
                        j += 1;
                    }
                }
                if j >= len {
                    return None;
                }
                let parsed_key = &obj[key_start..j];
                // Find the colon after the key.
                let mut k = j + 1;
                while k < len
                    && (bytes[k] == b' '
                        || bytes[k] == b'\t'
                        || bytes[k] == b'\n'
                        || bytes[k] == b'\r')
                {
                    k += 1;
                }
                if k >= len || bytes[k] != b':' {
                    return None;
                }
                k += 1;
                while k < len
                    && (bytes[k] == b' '
                        || bytes[k] == b'\t'
                        || bytes[k] == b'\n'
                        || bytes[k] == b'\r')
                {
                    k += 1;
                }
                // k now points at the start of the value (or `}` for empty).
                if k >= len {
                    return None;
                }
                // Determine value extent — must respect nested {} and "".
                let val_end = match bytes[k] {
                    b'{' | b'[' => find_matching(bytes, k) + 1,
                    b'"' => {
                        let mut m = k + 1;
                        while m < len && bytes[m] != b'"' {
                            if bytes[m] == b'\\' {
                                m += 2;
                            } else {
                                m += 1;
                            }
                        }
                        if m >= len {
                            return None;
                        }
                        m + 1
                    }
                    _ => {
                        let mut m = k;
                        while m < len && bytes[m] != b',' && bytes[m] != b'}' {
                            m += 1;
                        }
                        m
                    }
                };
                if parsed_key == key {
                    return Some((&obj[k..val_end], val_end - k));
                }
                // Not our key — advance past the value and any trailing
                // whitespace + comma so the next iteration finds the next key.
                i = val_end;
                while i < len
                    && (bytes[i] == b' '
                        || bytes[i] == b'\t'
                        || bytes[i] == b'\n'
                        || bytes[i] == b'\r'
                        || bytes[i] == b',')
                {
                    i += 1;
                }
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Return the offset just past the next comma or closing brace at the same depth
/// as the start position. Used to skip over values when scanning for a key.
fn skip_value(bytes: &[u8], start: usize) -> usize {
    let len = bytes.len();
    match bytes[start] {
        b'{' | b'[' => {
            let end = find_matching(bytes, start);
            end + 1
        }
        b'"' => {
            let mut m = start + 1;
            while m < len && bytes[m] != b'"' {
                if bytes[m] == b'\\' {
                    m += 2;
                } else {
                    m += 1;
                }
            }
            m + 1
        }
        _ => {
            let mut m = start;
            while m < len && bytes[m] != b',' && bytes[m] != b'}' {
                m += 1;
            }
            m
        }
    }
}

fn find_matching(bytes: &[u8], start: usize) -> usize {
    let open = bytes[start];
    let close = if open == b'{' { b'}' } else { b']' };
    let mut depth = 0i32;
    let mut in_str = false;
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        if in_str {
            if b == b'\\' {
                continue;
            }
            if b == b'"' {
                in_str = false;
            }
        } else {
            match b {
                b'"' => in_str = true,
                x if x == open => depth += 1,
                x if x == close => {
                    depth -= 1;
                    if depth == 0 {
                        return i;
                    }
                }
                _ => {}
            }
        }
    }
    bytes.len()
}

fn find_object_at_root(s: &str) -> Option<&str> {
    let trimmed = s.trim_start();
    if !trimmed.starts_with('{') {
        return None;
    }
    let end = find_matching(trimmed.as_bytes(), 0);
    Some(&trimmed[..end + 1])
}

// ---------------------------------------------------------------------------
// Extracted value with fuzzy numeric comparison
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub(crate) enum Extracted<'a> {
    Str(&'a str),
    Num(f64),
    Bool(bool),
    Null,
    /// JSON array of numbers.
    NumArray(Vec<f64>),
    /// JSON array of strings.
    StrArray(Vec<&'a str>),
}

impl<'a> std::fmt::Display for Extracted<'a> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Extracted::Str(s) => write!(f, "{s}"),
            Extracted::Num(n) => write!(f, "{n}"),
            Extracted::Bool(b) => write!(f, "{b}"),
            Extracted::Null => write!(f, "null"),
            Extracted::NumArray(v) => {
                f.write_str("[")?;
                for (i, x) in v.iter().enumerate() {
                    if i > 0 {
                        f.write_str(",")?;
                    }
                    write!(f, "{x}")?;
                }
                f.write_str("]")
            }
            Extracted::StrArray(v) => {
                f.write_str("[")?;
                for (i, x) in v.iter().enumerate() {
                    if i > 0 {
                        f.write_str(",")?;
                    }
                    write!(f, "\"{x}\"")?;
                }
                f.write_str("]")
            }
        }
    }
}

impl<'a> PartialEq for Extracted<'a> {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Extracted::Str(a), Extracted::Str(b)) => a == b,
            (Extracted::Num(a), Extracted::Num(b)) => a == b,
            (Extracted::Bool(a), Extracted::Bool(b)) => a == b,
            (Extracted::Null, Extracted::Null) => true,
            (Extracted::NumArray(a), Extracted::NumArray(b)) => a == b,
            _ => false,
        }
    }
}

impl<'a> Extracted<'a> {
    fn is_fuzzy_eq(&self, other: &Extracted<'a>, tolerance: f32) -> bool {
        match (self, other) {
            (Extracted::Num(a), Extracted::Num(b)) => (a - b).abs() <= tolerance as f64,
            (Extracted::NumArray(a), Extracted::NumArray(b)) => {
                a.len() == b.len()
                    && a.iter()
                        .zip(b.iter())
                        .all(|(x, y)| (x - y).abs() <= tolerance as f64)
            }
            _ => self == other,
        }
    }

    fn distance(&self, other: &Extracted<'a>) -> f64 {
        match (self, other) {
            (Extracted::Num(a), Extracted::Num(b)) => (a - b).abs(),
            (Extracted::NumArray(a), Extracted::NumArray(b)) => a
                .iter()
                .zip(b.iter())
                .map(|(x, y)| (x - y).abs())
                .fold(0.0_f64, f64::max),
            _ => 0.0,
        }
    }
}

/// Convert the raw text of a value into an `Extracted` typed value.
fn parse_extracted<'a>(raw: &'a str) -> Extracted<'a> {
    let trimmed = raw.trim();
    if trimmed == "null" {
        return Extracted::Null;
    }
    if trimmed == "true" {
        return Extracted::Bool(true);
    }
    if trimmed == "false" {
        return Extracted::Bool(false);
    }
    if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2 {
        return Extracted::Str(&trimmed[1..trimmed.len() - 1]);
    }
    if trimmed.starts_with('[') && trimmed.ends_with(']') {
        let inner = &trimmed[1..trimmed.len() - 1];
        // Try as a number array first.
        let parts: Vec<&str> = inner.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
        if !parts.is_empty() {
            if let Ok(arr) = parts
                .iter()
                .map(|p| p.parse::<f64>())
                .collect::<Result<Vec<_>, _>>()
            {
                return Extracted::NumArray(arr);
            }
            // Fall back to string array (best-effort).
            let strs: Vec<&str> = parts
                .iter()
                .filter_map(|p| {
                    if p.starts_with('"') && p.ends_with('"') && p.len() >= 2 {
                        Some(&p[1..p.len() - 1])
                    } else {
                        None
                    }
                })
                .collect();
            if strs.len() == parts.len() {
                return Extracted::StrArray(strs);
            }
        }
    }
    if let Ok(n) = trimmed.parse::<f64>() {
        return Extracted::Num(n);
    }
    Extracted::Str(trimmed)
}

/// Parse an XMP numeric scalar (extracted from inside a JSON string value).
/// Returns `Num(n)` if the text parses cleanly, otherwise preserves the
/// original `Extracted` so the comparison still reports something useful.
fn parse_xmp_num<'a>(e: Option<&'a Extracted<'a>>) -> Option<Extracted<'a>> {
    e.and_then(|v| match v {
        Extracted::Str(s) => s.trim().parse::<f64>().ok().map(Extracted::Num),
        Extracted::Num(n) => Some(Extracted::Num(*n)),
        other => Some(other.clone()),
    })
}

/// Parse an XMP space-separated list of numbers into a `NumArray`. The raw
/// text comes from a JSON string value (the XMP field is unquoted text inside
/// the JSON).
fn parse_xmp_num_vec<'a>(e: Option<&'a Extracted<'a>>) -> Option<Extracted<'a>> {
    let s: &'a str = match e? {
        Extracted::Str(s) => s,
        Extracted::Num(n) => return Some(Extracted::NumArray(vec![*n])),
        Extracted::NumArray(a) => return Some(Extracted::NumArray(a.clone())),
        _ => return None,
    };
    let parts: Result<Vec<f64>, _> = s
        .split_whitespace()
        .map(|p| p.parse::<f64>())
        .collect();
    match parts {
        Ok(v) if !v.is_empty() => Some(Extracted::NumArray(v)),
        _ => Some(e?.clone()),
    }
}

/// Walk a dotted path by re-parsing keys from the root each time, since the
/// caller wants a typed value. (Simpler than threading state through the
/// per-segment search above.)
pub(crate) fn extract<'a>(json: &'a str, path: &str) -> Option<Extracted<'a>> {
    extract_path(json, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_num_array_match() {
        let a = Extracted::NumArray(vec![1.0, 2.0000001]);
        let b = Extracted::NumArray(vec![1.0, 2.0]);
        assert!(a.is_fuzzy_eq(&b, 1e-5));
    }

    #[test]
    fn fuzzy_num_array_mismatch() {
        let a = Extracted::NumArray(vec![1.0, 2.5]);
        let b = Extracted::NumArray(vec![1.0, 2.0]);
        assert!(!a.is_fuzzy_eq(&b, 1e-3));
    }

    #[test]
    fn extract_simple() {
        let json = r#"{"foo": 1.5, "bar": [1,2,3]}"#;
        assert_eq!(
            format!("{}", extract(json, "foo").unwrap()),
            "1.5"
        );
        let arr = extract(json, "bar").unwrap();
        assert_eq!(arr.distance(&Extracted::NumArray(vec![1.0, 2.0, 3.0])), 0.0);
    }

    #[test]
    fn extract_nested_object() {
        let json = r#"{"outer": {"inner": "v"}, "list": [1,2]}"#;
        assert_eq!(
            format!("{}", extract(json, "outer.inner").unwrap()),
            "v"
        );
    }

    #[test]
    fn extract_indented_python_json() {
        // Mirrors what `json.dump(indent=2)` produces on a single key.
        let json = "{\n  \"edr_scale\": 4.926108360290527,\n  \"family\": \"x7\"\n}";
        let v = extract(json, "edr_scale");
        assert!(v.is_some(), "edr_scale should be extractable");
        let v2 = extract(json, "family");
        assert!(v2.is_some(), "family should be extractable");
    }

    #[test]
    fn extract_nested_indented() {
        let json = "{\n  \"tmap_payloads\": {\n    \"apple_62\": {\n      \"md5\": \"abc\"\n    }\n  }\n}";
        let v = extract(json, "tmap_payloads.apple_62.md5");
        assert!(v.is_some(), "deeply nested should work");
        assert_eq!(format!("{}", v.unwrap()), "abc");
    }

    #[test]
    fn extract_real_py_file() {
        let path = std::path::Path::new("/tmp/py_55054.json");
        if !path.exists() {
            return;
        }
        let s = std::fs::read_to_string(path).unwrap();
        eprintln!("len={}", s.len());
        eprintln!("first 100 bytes: {:?}", &s[..100.min(s.len())]);
        let root = find_object_at_root(&s).unwrap();
        eprintln!("root len: {}", root.len());
        // Try to find a simple key
        for &k in &["schema", "implementation", "edr_scale", "family"] {
            let result = find_in_object(root, k);
            eprintln!("find {:?}: is_some={}", k, result.is_some());
            if let Some((v, _)) = result {
                eprintln!("  value = {:?}", v);
            }
        }
    }
}
