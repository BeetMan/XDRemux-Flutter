fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 3 {
        let still = std::fs::read(&args[1]).expect("read still");
        let mov = std::fs::read(&args[2]).expect("read mov");
        let still_cid = xdremux_core::live_photo::read_still_content_identifier(&still);
        let mov_cid = xdremux_core::live_photo::read_movie_content_identifier(&mov);
        let valid = xdremux_core::live_photo::existing_pair_is_valid(&still, &mov);
        println!("Still CID:  {:?}", still_cid);
        println!("Mov CID:    {:?}", mov_cid);
        println!("Pair valid: {}", valid);
        return;
    }
    let source = std::fs::read("/Users/beet/Downloads/动态照片/大师 3x.jpg").unwrap();
    let still = std::fs::read("/tmp/lp-final3/大师 3x_iso.heic").unwrap();
    let asset = xdremux_core::motion_photo::parse_motion_photo(&source).unwrap().unwrap();
    let primary = xdremux_core::motion_photo::primary_video_range(&source, &asset);
    let clean_len = xdremux_core::motion_photo::standalone_bmff_length(&source[primary.start as usize..primary.end as usize]).unwrap();
    let video = &source[primary.start as usize..primary.start as usize + clean_len];
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        xdremux_core::live_photo::make_live_photo(
            &still, video, asset.presentation_timestamp_us, asset.vendor_metadata.as_ref(),
        )
    }));
    match r {
        Ok(Ok((s, m, id))) => println!("OK still={} mov={} id={}", s.len(), m.len(), id),
        Ok(Err(e)) => println!("ERR: {e}"),
        Err(p) => println!("PANIC: {:?}", p.downcast::<String>().map(|s| *s).or_else(|p| p.downcast::<&str>().map(|s| s.to_string()))),
    }
}
