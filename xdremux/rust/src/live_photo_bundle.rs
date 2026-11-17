//! Apple Live Photo bundle (`.pvt`) packaging, cross-platform.
//!
//! A `.pvt` is the directory package AirDrop and Telegram use to carry one
//! Live Photo (UTI `com.apple.private.live-photo-bundle`, conforming to
//! `com.apple.live-photo`). Layout, taken from an iPhone 18 Pro / iOS 27.2
//! sample and accepted by macOS Photos as a single Live Photo asset
//! (2026-10-30):
//!
//! ```text
//! <name>.pvt/
//!   <stem>.heic        still with the Apple MakerNote content identifier
//!   <stem>.mov         paired MOV with the same content identifier
//!   metadata.plist     PFVideoComplementMetadataVersionKey = "1"
//! ```
//!
//! The media files are copied byte-for-byte from an already composed pair
//! (`live_photo::make_live_photo`); nothing is re-encoded here.

use std::fs;
use std::path::{Path, PathBuf};

use crate::live_photo;
use crate::live_photo_publish::{compare_file, write_new_synced, Publication};

pub const BUNDLE_EXTENSION: &str = "pvt";
pub const METADATA_FILE: &str = "metadata.plist";
const METADATA_VERSION_KEY: &str = "PFVideoComplementMetadataVersionKey";

/// `metadata.plist` byte-for-byte as iOS writes it (XML plist, trailing newline).
pub const METADATA_PLIST: &str = concat!(
    r#"<?xml version="1.0" encoding="UTF-8"?>"#,
    "\n",
    r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
    "\n",
    r#"<plist version="1.0"><dict><key>PFVideoComplementMetadataVersionKey</key><string>1</string></dict></plist>"#,
    "\n",
);

const STILL_EXTENSIONS: &[&str] = &["heic", "heif", "jpg", "jpeg"];
const MOVIE_EXTENSIONS: &[&str] = &["mov"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundlePaths {
    pub bundle: PathBuf,
    pub still: PathBuf,
    pub movie: PathBuf,
}

fn has_extension(path: &Path, allowed: &[&str]) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| allowed.iter().any(|a| e.eq_ignore_ascii_case(a)))
        .unwrap_or(false)
}

fn bundle_stem(bundle: &Path) -> Result<String, String> {
    if !has_extension(bundle, &[BUNDLE_EXTENSION]) {
        return Err(format!(
            "Live Photo bundle must end with .{BUNDLE_EXTENSION}"
        ));
    }
    bundle
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "Live Photo bundle name is empty or not valid UTF-8".to_string())
}

/// Locate the still and movie inside an existing bundle. Requires
/// `metadata.plist` with the version key and exactly one still and one MOV
/// sharing a file stem; hidden files (`.DS_Store`, AppleDouble) are ignored.
pub fn read_bundle(bundle: &Path) -> Result<BundlePaths, String> {
    let plist = fs::read_to_string(bundle.join(METADATA_FILE))
        .map_err(|e| format!("bundle has no readable {METADATA_FILE}: {e}"))?;
    if !plist.contains(METADATA_VERSION_KEY) {
        return Err(format!("{METADATA_FILE} lacks {METADATA_VERSION_KEY}"));
    }
    let mut stills = Vec::new();
    let mut movies = Vec::new();
    for entry in fs::read_dir(bundle).map_err(|e| format!("read bundle: {e}"))? {
        let path = entry.map_err(|e| format!("read bundle: {e}"))?.path();
        let hidden = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with('.'))
            .unwrap_or(true);
        if hidden || !path.is_file() {
            continue;
        }
        if has_extension(&path, STILL_EXTENSIONS) {
            stills.push(path);
        } else if has_extension(&path, MOVIE_EXTENSIONS) {
            movies.push(path);
        }
    }
    if stills.len() != 1 || movies.len() != 1 {
        return Err(format!(
            "bundle must hold one still and one MOV (found {} and {})",
            stills.len(),
            movies.len()
        ));
    }
    let (still, movie) = (stills.remove(0), movies.remove(0));
    if still.file_stem() != movie.file_stem() {
        return Err("bundle still and MOV do not share a file name".into());
    }
    Ok(BundlePaths {
        bundle: bundle.to_path_buf(),
        still,
        movie,
    })
}

/// True when `bundle` is structurally complete and its pair content
/// identifiers match.
pub fn bundle_is_valid(bundle: &Path) -> bool {
    let Ok(paths) = read_bundle(bundle) else {
        return false;
    };
    match (fs::read(&paths.still), fs::read(&paths.movie)) {
        (Ok(still), Ok(movie)) => live_photo::existing_pair_is_valid(&still, &movie),
        _ => false,
    }
}

