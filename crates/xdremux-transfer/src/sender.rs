use crate::snapshot::{RetryPlan, RetrySource};
use crate::{
    model::*,
    service::{Inner, Outgoing, Service},
    storage::{self, hex},
};
use futures_util::StreamExt;
use localsend::{
    http::{client::ClientError, dto_v2::PrepareUploadRequestDtoV2},
    model::{discovery::ProtocolType, transfer::FileDto},
};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::oneshot,
};
use tokio_util::{io::ReaderStream, sync::CancellationToken};
use uuid::Uuid;

pub struct SendHandle {
    pub id: String,
    cancel: CancellationToken,
    result: Option<oneshot::Receiver<SendReport>>,
}
impl SendHandle {
    pub fn cancel(&self) {
        self.cancel.cancel();
    }
    pub async fn wait(mut self) -> SendReport {
        self.result.take().unwrap().await.unwrap_or(SendReport {
            files: Vec::new(),
            error: Some(ErrorCode::Closed),
        })
    }
}
impl Drop for SendHandle {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
impl Service {
    /// Snapshots inputs before negotiating, then uploads only the immutable copies.
    /// Returned report lists ACKed files even if a later file fails. Retry only the
    /// remaining files with a new call; never automatically resend committed files.
    pub fn start_send(
        &self,
        peer: Peer,
        paths: Vec<PathBuf>,
        pin: Option<String>,
    ) -> Result<SendHandle> {
        let sources = paths
            .into_iter()
            .map(|path| RetrySource {
                path,
                file_id: None,
                expected: None,
            })
            .collect();
        self.start_plan(RetryPlan { peer, sources }, pin)
    }
    /// Explicit retry of only unacknowledged files. PINs are never retained.
    pub fn retry_send(&self, id: &str, peer: Peer, pin: Option<String>) -> Result<SendHandle> {
        let plan = self.inner.journal.lock().unwrap().claim_retry(id, &peer)?;
        let result = self.start_plan(plan, pin);
        if result.is_err() {
            self.inner.journal.lock().unwrap().restore_retry(id);
        }
        result
    }
    fn start_plan(&self, plan: RetryPlan, pin: Option<String>) -> Result<SendHandle> {
        let peer = plan.peer.clone();
        let paths: Vec<_> = plan.sources.iter().map(|s| s.path.clone()).collect();
        if paths.is_empty()
            || paths.len() > self.inner.config.max_files
            || !valid_hash(&peer.fingerprint)
            || peer.address.port() == 0
            || peer.address.ip().is_unspecified()
            || pin
                .as_ref()
                .is_some_and(|s| s.len() > 128 || s.chars().any(char::is_control))
        {
            return Err(ErrorCode::InvalidInput);
        }
        let id = Uuid::new_v4().to_string();
        let cancel = self.inner.stop.child_token();
        let mut state = self.inner.state.lock().unwrap();
        if self.inner.stop.is_cancelled() {
            return Err(ErrorCode::Closed);
        }
        if state.outgoing.len() >= self.inner.config.max_outgoing {
            return Err(ErrorCode::Busy);
        }
        state.outgoing.insert(
            id.clone(),
            Outgoing {
                peer: peer.clone(),
                session: None,
                cancel: cancel.clone(),
            },
        );
        let (tx, rx) = oneshot::channel();
        let inner = self.inner.clone();
        let task_id = id.clone();
        let token = cancel.clone();
        self.inner.emit(EventKind::SendStarted {
            transfer_id: id.clone(),
            file_count: paths.len(),
        });
        self.inner
            .journal
            .lock()
            .unwrap()
            .sources(&id, plan.clone());
        // Insert and spawn under the same lock so shutdown sees every accepted job.
        self.inner.tasks.spawn(async move{
            let mut report=SendReport::default();
            let result=tokio::select! {
                biased;
                _=token.cancelled()=>Err(ErrorCode::Cancelled),
                result=tokio::time::timeout(inner.config.session_timeout,send(&inner,&task_id,&plan,pin.as_deref(),token.clone(),&mut report))=>result.unwrap_or(Err(ErrorCode::TimedOut)),
            };
            report.error=result.err();
            if report.error.is_some() {
                let remote_session=inner.state.lock().unwrap().outgoing.get(&task_id).and_then(|s|s.session.clone());
                if let (Some(session),Ok(client))=(remote_session,inner.client(Some(peer.fingerprint.clone()))) {
                    let _=tokio::time::timeout(Duration::from_secs(2),client.cancel(ProtocolType::Https,&peer.address.ip().to_string(),peer.address.port(),&session)).await;
                }
            }
            inner.state.lock().unwrap().outgoing.remove(&task_id);
            inner.emit(EventKind::Sent{transfer_id:task_id,report:report.clone()});
            let _=tx.send(report);
        });
        drop(state);
        Ok(SendHandle {
            id,
            cancel,
            result: Some(rx),
        })
    }
}

pub(crate) fn map_error(error: ClientError) -> ErrorCode {
    match error {
        ClientError::Cancelled => ErrorCode::Cancelled,
        ClientError::StatusCode(s) => match s.status {
            401 => ErrorCode::Authentication,
            403 => ErrorCode::Declined,
            409 | 429 => ErrorCode::Busy,
            422 => ErrorCode::ChecksumMismatch,
            _ => ErrorCode::RemoteFailure,
        },
        ClientError::Reqwest(e) if e.is_timeout() => ErrorCode::TimedOut,
        ClientError::Reqwest(_) => ErrorCode::Network,
        ClientError::Io(e) => e.into(),
        _ => ErrorCode::RemoteFailure,
    }
}

async fn send(
    inner: &Arc<Inner>,
    id: &str,
    plan: &RetryPlan,
    pin: Option<&str>,
    cancel: CancellationToken,
    report: &mut SendReport,
) -> Result<()> {
    let peer = &plan.peer;
    let staging = inner.storage.transaction(true)?;
    let mut sources = HashMap::new();
    let mut files = HashMap::new();
    let mut names = HashSet::new();
    let mut total = 0u64;
    let mut retry_sources = Vec::new();
    for original in &plan.sources {
        let path = &original.path;
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(ErrorCode::InvalidInput)?
            .to_owned();
        if !safe_name(&name) || !names.insert(name.to_lowercase()) {
            return Err(ErrorCode::InvalidInput);
        }
        storage::plain(path, false)?;
        let mut input = tokio::fs::File::open(&path).await?;
        let before = input.metadata().await?;
        if !before.is_file() || before.len() > inner.config.max_file_bytes {
            return Err(ErrorCode::InvalidInput);
        }
        total = total
            .checked_add(before.len())
            .ok_or(ErrorCode::InvalidInput)?;
        if total > inner.config.max_session_bytes {
            return Err(ErrorCode::InvalidInput);
        }
        inner
            .storage
            .space(before.len(), inner.config.min_free_bytes)?;
        let file_id = Uuid::new_v4().to_string();
        let saved = staging.path().join(&file_id);
        let mut output = tokio::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&saved)
            .await?;
        let mut hasher = Sha256::new();
        let mut copied = 0u64;
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            let n = input.read(&mut buffer).await?;
            if n == 0 {
                break;
            }
            copied += n as u64;
            if copied > before.len() {
                return Err(ErrorCode::SourceChanged);
            }
            output.write_all(&buffer[..n]).await?;
            hasher.update(&buffer[..n]);
        }
        output.flush().await?;
        drop(output);
        let after = input.metadata().await?;
        if copied != before.len()
            || after.len() != before.len()
            || before.modified()? != after.modified()?
        {
            return Err(ErrorCode::SourceChanged);
        }
        let sha256 = hex(hasher.finalize());
        if original
            .expected
            .as_ref()
            .is_some_and(|(size, hash)| *size != copied || *hash != sha256)
        {
            return Err(ErrorCode::SourceChanged);
        }
        retry_sources.push(RetrySource {
            path: path.clone(),
            file_id: Some(file_id.clone()),
            expected: Some((copied, sha256.clone())),
        });
        files.insert(
            file_id.clone(),
            FileDto {
                id: file_id.clone(),
                file_name: name,
                size: copied,
                file_type: "application/octet-stream".into(),
                sha256: Some(sha256),
                preview: None,
                metadata: None,
            },
        );
        sources.insert(file_id, saved);
    }
    inner.journal.lock().unwrap().sources(
        id,
        RetryPlan {
            peer: peer.clone(),
            sources: retry_sources,
        },
    );
    inner.emit(EventKind::Prepared {
        transfer_id: id.into(),
        files: files.values().map(sent_file).collect(),
    });
    let host = peer.address.ip().to_string();
    let port = peer.address.port();
    // Detect an explicitly incorrect trust decision before sending any file metadata.
    let discovered = inner
        .client(None)?
        .register(ProtocolType::Https, &host, port, inner.register())
        .await
        .map_err(map_error)?;
    if !discovered
        .cert_fingerprint
        .is_some_and(|fp| fp.eq_ignore_ascii_case(&peer.fingerprint))
    {
        return Err(ErrorCode::IdentityMismatch);
    }
    let client = inner.client(Some(peer.fingerprint.clone()))?;
    let prepared = client
        .prepare_upload(
            ProtocolType::Https,
            &host,
            port,
            None,
            PrepareUploadRequestDtoV2 {
                info: inner.register(),
                files: files.clone(),
            },
            pin,
            cancel.clone(),
        )
        .await
        .map_err(map_error)?;
    let session = prepared.response.ok_or(ErrorCode::Declined)?;
    if let Some(outgoing) = inner.state.lock().unwrap().outgoing.get_mut(id) {
        outgoing.session = Some(session.session_id.clone());
    }
    if session.files.len() != files.len() || session.files.keys().any(|id| !files.contains_key(id))
    {
        return Err(ErrorCode::Declined);
    }
    for (file_id, token) in session.files {
        let file = files.get(&file_id).ok_or(ErrorCode::RemoteFailure)?;
        let source = tokio::fs::File::open(sources.get(&file_id).ok_or(ErrorCode::Io)?).await?;
        let progress_inner = inner.clone();
        let progress_id = id.to_owned();
        let progress_file = file_id.clone();
        let size = file.size;
        let mut bytes = 0u64;
        let mut reported = 0u64;
        let stream = ReaderStream::with_capacity(source, 64 * 1024).inspect(move |chunk| {
            if let Ok(chunk) = chunk {
                bytes += chunk.len() as u64;
                if bytes - reported >= 512 * 1024 || bytes == size {
                    reported = bytes;
                    progress_inner.emit(EventKind::Progress {
                        transfer_id: progress_id.clone(),
                        file_id: progress_file.clone(),
                        bytes,
                        total: size,
                    });
                }
            }
        });
        client
            .upload(
                ProtocolType::Https,
                &host,
                port,
                None,
                &session.session_id,
                &file_id,
                &token,
                localsend::reqwest::Body::wrap_stream(stream),
                cancel.clone(),
            )
            .await
            .map_err(map_error)?;
        report.files.push(sent_file(file));
        inner.emit(EventKind::FileSent {
            transfer_id: id.to_owned(),
            file: sent_file(file),
        });
    }
    Ok(())
}
fn sent_file(file: &FileDto) -> SentFile {
    SentFile {
        id: file.id.clone(),
        name: file.file_name.clone(),
        size: file.size,
        sha256: file.sha256.clone().unwrap_or_default(),
    }
}
