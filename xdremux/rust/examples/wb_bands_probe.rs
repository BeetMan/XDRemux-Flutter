use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    let donor_path = &args[1];
    let returned_path = &args[2];
    let donor = std::fs::read(donor_path).unwrap();
    let returned = std::fs::read(returned_path).unwrap();

    let dimg = heif_oxide::decode_bytes(&donor).unwrap();
    let rimg = heif_oxide::decode_bytes(&returned).unwrap();
    println!("donor {}x{} returned {}x{}", dimg.width, dimg.height, rimg.width, rimg.height);

    let donor_rgba = dimg.to_rgba8();
    let bands = xdremux_core::watermark_codec::detect_frame_bands(&donor_rgba, dimg.width, dimg.height);
    println!("bands: {:?}", bands);

    // Simulate the composite on the returned raster and check band pixels.
    let mut ret = rimg.to_rgba8();
    if let Ok(bands) = &bands {
        let stride = dimg.width as usize * 4;
        for &(y0, y1) in bands {
            println!("copy band rows {}..{}", y0, y1);
            for row in y0..y1 {
                let start = row as usize * stride;
                ret[start..start + stride].copy_from_slice(&donor_rgba[start..start + stride]);
            }
        }
        // Sample a few pixels in the bottom band text row (y=4100)
        for y in [100u32, 4100, 4200, 4419] {
            let x = 2134usize;
            let base = y as usize * stride + x * 4;
            println!("y={y} x={x}: donor={:?} returned_after={:?}",
                &donor_rgba[base..base + 3], &ret[base..base + 3]);
        }
    }
}
