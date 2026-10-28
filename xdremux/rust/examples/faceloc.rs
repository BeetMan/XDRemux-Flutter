fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let (rgb, w, h, _) = xdremux_core::sdr_source::decode_to_rgb(&bytes).unwrap();
    let img = xdremux_core::person_stats::RgbImage { pixels: &rgb, width: w, height: h };
    // 8x8 grid of skin-pixel density
    let mut g = [[0u32; 8]; 8];
    let mut n = [[0u32; 8]; 8];
    for y in 0..h { for x in 0..w {
        let p = img.at(x, y);
        let (r,g_,b) = (p[0] as f64, p[1] as f64, p[2] as f64);
        let mx = r.max(g_).max(b); let mn = r.min(g_).min(b);
        let skin = mx>0.2 && (mx-mn)<0.25 && r>g_ && g_>b;
        let (gx, gy) = ((x * 8 / w) as usize, (y * 8 / h) as usize);
        n[gy][gx] += 1;
        if skin { g[gy][gx] += 1; }
    }}
    println!("肤色密度 (8x8, {}x{}):", w, h);
    for gy in 0..8 { print!("  "); for gx in 0..8 {
        let d = if n[gy][gx]>0 { g[gy][gx] as f64 / n[gy][gx] as f64 } else {0.0};
        print!("{:4.0}%", d*100.0);
    } println!(); }
    // 找最密集格
    let mut best = (0,0,0.0);
    for gy in 0..8 { for gx in 0..8 {
        let d = if n[gy][gx]>0 { g[gy][gx] as f64 / n[gy][gx] as f64 } else {0.0};
        if d > best.2 { best = (gx, gy, d); }
    }}
    println!("最密格: col={} row={} -> 中心 x={:.3} y={:.3}", best.0, best.1, (best.0 as f64+0.5)/8.0, (best.1 as f64+0.5)/8.0);
}
