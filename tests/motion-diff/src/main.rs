//! Motion Photo parser differential: `xdremux-core` vs LibLivePhoto.
//!
//! Runs both parsers on the same bytes and compares what each reports:
//! whether the file is a Motion Photo, the still byte range, the primary
//! video byte range and the presentation time. The two sides name formats
//! differently, so `kind` is printed for review but not compared.
//!
//! Directories are walked recursively; only JPEG / HEIC / HEIF / AVIF files
//! are read. Apple HEIC+MOV pairs are out of scope: `parse_motion_photo`
//! only takes single files.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use liblivephoto::{Input, MediaTime, MotionPhoto, MotionPhotoReadError, ParseOptions};
use serde_json::{json, Value};
use xdremux_core::motion_photo::{parse_motion_photo, primary_video_range, standalone_bmff_length};

const USAGE: &str = "\
Usage:
  xdremux-motion-diff [--json] <file-or-dir>...

Compares xdremux-core motion_photo with LibLivePhoto (compatible mode) on
every .jpg/.jpeg/.heic/.heif/.avif file. Exit code 1 when any file differs.
";

const EXTENSIONS: &[&str] = &["jpg", "jpeg", "heic", "heif", "avif"];

/// What one parser reported for one file.
#[derive(Debug, Default)]
struct Side {
    /// "motion", "ordinary" or "error".
    status: &'static str,
    kind: String,
    still: Option<(u64, u64)>,
    video: Option<(u64, u64)>,
    pts_us: Option<i64>,
    note: Option<String>,
}

impl Side {
    fn plain(status: &'static str, note: Option<String>) -> Self {
        Self {
            status,
            note,
            ..Self::default()
        }
    }

    fn to_json(&self) -> Value {
        json!({
            "status": self.status,
            "kind": self.kind,
            "still": self.still.map(|(s, e)| [s, e]),
            "video": self.video.map(|(s, e)| [s, e]),
            "ptsUs": self.pts_us,
            "note": self.note,
        })
    }

    fn summary(&self) -> String {
        let range = |r: Option<(u64, u64)>| r.map_or("-".to_string(), |(s, e)| format!("{s}..{e}"));
        let mut text = format!(
            "{} {} still={} video={} pts={}",
            self.status,
            if self.kind.is_empty() {
                "-"
            } else {
                &self.kind
            },
            range(self.still),
            range(self.video),
            self.pts_us.map_or("-".to_string(), |v| v.to_string()),
        );
        if let Some(note) = &self.note {
            text.push_str(&format!(" ({note})"));
        }
        text
    }
}

fn ours(data: &[u8]) -> Side {
    match catch_unwind(AssertUnwindSafe(|| parse_motion_photo(data))) {
        Err(_) => Side::plain("error", Some("panic".into())),
        Ok(Err(e)) => Side::plain("error", Some(e)),
        Ok(Ok(None)) => Side::plain("ordinary", None),
        Ok(Ok(Some(asset))) => {
            // Compare the movie the Live Photo converter feeds to the remux
            // (`xdremux_make_live_photo`): the primary stream of an OPPO
            // dual-stream file, cut after its last complete BMFF box.
            let primary = primary_video_range(data, &asset);
            let mut notes = Vec::new();
            if primary != asset.video_range {
                notes.push(format!(
                    "full video {}..{}",
                    asset.video_range.start, asset.video_range.end
                ));
            }
            let raw = &data[primary.start as usize..primary.end as usize];
            let end = match standalone_bmff_length(raw) {
                Ok(len) => primary.start + len as u64,
                Err(e) => {
                    notes.push(format!("standalone_bmff_length: {e}"));
                    primary.end
                }
            };
            if end != primary.end {
                notes.push(format!("raw primary ends {}", primary.end));
            }
            Side {
                status: "motion",
                kind: asset.source_kind.clone(),
                still: Some((asset.still_range.start, asset.still_range.end)),
                video: Some((primary.start, end)),
                pts_us: asset.presentation_timestamp_us,
                note: (!notes.is_empty()).then(|| notes.join(", ")),
            }
        }
    }
}