/// Package a composed pair into `bundle` (`<dir>/<stem>.pvt`). The pair is
/// checked first; the bundle is assembled in a hidden sibling directory and
/// only then moved into place, replacing an earlier bundle of the same name
/// (only ever a directory). The bundle in place is then read back: it must be
/// structurally complete, and its still, MOV and metadata.plist must equal
/// what was written. If that fails, the new bundle is removed and the earlier
/// one restored. The source files are never written.
pub fn write_bundle(still: &Path, movie: &Path, bundle: &Path) -> Result<BundlePaths, String> {
    write_bundle_with(
        still,
        movie,
        bundle,
        live_photo::existing_pair_is_valid,
        |_| {},
    )
}

fn write_bundle_with(
    still: &Path,
    movie: &Path,
    bundle: &Path,
    pair_is_valid: impl Fn(&[u8], &[u8]) -> bool,
    before_verify: impl FnOnce(&Path),
) -> Result<BundlePaths, String> {
    const WHAT: &str = "Live Photo bundle";
    let stem = bundle_stem(bundle)?;
    if !has_extension(still, STILL_EXTENSIONS) {
        return Err("Live Photo still must be HEIC/HEIF/JPEG".into());
    }
    if still.starts_with(bundle) || movie.starts_with(bundle) {
        return Err("Live Photo sources must not live inside the target bundle".into());
    }
    let still_bytes = fs::read(still).map_err(|e| format!("cannot read still: {e}"))?;
    let movie_bytes = fs::read(movie).map_err(|e| format!("cannot read movie: {e}"))?;
    if still_bytes.is_empty() || movie_bytes.is_empty() {
        return Err("Live Photo still or movie is empty".into());
    }
    if !pair_is_valid(&still_bytes, &movie_bytes) {
        return Err("still and MOV content identifiers do not match".into());
    }

    let parent = bundle
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent).map_err(|e| format!("create bundle parent: {e}"))?;
    let mut publication = Publication::new(true);
    let staging = publication.stage_directory(bundle)?;
    let still_ext = still
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("heic")
        .to_ascii_lowercase();
    let filled = write_new_synced(&staging.join(format!("{stem}.{still_ext}")), &still_bytes)
        .and_then(|()| write_new_synced(&staging.join(format!("{stem}.mov")), &movie_bytes))
        .and_then(|()| write_new_synced(&staging.join(METADATA_FILE), METADATA_PLIST.as_bytes()));
    if let Err(e) = filled {
        return Err(publication.abandon(WHAT, e).into());
    }
    publication
        .finish(WHAT, || {
            before_verify(bundle);
            verify_written_bundle(bundle, &still_bytes, &movie_bytes)
        })
        .map_err(String::from)
}

