//! Write, place, read back, then commit or roll back: how a Live Photo
//! conversion publishes its outputs (the HEIC + MOV pair and the `.pvt`
//! bundle).
//!
//! Each output is first written under a hidden name of fixed length that did
//! not exist before (`.xdremux-publish-<run>-<n>.partial`, `create_new`),
//! flushed, then renamed onto its final path. `<run>` is random, so a run
//! never picks the name of an entry a killed run left behind, in this process
//! or another (another machine writing to the same share included). What
//! happens to an entry already at the final path depends on the publication:
//!
//! - replacing: it is renamed aside (`.xdremux-publish-<run>-<n>.old`, never
//!   onto an existing entry) and only deleted once the run commits;
//! - exclusive: the run fails with [`PublishError::target_exists`] and
//!   touches nothing.
//!
//! Every rename refuses an existing target (`renameat2(RENAME_NOREPLACE)`,
//! `renamex_np(RENAME_EXCL)`, `MoveFileExW` without replace); on file systems
//! without such a rename it checks first, which cannot guard against another
//! process slipping in between. Publications in one process that target the
//! same directory run one after the other while placing, verifying and
//! committing (or rolling back).
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
//! run wrote. The identity is taken from the written file (FAT/exFAT number
//! an empty file with a placeholder). After the rename, when a file system
//! derives a new identity from the destination path (some network shares), the
//! identity is followed only if the entry at the final path still hashes
//! (SHA-256) identically to what this run wrote.
//! An output another writer has replaced is left alone and named in the error.
//! Other platforms identify outputs by path.
//!
//! A run killed between placing and committing can leave hidden entries
//! behind. The first run in a process that publishes into a directory removes
//! `.partial` entries older than an hour there. `.old` entries are kept: one
//! may be the only copy of an earlier output.

use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    /// output paths and left everything as it was: pick another name and
    /// retry. False when the rollback after that could not be completed.
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

/// What this run's entry looked like when it was written: its identity, and
/// a SHA-256 digest of what it wrote so a path-derived identity can be
/// verified after a rename without trusting size or coarse modification times.
#[derive(Clone, Copy)]
struct Seen {
    identity: Identity,
    digest: [u8; 32],
}

impl Seen {
    fn of(meta: &fs::Metadata, digest: [u8; 32]) -> Self {
        Self {
            identity: identity_of(meta),
            digest,
        }
    }

    /// False only when `meta` is provably another entry.
    fn may_be(&self, meta: &fs::Metadata) -> bool {
        self.identity.is_none() || identity_of(meta) == self.identity
    }

    /// Take the identity of `meta` only if the entry on disk at `path` still
    /// hashes identically to what this run wrote.
    fn follow(&mut self, path: &Path, kind: Kind, meta: &fs::Metadata) {
        let actual = match kind {
            Kind::File => sha256_file(path),
            Kind::Directory => sha256_dir_on_disk(path),
        };
        if actual.ok() == Some(self.digest) {
            self.identity = identity_of(meta);
        }
    }
}

fn sha256_bytes(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn sha256_file(path: &Path) -> std::io::Result<[u8; 32]> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().into())
}

fn sha256_dir_entries(files: &[(&str, &[u8])]) -> [u8; 32] {
    let mut sorted: Vec<(&str, &[u8])> = files.to_vec();
    sorted.sort_by_key(|(name, _)| *name);
    let mut hasher = Sha256::new();
    for (name, bytes) in sorted {
        hasher.update((name.len() as u64).to_le_bytes());
        hasher.update(name.as_bytes());
        hasher.update((bytes.len() as u64).to_le_bytes());
        hasher.update(bytes);
    }
    hasher.finalize().into()
}

