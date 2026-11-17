//! Write, place, read back, then commit or roll back: how a Live Photo
//! conversion publishes its outputs (the HEIC + MOV pair and the `.pvt`
//! bundle).
//!
//! Each output is first written under a hidden name of fixed length that did
//! not exist before (`.xdremux-publish-<run>-<n>.partial`, `create_new`),
//! flushed, then renamed onto its final path. What happens to an entry already
//! at that path depends on the publication:
//!
//! - replacing: it is renamed aside (`.xdremux-publish-<run>-<n>.old`) and
//!   only deleted once the run commits;
//! - exclusive: the run fails with [`PublishError::target_exists`] and
//!   touches nothing. The rename itself refuses an existing target
//!   (`renameat2(RENAME_NOREPLACE)`, `renamex_np(RENAME_EXCL)`, `MoveFileExW`
//!   without replace); on file systems without such a rename it checks first.
//!
//! The caller then reads the final paths back. Only after that check passes
//! does the run commit. On any failure it rolls back: what it placed is
//! removed and the entries moved aside are renamed back, so the destination is
//! as it was before. Inputs are never written. The read-back goes through the
//! file system and may be served from the OS page cache, so it catches a
//! wrong, truncated or later-changed file, not faults of the storage medium.
//!
//! Only entries this run created are removed. On Unix a placed output is
//! removed only while it is still the file or directory (device + inode) this
//! run created; the identity is taken after writing and again after renaming,
//! because FAT/exFAT number empty files with a placeholder and some network
//! file systems derive it from the path. An output replaced by another writer
//! in the meantime is left alone and named in the error. Other platforms
//! identify outputs by path.
//!
//! A run killed between placing and committing can leave hidden entries
//! behind. The first run in a process that publishes into a directory removes
//! `.partial` entries older than an hour there. `.old` entries are kept: one
//! may be the only copy of an earlier output.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

static NEXT_PUBLICATION: AtomicU64 = AtomicU64::new(0);
const HIDDEN_PREFIX: &str = ".xdremux-publish-";
const STALE_AFTER: Duration = Duration::from_secs(60 * 60);

/// Why a publication failed. The message ends with what the rollback did.
#[derive(Debug)]
pub struct PublishError {
    message: String,
    target_exists: bool,
}

impl PublishError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            target_exists: false,
        }
    }

    fn exists(target: &Path) -> Self {
        Self {
            message: format!("{} already exists", target.display()),
            target_exists: true,
        }
    }

    /// True when an exclusive publication found an entry at one of its
    /// output paths. Nothing was replaced; pick another name and retry.
    pub fn target_exists(&self) -> bool {
        self.target_exists
    }
}

impl std::fmt::Display for PublishError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for PublishError {}

impl From<PublishError> for String {
    fn from(error: PublishError) -> String {
        error.message
    }
}

type Identity = Option<(u64, u64)>;

#[cfg(unix)]
fn identity_of(meta: &fs::Metadata) -> Identity {
    use std::os::unix::fs::MetadataExt;
    Some((meta.dev(), meta.ino()))
}

#[cfg(not(unix))]
fn identity_of(_meta: &fs::Metadata) -> Identity {
    None
}

fn identity(path: &Path) -> Identity {
    fs::symlink_metadata(path)
        .ok()
        .and_then(|m| identity_of(&m))
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

fn parent_of(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
}

fn is_missing(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(e) if e.kind() == ErrorKind::NotFound)
}

fn describe(meta: &fs::Metadata) -> &'static str {
    if meta.file_type().is_symlink() {
        "a symbolic link"
    } else if meta.is_dir() {
        "a directory"
    } else if meta.is_file() {
        "a file"
    } else {
        "not a regular file"
    }
}

fn remove_entry(path: &Path) -> std::io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

