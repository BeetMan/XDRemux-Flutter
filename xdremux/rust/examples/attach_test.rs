use xdremux_core::styles_attach::attach_styles;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 { return Err("usage: attach_test <in> <out>".into()); }
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    match attach_styles(&data, 104) {
        Ok((patched, report)) => {
            std::fs::write(&args[2], patched).map_err(|e| format!("write: {e}"))?;
            println!("status={:?} added={:?}", report.status, report.added);
            Ok(())
        }
        Err(e) => { println!("ATTACH ERROR: {e}"); Err(e) }
    }
}