fn sha256_dir_on_disk(dir: &Path) -> std::io::Result<[u8; 32]> {
    let mut entries = Vec::new();
    for item in fs::read_dir(dir)? {
        let item = item?;
        let name = item.file_name();
        let Some(name) = name.to_str() else {
            return Err(std::io::Error::from(ErrorKind::InvalidData));
        };
        if name.starts_with('.') {
            continue;
        }
        let path = item.path();
        let meta = fs::symlink_metadata(&path)?;
        if !meta.file_type().is_file() {
            return Err(std::io::Error::from(ErrorKind::InvalidData));
        }
        entries.push((name.to_string(), path, meta.len()));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    for (name, path, len) in entries {
        hasher.update((name.len() as u64).to_le_bytes());
        hasher.update(name.as_bytes());
        hasher.update(len.to_le_bytes());
        let mut file = File::open(&path)?;
        let mut seen_len = 0u64;
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            seen_len += n as u64;
            hasher.update(&buf[..n]);
        }
        if seen_len != len {
            return Err(std::io::Error::from(ErrorKind::InvalidData));
        }
    }
    Ok(hasher.finalize().into())
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

/// The directory `path` is in (`.` for a bare file name).
pub(crate) fn parent_of(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
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

/// A run's random tag. The OS seeds `RandomState`; the time, process and
/// counter only make two tags in one process differ for certain.
fn random_tag() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = RandomState::new().build_hasher();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    hasher.write_u128(nanos);
    hasher.write_u32(std::process::id());
    hasher.write_u64(NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed));
    format!("{:016x}", hasher.finish())
}

/// Flush a written file before it is renamed into place: its data must reach
/// the disk before the entry it replaces is deleted. Apple's `sync_all` is
/// `F_FULLFSYNC`, which SMB shares without full-sync support and WebDAV
/// reject. Ordering is all a publication needs, so use `F_BARRIERFSYNC` there
/// and fall back to `fsync` when a file system does not support it, as SQLite
/// and Go do. Other errors (EIO) are reported.
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
    match retrying(&|| unsafe { libc::fcntl(fd, libc::F_BARRIERFSYNC) }) {
        Err(e)
            if matches!(
                e.raw_os_error(),
                Some(libc::ENOTSUP | libc::EOPNOTSUPP | libc::ENOTTY | libc::EINVAL | libc::ENODEV)
            ) =>
        {
            retrying(&|| unsafe { libc::fsync(fd) })
        }
        other => other,
    }
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
        Err(e) if unsupported(&e) => match fs::symlink_metadata(to) {
            Err(e) if e.kind() == ErrorKind::NotFound => fs::rename(from, to),
            Err(e) => Err(e),
            Ok(_) => Err(ErrorKind::AlreadyExists.into()),
        },
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

