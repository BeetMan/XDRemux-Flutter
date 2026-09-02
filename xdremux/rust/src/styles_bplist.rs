//! Minimal binary plist writer for the style-metadata payload (R3c).
//!
//! Supports exactly the object kinds the style metadata needs:
//! bool / int (u64) / real (f64) / data / ASCII string / dict.

#[derive(Clone)]
enum Obj {
    Bool(bool),
    Int(u64),
    Real(f64),
    Data(Vec<u8>),
    Str(String),
    Dict(Vec<(usize, usize)>), // (key ref, value ref)
}

pub struct BplistWriter {
    objects: Vec<Obj>,
}

/// Validate the binary plist shape used by Apple Styles and locate its
/// `styleData` payload. The metadata contains several dictionaries and one
/// large Data object; requiring exactly 51,840 bytes catches truncated or
/// incorrectly grafted Styles outputs without depending on Apple's private
/// frameworks.
pub fn contains_data_object(payload: &[u8], expected_len: usize) -> bool {
    if payload.len() < 40 || &payload[..8] != b"bplist00" {
        return false;
    }
    let trailer = payload.len() - 32;
    let offset_size = payload[trailer + 6] as usize;
    let object_ref_size = payload[trailer + 7] as usize;
    let object_count = read_u64_be(&payload[trailer + 8..trailer + 16]);
    let offset_table = read_u64_be(&payload[trailer + 24..trailer + 32]) as usize;
    if offset_size == 0
        || offset_size > 8
        || object_ref_size == 0
        || object_ref_size > 8
        || object_count == 0
        || object_count > usize::MAX as u64
        || offset_table >= trailer
    {
        return false;
    }
    let object_count = object_count as usize;
    let table_len = match object_count.checked_mul(offset_size) {
        Some(v) => v,
        None => return false,
    };
    if offset_table.checked_add(table_len).unwrap_or(usize::MAX) > trailer {
        return false;
    }

    for index in 0..object_count {
        let at = offset_table + index * offset_size;
        let object_offset = read_sized_be(&payload[at..at + offset_size]);
        if object_offset >= offset_table || object_offset >= trailer {
            continue;
        }
        let marker = payload[object_offset];
        if marker >> 4 != 0x4 {
            continue;
        }
        let (length, header_len) = match plist_length(payload, object_offset) {
            Some(v) => v,
            None => continue,
        };
        if length == expected_len
            && object_offset
                .checked_add(header_len)
                .and_then(|start| start.checked_add(length))
                .map(|end| end <= offset_table)
                .unwrap_or(false)
        {
            return true;
        }
    }
    false
}

fn read_sized_be(bytes: &[u8]) -> usize {
    bytes.iter().fold(0usize, |value, byte| {
        value.saturating_mul(256).saturating_add(*byte as usize)
    })
}

fn read_u64_be(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0u64, |value, byte| {
        value.saturating_mul(256).saturating_add(*byte as u64)
    })
}

fn plist_length(payload: &[u8], object_offset: usize) -> Option<(usize, usize)> {
    let marker = payload[object_offset];
    let inline = (marker & 0x0f) as usize;
    if inline < 15 {
        return Some((inline, 1));
    }
    let int_marker = *payload.get(object_offset + 1)?;
    if int_marker >> 4 != 0x1 {
        return None;
    }
    let byte_count = 1usize.checked_shl((int_marker & 0x0f) as u32)?;
    let start = object_offset.checked_add(2)?;
    let end = start.checked_add(byte_count)?;
    if end > payload.len() {
        return None;
    }
    Some((read_sized_be(&payload[start..end]), 2 + byte_count))
}

impl BplistWriter {
    pub fn new() -> Self {
        Self {
            objects: Vec::new(),
        }
    }
    pub fn add_bool(&mut self, v: bool) -> usize {
        self.objects.push(Obj::Bool(v));
        self.objects.len() - 1
    }
    pub fn add_int(&mut self, v: u64) -> usize {
        self.objects.push(Obj::Int(v));
        self.objects.len() - 1
    }
    pub fn add_real(&mut self, v: f64) -> usize {
        self.objects.push(Obj::Real(v));
        self.objects.len() - 1
    }
    pub fn add_data(&mut self, v: &[u8]) -> usize {
        self.objects.push(Obj::Data(v.to_vec()));
        self.objects.len() - 1
    }
    pub fn add_str(&mut self, v: &str) -> usize {
        self.objects.push(Obj::Str(v.to_string()));
        self.objects.len() - 1
    }
    pub fn add_dict(&mut self, entries: &[(usize, usize)]) -> usize {
        self.objects.push(Obj::Dict(entries.to_vec()));
        self.objects.len() - 1
    }

