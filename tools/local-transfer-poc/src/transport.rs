use anyhow::{bail, ensure, Context, Result};
use localsend::{
    crypto::{
        cert::{generate_self_signed, SelfSignedCert},
        hash::sha256_file_content,
    },
    http::{
        client::v2::LsHttpClientV2,
        dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2},
        server::{
            common::save::FileUploadTarget,
            start_with_port,
            v2::{PrepareUploadDecisionV2, ServerEventV2},
            ServerConfigV2, ServerHandle, TlsConfig,
        },
        state::ClientInfo,
    },
    model::{
        discovery::{DeviceType, ProtocolType},
        transfer::{FileContent, FileDto},
    },
};
use serde::Serialize;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_util::{io::ReaderStream, sync::CancellationToken};
use uuid::Uuid;

pub struct Identity {
    cert: SelfSignedCert,
    alias: String,
}
impl Identity {
    pub fn new(alias: &str) -> Result<Self> {
        Ok(Self {
            cert: generate_self_signed()?,
            alias: alias.to_owned(),
        })
    }
    fn register(&self, port: u16) -> RegisterDtoV2 {
        RegisterDtoV2 {
            alias: self.alias.clone(),
            version: "2.2".into(),
            device_model: Some("XDRemux protocol PoC".into()),
            device_type: Some(DeviceType::Headless),
            fingerprint: self.cert.fingerprint.clone(),
            port,
            protocol: ProtocolType::Https,
            download: false,
        }
    }
    fn client(&self, fingerprint: Option<String>) -> Result<LsHttpClientV2> {
        Ok(LsHttpClientV2::try_new(
            &self.cert.private_key_pem,
            &self.cert.certificate_pem,
            fingerprint,
            Some(Duration::from_secs(90)),
        )?)
    }
}

pub async fn hash_file(path: &Path) -> Result<String> {
    Ok(sha256_file_content(
        FileContent::Path(path.to_path_buf()),
        &CancellationToken::new(),
        |_| {},
    )
    .await?)
}

#[derive(Clone, Debug, Serialize)]
pub struct FileResult {
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub peer_hash_present: bool,
    pub success: bool,
    pub elapsed_ms: u128,
}

pub struct Receiver {
    server: ServerHandle,
    stop: oneshot::Sender<()>,
    worker_stop: CancellationToken,
    worker: tokio::task::JoinHandle<()>,
    results: Arc<Mutex<Vec<FileResult>>>,
    fingerprint: String,
    identity: Identity,
    pub startup_ms: u128,
}
impl Receiver {
    pub async fn start(
        root: PathBuf,
        port: u16,
        pin: Option<String>,
        decline: bool,
    ) -> Result<Self> {
        let started = Instant::now();
        // The harness owns a new output directory; never reuse a user's folder.
        ensure!(!root.exists(), "receive directory must not already exist");
        tokio::fs::create_dir_all(root.join("incoming")).await?;
        tokio::fs::create_dir_all(root.join("received")).await?;
        let identity = Identity::new("XDRemux PoC receiver")?;
        let fingerprint = identity.cert.fingerprint.clone();
        let (tx, mut rx) = mpsc::channel(32);
        let (stop, stop_rx) = oneshot::channel();
        let server = start_with_port(
            port,
            Some(TlsConfig {
                cert: identity.cert.certificate_pem.clone(),
                private_key: identity.cert.private_key_pem.clone(),
            }),
            ClientInfo {
                alias: identity.alias.clone(),
                version: "2.2".into(),
                device_model: Some("XDRemux protocol PoC".into()),
                device_type: Some(DeviceType::Headless),
                token: Uuid::new_v4().to_string(),
            },
            None,
            Some(ServerConfigV2 {
                pin,
                verify_checksums: true,
                event_tx: tx,
            }),
            None,
            stop_rx,
        )
        .await?;
        let results = Arc::new(Mutex::new(Vec::new()));
        let worker_results = results.clone();
        let worker_stop = CancellationToken::new();
        let worker_cancel = worker_stop.clone();
        let worker = tokio::spawn(async move {
            let mut jobs = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    _ = worker_cancel.cancelled() => break,
                    Some(_) = jobs.join_next(), if !jobs.is_empty() => {},
                    event = rx.recv() => {
                        let Some(event) = event else { break };
                        match event {
                            ServerEventV2::PrepareUpload {files, decision_tx, ..} => {
                                let mut total = 0u64;
                                let mut names = std::collections::HashSet::new();
                                let valid = !files.is_empty() && files.len() <= 1024 && files.values().all(|file| {
                                    total = total.saturating_add(file.size);
                                    safe_test_name(&file.file_name) && names.insert(file.file_name.to_lowercase()) && file.size <= 64*1024*1024
                                }) && total <= 256*1024*1024;
                                let answer = if valid && !decline { PrepareUploadDecisionV2::Accept(files.keys().cloned().collect()) } else { PrepareUploadDecisionV2::Decline };
                                let _ = decision_tx.send(answer);
                            }
                            ServerEventV2::FileUpload {session_id, file, target_tx, ..} => {
                                let root = root.clone();
                                let output = worker_results.clone();
                                jobs.spawn(async move {
                                    let start = Instant::now();
                                    let temporary = root.join("incoming").join(format!("{}.part", Uuid::new_v4()));
                                    let (result_tx, result_rx) = oneshot::channel();
                                    if target_tx.send(FileUploadTarget::Path {path: temporary.clone(), result_tx, progress_tx: None}).is_err() { return; }
                                    let mut success = matches!(result_rx.await, Ok(Ok(())));
                                    let size = tokio::fs::metadata(&temporary).await.map(|m| m.len()).unwrap_or(0);
                                    let hash = hash_file(&temporary).await.unwrap_or_default();
                                    success &= size == file.size && !hash.is_empty();
                                    if let Some(expected) = &file.sha256 { success &= hash.eq_ignore_ascii_case(expected); }
                                    // Session ID comes from the server, not from a supplied filename.
                                    let destination = root.join("received").join(session_id);
                                    if success {
                                        success = tokio::fs::create_dir_all(&destination).await.is_ok();
                                        let final_path = destination.join(&file.file_name);
                                        // Duplicate basenames fail rather than overwrite an earlier result.
                                        success &= !final_path.exists();
                                        if success { success = tokio::fs::rename(&temporary, final_path).await.is_ok(); }
                                    }
                                    if !success { let _ = tokio::fs::remove_file(&temporary).await; }
                                    output.lock().await.push(FileResult {name: file.file_name, size, sha256: hash, peer_hash_present: file.sha256.is_some(), success, elapsed_ms: start.elapsed().as_millis()});
                                });
                            }
                            _ => {},
                        }
                    }
                }
            }
            while jobs.join_next().await.is_some() {}
        });
        Ok(Self {
            server,
            stop,
            worker_stop,
            worker,
            results,
            fingerprint,
            identity,
            startup_ms: started.elapsed().as_millis(),
        })
    }
    pub fn port(&self) -> u16 {
        self.server.port()
    }
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }
    pub async fn register_with(&self, host: &str, port: u16) -> Result<()> {
        self.identity
            .client(None)?
            .register(
                ProtocolType::Https,
                host,
                port,
                self.identity.register(self.port()),
            )
            .await?;
        Ok(())
    }
    pub async fn stop(self) -> Result<Vec<FileResult>> {
        let _ = self.stop.send(());
        self.server.wait_stopped().await;
        self.worker_stop.cancel();
        self.worker.await?;
        Ok(self.results.lock().await.clone())
    }
}

