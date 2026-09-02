//! Build a Live Photo pair from a styled still + an extracted motion video.
//! Usage: lp_pair <still.heic> <motion.mp4> <out_still.heic> <out.mov> [source.jpg]
//! If source.jpg is given, presentation pts + OPPO vendor metadata are read
//! from the original Motion Photo container.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: lp_pair <still.heic> <motion.mp4> <out_still.heic> <out.mov> [source.jpg]");
        std::process::exit(2);
    }
    let still = std::fs::read(&args[1]).unwrap();
    let video = std::fs::read(&args[2]).unwrap();
    let mut pts: Option<i64> = None;
    let mut oppo: Option<xdremux_core::motion_photo::OppoMetadata> = None;
    if let Some(src) = args.get(5) {
        let data = std::fs::read(src).unwrap();
        if let Ok(Some(asset)) = xdremux_core::motion_photo::parse_motion_photo(&data) {
            pts = asset.presentation_timestamp_us;
            oppo = asset.vendor_metadata.clone();
        }
    }
    match xdremux_core::live_photo::make_live_photo(&still, &video, pts, oppo.as_ref()) {
        Ok((still_out, mov, id)) => {
            std::fs::write(&args[3], &still_out).unwrap();
            std::fs::write(&args[4], &mov).unwrap();
            println!("OK content_id={id} still={}B mov={}B", still_out.len(), mov.len());
            println!("still cid present: {}", xdremux_core::live_photo::read_still_content_identifier(&still_out).is_some());
            println!("movie cid present: {}", xdremux_core::live_photo::read_movie_content_identifier(&mov).is_some());
            println!("pair valid: {}", xdremux_core::live_photo::existing_pair_is_valid(&still_out, &mov));
        }
        Err(e) => { eprintln!("ERR: {e}"); std::process::exit(1); }
    }
}
