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
        let mut out = b"bplist00".to_vec();
        let mut offsets: Vec<u64> = Vec::with_capacity(self.objects.len());
        for obj in &self.objects {
            offsets.push(out.len() as u64);
            write_obj(&mut out, obj);
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
        out.push(1); // objectRefSize
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

fn write_obj(out: &mut Vec<u8>, obj: &Obj) {
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
                out.push(*k as u8);
            }
            for (_, v) in entries {
                out.push(*v as u8);
            }
        }
    }
}
