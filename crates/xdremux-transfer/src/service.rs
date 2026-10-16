use crate::{
    model::*,
    storage::{self, Identity, Storage},
};
use bytes::Bytes;
use localsend::{
    http::{
        client::LsHttpClientV2,
        dto_v2::RegisterDtoV2,
        server::{
            self,
            common::save::{FileUploadTarget, TransactionError},
            v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2},
            ServerConfigV2, ServerHandle, TlsConfig,
        },
        state::ClientInfo,
    },
    model::{
        discovery::{DeviceType, ProtocolType},
        transfer::FileDto,
    },
};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::SocketAddr,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::{
    io::AsyncWriteExt,
    sync::{broadcast, mpsc, oneshot, Semaphore},
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};
use uuid::Uuid;

pub struct Service {
    pub(crate) inner: Arc<Inner>,
}
pub(crate) struct Inner {
    pub config: Config,
    pub storage: Arc<Storage>,
    pub identity: Identity,
    pub server: ServerHandle,
    pub stop: CancellationToken,
    pub tasks: TaskTracker,
    pub state: Mutex<State>,
    events: broadcast::Sender<Event>,
    history: Mutex<VecDeque<Event>>,
    sequence: AtomicU64,
    files: Arc<Semaphore>,
    stopped: tokio::sync::watch::Sender<bool>,
}
#[derive(Default)]
pub(crate) struct State {
    sessions: HashMap<String, Arc<Session>>,
    pub outgoing: HashMap<String, Outgoing>,
}
pub(crate) struct Outgoing {
    pub peer: Peer,
    pub session: Option<String>,
    pub cancel: CancellationToken,
}
struct Session {
    offer: Offer,
    decision: Mutex<Option<oneshot::Sender<Decision>>>,
    cancel: CancellationToken,
    gate: tokio::sync::Mutex<bool>,
    last: Mutex<Instant>,
}
impl Drop for Service {
    fn drop(&mut self) {
        self.inner.stop.cancel();
    }
}

