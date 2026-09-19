// SDR JPEG → standard HEIC via the Ultra HDR pipeline with identity gain map.
use xdremux_core::uhdr_jpeg;

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 3 { return Err("usage: sdr_convert <jpeg> <out-heic>".into()); }
    let jpeg = std::fs::read(&a[1]).map_err(|e| format!("read: {e}"))?;
    let info = uhdr_jpeg::parse(&jpeg)?.ok_or("not a JPEG")?;
    println!("gainmap_jpeg {}B, meta_floats {}",
        info.gainmap_jpeg.len(), info.meta_floats.len());
    let synth = uhdr_jpeg::synthesize_source_container(&jpeg, &info, false)?;
    println!("synthesized container {}B", synth.len());
    // Now the standard pipeline: prepare + assemble would work on this.
    // For testing, just save the synthesized container.
    std::fs::write(&a[2], synth).map_err(|e| format!("write: {e}"))?;
    println!("OK {} -> {}", a[1], a[2]);
    Ok(())
}