    pub fn finish(&self, top: usize) -> Vec<u8> {
        // Object references must be addressable: 1 byte covers 255 objects,
        // but the stats-override path can exceed that, so widen dynamically.
        let object_ref_size = if self.objects.len() <= 0xff { 1 } else { 2 };
        let mut out = b"bplist00".to_vec();
        let mut offsets: Vec<u64> = Vec::with_capacity(self.objects.len());
        for obj in &self.objects {
            offsets.push(out.len() as u64);
            write_obj(&mut out, obj, object_ref_size);
        }
        let offset_table_offset = out.len() as u64;
        let max_offset = offset_table_offset + 8; // safe upper bound
        let offset_int_size = if max_offset <= 0xff {
            1u8
        } else if max_offset <= 0xffff {
            2
        } else {
            4
        };
        for off in &offsets {
            match offset_int_size {
                1 => out.push(*off as u8),
                2 => out.extend_from_slice(&(*off as u16).to_be_bytes()),
                _ => out.extend_from_slice(&(*off as u32).to_be_bytes()),
            }
        }
        // Trailer: 6 pad + offsetIntSize + objectRefSize + numObjects +
        // topObject + offsetTableOffset.
        out.extend_from_slice(&[0; 6]);
        out.push(offset_int_size);
        out.push(object_ref_size);
        out.extend_from_slice(&(self.objects.len() as u64).to_be_bytes());
        out.extend_from_slice(&(top as u64).to_be_bytes());
        out.extend_from_slice(&offset_table_offset.to_be_bytes());
        out
    }
}

fn write_len_prefixed(out: &mut Vec<u8>, marker_base: u8, len: usize) {
    if len < 15 {
        out.push(marker_base | len as u8);
    } else {
        out.push(marker_base | 0x0f);
        // length as an int object (inline, not registered)
        if len <= 0xff {
            out.push(0x10);
            out.push(len as u8);
        } else if len <= 0xffff {
            out.push(0x11);
            out.extend_from_slice(&(len as u16).to_be_bytes());
        } else {
            out.push(0x12);
            out.extend_from_slice(&(len as u32).to_be_bytes());
        }
    }
}

fn write_obj(out: &mut Vec<u8>, obj: &Obj, ref_size: u8) {
    match obj {
        Obj::Bool(false) => out.push(0x08),
        Obj::Bool(true) => out.push(0x09),
        Obj::Int(v) => {
            let bytes = if *v <= 0xff {
                1
            } else if *v <= 0xffff {
                2
            } else if *v <= 0xffff_ffff {
                4
            } else {
                8
            };
            let marker = 0x10
                | match bytes {
                    1 => 0,
                    2 => 1,
                    4 => 2,
                    _ => 3,
                };
            out.push(marker);
            out.extend_from_slice(&v.to_be_bytes()[8 - bytes..]);
        }
        Obj::Real(v) => {
            out.push(0x23);
            out.extend_from_slice(&v.to_be_bytes());
        }
        Obj::Data(v) => {
            write_len_prefixed(out, 0x40, v.len());
            out.extend_from_slice(v);
        }
        Obj::Str(s) => {
            debug_assert!(s.is_ascii());
            write_len_prefixed(out, 0x50, s.len());
            out.extend_from_slice(s.as_bytes());
        }
        Obj::Dict(entries) => {
            write_len_prefixed(out, 0xd0, entries.len());
            for (k, _) in entries {
                push_ref(out, *k, ref_size);
            }
            for (_, v) in entries {
                push_ref(out, *v, ref_size);
            }
        }
    }
}

fn push_ref(out: &mut Vec<u8>, index: usize, ref_size: u8) {
    match ref_size {
        1 => out.push(index as u8),
        _ => out.extend_from_slice(&(index as u16).to_be_bytes()),
    }
}