impl Inner {
    pub fn emit(&self, kind: EventKind) {
        // Serialize allocation and publication so observers see increasing sequence IDs.
        let mut history = self.history.lock().unwrap();
        let event = Event {
            sequence: self.sequence.fetch_add(1, Ordering::SeqCst) + 1,
            kind,
        };
        if !matches!(event.kind, EventKind::Progress { .. }) {
            if history.len() == self.config.event_capacity {
                history.pop_front();
            }
            history.push_back(event.clone());
        }
        let _ = self.events.send(event);
    }
    pub fn register(&self) -> RegisterDtoV2 {
        RegisterDtoV2 {
            alias: self.config.alias.clone(),
            version: "2.2".into(),
            device_model: Some("XDRemux".into()),
            device_type: Some(DeviceType::Headless),
            fingerprint: self.identity.fingerprint.clone(),
            port: self.server.port(),
            protocol: ProtocolType::Https,
            download: false,
        }
    }
    pub fn client(&self, fingerprint: Option<String>) -> Result<LsHttpClientV2> {
        LsHttpClientV2::try_new(
            &self.identity.key,
            &self.identity.cert,
            fingerprint.map(|s| s.to_ascii_uppercase()),
            Some(self.config.request_timeout),
        )
        .map_err(|_| ErrorCode::Io)
    }
    async fn cancel_session(&self, id: &str, code: ErrorCode) {
        let session = self.state.lock().unwrap().sessions.get(id).cloned();
        if let Some(session) = session {
            *session.gate.lock().await = false;
            session.cancel.cancel();
            self.server.cancel_v2_session(id).await;
            self.state.lock().unwrap().sessions.remove(id);
            self.emit(EventKind::Failed {
                transfer_id: id.into(),
                file_id: None,
                code,
            });
            self.emit(EventKind::SessionEnded {
                session_id: id.into(),
            });
        }
    }
}
impl Service {
    pub async fn start(config: Config) -> Result<Self> {
        config.validate()?;
        let root = config.root.clone();
        let (storage, identity) = tokio::task::spawn_blocking(move || {
            let storage = Storage::open(&root)?;
            let identity = storage.identity()?;
            Ok::<_, ErrorCode>((Arc::new(storage), identity))
        })
        .await
        .map_err(|_| ErrorCode::Io)??;
        let (tx, rx) = mpsc::channel(32);
        let (stop_tx, stop_rx) = oneshot::channel();
        let server = server::start_with_address(
            config.bind,
            Some(TlsConfig {
                cert: identity.cert.clone(),
                private_key: identity.key.clone(),
            }),
            ClientInfo {
                alias: config.alias.clone(),
                version: "2.2".into(),
                device_model: Some("XDRemux".into()),
                device_type: Some(DeviceType::Headless),
                token: identity.fingerprint.clone(),
            },
            None,
            Some(ServerConfigV2 {
                pin: config.pin.clone(),
                verify_checksums: true,
                event_tx: tx,
            }),
            None,
            stop_rx,
        )
        .await
        .map_err(|_| ErrorCode::Network)?;
        let (events, _) = broadcast::channel(config.event_capacity);
        let (stopped, _) = tokio::sync::watch::channel(false);
        let inner = Arc::new(Inner {
            files: Arc::new(Semaphore::new(config.max_parallel_files)),
            config,
            storage,
            identity,
            server,
            events,
            stopped,
            stop: CancellationToken::new(),
            tasks: TaskTracker::new(),
            state: Mutex::new(State::default()),
            history: Mutex::new(VecDeque::new()),
            sequence: AtomicU64::new(0),
        });
        tokio::spawn(supervise(inner.clone(), rx, stop_tx));
        Ok(Self { inner })
    }
    pub fn address(&self) -> SocketAddr {
        SocketAddr::new(self.inner.config.bind.ip(), self.inner.server.port())
    }
    pub fn fingerprint(&self) -> &str {
        &self.inner.identity.fingerprint
    }
    /// Broadcast overflow returns RecvError::Lagged; resync offers/history/receipts.
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.inner.events.subscribe()
    }
    /// Bounded recent control/terminal events; progress is deliberately excluded.
    pub fn recent_events(&self) -> Vec<Event> {
        self.inner.history.lock().unwrap().iter().cloned().collect()
    }
    pub fn pending_offers(&self) -> Vec<Offer> {
        self.inner
            .state
            .lock()
            .unwrap()
            .sessions
            .values()
            .filter(|s| s.decision.lock().unwrap().is_some())
            .map(|s| s.offer.clone())
            .collect()
    }
    pub fn decide(&self, id: &str, decision: Decision) -> Result<()> {
        if self.inner.stop.is_cancelled() {
            return Err(ErrorCode::Closed);
        }
        let session = self
            .inner
            .state
            .lock()
            .unwrap()
            .sessions
            .get(id)
            .cloned()
            .ok_or(ErrorCode::InvalidInput)?;
        let tx = session
            .decision
            .lock()
            .unwrap()
            .take()
            .ok_or(ErrorCode::InvalidInput)?;
        tx.send(decision).map_err(|_| ErrorCode::Cancelled)
    }
    /// Returns after the commit gate closes. Previously committed files remain valid.
    pub async fn cancel_receive(&self, id: &str) {
        self.inner.cancel_session(id, ErrorCode::Cancelled).await;
    }
    pub async fn receipts(&self, limit: usize) -> Result<Vec<Receipt>> {
        self.receipts_after(None, limit).await
    }
    /// Ascending receipt IDs; pass the last ID as the cursor for the next page.
    pub async fn receipts_after(
        &self,
        after: Option<String>,
        limit: usize,
    ) -> Result<Vec<Receipt>> {
        let storage = self.inner.storage.clone();
        tokio::task::spawn_blocking(move || storage.receipts_after(after.as_deref(), limit))
            .await
            .map_err(|_| ErrorCode::Io)?
    }
    pub async fn received_path(&self, id: &str) -> Result<PathBuf> {
        let storage = self.inner.storage.clone();
        let id = id.to_owned();
        tokio::task::spawn_blocking(move || storage.data_path(&id))
            .await
            .map_err(|_| ErrorCode::Io)?
    }
    /// Discovery only. The caller must confirm the returned identity before start_send.
    pub async fn probe(&self, address: SocketAddr) -> Result<Peer> {
        if self.inner.stop.is_cancelled() {
            return Err(ErrorCode::Closed);
        }
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            self.inner.client(None)?.register(
                ProtocolType::Https,
                &address.ip().to_string(),
                address.port(),
                self.inner.register(),
            ),
        )
        .await
        .map_err(|_| ErrorCode::TimedOut)?
        .map_err(crate::sender::map_error)?;
        Ok(Peer {
            address,
            fingerprint: result.cert_fingerprint.ok_or(ErrorCode::IdentityMismatch)?,
        })
    }
    pub async fn shutdown(self) {
        let mut stopped = self.inner.stopped.subscribe();
        self.inner.stop.cancel();
        while !*stopped.borrow_and_update() {
            if stopped.changed().await.is_err() {
                break;
            }
        }
    }
}

