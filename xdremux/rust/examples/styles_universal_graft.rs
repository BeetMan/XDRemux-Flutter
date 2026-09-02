//! Graft a universal-model-predicted style state into a converted HEIC.
//!
//! Input state file layout (produced by /tmp/univ_style_predict.py, mirroring
//! the upstream universal_photographic_style adapter):
//!   [key1 51840 B f16 LE][uncertainty f32][gtc 516 B u8]
//!   [lightmaps 2x2048 B f16][scalars 6x f16: TagH,min,max,gain,Tag4,Tag5]
//!
//! Usage: cargo run -p xdremux-core --release --example styles_universal_graft -- \
//!   <converted.heic> <state.bin> <output.heic>
use xdremux_core::isobmff;
use xdremux_core::styles_native::{replace_style_metadata, StyleStateOverride};

fn f16_to_f32(h: u16) -> f32 {
    let s = ((h >> 15) & 1) as i32;
    let e = ((h >> 10) & 0x1f) as i32;
    let m = (h & 0x3ff) as i32;
    let v = if e == 0 {
        (m as f32) / 1024.0 * 2f32.powi(-14)
    } else {
        (1.0 + (m as f32) / 1024.0) * 2f32.powi(e - 15)
    };
    if s == 1 { -v } else { v }
}

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let key1_only = args.iter().any(|a| a == "--key1-only");
    let positional: Vec<&String> = args.iter().skip(1).filter(|a| !a.starts_with("--")).collect();
    if positional.len() != 3 {
        return Err("usage: styles_universal_graft <in.heic> <state.bin> <out.heic> [--key1-only]".into());
    }
    let heic = std::fs::read(positional[0]).map_err(|e| e.to_string())?;
    let state_bin = std::fs::read(positional[1]).map_err(|e| e.to_string())?;
    let v2 = state_bin.len() == 56468 + 72 + 12;
    if state_bin.len() != 56468 && !v2 {
        return Err(format!(
            "state bin size {} != expected 56468 (v1) or 56552 (v2)",
            state_bin.len()
        ));
    }
    let mut pos = 0usize;
    let key1 = state_bin[pos..pos + 51840].to_vec();
    pos += 51840;
    let uncertainty = f32::from_le_bytes(state_bin[pos..pos + 4].try_into().unwrap());
    pos += 4;
    let gtc = state_bin[pos..pos + 516].to_vec();
    pos += 516;
    let light_c = state_bin[pos..pos + 2048].to_vec();
    pos += 2048;
    let light_d = state_bin[pos..pos + 2048].to_vec();
    pos += 2048;
    let tail = &state_bin[pos..];
    let (stats, key7): (Vec<f32>, [f32; 3]) = if v2 && tail.len() >= 96 {
        // tail = [scalars 12B][stats 72B][key7 12B]
        let s: Vec<f32> = tail[12..84]
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();
        let k: [f32; 3] = tail[84..96]
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect::<Vec<f32>>()
            .try_into()
            .unwrap();
        (s, k)
    } else {
        (vec![], [0.0; 3])
    };
    let scalars: Vec<f32> = state_bin[pos..pos + 12]
        .chunks_exact(2)
        .map(|c| f16_to_f32(u16::from_le_bytes([c[0], c[1]])))
        .collect();

    let mut predicted = StyleStateOverride {
        key0: 16,
        key1,
        gtc,
        tag4: scalars[4] as f64,
        tag5: scalars[5].round() as u64,
        light_c,
        light_d,
        tag_h: scalars[0] as f64,
        range_min: scalars[1] as f64,
        range_max: scalars[2] as f64,
        gain: scalars[3] as f64,
        key7: None,
        stats: None,
    };
    if !stats.is_empty() {
        predicted.stats = Some(vec![
            ("ToneMappedImage", [
                stats[0] as f64, stats[1] as f64, stats[2] as f64, stats[3] as f64,
                stats[4] as f64, stats[5] as f64, stats[6] as f64, stats[7] as f64,
                stats[8] as f64,
            ]),
            ("LinearImage", [
                stats[9] as f64, stats[10] as f64, stats[11] as f64, stats[12] as f64,
                stats[13] as f64, stats[14] as f64, stats[15] as f64, stats[16] as f64,
                stats[17] as f64,
            ]),
        ]);
        predicted.key7 = Some(xdremux_core::styles_native::SemanticFlags {
            people_ratio: key7[0] as f64,
            skin_ratio: key7[1] as f64,
            person_masks_valid_hint: key7[2] as f64,
        });
    }
    // Bisect mode: keep the golden reference for everything except key1, to
    // isolate which predicted field Photos rejects.
    let state = if key1_only {
        let mut s = StyleStateOverride::identity();
        s.key0 = predicted.key0;
        s.key1 = predicted.key1;
        s
    } else {
        predicted
    };
    eprintln!(
        "predicted state: uncertainty={uncertainty:.4} tag4={} tag5={} tag_h={:.4} \
         range=({:.4},{:.4}) gain={:.4}",
        state.tag4, state.tag5, state.tag_h, state.range_min, state.range_max, state.gain
    );

    // Sanity: confirm the input actually carries a styleMetadata item before
    // rewriting anything.
    let parsed = isobmff::parse_source_meta(&heic).map_err(|e| e.to_string())?;
    if !parsed
        .items
        .iter()
        .any(|i| i.raw_infe.windows(13).any(|w| w == b"styleMetadata"))
    {
        return Err("input has no styleMetadata item (convert with styles enabled first)"
            .into());
    }

    let out = replace_style_metadata(&heic, &state)?;
    std::fs::write(positional[2], out).map_err(|e| e.to_string())?;
    eprintln!("written {}", positional[2]);
    Ok(())
}