/// Read a just-written bundle back: complete layout, and the still, MOV and
/// metadata.plist equal to what was written. The pair itself was checked
/// before writing.
fn verify_written_bundle(bundle: &Path, still: &[u8], movie: &[u8]) -> Result<BundlePaths, String> {
    let paths = read_bundle(bundle)?;
    live_photo::verify_written_pair(still, movie, &paths.still, &paths.movie)?;
    compare_file(&bundle.join(METADATA_FILE), METADATA_PLIST.as_bytes())?;
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "xdremux_pvt_{name}_{}_{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn pair(dir: &Path) -> (PathBuf, PathBuf) {
        let still = dir.join("IMG_1_iso.heic");
        let movie = dir.join("IMG_1_iso.mov");
        fs::write(&still, b"still-bytes").unwrap();
        fs::write(&movie, b"movie-bytes").unwrap();
        (still, movie)
    }

    #[test]
    fn writes_apple_layout_byte_for_byte() {
        let dir = scratch("layout");
        let (still, movie) = pair(&dir);
        let bundle = dir.join("out").join("IMG_1_iso.pvt");
        let paths = write_bundle_with(&still, &movie, &bundle, |_, _| true, |_| {}).unwrap();
        assert_eq!(paths.still, bundle.join("IMG_1_iso.heic"));
        assert_eq!(paths.movie, bundle.join("IMG_1_iso.mov"));
        assert_eq!(fs::read(&paths.still).unwrap(), b"still-bytes");
        assert_eq!(fs::read(&paths.movie).unwrap(), b"movie-bytes");
        let plist = fs::read_to_string(bundle.join(METADATA_FILE)).unwrap();
        assert!(plist.contains("<key>PFVideoComplementMetadataVersionKey</key><string>1</string>"));
        let names = crate::live_photo_publish::test_support::names(&bundle);
        assert_eq!(names, ["IMG_1_iso.heic", "IMG_1_iso.mov", "metadata.plist"]);
        // Sources are copied, not moved; no staging directory is left behind.
        assert!(still.exists() && movie.exists());
        assert_eq!(entry_count(&dir.join("out")), 1);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rejects_mismatched_pair_without_touching_existing_bundle() {
        let dir = scratch("mismatch");
        let (still, movie) = pair(&dir);
        let bundle = dir.join("IMG_1_iso.pvt");
        write_bundle_with(&still, &movie, &bundle, |_, _| true, |_| {}).unwrap();
        let err = write_bundle_with(&still, &movie, &bundle, |_, _| false, |_| {}).unwrap_err();
        assert!(err.contains("content identifiers"), "{err}");
        assert!(read_bundle(&bundle).is_ok());
        // The real validator rejects bytes without content identifiers.
        assert!(write_bundle(&still, &movie, &dir.join("other.pvt")).is_err());
        assert!(!dir.join("other.pvt").exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn replaces_existing_bundle_and_drops_stale_files() {
        let dir = scratch("replace");
        let (still, movie) = pair(&dir);
        let bundle = dir.join("IMG_1_iso.pvt");
        fs::create_dir_all(&bundle).unwrap();
        fs::write(bundle.join("stale.mov"), b"old").unwrap();
        write_bundle_with(&still, &movie, &bundle, |_, _| true, |_| {}).unwrap();
        assert!(!bundle.join("stale.mov").exists());
        assert!(read_bundle(&bundle).is_ok());
        let leftovers = hidden_entries(&dir);
        assert!(leftovers.is_empty(), "{leftovers:?}");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rejects_bad_targets_and_sources() {
        let dir = scratch("targets");
        let (still, movie) = pair(&dir);
        assert!(
            write_bundle_with(&still, &movie, &dir.join("x.zip"), |_, _| true, |_| {}).is_err()
        );
        assert!(write_bundle_with(&still, &movie, &dir.join(".pvt"), |_, _| true, |_| {}).is_err());
        assert!(
            write_bundle_with(&movie, &movie, &dir.join("x.pvt"), |_, _| true, |_| {}).is_err()
        );
        let bundle = dir.join("IMG_1_iso.pvt");
        let paths = write_bundle_with(&still, &movie, &bundle, |_, _| true, |_| {}).unwrap();
        let err = write_bundle_with(&paths.still, &paths.movie, &bundle, |_, _| true, |_| {})
            .unwrap_err();
        assert!(err.contains("inside"), "{err}");
        fs::write(dir.join("empty.mov"), b"").unwrap();
        assert!(write_bundle_with(
            &still,
            &dir.join("empty.mov"),
            &dir.join("e.pvt"),
            |_, _| true,
            |_| {}
        )
        .is_err());
        fs::remove_dir_all(&dir).unwrap();
    }

    /// A real pair (see `live_photo::pair_fixture`) written as source files.
    fn real_pair(dir: &Path, content_id: &str) -> (PathBuf, PathBuf, Vec<u8>, Vec<u8>) {
        let (still_bytes, movie_bytes) = crate::live_photo::pair_fixture::pair(content_id);
        let still = dir.join("IMG_1_iso.heic");
        let movie = dir.join("IMG_1_iso.mov");
        fs::write(&still, &still_bytes).unwrap();
        fs::write(&movie, &movie_bytes).unwrap();
        (still, movie, still_bytes, movie_bytes)
    }

    fn hidden_entries(dir: &Path) -> Vec<String> {
        crate::live_photo_publish::test_support::names(dir)
            .into_iter()
            .filter(|n| n.starts_with('.'))
            .collect()
    }

    fn entry_count(dir: &Path) -> usize {
        crate::live_photo_publish::test_support::names(dir).len()
    }

    #[test]
    fn real_pair_is_bundled_and_verified() {
        let dir = scratch("verified");
        let content_id = crate::live_photo::pair_fixture::CONTENT_ID;
        let (still, movie, still_bytes, movie_bytes) = real_pair(&dir, content_id);
        let bundle = dir.join("out").join("IMG_1_iso.pvt");
        let paths = write_bundle(&still, &movie, &bundle).unwrap();
        assert!(bundle_is_valid(&bundle));
        assert_eq!(fs::read(&paths.still).unwrap(), still_bytes);
        assert_eq!(fs::read(&paths.movie).unwrap(), movie_bytes);
        assert_eq!(entry_count(&dir.join("out")), 1);
        // Sources untouched.
        assert_eq!(fs::read(&still).unwrap(), still_bytes);
        assert_eq!(fs::read(&movie).unwrap(), movie_bytes);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_changed_bundle_is_removed_and_the_previous_one_restored() {
        let dir = scratch("changed");
        let (still, movie, still_bytes, movie_bytes) =
            real_pair(&dir, "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9");
        let bundle = dir.join("IMG_1_iso.pvt");
        write_bundle(&still, &movie, &bundle).unwrap();
        let previous = fs::read(bundle.join("IMG_1_iso.mov")).unwrap();

        let (still, movie, still_bytes2, movie_bytes2) =
            real_pair(&dir, crate::live_photo::pair_fixture::CONTENT_ID);
        assert_ne!(
            (still_bytes, movie_bytes),
            (still_bytes2.clone(), movie_bytes2.clone())
        );
        // The MOV in the new bundle changes after it was moved into place.
        let err = write_bundle_with(
            &still,
            &movie,
            &bundle,
            live_photo::existing_pair_is_valid,
            |b| {
                let mov = b.join("IMG_1_iso.mov");
                let len = fs::metadata(&mov).unwrap().len();
                crate::live_photo_publish::test_support::truncate_to(&mov, len / 2);
            },
        )
        .unwrap_err();
        assert!(
            err.contains("Live Photo bundle failed verification"),
            "{err}"
        );
        assert!(
            err.ends_with(
                "rolled back: removed IMG_1_iso.pvt; restored the previous IMG_1_iso.pvt"
            ),
            "{err}"
        );
        assert!(bundle_is_valid(&bundle), "earlier bundle is back");
        assert_eq!(fs::read(bundle.join("IMG_1_iso.mov")).unwrap(), previous);
        assert!(
            hidden_entries(&dir).is_empty(),
            "{:?}",
            hidden_entries(&dir)
        );
        // Sources untouched.
        assert_eq!(fs::read(&still).unwrap(), still_bytes2);
        assert_eq!(fs::read(&movie).unwrap(), movie_bytes2);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn failed_verification_without_an_earlier_bundle_leaves_nothing() {
        let dir = scratch("nothing_left");
        let (still, movie, _, _) = real_pair(&dir, crate::live_photo::pair_fixture::CONTENT_ID);
        let bundle = dir.join("out").join("IMG_1_iso.pvt");
        // A stray file shows up in the new bundle, so it no longer holds
        // exactly one still and one MOV.
        let err = write_bundle_with(
            &still,
            &movie,
            &bundle,
            live_photo::existing_pair_is_valid,
            |b| {
                fs::write(b.join("IMG_2.heic"), b"stray").unwrap();
            },
        )
        .unwrap_err();
        assert!(err.contains("one still and one MOV"), "{err}");
        assert!(err.ends_with("rolled back: removed IMG_1_iso.pvt"), "{err}");
        assert_eq!(entry_count(&dir.join("out")), 0, "no bundle, no staging");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_file_at_the_bundle_path_is_never_replaced() {
        let dir = scratch("file_target");
        let (still, movie, _, _) = real_pair(&dir, crate::live_photo::pair_fixture::CONTENT_ID);
        let bundle = dir.join("IMG_1_iso.pvt");
        fs::write(&bundle, b"not a bundle").unwrap();
        let err = write_bundle(&still, &movie, &bundle).unwrap_err();
        assert!(err.contains("it is a file"), "{err}");
        assert_eq!(fs::read(&bundle).unwrap(), b"not a bundle");
        assert!(
            hidden_entries(&dir).is_empty(),
            "{:?}",
            hidden_entries(&dir)
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn read_bundle_requires_metadata_and_one_matching_pair() {
        let dir = scratch("read");
        let bundle = dir.join("A.pvt");
        fs::create_dir_all(&bundle).unwrap();
        fs::write(bundle.join("A.heic"), b"s").unwrap();
        fs::write(bundle.join("A.mov"), b"m").unwrap();
        assert!(read_bundle(&bundle).unwrap_err().contains(METADATA_FILE));
        fs::write(bundle.join(METADATA_FILE), "<plist/>").unwrap();
        assert!(read_bundle(&bundle).is_err());
        fs::write(bundle.join(METADATA_FILE), METADATA_PLIST).unwrap();
        fs::write(bundle.join(".DS_Store"), b"x").unwrap();
        // Mixed-case extensions and a different bundle name are both what
        // iOS itself produces (IMG_3648_HDR10_Live.pvt/IMG_3648_..._experimental.heic).
        fs::rename(bundle.join("A.mov"), bundle.join("A.MOV")).unwrap();
        let paths = read_bundle(&bundle).unwrap();
        assert_eq!(paths.movie, bundle.join("A.MOV"));
        assert!(
            !bundle_is_valid(&bundle),
            "fake bytes carry no content identifier"
        );
        fs::write(bundle.join("B.mov"), b"m").unwrap();
        assert!(read_bundle(&bundle).is_err());
        fs::remove_file(bundle.join("B.mov")).unwrap();
        fs::rename(bundle.join("A.MOV"), bundle.join("C.mov")).unwrap();
        assert!(read_bundle(&bundle).unwrap_err().contains("share"));
        fs::remove_dir_all(&dir).unwrap();
    }
}
