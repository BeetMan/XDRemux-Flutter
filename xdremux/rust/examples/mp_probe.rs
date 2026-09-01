use std::env;

fn main() {
    for path in env::args().skip(1) {
        let data = match std::fs::read(&path) {
            Ok(d) => d,
            Err(e) => {
                println!("{{\"file\":{:?},\"error\":{:?}}}", path, e.to_string());
                continue;
            }
        };
        match xdremux_core::motion_photo::parse_motion_photo(&data) {
            Ok(Some(asset)) => {
                let primary = xdremux_core::motion_photo::primary_video_range(&data, &asset);
                let name = std::path::Path::new(&path)
                    .file_name()
                    .unwrap()
                    .to_string_lossy();
                println!(
                    "{{\"file\":\"{}\",\"kind\":\"{}\",\"still\":[{},{}],\"video\":[{},{}],\"pts\":{},\"ptsSrc\":{},\"streams\":{},\"primary\":[{},{}]}}",
                    name,
                    asset.source_kind,
                    asset.still_range.start,
                    asset.still_range.end,
                    asset.video_range.start,
                    asset.video_range.end,
                    asset
                        .presentation_timestamp_us
                        .map(|v| v.to_string())
                        .unwrap_or("null".into()),
                    asset
                        .presentation_source
                        .map(|s| format!("\"{s}\""))
                        .unwrap_or("null".into()),
                    asset
                        .vendor_metadata
                        .as_ref()
                        .map(|m| m.stream_count)
                        .unwrap_or(0),
                    primary.start,
                    primary.end,
                );
            }
            Ok(None) => {
                let name = std::path::Path::new(&path)
                    .file_name()
                    .unwrap()
                    .to_string_lossy();
                println!("{{\"file\":\"{name}\",\"kind\":null}}");
            }
            Err(e) => {
                let name = std::path::Path::new(&path)
                    .file_name()
                    .unwrap()
                    .to_string_lossy();
                println!("{{\"file\":\"{}\",\"error\":{}}}", name, serde_json::json!(e));
            }
        }
    }
}
