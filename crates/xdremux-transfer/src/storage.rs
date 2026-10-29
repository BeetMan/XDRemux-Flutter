use crate::model::*;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tempfile::TempDir;
use uuid::Uuid;

pub(crate) struct Storage {
    pub root: PathBuf,
    lease: std::sync::Mutex<Option<File>>,
    publication: std::sync::Mutex<Publication>,
    readers_changed: tokio::sync::Notify,
}
#[derive(Default)]
struct Publication {
    readers: std::collections::HashMap<String, usize>,
    closing: bool,
}
/// A read lease on immutable committed data. Drop before awaiting Service::shutdown.
pub struct ReceiptLease {
    storage: std::sync::Arc<Storage>,
    receipt: Receipt,
    path: PathBuf,
}
impl ReceiptLease {
    pub fn receipt(&self) -> &Receipt {
        &self.receipt
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
}
impl Drop for ReceiptLease {
    fn drop(&mut self) {
        let mut publication = self.storage.publication.lock().unwrap();
        if let Some(count) = publication.readers.get_mut(&self.receipt.id) {
            *count -= 1;
            if *count == 0 {
                publication.readers.remove(&self.receipt.id);
            }
        }
        self.storage.readers_changed.notify_one();
    }
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Identity {
    pub cert: String,
    pub key: String,
    pub fingerprint: String,
}

pub(crate) fn plain(path: &Path, directory: bool) -> Result<()> {
    let m = fs::symlink_metadata(path)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if m.file_attributes() & 0x400 != 0 {
            return Err(ErrorCode::UnsafeStorage);
        }
    }
    if m.file_type().is_symlink() || (directory && !m.is_dir()) || (!directory && !m.is_file()) {
        return Err(ErrorCode::UnsafeStorage);
    }
    Ok(())
}

fn private_file(path: &Path) -> Result<File> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    Ok(opts.open(path)?)
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = private_file(path)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}
pub(crate) fn sync_dir(path: &Path) -> Result<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path; // Windows durability uses FlushFileBuffers on both files.
    Ok(())
}

/// Atomic publication with OS-enforced no-replace semantics (including directories).
pub(crate) fn publish(source: &Path, destination: &Path) -> Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
        let destination: Vec<u16> = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        // A scanner or a closing OS handle may briefly deny a directory rename.
        // Retry only sharing/access/lock errors with 450 ms total backoff. Every attempt
        // retains the same atomic no-replace operation; persistent failures fail closed.
        for attempt in 0..8 {
            // SAFETY: both buffers are valid NUL-terminated paths for the call.
            let ok = unsafe {
                windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                    source.as_ptr(),
                    destination.as_ptr(),
                    windows_sys::Win32::Storage::FileSystem::MOVEFILE_WRITE_THROUGH,
                )
            };
            if ok != 0 {
                return Ok(());
            }
            let error = std::io::Error::last_os_error();
            if attempt == 7 || !matches!(error.raw_os_error(), Some(5 | 32 | 33)) {
                return Err(error.into());
            }
            std::thread::sleep(std::time::Duration::from_millis((10 << attempt).min(100)));
        }
        unreachable!()
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let source = std::ffi::CString::new(source.as_os_str().as_bytes())
            .map_err(|_| ErrorCode::UnsafeStorage)?;
        let destination = std::ffi::CString::new(destination.as_os_str().as_bytes())
            .map_err(|_| ErrorCode::UnsafeStorage)?;
        #[cfg(any(target_os = "linux", target_os = "android"))]
        // SAFETY: valid C strings, AT_FDCWD resolves absolute private paths; the
        // kernel enforces RENAME_NOREPLACE atomically. No racy exists/rename fallback.
        let result = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                libc::AT_FDCWD,
                source.as_ptr(),
                libc::AT_FDCWD,
                destination.as_ptr(),
                1u32,
            )
        };
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        // SAFETY: valid C strings; RENAME_EXCL refuses every existing target.
        let result =
            unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
        #[cfg(not(any(
            target_os = "linux",
            target_os = "android",
            target_os = "macos",
            target_os = "ios"
        )))]
        return Err(ErrorCode::UnsafeStorage);
        #[cfg(any(
            target_os = "linux",
            target_os = "android",
            target_os = "macos",
            target_os = "ios"
        ))]
        if result != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        #[cfg(any(
            target_os = "linux",
            target_os = "android",
            target_os = "macos",
            target_os = "ios"
        ))]
        Ok(())
    }
}
fn read_small(path: &Path, max: u64) -> Result<Vec<u8>> {
    plain(path, false)?;
    let f = File::open(path)?;
    let mut bytes = Vec::new();
    f.take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        return Err(ErrorCode::UnsafeStorage);
    }
    Ok(bytes)
}
fn owned_id(name: &str, prefix: &str) -> bool {
    name.strip_prefix(prefix)
        .is_some_and(|id| Uuid::parse_str(id).is_ok())
}

