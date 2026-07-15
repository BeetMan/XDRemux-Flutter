//! Cross-implementation conformance harness for XDRemux.
//!
//! Subcommands:
//! - `inspect <input.heic> <output.json>` — emit canonical JSON describing
//!   the source file's LHDR/UHDR metadata and the tmap payloads that would
//!   be produced.
//! - `compare <a.json> <b.json> [--tolerance 1e-6]` — diff two inspect
//!   outputs and print a Markdown report.
//! - `dump <output.heic> <output.json>` — emit canonical JSON describing
//!   the output file's ISOBMFF box structure (Tier 3).
//! - `compare-dump <a.json> <b.json>` — diff two dump outputs and print
//!   a Markdown report.

use std::path::PathBuf;
use std::process::ExitCode;

mod compare;
mod compare_dump;
mod convert;
mod dump;
mod inspect;
mod json;

const USAGE: &str = "\
Usage:
  xdremux-conformance inspect <input.heic> <output.json>
  xdremux-conformance compare <a.json> <b.json> [--tolerance <f32>]
  xdremux-conformance dump <output.heic> <output.json>
  xdremux-conformance compare-dump <a.json> <b.json>
  xdremux-conformance convert <input.heic> <output.heic> [--oppo-compat <0|1|2|3>]

Options:
  --tolerance <f32>   Numeric tolerance for compare (default 1e-6)
  --oppo-compat <N>   OPPO compatibility mode: 0=off, 1=auto, 2=on, 3=tail (default 0)
  -h, --help          Show this help
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    }

    match args[1].as_str() {
        "-h" | "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        "inspect" => cmd_inspect(&args[2..]),
        "compare" => cmd_compare(&args[2..]),
        "dump" => cmd_dump(&args[2..]),
        "compare-dump" => cmd_compare_dump(&args[2..]),
        "convert" => cmd_convert(&args[2..]),
        other => {
            eprintln!("unknown subcommand: {other}");
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn cmd_inspect(args: &[String]) -> ExitCode {
    if args.len() != 2 {
        eprintln!("inspect: expected <input.heic> <output.json>");
        return ExitCode::from(2);
    }
    let input = PathBuf::from(&args[0]);
    let output = PathBuf::from(&args[1]);
    if let Err(e) = inspect::run(&input, &output, "rust") {
        eprintln!("inspect: {e}");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

fn cmd_compare(args: &[String]) -> ExitCode {
    if args.len() < 2 {
        eprintln!("compare: expected <a.json> <b.json> [--tolerance <f32>]");
        return ExitCode::from(2);
    }
    let mut tolerance: f32 = 1e-6;
    let mut positional: Vec<&str> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--tolerance" => {
                if i + 1 >= args.len() {
                    eprintln!("compare: --tolerance needs a value");
                    return ExitCode::from(2);
                }
                tolerance = match args[i + 1].parse() {
                    Ok(t) => t,
                    Err(e) => {
                        eprintln!("compare: invalid tolerance '{}': {e}", args[i + 1]);
                        return ExitCode::from(2);
                    }
                };
                i += 2;
            }
            a if a.starts_with("--") => {
                eprintln!("compare: unknown flag {a}");
                return ExitCode::from(2);
            }
            _ => {
                positional.push(a);
                i += 1;
            }
        }
    }
    if positional.len() != 2 {
        eprintln!("compare: expected 2 JSON files, got {}", positional.len());
        return ExitCode::from(2);
    }
    let a = PathBuf::from(positional[0]);
    let b = PathBuf::from(positional[1]);
    let report = match compare::run(&a, &b, tolerance) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("compare: {e}");
            return ExitCode::from(1);
        }
    };
    print!("{report}");
    // Exit 0 if there are no differences, 1 otherwise.
    if report.contains("differences: 0\n") {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

fn cmd_dump(args: &[String]) -> ExitCode {
    if args.len() != 2 {
        eprintln!("dump: expected <output.heic> <output.json>");
        return ExitCode::from(2);
    }
    let input = PathBuf::from(&args[0]);
    let output = PathBuf::from(&args[1]);
    if let Err(e) = dump::run(&input, &output, "rust") {
        eprintln!("dump: {e}");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

fn cmd_compare_dump(args: &[String]) -> ExitCode {
    if args.len() != 2 {
        eprintln!("compare-dump: expected <a.json> <b.json>");
        return ExitCode::from(2);
    }
    let a = PathBuf::from(&args[0]);
    let b = PathBuf::from(&args[1]);
    let report = match compare_dump::run(&a, &b) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("compare-dump: {e}");
            return ExitCode::from(1);
        }
    };
    print!("{report}");
    // Exit 0 if all match, 1 otherwise.
    if report.contains("✓ All structural elements match!") {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

fn cmd_convert(args: &[String]) -> ExitCode {
    let mut oppo_compat: u8 = 0;
    let mut positional: Vec<&str> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--oppo-compat" => {
                if i + 1 >= args.len() {
                    eprintln!("convert: --oppo-compat needs a value (0-3)");
                    return ExitCode::from(2);
                }
                oppo_compat = match args[i + 1].parse() {
                    Ok(c) if c <= 3 => c,
                    _ => {
                        eprintln!("convert: --oppo-compat must be 0-3");
                        return ExitCode::from(2);
                    }
                };
                i += 2;
            }
            a if a.starts_with("--") => {
                eprintln!("convert: unknown flag {a}");
                return ExitCode::from(2);
            }
            _ => {
                positional.push(a);
                i += 1;
            }
        }
    }
    if positional.len() != 2 {
        eprintln!("convert: expected <input.heic> <output.heic>");
        return ExitCode::from(2);
    }
    let input = PathBuf::from(positional[0]);
    let output = PathBuf::from(positional[1]);
    if let Err(e) = convert::run(&input, &output, oppo_compat) {
        eprintln!("convert: {e}");
        return ExitCode::from(1);
    }
    println!("wrote {}", output.display());
    ExitCode::SUCCESS
}
