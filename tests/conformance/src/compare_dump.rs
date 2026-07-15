//! Tier 3: Compare two ISOBMFF structural dumps.
//!
//! Compares the canonical JSON representations of two output HEIC files
//! and produces a Markdown report highlighting structural differences.

use std::fs;
use std::path::Path;

/// Run the compare-dump subcommand and return a Markdown report.
pub fn run<P1: AsRef<Path>, P2: AsRef<Path>>(a: P1, b: P2) -> Result<String, String> {
    let a_json = fs::read_to_string(a.as_ref())
        .map_err(|e| format!("cannot read {}: {e}", a.as_ref().display()))?;
    let b_json = fs::read_to_string(b.as_ref())
        .map_err(|e| format!("cannot read {}: {e}", b.as_ref().display()))?;

    compare_str(&a_json, &b_json)
}

/// Compare two JSON strings and return a Markdown report.
pub fn compare_str(a_json: &str, b_json: &str) -> Result<String, String> {
    let a: serde_json::Value = serde_json::from_str(a_json)
        .map_err(|e| format!("cannot parse A JSON: {e}"))?;
    let b: serde_json::Value = serde_json::from_str(b_json)
        .map_err(|e| format!("cannot parse B JSON: {e}"))?;

    let mut report = String::new();
    report.push_str("# ISOBMFF Structure Comparison Report\n\n");

    // Compare schema versions
    let a_schema = a.get("schema").and_then(|v| v.as_str()).unwrap_or("");
    let b_schema = b.get("schema").and_then(|v| v.as_str()).unwrap_or("");
    if a_schema != b_schema {
        report.push_str(&format!("⚠ Schema version mismatch: A={}, B={}\n\n", a_schema, b_schema));
    }

    // Compare ftyp
    let a_ftyp = a.get("ftyp");
    let b_ftyp = b.get("ftyp");
    if a_ftyp != b_ftyp {
        report.push_str("## ftyp differences\n\n");
        report.push_str(&format!("- A: {}\n", serde_json::to_string_pretty(&a_ftyp).unwrap_or_default()));
        report.push_str(&format!("- B: {}\n\n", serde_json::to_string_pretty(&b_ftyp).unwrap_or_default()));
    } else {
        report.push_str("✓ ftyp: identical\n\n");
    }

    // Compare meta
    let a_meta = a.get("meta");
    let b_meta = b.get("meta");

    // Compare pitm
    let a_pitm = a_meta.and_then(|m| m.get("pitm"));
    let b_pitm = b_meta.and_then(|m| m.get("pitm"));
    if a_pitm != b_pitm {
        report.push_str(&format!("## pitm differences\n\n- A: {:?}\n- B: {:?}\n\n", a_pitm, b_pitm));
    } else {
        report.push_str(&format!("✓ pitm: {:?}\n\n", a_pitm));
    }

    // Compare iinf
    let a_iinf = a_meta.and_then(|m| m.get("iinf")).and_then(|v| v.as_array());
    let b_iinf = b_meta.and_then(|m| m.get("iinf")).and_then(|v| v.as_array());
    if a_iinf != b_iinf {
        report.push_str("## iinf differences\n\n");
        let a_count = a_iinf.map(|v| v.len()).unwrap_or(0);
        let b_count = b_iinf.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("- A: {} items\n", a_count));
        report.push_str(&format!("- B: {} items\n\n", b_count));

        // Show first few items that differ
        if let (Some(a_items), Some(b_items)) = (a_iinf, b_iinf) {
            for (i, (a_item, b_item)) in a_items.iter().zip(b_items.iter()).enumerate() {
                if a_item != b_item {
                    report.push_str(&format!("Item {} differs:\n- A: {}\n- B: {}\n\n", i, a_item, b_item));
                    if i >= 5 {
                        report.push_str("... (more differences omitted)\n\n");
                        break;
                    }
                }
            }
        }
    } else {
        let count = a_iinf.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("✓ iinf: {} items, identical\n\n", count));
    }

    // Compare iref
    let a_iref = a_meta.and_then(|m| m.get("iref")).and_then(|v| v.as_array());
    let b_iref = b_meta.and_then(|m| m.get("iref")).and_then(|v| v.as_array());
    if a_iref != b_iref {
        report.push_str("## iref differences\n\n");
        let a_count = a_iref.map(|v| v.len()).unwrap_or(0);
        let b_count = b_iref.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("- A: {} references\n", a_count));
        report.push_str(&format!("- B: {} references\n\n", b_count));
    } else {
        let count = a_iref.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("✓ iref: {} references, identical\n\n", count));
    }

    // Compare ipco
    let a_ipco = a_meta.and_then(|m| m.get("ipco")).and_then(|v| v.as_array());
    let b_ipco = b_meta.and_then(|m| m.get("ipco")).and_then(|v| v.as_array());
    if a_ipco != b_ipco {
        report.push_str("## ipco differences\n\n");
        let a_count = a_ipco.map(|v| v.len()).unwrap_or(0);
        let b_count = b_ipco.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("- A: {} properties\n", a_count));
        report.push_str(&format!("- B: {} properties\n\n", b_count));
    } else {
        let count = a_ipco.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("✓ ipco: {} properties, identical\n\n", count));
    }

    // Compare ipma
    let a_ipma = a_meta.and_then(|m| m.get("ipma")).and_then(|v| v.as_array());
    let b_ipma = b_meta.and_then(|m| m.get("ipma")).and_then(|v| v.as_array());
    if a_ipma != b_ipma {
        report.push_str("## ipma differences\n\n");
        let a_count = a_ipma.map(|v| v.len()).unwrap_or(0);
        let b_count = b_ipma.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("- A: {} associations\n", a_count));
        report.push_str(&format!("- B: {} associations\n\n", b_count));
    } else {
        let count = a_ipma.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("✓ ipma: {} associations, identical\n\n", count));
    }

    // Compare iloc
    let a_iloc = a_meta.and_then(|m| m.get("iloc")).and_then(|v| v.as_array());
    let b_iloc = b_meta.and_then(|m| m.get("iloc")).and_then(|v| v.as_array());
    if a_iloc != b_iloc {
        report.push_str("## iloc differences\n\n");
        let a_count = a_iloc.map(|v| v.len()).unwrap_or(0);
        let b_count = b_iloc.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("- A: {} entries\n", a_count));
        report.push_str(&format!("- B: {} entries\n\n", b_count));
    } else {
        let count = a_iloc.map(|v| v.len()).unwrap_or(0);
        report.push_str(&format!("✓ iloc: {} entries, identical\n\n", count));
    }

    // Summary
    let all_match = a_ftyp == b_ftyp
        && a_pitm == b_pitm
        && a_iinf == b_iinf
        && a_iref == b_iref
        && a_ipco == b_ipco
        && a_ipma == b_ipma
        && a_iloc == b_iloc;

    if all_match {
        report.push_str("## Summary\n\n✓ All structural elements match!\n");
    } else {
        report.push_str("## Summary\n\n⚠ Structural differences detected. See above for details.\n");
    }

    Ok(report)
}