/// `path` as an absolute, NUL-terminated `\\?\` path. Without that prefix
/// `MoveFileExW` stops at MAX_PATH (260 UTF-16 units); `std::fs` adds it
/// itself, and so must a direct call. `absolute` also turns `/` into `\` and
/// resolves `.` and `..`, which a `\\?\` path no longer does.
#[cfg(windows)]
fn verbatim(path: &Path) -> std::io::Result<Vec<u16>> {
    use std::os::windows::ffi::OsStrExt;
    const SLASH: u16 = b'\\' as u16;
    let absolute: Vec<u16> = std::path::absolute(path)?
        .as_os_str()
        .encode_wide()
        .collect();
    let mut wide = Vec::with_capacity(absolute.len() + 9);
    if absolute.starts_with(&[SLASH, SLASH, b'?' as u16, SLASH])
        || absolute.starts_with(&[SLASH, SLASH, b'.' as u16, SLASH])
    {
        wide.extend_from_slice(&absolute);
    } else if absolute.starts_with(&[SLASH, SLASH]) {
        // \\server\share\... becomes \\?\UNC\server\share\...
        wide.extend(r"\\?\UNC\".encode_utf16());
        wide.extend_from_slice(&absolute[2..]);
    } else {
        wide.extend(r"\\?\".encode_utf16());
        wide.extend_from_slice(&absolute);
    }
    wide.push(0);
    Ok(wide)
}

#[cfg(windows)]
fn rename_noreplace(from: &Path, to: &Path) -> std::io::Result<()> {
    #[link(name = "kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    let (from, to) = (verbatim(from)?, verbatim(to)?);
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
/// per process (the record is bounded; forgetting a directory only means a
/// second sweep), and only those older than an hour, so a run still writing
/// elsewhere is never touched.
fn sweep_stale(dir: &Path) {
    static SWEPT: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);
    {
        let mut swept = SWEPT.lock().unwrap_or_else(|e| e.into_inner());
        let swept = swept.get_or_insert_with(HashSet::new);
        if swept.contains(dir) {
            return;
        }
        if swept.len() >= 1024 {
            swept.clear();
        }
        swept.insert(dir.to_path_buf());
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

/// Output directories a publication in this process is placing, verifying
/// and committing (or rolling back). Another publication targeting the same
/// canonical directory waits until it is released, avoiding Unicode case/NFD
/// mismatches so two runs in one process never move each other's entries aside.
static BUSY: (Mutex<Vec<PathBuf>>, Condvar) = (Mutex::new(Vec::new()), Condvar::new());

struct Claim(Vec<PathBuf>);

impl Claim {
    fn take<'a>(targets: impl Iterator<Item = &'a Path>) -> Self {
        let mut keys: Vec<PathBuf> = targets
            .map(|target| {
                let dir = parent_of(target);
                fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf())
            })
            .collect();
        keys.sort();
        keys.dedup();
        let (lock, released) = &BUSY;
        let mut busy = lock.lock().unwrap_or_else(|e| e.into_inner());
        while keys.iter().any(|key| busy.contains(key)) {
            busy = released.wait(busy).unwrap_or_else(|e| e.into_inner());
        }
        busy.extend(keys.iter().cloned());
        Self(keys)
    }
}

impl Drop for Claim {
    fn drop(&mut self) {
        let (lock, released) = &BUSY;
        let mut busy = lock.lock().unwrap_or_else(|e| e.into_inner());
        busy.retain(|key| !self.0.contains(key));
        released.notify_all();
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
    seen: Option<Seen>,
    /// Where the entry previously at `target` was moved aside.
    retired: Option<PathBuf>,
    placed: bool,
}

impl Entry {
    /// The path this run's entry is at now.
    fn current(&self) -> &Path {
        if self.placed {
            &self.target
        } else {
            &self.staged
        }
    }

    /// How the entry is named in an error: its final name, and while it is
    /// not placed also the hidden name it waits under.
    fn label(&self) -> String {
        if self.placed {
            self.target.display().to_string()
        } else {
            format!(
                "{} (staged for {})",
                self.staged.display(),
                file_name(&self.target)
            )
        }
    }
}

/// What a rollback did: a clause for the error message, and whether
/// everything was removed and restored.
struct Rollback {
    summary: String,
    complete: bool,
}

/// One run's outputs. Dropping it without `finish` rolls back.
pub(crate) struct Publication {
    tag: String,
    replace: bool,
    entries: Vec<Entry>,
    finished: bool,
    #[cfg(test)]
    after_rename: Option<Box<dyn Fn(&Path)>>,
}

impl Publication {
    /// With `replace`, entries already at the output paths are moved aside and
    /// replaced; without it, an existing entry makes `finish` fail with
    /// [`PublishError::target_exists`] and nothing is touched.
    pub(crate) fn new(replace: bool) -> Self {
        Self {
            tag: random_tag(),
            replace,
            entries: Vec::new(),
            finished: false,
            #[cfg(test)]
            after_rename: None,
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
        let written = write_synced(&mut file, &staged, bytes);
        let digest = sha256_bytes(bytes);
        // Recognise the file by what it is after writing (FAT/exFAT number an
        // empty file with a placeholder), taken from the open file itself.
        let seen = file.metadata().ok().map(|m| Seen::of(&m, digest));
        self.entries.push(Entry {
            staged,
            target: target.to_path_buf(),
            kind: Kind::File,
            seen,
            retired: None,
            placed: false,
        });
        written
    }

    /// Create a new hidden directory next to `target` holding `files` (each
    /// created exclusively and synced), and record its combined SHA-256 digest.
    pub(crate) fn stage_directory(
        &mut self,
        target: &Path,
        files: &[(&str, &[u8])],
    ) -> Result<(), String> {
        sweep_stale(parent_of(target));
        let staged = self.hidden(target, self.entries.len(), "partial");
        fs::create_dir(&staged).map_err(|e| format!("cannot create {}: {e}", staged.display()))?;
        let digest = sha256_dir_entries(files);
        let seen = fs::symlink_metadata(&staged)
            .ok()
            .map(|m| Seen::of(&m, digest));
        self.entries.push(Entry {
            staged: staged.clone(),
            target: target.to_path_buf(),
            kind: Kind::Directory,
            seen,
            retired: None,
            placed: false,
        });
        for (name, bytes) in files {
            write_new_synced(&staged.join(name), bytes)?;
        }
        Ok(())
    }

    /// Give up before placing anything; `error` is why.
    pub(crate) fn abandon(self, what: &str, error: String) -> PublishError {
        PublishError::new(format!(
            "{what} could not be written: {error}; {}",
            self.rollback().summary
        ))
    }

    /// Place every staged output, run `verify` on the placed outputs, then
    /// commit if it passes and roll back if anything fails. `what` names the
    /// output in error messages.
    pub(crate) fn finish<T>(
        self,
        what: &str,
        verify: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, PublishError> {
        // Claim before moving `self` so that if `verify` panics and unwinds,
        // `publication`'s Drop rollback still runs under the claim.
        let _claim = Claim::take(self.entries.iter().map(|e| e.target.as_path()));
        let mut publication = self;
        if let Err(error) = publication.place() {
            let rollback = publication.rollback();
            return Err(PublishError {
                message: format!(
                    "{what} could not be written: {}; {}",
                    error.message, rollback.summary
                ),
                // "Nothing was touched" holds only if the rollback completed.
                target_exists: error.target_exists && rollback.complete,
            });
        }
        match verify() {
            Ok(value) => {
                publication.commit();
                Ok(value)
            }
            Err(error) => Err(PublishError::new(format!(
                "{what} failed verification: {error}; {}",
                publication.rollback().summary
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
                    let retired = self.retire(&target, index)?;
                    self.entries[index].retired = Some(retired);
                }
            }
            let entry = &mut self.entries[index];
            match rename_exclusive(&entry.staged, &target) {
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
            entry.placed = true;
            #[cfg(test)]
            if let Some(hook) = &self.after_rename {
                hook(&target);
            }
            // Most file systems keep the identity across a rename; some
            // network ones derive it from the path. Follow it only when the
            // entry on disk still hashes identically to what this run wrote,
            // so a file swapped in by another writer is never taken for ours.
            let entry = &mut self.entries[index];
            if let (Some(seen), Ok(meta)) = (entry.seen.as_mut(), fs::symlink_metadata(&target)) {
                if !seen.may_be(&meta) {
                    seen.follow(&target, entry.kind, &meta);
                }
            }
        }
        self.sync_directories();
        Ok(())
    }

    /// Move the entry at `target` aside under a hidden name that is free
    /// (never onto an entry a killed run left there) and return that name.
    fn retire(&self, target: &Path, index: usize) -> Result<PathBuf, PublishError> {
        for attempt in 0..8 {
            let retired = match attempt {
                0 => self.hidden(target, index, "old"),
                n => self.hidden(target, index, &format!("{n}.old")),
            };
            match rename_exclusive(target, &retired) {
                Ok(()) => return Ok(retired),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
                Err(e) => {
                    return Err(PublishError::new(format!(
                        "cannot move the existing {} aside: {e}",
                        target.display()
                    )))
                }
            }
        }
        Err(PublishError::new(format!(
            "cannot move the existing {} aside: no free hidden name",
            target.display()
        )))
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
        let mut removed_any = false;
        for entry in &self.entries {
            if let Some(retired) = &entry.retired {
                removed_any |= remove_entry(retired).is_ok();
            }
        }
        if removed_any {
            self.sync_directories();
        }
    }

    /// Undo this run.
    fn rollback(mut self) -> Rollback {
        self.finished = true;
        self.undo()
    }

    fn undo(&mut self) -> Rollback {
        let mut removed = Vec::new();
        let mut restored = Vec::new();
        let mut problems = Vec::new();
        for entry in self.entries.iter().rev() {
            let ours = entry.current();
            match fs::symlink_metadata(ours) {
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) => problems.push(format!("cannot inspect {}: {e}", entry.label())),
                Ok(meta) if entry.seen.is_some_and(|seen| !seen.may_be(&meta)) => {
                    problems.push(format!(
                        "left {} alone: it is no longer the entry this run wrote",
                        entry.label()
                    ))
                }
                Ok(_) => match remove_entry(ours) {
                    Ok(()) if entry.placed => removed.push(file_name(&entry.target)),
                    Ok(()) => {}
                    Err(e) => problems.push(format!("cannot remove {}: {e}", entry.label())),
                },
            }
            let Some(retired) = &entry.retired else {
                continue;
            };
            // Never onto an occupied path: that would replace whatever is
            // there, for example another writer's new output.
            match rename_exclusive(retired, &entry.target) {
                Ok(()) => restored.push(file_name(&entry.target)),
                Err(e) => problems.push(format!(
                    "the previous {} is kept at {} ({e})",
                    entry.target.display(),
                    retired.display()
                )),
            }
        }
        if !problems.is_empty() {
            problems.reverse();
            return Rollback {
                summary: format!("rollback incomplete: {}", problems.join("; ")),
                complete: false,
            };
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
        Rollback {
            summary,
            complete: true,
        }
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

    #[test]
    fn a_killed_runs_old_entry_is_never_overwritten() {
        let dir = scratch("killed_old");
        let target = dir.join("IMG_1.heic");
        fs::write(&target, b"previous").unwrap();
        let mut publication = Publication::new(true);
        // What a killed run with the same name would have left behind.
        let left = publication.hidden(&target, 0, "old");
        fs::write(&left, b"only copy of an earlier output").unwrap();
        publication.stage_file(&target, b"new").unwrap();
        publication.finish("test output", || Ok(())).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert_eq!(fs::read(&left).unwrap(), b"only copy of an earlier output");
        assert_eq!(names(&dir).len(), 2, "{:?}", names(&dir));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn runs_never_share_hidden_names() {
        let a = Publication::new(true);
        let b = Publication::new(true);
        let target = Path::new("IMG_1.heic");
        assert_ne!(a.hidden(target, 0, "old"), b.hidden(target, 0, "old"));
    }

    #[cfg(unix)]
    #[test]
    fn a_file_swapped_in_right_after_the_rename_is_not_taken_for_ours() {
        let dir = scratch("swapped_in");
        let target = dir.join("IMG_1.heic");
        let theirs = dir.join("theirs");
        let mut publication = Publication::new(true);
        publication.stage_file(&target, b"ours").unwrap();
        let swap_from = theirs.clone();
        publication.after_rename = Some(Box::new(move |placed: &Path| {
            fs::write(&swap_from, b"another writer's file").unwrap();
            fs::rename(&swap_from, placed).unwrap();
        }));
        let error = publication
            .finish("test output", || Err::<(), _>("changed".to_string()))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("no longer the entry this run wrote"),
            "{error}"
        );
        assert_eq!(fs::read(&target).unwrap(), b"another writer's file");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_same_size_same_mtime_file_swapped_in_after_rename_is_not_taken_for_ours() {
        let dir = scratch("swapped_in_same_mtime");
        let target = dir.join("IMG_1.heic");
        let theirs = dir.join("theirs");
        let mut publication = Publication::new(true);
        publication.stage_file(&target, b"ours").unwrap();
        let swap_from = theirs.clone();
        publication.after_rename = Some(Box::new(move |placed: &Path| {
            let mtime = fs::symlink_metadata(placed).unwrap().modified().unwrap();
            fs::write(&swap_from, b"them").unwrap();
            File::options()
                .write(true)
                .open(&swap_from)
                .unwrap()
                .set_modified(mtime)
                .unwrap();
            fs::rename(&swap_from, placed).unwrap();
        }));
        let error = publication
            .finish("test output", || Err::<(), _>("changed".to_string()))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("no longer the entry this run wrote"),
            "{error}"
        );
        assert_eq!(fs::read(&target).unwrap(), b"them");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn an_incomplete_rollback_does_not_report_target_exists() {
        let dir = scratch("incomplete_exists");
        let still = dir.join("IMG_1.heic");
        let movie = dir.join("IMG_1.mov");
        fs::write(&movie, b"someone's movie").unwrap();
        let mut publication = Publication::new(false);
        publication.stage_file(&still, b"still").unwrap();
        publication.stage_file(&movie, b"movie").unwrap();
        // The placed still is replaced before the MOV turns out to be taken,
        // so the rollback cannot remove it: the destination is not as it was.
        let theirs = dir.join("theirs");
        publication.after_rename = Some(Box::new(move |placed: &Path| {
            fs::write(&theirs, b"another still").unwrap();
            fs::rename(&theirs, placed).unwrap();
        }));
        let error = publication.finish("test output", || Ok(())).unwrap_err();
        assert!(!error.target_exists(), "{error}");
        assert!(error.to_string().contains("already exists"), "{error}");
        assert!(error.to_string().contains("rollback incomplete"), "{error}");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn publications_to_the_same_target_in_one_process_take_turns() {
        let dir = scratch("take_turns");
        let still = dir.join("IMG_1.heic");
        let movie = dir.join("IMG_1.mov");
        fs::write(&still, b"old still").unwrap();
        fs::write(&movie, b"old movie").unwrap();
        let workers: Vec<_> = (0..4u8)
            .map(|worker| {
                let (still, movie) = (still.clone(), movie.clone());
                std::thread::spawn(move || {
                    for round in 0..25u8 {
                        let tag = [worker, round];
                        let mut publication = Publication::new(true);
                        publication.stage_file(&still, &tag).unwrap();
                        publication.stage_file(&movie, &tag).unwrap();
                        publication
                            .finish("test output", || {
                                compare_file(&still, &tag)?;
                                compare_file(&movie, &tag)
                            })
                            .unwrap();
                    }
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
        // Every publication succeeded, the last one left a matching pair and
        // nothing hidden stayed behind.
        assert_eq!(fs::read(&still).unwrap(), fs::read(&movie).unwrap());
        assert_eq!(names(&dir), ["IMG_1.heic", "IMG_1.mov"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn windows_paths_go_to_movefileexw_in_verbatim_form() {
        let text = |p: &str| String::from_utf16(&verbatim(Path::new(p)).unwrap()).unwrap();
        assert_eq!(
            text(r"C:\photos\IMG_1.heic"),
            "\\\\?\\C:\\photos\\IMG_1.heic\0"
        );
        assert_eq!(
            text(r"C:/photos/./x/../IMG_1.heic"),
            "\\\\?\\C:\\photos\\IMG_1.heic\0"
        );
        assert_eq!(
            text(r"\\server\share\IMG_1.heic"),
            "\\\\?\\UNC\\server\\share\\IMG_1.heic\0"
        );
        let long = format!(r"C:\{}\IMG_1.heic", "d".repeat(300));
        assert!(text(&long).starts_with("\\\\?\\C:\\"));
    }
}