async fn supervise(
    inner: Arc<Inner>,
    mut rx: mpsc::Receiver<ServerEventV2>,
    stop_tx: oneshot::Sender<()>,
) {
    loop {
        tokio::select! {
            biased;
            _=inner.stop.cancelled()=>break,
            event=rx.recv()=>match event {
                Some(event)=>handle_event(inner.clone(),event).await,
                None=>break,
            }
        }
    }
    inner.stop.cancel();
    let ids: Vec<_> = inner
        .state
        .lock()
        .unwrap()
        .sessions
        .keys()
        .cloned()
        .collect();
    for id in ids {
        inner.cancel_session(&id, ErrorCode::Closed).await;
    }
    let _ = stop_tx.send(());
    // Drop responders still in the bounded queue before waiting for the server.
    rx.close();
    while rx.try_recv().is_ok() {}
    inner.server.wait_stopped().await;
    inner.tasks.close();
    inner.tasks.wait().await;
    inner.storage.release();
    inner.emit(EventKind::Stopped);
    inner.stopped.send_replace(true);
}

fn offer(
    config: &Config,
    id: String,
    alias: String,
    fingerprint: Option<String>,
    files: &HashMap<String, FileDto>,
) -> Result<Offer> {
    let fingerprint = fingerprint
        .filter(|s| valid_hash(s))
        .ok_or(ErrorCode::IdentityMismatch)?;
    if files.is_empty()
        || files.len() > config.max_files
        || alias.len() > 128
        || alias.chars().any(char::is_control)
    {
        return Err(ErrorCode::InvalidInput);
    }
    let mut total = 0u64;
    let mut names = HashSet::new();
    let mut offered = Vec::new();
    for (key, f) in files {
        total = total.checked_add(f.size).ok_or(ErrorCode::InvalidInput)?;
        if key.is_empty()
            || key.len() > 128
            || key.chars().any(char::is_control)
            || key != &f.id
            || !safe_name(&f.file_name)
            || !names.insert(f.file_name.to_lowercase())
            || f.size > config.max_file_bytes
            || total > config.max_session_bytes
            || f.sha256.as_ref().is_some_and(|s| !valid_hash(s))
            || f.file_type.len() > 256
            || f.preview.is_some()
        {
            return Err(ErrorCode::InvalidInput);
        }
        offered.push(OfferedFile {
            id: key.clone(),
            name: f.file_name.clone(),
            size: f.size,
            sha256: f.sha256.clone(),
        });
    }
    Ok(Offer {
        session_id: id,
        alias,
        peer_fingerprint: fingerprint,
        files: offered,
    })
}
async fn handle_event(inner: Arc<Inner>, event: ServerEventV2) {
    match event {
        ServerEventV2::PrepareUpload {
            session_id,
            info,
            cert_fingerprint,
            files,
            decision_tx,
            ..
        } => {
            let validated = offer(
                &inner.config,
                session_id.clone(),
                info.alias,
                cert_fingerprint,
                &files,
            )
            .and_then(|o| {
                inner.storage.space(
                    o.files.iter().map(|f| f.size).sum(),
                    inner.config.min_free_bytes,
                )?;
                Ok(o)
            });
            let offered = match validated {
                Ok(o) => o,
                Err(code) => {
                    let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
                    inner.emit(EventKind::Failed {
                        transfer_id: session_id,
                        file_id: None,
                        code,
                    });
                    return;
                }
            };
            let (tx, rx) = oneshot::channel();
            let session = Arc::new(Session {
                offer: offered.clone(),
                decision: Mutex::new(Some(tx)),
                cancel: inner.stop.child_token(),
                gate: tokio::sync::Mutex::new(true),
                last: Mutex::new(Instant::now()),
            });
            inner
                .state
                .lock()
                .unwrap()
                .sessions
                .insert(session_id.clone(), session.clone());
            inner.emit(EventKind::Offer { offer: offered });
            inner.tasks.spawn({let inner=inner.clone();async move{
                let answer=tokio::select! {
                    _=session.cancel.cancelled()=>Err(ErrorCode::Cancelled),
                    _=tokio::time::sleep(inner.config.decision_timeout)=>Err(ErrorCode::TimedOut),
                    result=rx=>match result {Ok(Decision::Accept)=>Ok(()),_=>Err(ErrorCode::Declined)},
                };
                if let Err(code)=answer {
                    let _=decision_tx.send(PrepareUploadDecisionV2::Decline);
                    inner.cancel_session(&session_id,code).await;
                    return;
                }
                // Serialize accepting with local cancellation. A cancelled pending offer
                // must never leave an untracked active core session behind.
                let gate=session.gate.lock().await;
                if !*gate || session.cancel.is_cancelled() {let _=decision_tx.send(PrepareUploadDecisionV2::Decline);return;}
                let ids=session.offer.files.iter().map(|f|f.id.clone()).collect();
                if decision_tx.send(PrepareUploadDecisionV2::Accept(ids)).is_err() {drop(gate);inner.cancel_session(&session_id,ErrorCode::Cancelled).await;return;}
                *session.last.lock().unwrap()=Instant::now();
                inner.emit(EventKind::Accepted{session_id:session_id.clone()});
                drop(gate);
                let started=Instant::now();
                loop {
                    tokio::select! {_=session.cancel.cancelled()=>break,_=tokio::time::sleep(Duration::from_millis(20))=>{}}
                    if started.elapsed()>=inner.config.session_timeout || session.last.lock().unwrap().elapsed()>=inner.config.idle_timeout {
                        inner.cancel_session(&session_id,ErrorCode::TimedOut).await; break;
                    }
                }
            }});
        }
        ServerEventV2::FileUpload {
            session_id,
            file_id,
            file,
            target_tx,
        } => {
            let session = inner
                .state
                .lock()
                .unwrap()
                .sessions
                .get(&session_id)
                .cloned();
            let Some(session) = session else {
                return;
            };
            let Ok(permit) = inner.files.clone().try_acquire_owned() else {
                inner.emit(EventKind::Failed {
                    transfer_id: session_id,
                    file_id: Some(file_id),
                    code: ErrorCode::Busy,
                });
                return;
            };
            inner.tasks.spawn({
                let inner = inner.clone();
                async move {
                    let _permit = permit;
                    let (binary_tx, binary_rx) = mpsc::channel(4);
                    let (body_done_tx, body_done_rx) = oneshot::channel();
                    let (result_tx, result_rx) = oneshot::channel();
                    if target_tx
                        .send(FileUploadTarget::Transactional {
                            binary_tx,
                            body_done_tx,
                            result_rx,
                        })
                        .is_err()
                    {
                        return;
                    }
                    let result =
                        receive(&inner, &session, &file_id, &file, binary_rx, body_done_rx).await;
                    let protocol_result = match &result {
                        Ok(_) => Ok(()),
                        Err(ErrorCode::ChecksumMismatch) => Err(TransactionError::HashMismatch),
                        Err(_) => Err(TransactionError::Failed),
                    };
                    if let Err(code) = result {
                        inner.emit(EventKind::Failed {
                            transfer_id: session_id,
                            file_id: Some(file_id),
                            code,
                        });
                    }
                    let _ = result_tx.send(protocol_result);
                }
            });
        }
        ServerEventV2::PrepareUploadAborted { session_id } => {
            inner
                .cancel_session(&session_id, ErrorCode::Cancelled)
                .await
        }
        ServerEventV2::SessionEnd { session_id, reason } => {
            if reason == SessionEndReasonV2::Cancelled {
                inner
                    .cancel_session(&session_id, ErrorCode::Cancelled)
                    .await;
            } else {
                let session = inner.state.lock().unwrap().sessions.remove(&session_id);
                if let Some(session) = session {
                    session.cancel.cancel();
                }
                inner.emit(EventKind::SessionEnded { session_id });
            }
        }
        ServerEventV2::CancelReceived {
            ip,
            session_id,
            cert_fingerprint,
        } => {
            for send in inner.state.lock().unwrap().outgoing.values() {
                if send.peer.address.ip() == ip.ip
                    && send.session.as_ref() == Some(&session_id)
                    && cert_fingerprint
                        .as_ref()
                        .is_some_and(|s| s.eq_ignore_ascii_case(&send.peer.fingerprint))
                {
                    send.cancel.cancel();
                }
            }
        }
        ServerEventV2::ListenerFailed { .. } => {
            inner.emit(EventKind::Failed {
                transfer_id: "service".into(),
                file_id: None,
                code: ErrorCode::Network,
            });
            inner.stop.cancel();
        }
        ServerEventV2::Register { .. } => {}
    }
}

