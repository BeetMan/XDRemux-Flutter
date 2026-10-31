//! Add the Photographic Styles companion tracks to an existing Live Photo MOV.
//! Usage: lp_style_tracks <paired_still.heic> <paired.mov> <out.mov> [off|thumbnail|info|full]
//! The still must already carry the Styles plist; the MOV keeps its pairing.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: lp_style_tracks <still.heic> <in.mov> <out.mov> [off|thumbnail|info|full]");
        std::process::exit(2);
    }
    let still = std::fs::read(&args[1]).unwrap();
    let mov = std::fs::read(&args[2]).unwrap();
    let level = match args.get(4) {
        Some(v) => xdremux_core::live_photo_styles::MovieStyleLevel::parse(v).unwrap_or_else(|| {
            eprintln!("unknown level {v}");
            std::process::exit(2);
        }),
        None => xdremux_core::live_photo_styles::MovieStyleLevel::Full,
    };
    println!("styles: {:?}", xdremux_core::live_photo_styles::read_still_styles(&still).map(|s| (
        s.baseline_exposure,
        s.key5,
        s.h,
        s.tone_curve.len(),
        s.texture
    )));
    match xdremux_core::live_photo_styles::attach_style_tracks(&mov, &still, level) {
        Ok(out) => {
            std::fs::write(&args[3], &out).unwrap();
            println!("OK level={level:?} mov={}B -> {}B", mov.len(), out.len());
            println!("pair valid: {}", xdremux_core::live_photo::existing_pair_is_valid(&still, &out));
        }
        Err(e) => {
            eprintln!("ERR: {e}");
            std::process::exit(1);
        }
    }
}
