use std::env;
use std::path::Path;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: huawei_portrait_remux <input_huawei.heic> <output_apple_portrait.heic>");
        std::process::exit(1);
    }
    let input_path = Path::new(&args[1]);
    let output_path = Path::new(&args[2]);

    println!("Reading Huawei HEIC: {}", input_path.display());
    let source_bytes = std::fs::read(input_path).expect("failed to read source HEIC");

    println!("Running Huawei -> Apple Portrait remux...");
    let result_bytes = xdremux_core::run_huawei_portrait(&source_bytes)
        .expect("Huawei portrait remux failed");

    std::fs::write(output_path, &result_bytes).expect("failed to write output HEIC");
    println!(
        "Successfully wrote Apple Portrait HEIC to {} ({} bytes)",
        output_path.display(),
        result_bytes.len()
    );
}
