//! Narrow relocation checks for Apple metadata, not arbitrary opaque blobs.
//! Plists containing Data/UID objects remain opaque. Scalar/container plists
//! use offsets relative to their own payload, never to the enclosing note.
fn number(bytes: &[u8]) -> Option<usize> {
    bytes
        .iter()
        .try_fold(0usize, |n, &b| n.checked_mul(256)?.checked_add(b as usize))
}
pub(crate) fn relocatable(tag: u16, payload: &[u8]) -> bool {
    // AEMatrix: the reference Apple JPEGs carry a 16x16 little-endian u16
    // numeric matrix, not a plist. Restrict to that observed 10-bit layout;
    // this is NOT an assertion about every historical/future tag-2 encoding.
    if tag == 2
        && payload.len() == 512
        && payload
            .chunks_exact(2)
            .all(|v| u16::from_le_bytes([v[0], v[1]]) <= 1023)
    {
        return true;
    }
    scalar_plist(payload)
}

fn scalar_plist(p: &[u8]) -> bool {
    parse(p).is_some()
}
fn parse(p: &[u8]) -> Option<()> {
    if p.len() < 40 || p.len() > 1024 * 1024 || p.get(..8)? != b"bplist00" {
        return None;
    }
    let tail = p.len() - 32;
    let os = p[tail + 6] as usize;
    let rs = p[tail + 7] as usize;
    if !(1..=8).contains(&os) || !(1..=8).contains(&rs) || p[tail..tail + 6].iter().any(|&b| b != 0)
    {
        return None;
    }
    let count = number(&p[tail + 8..tail + 16])?;
    let top = number(&p[tail + 16..tail + 24])?;
    let table = number(&p[tail + 24..])?;
    if count == 0
        || count > 4096
        || top >= count
        || table < 8
        || table.checked_add(count.checked_mul(os)?)? != tail
    {
        return None;
    }
    let offsets: Vec<usize> = (0..count)
        .map(|i| number(&p[table + i * os..table + (i + 1) * os]))
        .collect::<Option<_>>()?;
    let mut ordered = offsets.clone();
    ordered.sort_unstable();
    if ordered[0] < 8
        || ordered.last().copied()? >= table
        || ordered.windows(2).any(|v| v[0] == v[1])
    {
        return None;
    }
    let mut refs = vec![Vec::<usize>::new(); count];
    for (i, &at) in offsets.iter().enumerate() {
        let end = ordered.iter().copied().find(|&v| v > at).unwrap_or(table);
        let marker = p[at];
        let kind = marker >> 4;
        let small = (marker & 15) as usize;
        let mut start = at + 1;
        let size = match kind {
            0 if matches!(marker, 0x00 | 0x08 | 0x09 | 0x0f) => 0,
            1 if small <= 4 => 1usize << small,
            2 if matches!(small, 2 | 3) => 1usize << small,
            3 if small == 3 => 8,
            5 | 6 | 10 | 13 => {
                let len = if small == 15 {
                    let m = *p.get(start)?;
                    if m >> 4 != 1 || m & 15 > 3 {
                        return None;
                    }
                    let bytes = 1usize << (m & 15);
                    let value = number(p.get(start + 1..start + 1 + bytes)?)?;
                    start += 1 + bytes;
                    value
                } else {
                    small
                };
                let unit = match kind {
                    6 => 2,
                    10 => rs,
                    13 => rs.checked_mul(2)?,
                    _ => 1,
                };
                len.checked_mul(unit)?
            }
            _ => return None, // Data/UID/unknown: never assume safe relocation.
        };
        let stop = start.checked_add(size)?;
        if stop > end || p[stop..end].iter().any(|&b| b != 0 && b != 0x0f) {
            return None;
        }
        if kind == 5 && !p[start..stop].is_ascii() {
            return None;
        }
        if kind == 10 || kind == 13 {
            for r in p[start..stop].chunks_exact(rs) {
                let value = number(r)?;
                if value >= count {
                    return None;
                }
                refs[i].push(value);
            }
        }
    }
    // Reject cycles and pathological nesting, even in otherwise-valid tables.
    fn visit(i: usize, edges: &[Vec<usize>], state: &mut [u8], depth: usize) -> Option<()> {
        if depth > 64 || state[i] == 1 {
            return None;
        }
        if state[i] == 2 {
            return Some(());
        }
        state[i] = 1;
        for &child in &edges[i] {
            visit(child, edges, state, depth + 1)?;
        }
        state[i] = 2;
        Some(())
    }
    let mut state = vec![0; count];
    for i in 0..count {
        visit(i, &refs, &mut state, 0)?;
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::styles_bplist::BplistWriter;
    #[test]
    fn scalar_plists_are_self_relative_but_data_is_opaque() {
        let mut writer = BplistWriter::new();
        let key = writer.add_str("value");
        let value = writer.add_int(123);
        let top = writer.add_dict(&[(key, value)]);
        let bytes = writer.finish(top);
        assert!(relocatable(999, &bytes));
        for n in 0..bytes.len() {
            assert!(!relocatable(999, &bytes[..n]));
        }
        let mut writer = BplistWriter::new();
        let top = writer.add_data(&[1, 2, 3, 4, 5]);
        assert!(!relocatable(999, &writer.finish(top)));
        assert!(!relocatable(999, b"opaque pointers"));
    }
    #[test]
    fn matrix_matching_is_narrow() {
        assert!(relocatable(2, &[0; 512]));
        assert!(!relocatable(999, &[0; 512]));
        assert!(!relocatable(2, &[255; 512]));
        assert!(!relocatable(2, &[0; 510]));
    }
}