/// Flush a written file before it is renamed into place: its data must reach
/// the disk before the entry it replaces is deleted. Apple's `sync_all` is
/// `F_FULLFSYNC`, which SMB shares without full-sync support and WebDAV
/// reject. Ordering is all a publication needs, so use `F_BARRIERFSYNC` there
/// and fall back to `fsync`, as SQLite and Go do.
#[cfg(target_vendor = "apple")]
fn sync(file: &File) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    let fd = file.as_raw_fd();
    let retrying = |call: &dyn Fn() -> libc::c_int| loop {
        if call() != -1 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != ErrorKind::Interrupted {
            return Err(error);
        }
    };
    // SAFETY: `fd` stays open (owned by `file`) for both calls.
    retrying(&|| unsafe { libc::fcntl(fd, libc::F_BARRIERFSYNC) })
        .or_else(|_| retrying(&|| unsafe { libc::fsync(fd) }))
}

#[cfg(not(target_vendor = "apple"))]
fn sync(file: &File) -> std::io::Result<()> {
    file.sync_all()
}

/// Make renames in `dir` durable. Best effort: not every file system can
/// sync a directory, and the data itself is already flushed.
fn sync_dir(dir: &Path) {
    #[cfg(unix)]
    if let Ok(handle) = File::open(dir) {
        let _ = sync(&handle);
    }
    #[cfg(not(unix))]
    let _ = dir;
}

/// Rename `from` onto `to` only if `to` does not exist.
fn rename_exclusive(from: &Path, to: &Path) -> std::io::Result<()> {
    match rename_noreplace(from, to) {
        // No atomic no-replace rename on this file system (FUSE, some network
        // shares): check, then rename. Another writer could slip in between.
        Err(e) if unsupported(&e) => {
            if !is_missing(to) {
                return Err(ErrorKind::AlreadyExists.into());
            }
            fs::rename(from, to)
        }
        other => other,
    }
}

#[cfg(unix)]
fn c_path(path: &Path) -> std::io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(ErrorKind::InvalidInput))
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn rename_noreplace(from: &Path, to: &Path) -> std::io::Result<()> {
    const RENAME_NOREPLACE: libc::c_uint = 1;
    let (from, to) = (c_path(from)?, c_path(to)?);
    // SAFETY: valid NUL-terminated paths, resolved like rename(2). The raw
    // syscall also works where libc lacks renameat2 (Android before 11).
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_vendor = "apple")]
fn rename_noreplace(from: &Path, to: &Path) -> std::io::Result<()> {
    let (from, to) = (c_path(from)?, c_path(to)?);
    // SAFETY: valid NUL-terminated paths; RENAME_EXCL refuses any existing target.
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(windows)]
fn rename_noreplace(from: &Path, to: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    let wide = |p: &Path| -> Vec<u16> { p.as_os_str().encode_wide().chain(Some(0)).collect() };
    let (from, to) = (wide(from), wide(to));
    // SAFETY: NUL-terminated wide paths; without MOVEFILE_REPLACE_EXISTING the
    // call fails when `to` exists.
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } != 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_vendor = "apple",
    windows
)))]
fn rename_noreplace(_from: &Path, _to: &Path) -> std::io::Result<()> {
    Err(ErrorKind::Unsupported.into())
}