fn theirs(data: &[u8]) -> (Side, Vec<String>) {
    let parsed = catch_unwind(AssertUnwindSafe(|| {
        MotionPhoto::parse(Input::SingleFile(data), ParseOptions::compatible()).map(|photo| {
            let asset = photo.asset();
            let still = &photo.still().extents;
            let video = &photo.motion_video().extents;
            let extents =
                |name: &str, n: usize| (n != 1).then(|| format!("{name} has {n} extents"));
            let note = [extents("still", still.len()), extents("video", video.len())]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            let side = Side {
                status: "motion",
                kind: format!("{:?}/{:?}", asset.format, asset.dialect),
                still: single_extent(still),
                video: single_extent(video),
                pts_us: photo.presentation_time().map(microseconds),
                note: (!note.is_empty()).then(|| note.join(", ")),
            };
            let diagnostics = photo
                .diagnostics()
                .iter()
                .map(|d| format!("{d:?}"))
                .collect();
            (side, diagnostics)
        })
    }));
    match parsed {
        Err(_) => (Side::plain("error", Some("panic".into())), Vec::new()),
        Ok(Ok(result)) => result,
        Ok(Err(MotionPhotoReadError::Unrecognized)) => (Side::plain("ordinary", None), Vec::new()),
        Ok(Err(e)) => (Side::plain("error", Some(e.to_string())), Vec::new()),
    }
}

fn single_extent(extents: &[liblivephoto::ByteRange]) -> Option<(u64, u64)> {
    match extents {
        [only] => Some((only.lower_bound, only.upper_bound)),
        _ => None,
    }
}

/// Rounded to the nearest microsecond when the timescale does not divide.
fn microseconds(time: MediaTime) -> i64 {
    if let Some(exact) = time.rescale_exact(1_000_000) {
        return exact.value;
    }
    let scaled = i128::from(time.value) * 1_000_000;
    let half = i128::from(time.timescale) / 2;
    let rounded = if scaled >= 0 {
        scaled + half
    } else {
        scaled - half
    };
    (rounded / i128::from(time.timescale)) as i64
}

/// Fields on which the two sides disagree.
fn differences(a: &Side, b: &Side) -> Vec<&'static str> {
    if a.status != b.status {
        return vec!["status"];
    }
    if a.status != "motion" {
        return Vec::new();
    }
    let mut out = Vec::new();
    if a.still != b.still {
        out.push("still");
    }
    if a.video != b.video {
        out.push("video");
    }
    if a.pts_us != b.pts_us {
        out.push("pts");
    }
    out
}

fn collect(path: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    if path.is_dir() {
        let mut entries = std::fs::read_dir(path)?
            .map(|entry| entry.map(|e| e.path()))
            .collect::<std::io::Result<Vec<_>>>()?;
        entries.sort();
        for entry in entries {
            collect(&entry, out)?;
        }
    } else if path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
    {
        out.push(path.to_path_buf());
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    }
    let as_json = args.iter().any(|a| a == "--json");
    let mut files = Vec::new();
    for arg in args.iter().filter(|a| *a != "--json") {
        if let Err(e) = collect(Path::new(arg), &mut files) {
            eprintln!("{arg}: {e}");
            return ExitCode::from(2);
        }
    }

    // Silence the default panic printout; panics are reported per file.
    std::panic::set_hook(Box::new(|_| {}));

    let mut records = Vec::new();
    let (mut agree_motion, mut agree_other, mut differ) = (0usize, 0usize, 0usize);
    for path in &files {
        let data = match std::fs::read(path) {
            Ok(data) => data,
            Err(e) => {
                eprintln!("{}: {e}", path.display());
                return ExitCode::from(2);
            }
        };
        let a = ours(&data);
        let (b, diagnostics) = theirs(&data);
        let diff = differences(&a, &b);
        let verdict = if !diff.is_empty() {
            differ += 1;
            "differ"
        } else if a.status == "motion" {
            agree_motion += 1;
            "agree"
        } else {
            agree_other += 1;
            "agree"
        };
        if as_json {
            records.push(json!({
                "path": path.display().to_string(),
                "bytes": data.len(),
                "verdict": verdict,
                "differs": diff,
                "xdremux": a.to_json(),
                "liblivephoto": b.to_json(),
                "liblivephotoDiagnostics": diagnostics,
            }));
        } else if diff.is_empty() {
            println!(
                "agree   {}  [{} | {}]",
                path.display(),
                if a.kind.is_empty() { a.status } else { &a.kind },
                if b.kind.is_empty() { b.status } else { &b.kind },
            );
        } else {
            println!("DIFFER  {}  ({})", path.display(), diff.join(", "));
            println!("    xdremux:      {}", a.summary());
            println!("    liblivephoto: {}", b.summary());
        }
    }
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&Value::Array(records)).unwrap()
        );
    }
    eprintln!(
        "{} files: {} agree as Motion Photo, {} agree as ordinary/rejected, {} differ",
        files.len(),
        agree_motion,
        agree_other,
        differ
    );
    if differ == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}
