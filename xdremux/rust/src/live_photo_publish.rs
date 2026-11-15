//! Write, place, read back, then commit or roll back: how a Live Photo
//! conversion publishes its outputs (the HEIC + MOV pair and the `.pvt`
//! bundle).
//!
//! Each output is first written under a hidden sibling name that did not exist
//! before (`create_new`), then renamed onto its final path. An entry already at
//! that path is renamed aside instead of overwritten. The caller then reads the
//! final paths back and verifies them. Only after that check passes does
//! `commit` drop the entries that were moved aside. On any failure `rollback`
//! removes what this run placed and renames the earlier entries back, so the
//! destination is as it was before the run. Inputs are never written.
//!
//! Only entries this run created are removed. On Unix a placed output is
//! removed only while it is still the file or directory (device + inode) this
//! run created; one replaced by another writer in the meantime is left alone
//! and named in the error. Other platforms identify it by path.

use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_PUBLICATION: AtomicU64 = AtomicU64::new(0);

type Identity = Option<(u64, u64)>;

#[cfg(unix)]
fn identity(path: &Path) -> Identity {
    use std::os::unix::fs::MetadataExt;
    fs::symlink_metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

#[cfg(not(unix))]
fn identity(_path: &Path) -> Identity {
    None
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

fn is_missing(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(e) if e.kind() == ErrorKind::NotFound)
}

fn remove_entry(path: &Path) -> std::io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn create_new(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("cannot create {}: {e}", path.display()))
}

fn write_synced(file: &mut File, path: &Path, bytes: &[u8]) -> Result<(), String> {
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Create `path` (which must not exist yet) holding `bytes`, flushed to disk.
pub(crate) fn write_new_synced(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_synced(&mut create_new(path)?, path, bytes)
}

struct Entry {
    /// What this run wrote, under its hidden name until placed.
    staged: PathBuf,
    target: PathBuf,
    identity: Identity,
    /// Where the entry previously at `target` was moved aside.
    retired: Option<PathBuf>,
    placed: bool,
}

/// One run's outputs. Dropping it without `commit` rolls back.
pub(crate) struct Publication {
    tag: String,
    entries: Vec<Entry>,
    finished: bool,
}

impl Publication {
    pub(crate) fn new() -> Self {
        let n = NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed);
        Self {
            tag: format!("{}-{n}", std::process::id()),
            entries: Vec::new(),
            finished: false,
        }
    }

    /// Hidden sibling of `target` unique to this run, e.g.
    /// `.IMG_1.mov.partial-4242-0`.
    pub(crate) fn sibling(&self, target: &Path, kind: &str) -> PathBuf {
        target.with_file_name(format!(".{}.{kind}-{}", file_name(target), self.tag))
    }

    /// Write `bytes` to a new hidden sibling of `target`.
    pub(crate) fn stage_file(&mut self, target: &Path, bytes: &[u8]) -> Result<(), String> {
        let staged = self.sibling(target, "partial");
        // A name that already exists is not ours: fail without adopting it.
        let mut file = create_new(&staged)?;
        self.adopt(staged.clone(), target);
        write_synced(&mut file, &staged, bytes)
    }

    /// Adopt a file or directory this run created (the `.pvt` staging
    /// directory) as the output for `target`.
    pub(crate) fn adopt(&mut self, staged: PathBuf, target: &Path) {
        let identity = identity(&staged);
        self.entries.push(Entry {
            staged,
            target: target.to_path_buf(),
            identity,
            retired: None,
            placed: false,
        });
    }

    /// Rename every staged output onto its target, moving an existing target
    /// aside first. On error, call `rollback`.
    pub(crate) fn place(&mut self) -> Result<(), String> {
        for index in 0..self.entries.len() {
            let target = self.entries[index].target.clone();
            if !is_missing(&target) {
                let retired = self.sibling(&target, "old");
                fs::rename(&target, &retired).map_err(|e| {
                    format!("cannot move the existing {} aside: {e}", target.display())
                })?;
                self.entries[index].retired = Some(retired);
            }
            let entry = &mut self.entries[index];
            fs::rename(&entry.staged, &entry.target)
                .map_err(|e| format!("cannot move {} into place: {e}", target.display()))?;
            entry.placed = true;
        }
        Ok(())
    }

    /// Keep the placed outputs and delete the entries they replaced.
    pub(crate) fn commit(mut self) {
        self.finished = true;
        for entry in &self.entries {
            if let Some(retired) = &entry.retired {
                let _ = remove_entry(retired);
            }
        }
    }

    /// Undo this run. Returns a clause for the error message saying what was
    /// removed and restored, or what could not be.
    pub(crate) fn rollback(mut self) -> String {
        self.finished = true;
        self.undo()
    }

    fn undo(&mut self) -> String {
        let mut removed = Vec::new();
        let mut restored = Vec::new();
        let mut problems = Vec::new();
        for entry in self.entries.iter().rev() {
            let ours = if entry.placed {
                &entry.target
            } else {
                &entry.staged
            };
            match fs::symlink_metadata(ours) {
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) => problems.push(format!("cannot inspect {}: {e}", ours.display())),
                Ok(_) if entry.identity.is_some() && identity(ours) != entry.identity => problems
                    .push(format!(
                        "left {} alone: it is no longer the entry this run wrote",
                        ours.display()
                    )),
                Ok(_) => match remove_entry(ours) {
                    Ok(()) if entry.placed => removed.push(file_name(&entry.target)),
                    Ok(()) => {}
                    Err(e) => problems.push(format!("cannot remove {}: {e}", ours.display())),
                },
            }
            let Some(retired) = &entry.retired else {
                continue;
            };
            // Only a free target may take the earlier entry back: a rename
            // onto an occupied path would replace whatever is there.
            if is_missing(&entry.target) && fs::rename(retired, &entry.target).is_ok() {
                restored.push(file_name(&entry.target));
            } else {
                problems.push(format!(
                    "the previous {} is kept at {}",
                    entry.target.display(),
                    retired.display()
                ));
            }
        }
        if !problems.is_empty() {
            problems.reverse();
            return format!("rollback incomplete: {}", problems.join("; "));
        }
        removed.reverse();
        restored.reverse();
        let mut summary = String::from("rolled back");
        if !removed.is_empty() {
            summary.push_str(&format!(": removed {}", removed.join(", ")));
        }
        if !restored.is_empty() {
            let separator = if removed.is_empty() { ":" } else { ";" };
            summary.push_str(&format!(
                "{separator} restored the previous {}",
                restored.join(", ")
            ));
        }
        summary
    }
}