async fn receive(
    inner: &Arc<Inner>,
    session: &Session,
    file_id: &str,
    file: &FileDto,
    mut rx: mpsc::Receiver<Bytes>,
    body_done: oneshot::Receiver<bool>,
) -> Result<()> {
    let staging = inner.storage.transaction(false)?;
    let path = staging.path().join("data");
    let mut output = tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)
        .await?;
    let mut hash = Sha256::new();
    let mut written = 0u64;
    let mut reported = 0u64;
    loop {
        let chunk = tokio::select! {
            biased;
            _=session.cancel.cancelled()=>return Err(ErrorCode::Cancelled),
            result=tokio::time::timeout(inner.config.idle_timeout,rx.recv())=>result.map_err(|_|ErrorCode::TimedOut)?,
        };
        let Some(chunk) = chunk else {
            break;
        };
        written = written
            .checked_add(chunk.len() as u64)
            .ok_or(ErrorCode::Truncated)?;
        if written > file.size {
            return Err(ErrorCode::Truncated);
        }
        output.write_all(&chunk).await?;
        hash.update(&chunk);
        *session.last.lock().unwrap() = Instant::now();
        if written - reported >= 512 * 1024 || written == file.size {
            reported = written;
            inner.emit(EventKind::Progress {
                transfer_id: session.offer.session_id.clone(),
                file_id: file_id.into(),
                bytes: written,
                total: file.size,
            });
        }
    }
    if written != file.size {
        return Err(ErrorCode::Truncated);
    }
    let clean = tokio::select! {_=session.cancel.cancelled()=>return Err(ErrorCode::Cancelled), result=tokio::time::timeout(inner.config.idle_timeout,body_done)=>matches!(result,Ok(Ok(true)))};
    if !clean {
        return Err(ErrorCode::Truncated);
    }
    let sha256 = storage::hex(hash.finalize());
    if file
        .sha256
        .as_ref()
        .is_some_and(|s| !s.eq_ignore_ascii_case(&sha256))
    {
        return Err(ErrorCode::ChecksumMismatch);
    }
    output.flush().await?;
    output.sync_all().await?;
    drop(output);
    let gate = session.gate.lock().await;
    if !*gate || session.cancel.is_cancelled() {
        return Err(ErrorCode::Cancelled);
    }
    let receipt = Receipt {
        id: Uuid::new_v4().to_string(),
        session_id: session.offer.session_id.clone(),
        file_id: file_id.into(),
        name: file.file_name.clone(),
        size: written,
        sha256,
        peer_hash_present: file.sha256.is_some(),
    };
    let storage = inner.storage.clone();
    let saved = receipt.clone();
    tokio::task::spawn_blocking(move || storage.commit(&path, &saved))
        .await
        .map_err(|_| ErrorCode::Io)??;
    inner.emit(EventKind::Committed { receipt });
    drop(gate);
    Ok(())
}