fn unsupported(error: &std::io::Error) -> bool {
    if error.kind() == ErrorKind::Unsupported {
        return true;
    }
    #[cfg(unix)]
    if let Some(code) = error.raw_os_error() {
        return [libc::EINVAL, libc::ENOSYS, libc::ENOTSUP, libc::EOPNOTSUPP].contains(&code);
    }
    false
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
        .and_then(|()| sync(file))
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Create `path` (which must not exist yet) holding `bytes`, flushed to disk.
pub(crate) fn write_new_synced(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_synced(&mut create_new(path)?, path, bytes)
}

/// Read `path` back and compare it with `expected`, 64 KiB at a time.
pub(crate) fn compare_file(path: &Path, expected: &[u8]) -> Result<(), String> {
    let read_error = |e: std::io::Error| format!("cannot read back {}: {e}", path.display());
    let differs = || format!("{} differs from what was written", path.display());
    let mut file = File::open(path).map_err(read_error)?;
    let len = file.metadata().map_err(read_error)?.len();
    if len != expected.len() as u64 {
        return Err(format!(
            "{} holds {len} bytes, {} were written",
            path.display(),
            expected.len()
        ));
    }
    let mut buffer = vec![0u8; 64 * 1024];
    for chunk in expected.chunks(buffer.len()) {
        let read = &mut buffer[..chunk.len()];
        file.read_exact(read).map_err(read_error)?;
        if read != chunk {
            return Err(differs());
        }
    }
    if file.read(&mut buffer[..1]).map_err(read_error)? != 0 {
        return Err(differs());
    }
    Ok(())
}

/// Remove `.partial` entries a killed run left in `dir`: once per directory
/// per process, and only those older than an hour, so a run still writing
/// elsewhere is never touched.
fn sweep_stale(dir: &Path) {
    static SWEPT: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);
    {
        let mut swept = SWEPT.lock().unwrap_or_else(|e| e.into_inner());
        if !swept
            .get_or_insert_with(HashSet::new)
            .insert(dir.to_path_buf())
        {
            return;
        }
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let Some(cutoff) = SystemTime::now().checked_sub(STALE_AFTER) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with(HIDDEN_PREFIX) || !name.ends_with(".partial") {
            continue;
        }
        let path = entry.path();
        let stale = fs::symlink_metadata(&path)
            .and_then(|m| m.modified())
            .is_ok_and(|modified| modified < cutoff);
        if stale {
            let _ = remove_entry(&path);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    File,
    Directory,
}

struct Entry {
    /// What this run wrote, under its hidden name until placed.
    staged: PathBuf,
    target: PathBuf,
    kind: Kind,
    identity: Identity,
    /// Where the entry previously at `target` was moved aside.
    retired: Option<PathBuf>,
    placed: bool,
}

/// One run's outputs. Dropping it without `finish` rolls back.
pub(crate) struct Publication {
    tag: String,
    replace: bool,
    entries: Vec<Entry>,
    finished: bool,
}

impl Publication {
    /// With `replace`, entries already at the output paths are moved aside and
    /// replaced; without it, an existing entry makes `finish` fail with
    /// [`PublishError::target_exists`] and nothing is touched.
    pub(crate) fn new(replace: bool) -> Self {
        let n = NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed);
        Self {
            tag: format!("{}-{n}", std::process::id()),
            replace,
            entries: Vec::new(),
            finished: false,
        }
    }

    /// Hidden sibling of `target`, the same length whatever the target is
    /// called, so long file names keep working.
    fn hidden(&self, target: &Path, index: usize, kind: &str) -> PathBuf {
        target.with_file_name(format!("{HIDDEN_PREFIX}{}-{index}.{kind}", self.tag))
    }

    /// Write `bytes` to a new hidden sibling of `target`.
    pub(crate) fn stage_file(&mut self, target: &Path, bytes: &[u8]) -> Result<(), String> {
        sweep_stale(parent_of(target));
        let staged = self.hidden(target, self.entries.len(), "partial");
        // A name that already exists is not ours: fail without adopting it.
        let mut file = create_new(&staged)?;
        self.adopt(staged.clone(), target, Kind::File);
        let written = write_synced(&mut file, &staged, bytes);
        // Take the identity from the written file: FAT/exFAT give an empty
        // file a placeholder number that changes once it holds data.
        if let Some(entry) = self.entries.last_mut() {
            entry.identity = file.metadata().ok().and_then(|m| identity_of(&m));
        }
        written
    }

    /// Create a new hidden, empty directory next to `target` for the caller
    /// to fill (the `.pvt` bundle) and return its path.
    pub(crate) fn stage_directory(&mut self, target: &Path) -> Result<PathBuf, String> {
        sweep_stale(parent_of(target));
        let staged = self.hidden(target, self.entries.len(), "partial");
        fs::create_dir(&staged).map_err(|e| format!("cannot create {}: {e}", staged.display()))?;
        self.adopt(staged.clone(), target, Kind::Directory);
        Ok(staged)
    }

    fn adopt(&mut self, staged: PathBuf, target: &Path, kind: Kind) {
        let identity = identity(&staged);
        self.entries.push(Entry {
            staged,
            target: target.to_path_buf(),
            kind,
            identity,
            retired: None,
            placed: false,
        });
    }

    /// Give up before placing anything; `error` is why.
    pub(crate) fn abandon(self, what: &str, error: String) -> PublishError {
        PublishError::new(format!(
            "{what} could not be written: {error}; {}",
            self.rollback()
        ))
    }

    /// Place every staged output, run `verify` on the placed outputs, then
    /// commit if it passes and roll back if anything fails. `what` names the
    /// output in error messages.
    pub(crate) fn finish<T>(
        mut self,
        what: &str,
        verify: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, PublishError> {
        if let Err(error) = self.place() {
            return Err(PublishError {
                message: format!(
                    "{what} could not be written: {}; {}",
                    error.message,
                    self.rollback()
                ),
                target_exists: error.target_exists,
            });
        }
        match verify() {
            Ok(value) => {
                self.commit();
                Ok(value)
            }
            Err(error) => Err(PublishError::new(format!(
                "{what} failed verification: {error}; {}",
                self.rollback()
            ))),
        }
    }

    /// Rename every staged output onto its target, moving an existing target
    /// aside first when replacing.
    fn place(&mut self) -> Result<(), PublishError> {
        for index in 0..self.entries.len() {
            let target = self.entries[index].target.clone();
            match fs::symlink_metadata(&target) {
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) => {
                    return Err(PublishError::new(format!(
                        "cannot inspect {}: {e}",
                        target.display()
                    )))
                }
                Ok(_) if !self.replace => return Err(PublishError::exists(&target)),
                Ok(meta) => {
                    // Only ever replace what this kind of output could have
                    // been: never a directory with a file, never a symlink.
                    let replaceable = match self.entries[index].kind {
                        Kind::File => meta.file_type().is_file(),
                        Kind::Directory => meta.file_type().is_dir(),
                    };
                    if !replaceable {
                        return Err(PublishError::new(format!(
                            "refusing to replace {}: it is {}",
                            target.display(),
                            describe(&meta)
                        )));
                    }
                    let retired = self.hidden(&target, index, "old");
                    fs::rename(&target, &retired).map_err(|e| {
                        PublishError::new(format!(
                            "cannot move the existing {} aside: {e}",
                            target.display()
                        ))
                    })?;
                    self.entries[index].retired = Some(retired);
                }
            }
            match rename_exclusive(&self.entries[index].staged, &target) {
                Ok(()) => {}
                Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                    return Err(PublishError::exists(&target))
                }
                Err(e) => {
                    return Err(PublishError::new(format!(
                        "cannot move {} into place: {e}",
                        target.display()
                    )))
                }
            }
            let entry = &mut self.entries[index];
            entry.placed = true;
            // Some network file systems derive the number from the path.
            entry.identity = identity(&entry.target);
        }
        self.sync_directories();
        Ok(())
    }

    fn sync_directories(&self) {
        let mut done = HashSet::new();
        for entry in &self.entries {
            let dir = parent_of(&entry.target);
            if done.insert(dir.to_path_buf()) {
                sync_dir(dir);
            }
        }
    }

    /// Keep the placed outputs and delete the entries they replaced.
    fn commit(mut self) {
        self.finished = true;
        for entry in &self.entries {
            if let Some(retired) = &entry.retired {
                let _ = remove_entry(retired);
            }
        }
        self.sync_directories();
    }

    /// Undo this run. Returns a clause for the error message saying what was
    /// removed and restored, or what could not be.
    fn rollback(mut self) -> String {
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
                Ok(meta) if entry.identity.is_some() && identity_of(&meta) != entry.identity => {
                    problems.push(format!(
                        "left {} alone: it is no longer the entry this run wrote",
                        ours.display()
                    ))
                }
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

    /// Sorted names of the entries in `dir`, hidden ones included. macOS
    /// keeps extended attributes on FAT/exFAT in `._<name>` companions that
    /// it creates, renames and removes with each file; those are skipped.
    pub(crate) fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .filter(|n| !n.starts_with("._"))
            .collect();
        names.sort();
        names
    }

    /// Overwrite bytes of an existing file in place, the way a bad write
    /// would. (`fs::write` truncates first; on FAT/exFAT that gives the file
    /// a new inode number, i.e. makes it look like another file.)
    pub(crate) fn overwrite_at(path: &Path, offset: u64, bytes: &[u8]) {
        use std::io::{Seek, SeekFrom, Write};
        let mut file = fs::OpenOptions::new().write(true).open(path).unwrap();
        file.seek(SeekFrom::Start(offset)).unwrap();
        file.write_all(bytes).unwrap();
    }

    /// Cut an existing file short in place.
    pub(crate) fn truncate_to(path: &Path, len: u64) {
        fs::OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .set_len(len)
            .unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{names, scratch};
    use super::*;

    fn publish(replace: bool, files: &[(&Path, &[u8])]) -> Result<(), PublishError> {
        let mut publication = Publication::new(replace);
        for (target, bytes) in files {
            if let Err(e) = publication.stage_file(target, bytes) {
                return Err(publication.abandon("test output", e));
            }
        }
        publication.finish("test output", || Ok(()))
    }

    #[test]
    fn replacing_commit_places_new_files_and_drops_replaced_ones() {
        let dir = scratch("commit");
        let target = dir.join("IMG_1.mov");
        fs::write(&target, b"old").unwrap();
        publish(true, &[(&target, b"new")]).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert_eq!(names(&dir), ["IMG_1.mov"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn failed_verification_removes_new_files_and_restores_replaced_ones() {
        let dir = scratch("rollback");
        let kept = dir.join("IMG_1.heic");
        let fresh = dir.join("IMG_1.mov");
        fs::write(&kept, b"previous still").unwrap();
        let mut publication = Publication::new(true);
        publication.stage_file(&kept, b"new still").unwrap();
        publication.stage_file(&fresh, b"new movie").unwrap();
        let error = publication
            .finish("test output", || Err::<(), _>("bad".to_string()))
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            "test output failed verification: bad; rolled back: removed IMG_1.heic, \
             IMG_1.mov; restored the previous IMG_1.heic"
        );
        assert!(!error.target_exists());
        assert_eq!(fs::read(&kept).unwrap(), b"previous still");
        assert_eq!(names(&dir), ["IMG_1.heic"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn exclusive_publication_refuses_any_existing_target_and_touches_nothing() {
        let dir = scratch("exclusive");
        let still = dir.join("IMG_1.heic");
        let movie = dir.join("IMG_1.mov");
        // Only the MOV name is taken: the still placed first is rolled back.
        fs::write(&movie, b"someone's movie").unwrap();
        let error = publish(false, &[(&still, b"still"), (&movie, b"movie")]).unwrap_err();
        assert!(error.target_exists(), "{error}");
        assert!(
            error.to_string().contains("IMG_1.mov already exists"),
            "{error}"
        );
        assert!(
            error
                .to_string()
                .ends_with("rolled back: removed IMG_1.heic"),
            "{error}"
        );
        assert_eq!(fs::read(&movie).unwrap(), b"someone's movie");
        assert_eq!(names(&dir), ["IMG_1.mov"]);
        // A free name goes through.
        publish(
            false,
            &[
                (&dir.join("IMG_2.heic"), b"still"),
                (&dir.join("IMG_2.mov"), b"movie"),
            ],
        )
        .unwrap();
        assert_eq!(names(&dir), ["IMG_1.mov", "IMG_2.heic", "IMG_2.mov"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_directory_or_symlink_at_a_file_target_is_never_replaced() {
        let dir = scratch("not_a_file");
        let target = dir.join("IMG_1.heic");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("keep.txt"), b"keep").unwrap();
        let error = publish(true, &[(&target, b"still")]).unwrap_err();
        assert!(error.to_string().contains("it is a directory"), "{error}");
        assert_eq!(fs::read(target.join("keep.txt")).unwrap(), b"keep");
        assert_eq!(names(&dir), ["IMG_1.heic"]);
        #[cfg(unix)]
        {
            let link = dir.join("IMG_2.heic");
            std::os::unix::fs::symlink(target.join("keep.txt"), &link).unwrap();
            let error = publish(true, &[(&link, b"still")]).unwrap_err();
            assert!(error.to_string().contains("symbolic link"), "{error}");
            assert_eq!(fs::read(target.join("keep.txt")).unwrap(), b"keep");
        }
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn dropping_an_unfinished_publication_cleans_up_staged_files() {
        let dir = scratch("drop");
        let target = dir.join("IMG_1.heic");
        {
            let mut publication = Publication::new(true);
            publication.stage_file(&target, b"still").unwrap();
            assert_eq!(names(&dir).len(), 1, "staged under a hidden name");
        }
        assert!(names(&dir).is_empty(), "{:?}", names(&dir));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn staging_never_adopts_an_existing_name() {
        let dir = scratch("never_adopt");
        let target = dir.join("IMG_1.heic");
        let mut publication = Publication::new(true);
        let staged = publication.hidden(&target, 0, "partial");
        fs::write(&staged, b"someone else's file").unwrap();
        assert!(publication.stage_file(&target, b"still").is_err());
        drop(publication);
        assert_eq!(fs::read(&staged).unwrap(), b"someone else's file");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn hidden_names_do_not_grow_with_the_target_name() {
        let dir = scratch("long_name");
        // 250 bytes: hidden names derived from it would exceed NAME_MAX.
        let target = dir.join(format!("{}.heic", "长".repeat(82)));
        assert!(target.file_name().unwrap().len() > 240);
        publish(true, &[(&target, b"still")]).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"still");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn stale_partial_entries_are_swept_but_old_ones_kept() {
        let dir = scratch("sweep");
        let two_hours_ago = SystemTime::now() - Duration::from_secs(2 * 60 * 60);
        let stale = dir.join(".xdremux-publish-1-0-0.partial");
        let fresh = dir.join(".xdremux-publish-1-1-0.partial");
        let old = dir.join(".xdremux-publish-1-0-0.old");
        for path in [&stale, &fresh, &old] {
            fs::write(path, b"x").unwrap();
        }
        for path in [&stale, &old] {
            File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_modified(two_hours_ago)
                .unwrap();
        }
        publish(true, &[(&dir.join("IMG_1.heic"), b"still")]).unwrap();
        assert_eq!(
            names(&dir),
            [
                ".xdremux-publish-1-0-0.old",
                ".xdremux-publish-1-1-0.partial",
                "IMG_1.heic"
            ]
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn compare_file_catches_changed_truncated_and_extended_files() {
        let dir = scratch("compare");
        let path = dir.join("member");
        let bytes = vec![0x59; 64 * 1024 + 1];
        fs::write(&path, &bytes).unwrap();
        compare_file(&path, &bytes).unwrap();
        for changed in [
            &bytes[..64 * 1024],
            &vec![0x59; 64 * 1024 + 2][..],
            &vec![0x58; 64 * 1024 + 1][..],
        ] {
            fs::write(&path, changed).unwrap();
            assert!(compare_file(&path, &bytes).is_err());
        }
        fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn rollback_leaves_a_target_replaced_by_another_writer() {
        let dir = scratch("foreign");
        let target = dir.join("IMG_1.mov");
        fs::write(&target, b"previous").unwrap();
        let mut publication = Publication::new(true);
        publication.stage_file(&target, b"ours").unwrap();
        let error = publication
            .finish("test output", || {
                // Another writer swaps in its own file after placement.
                let theirs = dir.join("theirs");
                fs::write(&theirs, b"theirs").unwrap();
                fs::rename(&theirs, &target).unwrap();
                Err::<(), _>("changed".to_string())
            })
            .unwrap_err()
            .to_string();
        assert!(error.contains("rollback incomplete"), "{error}");
        assert!(
            error.contains("no longer the entry this run wrote"),
            "{error}"
        );
        assert!(error.contains("the previous"), "{error}");
        assert_eq!(fs::read(&target).unwrap(), b"theirs");
        fs::remove_dir_all(&dir).unwrap();
    }
}
