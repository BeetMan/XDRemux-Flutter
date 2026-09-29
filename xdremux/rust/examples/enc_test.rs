use xdremux_core::hevc::{drop_parameter_nals, x265_encode_tiles};

fn main() {
    let w = 64u32;
    let h = 64u32;
    let rgb = vec![128u8; (w * h * 3) as usize];
    let refs: Vec<&[u8]> = vec![&rgb];
    let streams = x265_encode_tiles(&refs, w, h, 3, true).unwrap();
    let stream = &streams[0];
    println!("stream len {}", stream.len());
    let idr = drop_parameter_nals(stream);
    println!("after drop_nals len {}", idr.len());
    // full annex-B = parameter sets + slice (for ffprobe)
    let mut annex: Vec<u8> = Vec::new();
    let mut i = 0usize;
    while i + 4 <= stream.len() {
        let sc = if stream[i..i + 4] == [0, 0, 0, 1] { 4 } else if stream[i..i + 3] == [0, 0, 1] { 3 } else { i += 1; continue };
        let start = i + sc;
        i = start;
        let mut j = start;
        while j + 4 <= stream.len()
            && stream[j..j + 3] != [0, 0, 1]
            && stream[j..j + 4] != [0, 0, 0, 1]
        {
            j += 1;
        }
        let mut end = j;
        while end > start && stream[end - 1] == 0 {
            end -= 1;
        }
        let nal_type = (stream[start] >> 1) & 0x3f;
        println!("  NAL type {} len {}", nal_type, end - start);
        if matches!(nal_type, 32 | 33 | 34 | 19 | 20) {
            annex.extend_from_slice(&[0, 0, 0, 1]);
            annex.extend_from_slice(&stream[start..end]);
        }
        i = end;
    }
    println!("annex written {}", annex.len());
    std::fs::write("/tmp/enc.265", annex).unwrap();
}
