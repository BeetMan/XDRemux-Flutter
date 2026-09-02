//! Validate the tiled Gain Map structure of HEIC files from the CLI.
fn main() {
    for path in std::env::args().skip(1) {
        let data = match std::fs::read(&path) {
            Ok(d) => d,
            Err(e) => {
                println!("{path}: read error {e}");
                continue;
            }
        };
        match xdremux_core::iso_validate::validate_gain_map_structure(&data) {
            Ok(s) => println!(
                "{path}: OK grid={}x{} tiles={} pixi_ch={} chroma_idc={} profile={}",
                s.columns, s.rows, s.tile_item_ids.len(), s.channel_count,
                s.chroma_format_idc, s.general_profile_idc
            ),
            Err(e) => println!("{path}: ERR {e}"),
        }
    }
}