fn safe_test_name(name: &str) -> bool {
    name.starts_with("xdremux-poc-")
        && name.len() <= 180
        && !name.ends_with('.')
        && !name.ends_with(' ')
        && !name
            .chars()
            .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c))
}

#[allow(
    clippy::too_many_arguments,
    reason = "Test harness keeps protocol arguments and fault injection explicit."
)]
pub async fn send_files(
    identity: &Identity,
    host: &str,
    port: u16,
    pin: Option<&str>,
    expected_fingerprint: Option<String>,
    paths: &[PathBuf],
    corrupt_hash: bool,
) -> Result<Vec<FileResult>> {
    ensure!(!paths.is_empty(), "no files");
    // Unpinned TLS is used only for metadata discovery, never for file upload.
    let discovered = identity
        .client(None)?
        .register(ProtocolType::Https, host, port, identity.register(0))
        .await?;
    let fingerprint = discovered
        .cert_fingerprint
        .context("HTTPS peer omitted certificate identity")?;
    if let Some(expected) = expected_fingerprint {
        ensure!(
            expected.eq_ignore_ascii_case(&fingerprint),
            "peer fingerprint mismatch"
        );
    }
    let client = identity.client(Some(fingerprint))?;
    let mut files = HashMap::new();
    let mut sources = HashMap::new();
    for path in paths {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .context("invalid filename")?
            .to_string();
        ensure!(
            safe_test_name(&name),
            "only xdremux-poc-* test basenames are allowed"
        );
        let metadata = tokio::fs::metadata(path).await?;
        ensure!(metadata.is_file(), "not a file");
        let id = Uuid::new_v4().to_string();
        let hash = if corrupt_hash {
            "0".repeat(64)
        } else {
            hash_file(path).await?
        };
        files.insert(
            id.clone(),
            FileDto {
                id: id.clone(),
                file_name: name,
                size: metadata.len(),
                file_type: "application/octet-stream".into(),
                sha256: Some(hash),
                preview: None,
                metadata: None,
            },
        );
        sources.insert(id, path.clone());
    }
    let prepared = client
        .prepare_upload(
            ProtocolType::Https,
            host,
            port,
            None,
            PrepareUploadRequestDtoV2 {
                info: identity.register(0),
                files: files.clone(),
            },
            pin,
            CancellationToken::new(),
        )
        .await?;
    let session = prepared.response.context("receiver accepted no files")?;
    ensure!(
        session.files.len() == files.len(),
        "receiver accepted only a subset"
    );
    let mut report = Vec::new();
    for (id, token) in session.files {
        let file = files
            .get(&id)
            .context("receiver returned unoffered file id")?;
        let path = sources.get(&id).context("missing source")?;
        let start = Instant::now();
        let body = localsend::reqwest::Body::wrap_stream(ReaderStream::new(
            tokio::fs::File::open(path).await?,
        ));
        if let Err(error) = client
            .upload(
                ProtocolType::Https,
                host,
                port,
                None,
                &session.session_id,
                &id,
                &token,
                body,
                CancellationToken::new(),
            )
            .await
        {
            let _ = client
                .cancel(ProtocolType::Https, host, port, &session.session_id)
                .await;
            bail!("upload failed: {error}");
        }
        report.push(FileResult {
            name: file.file_name.clone(),
            size: file.size,
            sha256: file.sha256.clone().unwrap_or_default(),
            peer_hash_present: true,
            success: true,
            elapsed_ms: start.elapsed().as_millis(),
        });
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture() -> Result<(PathBuf, PathBuf)> {
        let root = std::env::temp_dir().join(format!("xdremux-transfer-test-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&root).await?;
        let file = root.join("xdremux-poc-tail.bin");
        tokio::fs::write(&file, b"\0HEIF-like opaque bytes\xff\0PRIVATE-TAIL\0").await?;
        Ok((root, file))
    }
    #[test]
    fn rejects_paths_and_windows_aliases() {
        for name in [
            "../xdremux-poc-a",
            "xdremux-poc-a/../b",
            "xdremux-poc-a:stream",
            "xdremux-poc-a.",
            "xdremux-poc-a ",
            "xdremux-poc-a\n",
        ] {
            assert!(!safe_test_name(name));
        }
        assert!(safe_test_name("xdremux-poc-照片.mov"));
    }
    #[tokio::test]
    async fn tls_roundtrip_preserves_bytes_and_rejects_bad_hash() -> Result<()> {
        let (root, file) = fixture().await?;
        let receiver = Receiver::start(root.join("rx"), 0, Some("test-pin".into()), false).await?;
        let identity = Identity::new("test sender")?;
        let report = send_files(
            &identity,
            "127.0.0.1",
            receiver.port(),
            Some("test-pin"),
            Some(receiver.fingerprint().to_owned()),
            std::slice::from_ref(&file),
            false,
        )
        .await?;
        assert_eq!(report.len(), 1);
        let corrupt = send_files(
            &identity,
            "127.0.0.1",
            receiver.port(),
            Some("test-pin"),
            None,
            &[file],
            true,
        )
        .await;
        assert!(format!("{:#}", corrupt.unwrap_err()).contains("422"));
        let results = receiver.stop().await?;
        assert_eq!(results.iter().filter(|r| r.success).count(), 1);
        assert_eq!(results.iter().filter(|r| !r.success).count(), 1);
        let _ = tokio::fs::remove_dir_all(root).await;
        Ok(())
    }
    #[tokio::test]
    async fn rejects_wrong_pin_and_peer_identity_and_user_decline() -> Result<()> {
        let (root, file) = fixture().await?;
        let receiver = Receiver::start(root.join("rx"), 0, Some("test-pin".into()), false).await?;
        let identity = Identity::new("test sender")?;
        let bad_pin = send_files(
            &identity,
            "127.0.0.1",
            receiver.port(),
            Some("bad-pin"),
            None,
            std::slice::from_ref(&file),
            false,
        )
        .await;
        assert!(format!("{:#}", bad_pin.unwrap_err()).contains("401"));
        let bad_peer = send_files(
            &identity,
            "127.0.0.1",
            receiver.port(),
            Some("test-pin"),
            Some("0".repeat(64)),
            std::slice::from_ref(&file),
            false,
        )
        .await;
        assert!(format!("{:#}", bad_peer.unwrap_err()).contains("fingerprint mismatch"));
        let duplicate_dir = root.join("duplicate");
        tokio::fs::create_dir(&duplicate_dir).await?;
        let duplicate = duplicate_dir.join(file.file_name().unwrap());
        tokio::fs::copy(&file, &duplicate).await?;
        let duplicate_names = send_files(
            &identity,
            "127.0.0.1",
            receiver.port(),
            Some("test-pin"),
            None,
            &[file.clone(), duplicate],
            false,
        )
        .await;
        assert!(format!("{:#}", duplicate_names.unwrap_err()).contains("403"));
        assert!(receiver.stop().await?.is_empty());
        let decline = Receiver::start(root.join("decline"), 0, None, true).await?;
        let rejected = send_files(
            &identity,
            "127.0.0.1",
            decline.port(),
            None,
            None,
            &[file],
            false,
        )
        .await;
        assert!(format!("{:#}", rejected.unwrap_err()).contains("403"));
        assert!(decline.stop().await?.is_empty());
        let _ = tokio::fs::remove_dir_all(root).await;
        Ok(())
    }
}