impl Drop for Publication {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.undo();
        }
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::fs;
    use std::path::{Path, PathBuf};

    /// Fresh scratch directory under the system temp dir.
    pub(crate) fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "xdremux_publish_{name}_{}_{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Sorted names of the entries in `dir`, hidden ones included.
    pub(crate) fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{names, scratch};
    use super::*;

    #[test]
    fn commit_places_new_files_and_drops_replaced_ones() {
        let dir = scratch("commit");
        let target = dir.join("IMG_1.mov");
        fs::write(&target, b"old").unwrap();
        let mut publication = Publication::new();
        publication.stage_file(&target, b"new").unwrap();
        publication.place().unwrap();
        publication.commit();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert_eq!(names(&dir), ["IMG_1.mov"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rollback_removes_new_files_and_restores_replaced_ones() {
        let dir = scratch("rollback");
        let kept = dir.join("IMG_1.heic");
        let fresh = dir.join("IMG_1.mov");
        fs::write(&kept, b"previous still").unwrap();
        let mut publication = Publication::new();
        publication.stage_file(&kept, b"new still").unwrap();
        publication.stage_file(&fresh, b"new movie").unwrap();
        publication.place().unwrap();
        let summary = publication.rollback();
        assert_eq!(
            summary,
            "rolled back: removed IMG_1.heic, IMG_1.mov; restored the previous IMG_1.heic"
        );
        assert_eq!(fs::read(&kept).unwrap(), b"previous still");
        assert_eq!(names(&dir), ["IMG_1.heic"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn dropping_an_unfinished_publication_cleans_up_staged_files() {
        let dir = scratch("drop");
        let target = dir.join("IMG_1.heic");
        {
            let mut publication = Publication::new();
            publication.stage_file(&target, b"still").unwrap();
            assert_eq!(names(&dir).len(), 1, "staged under a hidden name");
        }
        assert!(names(&dir).is_empty(), "{:?}", names(&dir));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn staging_never_adopts_an_existing_name() {
        let dir = scratch("exclusive");
        let target = dir.join("IMG_1.heic");
        let mut publication = Publication::new();
        let staged = publication.sibling(&target, "partial");
        fs::write(&staged, b"someone else's file").unwrap();
        assert!(publication.stage_file(&target, b"still").is_err());
        drop(publication);
        assert_eq!(fs::read(&staged).unwrap(), b"someone else's file");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn rollback_leaves_a_target_replaced_by_another_writer() {
        let dir = scratch("foreign");
        let target = dir.join("IMG_1.mov");
        fs::write(&target, b"previous").unwrap();
        let mut publication = Publication::new();
        publication.stage_file(&target, b"ours").unwrap();
        publication.place().unwrap();
        // Another writer swaps in its own file after placement.
        let theirs = dir.join("theirs");
        fs::write(&theirs, b"theirs").unwrap();
        fs::rename(&theirs, &target).unwrap();
        let summary = publication.rollback();
        assert!(summary.starts_with("rollback incomplete"), "{summary}");
        assert!(
            summary.contains("no longer the entry this run wrote"),
            "{summary}"
        );
        assert!(summary.contains("the previous"), "{summary}");
        assert_eq!(fs::read(&target).unwrap(), b"theirs");
        fs::remove_dir_all(&dir).unwrap();
    }
}