impl Storage {
    pub fn open(root: &Path) -> Result<Self> {
        if !root.exists() {
            #[allow(unused_mut)]
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(root)?;
        }
        plain(root, true)?;
        let root = fs::canonicalize(root)?;
        let lock = root.join(".lock");
        if lock.exists() {
            plain(&lock, false)?;
        }
        let lease = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(lock)?;
        lease.try_lock_exclusive().map_err(|_| ErrorCode::Busy)?;
        let marker = root.join("schema");
        if !marker.exists() {
            if fs::read_dir(&root)?.any(|e| e.map_or(true, |e| e.file_name() != ".lock")) {
                return Err(ErrorCode::UnsafeStorage);
            }
            write_new(&marker, b"xdremux-transfer-v1\n")?;
        } else if read_small(&marker, 64)? != b"xdremux-transfer-v1\n" {
            return Err(ErrorCode::UnsafeStorage);
        }
        for name in [".incoming", ".outgoing", "received"] {
            let dir = root.join(name);
            if !dir.exists() {
                fs::create_dir(&dir)?;
            }
            plain(&dir, true)?;
        }
        let storage = Self {
            root,
            lease: std::sync::Mutex::new(Some(lease)),
            publication: std::sync::Mutex::new(Publication::default()),
            readers_changed: tokio::sync::Notify::new(),
        };
        storage.recover()?;
        Ok(storage)
    }
    pub fn identity(&self) -> Result<Identity> {
        let path = self.root.join("identity.json");
        let id: Identity = if path.exists() {
            serde_json::from_slice(&read_small(&path, 32 * 1024)?)
                .map_err(|_| ErrorCode::UnsafeStorage)?
        } else {
            let cert =
                localsend::crypto::cert::generate_self_signed().map_err(|_| ErrorCode::Io)?;
            let id = Identity {
                cert: cert.certificate_pem,
                key: cert.private_key_pem,
                fingerprint: cert.fingerprint,
            };
            // A crash before publication leaves a disposable staging file, not a corrupt identity.
            let staging = self.transaction(false)?;
            let temp = staging.path().join("identity");
            write_new(&temp, &serde_json::to_vec(&id).map_err(|_| ErrorCode::Io)?)?;
            publish(&temp, &path)?;
            sync_dir(&self.root)?;
            id
        };
        let cert = pem::parse(&id.cert).map_err(|_| ErrorCode::UnsafeStorage)?;
        if !valid_hash(&id.fingerprint)
            || !localsend::crypto::cert::fingerprint_from_cert_der(cert.contents())
                .eq_ignore_ascii_case(&id.fingerprint)
        {
            return Err(ErrorCode::UnsafeStorage);
        }
        localsend::http::client::LsHttpClientV2::try_new(&id.key, &id.cert, None, None)
            .map_err(|_| ErrorCode::UnsafeStorage)?;
        Ok(id)
    }
    pub async fn close(&self) {
        loop {
            {
                let mut publication = self.publication.lock().unwrap();
                publication.closing = true;
                if publication.readers.is_empty() {
                    self.lease.lock().unwrap().take();
                    return;
                }
            }
            self.readers_changed.notified().await;
        }
    }
    pub fn acquire(self: &std::sync::Arc<Self>, id: &str) -> Result<ReceiptLease> {
        let mut publication = self.publication.lock().map_err(|_| ErrorCode::Io)?;
        if publication.closing {
            return Err(ErrorCode::Closed);
        }
        let dir = self.receipt_dir(id)?;
        let receipt = self.read_receipt(&dir)?;
        *publication.readers.entry(id.to_owned()).or_default() += 1;
        Ok(ReceiptLease {
            storage: self.clone(),
            receipt,
            path: dir.join("data"),
        })
    }
    pub fn delete(&self, id: &str) -> Result<()> {
        let publication = self.publication.lock().map_err(|_| ErrorCode::Io)?;
        if publication.closing {
            return Err(ErrorCode::Closed);
        }
        if publication.readers.contains_key(id) {
            return Err(ErrorCode::Busy);
        }
        let dir = self.receipt_dir(id)?;
        self.read_receipt(&dir)?;
        // Validate all children before moving anything. Never recursively delete.
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            if entry.file_name() != "data" && entry.file_name() != "receipt.json" {
                return Err(ErrorCode::UnsafeStorage);
            }
            plain(&entry.path(), false)?;
        }
        let incoming = self.root.join(".incoming");
        plain(&incoming, true)?;
        let tombstone = incoming.join(format!("txn-{}", Uuid::new_v4()));
        publish(&dir, &tombstone)?;
        sync_dir(&self.root.join("received"))?;
        sync_dir(&incoming)?;
        self.remove_transaction(&tombstone)?;
        sync_dir(&incoming)
    }
    fn receipt_dir(&self, id: &str) -> Result<PathBuf> {
        if Uuid::parse_str(id).is_err() || Uuid::parse_str(id).unwrap().to_string() != id {
            return Err(ErrorCode::InvalidInput);
        }
        plain(&self.root, true)?;
        plain(&self.root.join("received"), true)?;
        Ok(self.root.join("received").join(format!("file-{id}")))
    }
    // Entries this store does not own (Finder's .DS_Store, antivirus or backup
    // droppings) and receipts that no longer verify are left untouched and
    // skipped: failing here would refuse every later start with no way to
    // recover the inbox from inside the app.
    fn recover(&self) -> Result<()> {
        for dir in [".incoming", ".outgoing"] {
            for entry in fs::read_dir(self.root.join(dir))? {
                let entry = entry?;
                if !owned_id(&entry.file_name().to_string_lossy(), "txn-") {
                    continue;
                }
                self.remove_transaction(&entry.path())?;
            }
        }
        for entry in fs::read_dir(self.root.join("received"))? {
            let entry = entry?;
            if !owned_id(&entry.file_name().to_string_lossy(), "file-")
                || plain(&entry.path(), true).is_err()
            {
                continue;
            }
            if !entry.path().join("receipt.json").exists() {
                self.remove_transaction(&entry.path())?;
            }
        }
        Ok(())
    }
    // Never recursively follow a local link while recovering owned staging files.
    fn remove_transaction(&self, dir: &Path) -> Result<()> {
        plain(dir, true)?;
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            plain(&entry.path(), false)?;
            fs::remove_file(entry.path())?;
        }
        fs::remove_dir(dir)?;
        Ok(())
    }
    pub fn transaction(&self, outgoing: bool) -> Result<TempDir> {
        let dir = self
            .root
            .join(if outgoing { ".outgoing" } else { ".incoming" });
        plain(&self.root, true)?;
        plain(&dir, true)?;
        Ok(tempfile::Builder::new()
            .prefix(&format!("txn-{}", Uuid::new_v4()))
            .rand_bytes(0)
            .tempdir_in(dir)?)
    }
    pub fn space(&self, bytes: u64, reserve: u64) -> Result<()> {
        if fs2::available_space(&self.root)?
            < bytes.checked_add(reserve).ok_or(ErrorCode::NoSpace)?
        {
            return Err(ErrorCode::NoSpace);
        }
        Ok(())
    }
    pub fn commit(&self, staging: &Path, receipt: &Receipt) -> Result<()> {
        let _publication = self.publication.lock().map_err(|_| ErrorCode::Io)?;
        let received = self.root.join("received");
        plain(&received, true)?;
        plain(staging, false)?;
        let dest = received.join(format!("file-{}", receipt.id));
        let transaction = staging.parent().ok_or(ErrorCode::UnsafeStorage)?;
        plain(transaction, true)?;
        if transaction.parent() != Some(self.root.join(".incoming").as_path())
            || !owned_id(
                &transaction
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy(),
                "txn-",
            )
        {
            return Err(ErrorCode::UnsafeStorage);
        }
        write_new(
            &transaction.join("receipt.json"),
            &serde_json::to_vec(receipt).map_err(|_| ErrorCode::Io)?,
        )?;
        sync_dir(transaction)?;
        publish(transaction, &dest)?;
        let result = (|| {
            sync_dir(&received)?;
            sync_dir(&self.root.join(".incoming"))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = self.remove_transaction(&dest);
        }
        result
    }
    fn read_receipt(&self, directory: &Path) -> Result<Receipt> {
        plain(directory, true)?;
        let r: Receipt =
            serde_json::from_slice(&read_small(&directory.join("receipt.json"), 16 * 1024)?)
                .map_err(|_| ErrorCode::UnsafeStorage)?;
        if Uuid::parse_str(&r.id).is_err()
            || directory.file_name().unwrap_or_default() != format!("file-{}", r.id).as_str()
            || !safe_name(&r.name)
            || !valid_hash(&r.sha256)
        {
            return Err(ErrorCode::UnsafeStorage);
        }
        plain(&directory.join("data"), false)?;
        if fs::metadata(directory.join("data"))?.len() != r.size {
            return Err(ErrorCode::UnsafeStorage);
        }
        Ok(r)
    }
    pub fn receipts_after(&self, after: Option<&str>, limit: usize) -> Result<Vec<Receipt>> {
        let _publication = self.publication.lock().map_err(|_| ErrorCode::Io)?;
        if limit == 0 || limit > 1024 || after.is_some_and(|id| Uuid::parse_str(id).is_err()) {
            return Err(ErrorCode::InvalidInput);
        }
        let received = self.root.join("received");
        plain(&received, true)?;
        let mut results = std::collections::BTreeMap::new();
        for entry in fs::read_dir(received)? {
            let entry = entry?;
            // A directory without a marker is an in-flight commit, never an exposed file.
            if !owned_id(&entry.file_name().to_string_lossy(), "file-")
                || !entry.path().join("receipt.json").exists()
            {
                continue;
            }
            // One damaged receipt must not hide every other one.
            let Ok(receipt) = self.read_receipt(&entry.path()) else {
                continue;
            };
            if after.is_none_or(|id| receipt.id.as_str() > id) {
                results.insert(receipt.id.clone(), receipt);
                if results.len() > limit {
                    results.pop_last();
                }
            }
        }
        Ok(results.into_values().collect())
    }
    pub fn data_path(&self, id: &str) -> Result<PathBuf> {
        let _publication = self.publication.lock().map_err(|_| ErrorCode::Io)?;
        let dir = self.receipt_dir(id)?;
        self.read_receipt(&dir)?;
        Ok(dir.join("data"))
    }
}

pub(crate) fn hex(bytes: impl AsRef<[u8]>) -> String {
    bytes.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}
pub async fn hash_file(path: &Path) -> Result<String> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(path).await?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(hex(hash.finalize()))
}
