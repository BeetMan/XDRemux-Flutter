//! Read-only comparison probe; not a production decoder or conversion path.
use serde_json::json;
use sha2::{Digest, Sha256};

fn main() {
    for path in std::env::args().skip(1) {
        let data = match std::fs::read(&path) {
            Ok(data) => data,
            Err(error) => {
                println!("{}", json!({"path":path,"readError":error.to_string()}));
                continue;
            }
        };
        let mut report = json!({"path":path,"coreVersion":env!("CARGO_PKG_VERSION"),
            "nativeFeature":cfg!(feature="libheif-decoder")});
        if data.starts_with(&[0xff, 0xd8]) {
            report["ultraHdr"] = match xdremux_core::uhdr_jpeg::parse(&data) {
                Ok(Some(info)) => json!({"parseAccepted":true,
                    "useBaseColorSpace":info.use_base_color_space,
                    "gainmapBytes":info.gainmap_jpeg.len(),"metaFloats":info.meta_floats}),
                Ok(None) => json!({"parseAccepted":false}),
                Err(error) => json!({"parseAccepted":false,"error":error}),
            };
        } else {
            report["productionSdrDecode"] = match xdremux_core::sdr_source::decode_to_rgb(&data) {
                Ok((pixels, width, height, oriented)) => json!({"success":true,
                    "pixelsSha256":format!("{:x}", Sha256::digest(&pixels)),
                    "width":width,"height":height,"bytes":pixels.len(),"oriented":oriented}),
                Err(error) => json!({"success":false,"error":error}),
            };
            report["decode"] = match heif_oxide::decode_bytes(&data) {
                Ok(image) => json!({"success":true,"width":image.width,"height":image.height}),
                Err(error) => json!({"success":false,"error":format!("{error:?}")}),
            };
        }
        println!("{report}");
    }
}
