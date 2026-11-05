use crate::*;
use localsend::{
    http::{
        client::LsHttpClientV2,
        dto_v2::{PrepareUploadRequestDtoV2, PrepareUploadResponseDtoV2},
    },
    model::{discovery::ProtocolType, transfer::FileDto},
};
use std::{collections::HashMap, fs, path::Path, sync::OnceLock, time::Duration};
use tokio::sync::broadcast;
use uuid::Uuid;

fn config(root: &Path) -> Config {
    // Share one test certificate to keep this suite fast. Production identities
    // remain independently generated, persisted and exclusively leased.
    static ID: OnceLock<Vec<u8>> = OnceLock::new();
    let bytes = ID.get_or_init(|| {
        let c = localsend::crypto::cert::generate_self_signed().unwrap();
        serde_json::to_vec(&storage::Identity {
            cert: c.certificate_pem,
            key: c.private_key_pem,
            fingerprint: c.fingerprint,
        })
        .unwrap()
    });
    let store = storage::Storage::open(root).unwrap();
    if !root.join("identity.json").exists() {
        fs::write(root.join("identity.json"), bytes).unwrap();
    }
    drop(store);
    let mut cfg = Config::new(root.to_owned());
    cfg.decision_timeout = Duration::from_secs(2);
    cfg.idle_timeout = Duration::from_secs(2);
    cfg.request_timeout = Duration::from_secs(5);
    cfg.min_free_bytes = 0;
    cfg
}
async fn next(
    events: &mut broadcast::Receiver<Event>,
    matches: impl Fn(&EventKind) -> bool,
) -> EventKind {
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            let event = events.recv().await.unwrap();
            if matches(&event.kind) {
                return event.kind;
            }
        }
    })
    .await
    .expect("expected service event")
}
fn file(name: &str, size: u64, hash: Option<String>) -> FileDto {
    FileDto {
        id: "test-file".into(),
        file_name: name.into(),
        size,
        file_type: "application/octet-stream".into(),
        sha256: hash,
        preview: None,
        metadata: None,
    }
}
async fn prepare(
    sender: &Service,
    receiver: &Service,
    file: FileDto,
) -> PrepareUploadResponseDtoV2 {
    let client = sender
        .inner
        .client(Some(receiver.fingerprint().into()))
        .unwrap();
    let payload = PrepareUploadRequestDtoV2 {
        info: sender.inner.register(),
        files: HashMap::from([(file.id.clone(), file)]),
    };
    let port = receiver.address().port();
    let mut events = receiver.subscribe();
    let request = tokio::spawn(async move {
        client
            .prepare_upload(
                ProtocolType::Https,
                "127.0.0.1",
                port,
                None,
                payload,
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await
    });
    let EventKind::Offer { offer } =
        next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    receiver
        .decide(&offer.session_id, Decision::Accept)
        .unwrap();
    request.await.unwrap().unwrap().response.unwrap()
}
async fn upload(
    sender: &Service,
    receiver: &Service,
    session: &PrepareUploadResponseDtoV2,
    body: impl Into<localsend::reqwest::Body>,
) -> std::result::Result<(), localsend::http::client::ClientError> {
    sender
        .inner
        .client(Some(receiver.fingerprint().into()))
        .unwrap()
        .upload(
            ProtocolType::Https,
            "127.0.0.1",
            receiver.address().port(),
            None,
            &session.session_id,
            "test-file",
            session.files.get("test-file").unwrap(),
            body.into(),
            tokio_util::sync::CancellationToken::new(),
        )
        .await
}
async fn pair(temp: &Path) -> (Service, Service) {
    let a = Service::start(config(&temp.join("a"))).await.unwrap();
    let b = Service::start(config(&temp.join("b"))).await.unwrap();
    (a, b)
}
fn peer(service: &Service) -> Peer {
    Peer {
        address: service.address(),
        fingerprint: service.fingerprint().into(),
    }
}

#[tokio::test]
async fn explicit_accept_snapshot_ack_and_restart() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let source = temp.path().join("照片😀.heic");
    let original = b"\0opaque HEIC with private tail\xff\0";
    fs::write(&source, original).unwrap();
    let empty = temp.path().join("empty.bin");
    fs::write(&empty, []).unwrap();
    let mut events = b.subscribe();
    let mut sent_events = a.subscribe();
    let job = a
        .start_send(peer(&b), vec![source.clone(), empty], None)
        .unwrap();
    let send_id = job.id.clone();
    let prepared = next(&mut sent_events, |e| {
        matches!(e, EventKind::Prepared { .. })
    })
    .await;
    fs::write(&source, b"source changed after snapshot").unwrap();
    let EventKind::Offer { offer } =
        next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    assert!(b.receipts(10).await.unwrap().is_empty());
    assert_eq!(b.pending_offers().len(), 1);
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    let report = job.wait().await;
    assert_eq!(report.error, None);
    assert_eq!(report.files.len(), 2);
    let EventKind::Prepared { files, .. } = prepared else {
        unreachable!()
    };
    for f in &report.files {
        assert!(files.iter().any(|p| p.id == f.id && p.name == f.name));
    }
    let state = a.transfer_snapshot(&send_id, None, 64).unwrap();
    assert_eq!(state.transfer.phase, Phase::Completed);
    assert_eq!(state.files.len(), 2);
    assert!(state
        .files
        .iter()
        .all(|f| f.phase == FilePhase::Sent && f.bytes == f.size));
    // A successful sender ACK already implies committed data and its receipt.
    let receipts = b.receipts(10).await.unwrap();
    assert_eq!(receipts.len(), 2);
    for r in &receipts {
        let path = b.received_path(&r.id).await.unwrap();
        assert_eq!(hash_file(&path).await.unwrap(), r.sha256);
        assert!(r.peer_hash_present);
        if r.name == "照片😀.heic" {
            assert_eq!(fs::read(path).unwrap(), original);
        }
    }
    let fingerprint = b.fingerprint().to_owned();
    let instance = b.instance_id();
    let port = b.address().port();
    a.shutdown().await;
    b.shutdown().await;
    let mut cfg = config(&temp.path().join("b"));
    cfg.bind.set_port(port);
    let restarted = Service::start(cfg).await.unwrap();
    assert_eq!(restarted.fingerprint(), fingerprint);
    assert_ne!(restarted.instance_id(), instance);
    assert_eq!(restarted.receipts(10).await.unwrap().len(), 2);
    restarted.shutdown().await;
}

#[tokio::test]
async fn decline_decision_timeout_and_pending_cancel_release_slot() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let source = temp.path().join("file.bin");
    fs::write(&source, b"abc").unwrap();
    for action in [0, 1, 2] {
        let mut events = b.subscribe();
        let job = a.start_send(peer(&b), vec![source.clone()], None).unwrap();
        let EventKind::Offer { offer } =
            next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
        else {
            unreachable!()
        };
        match action {
            0 => b.decide(&offer.session_id, Decision::Decline).unwrap(),
            1 => {}
            _ => b.cancel_receive(&offer.session_id).await,
        }
        let report = job.wait().await;
        assert!(report.error.is_some());
        if action == 1 {
            assert!(b.recent_events().iter().any(|e| matches!(
                e.kind,
                EventKind::Failed {
                    code: ErrorCode::TimedOut,
                    ..
                }
            )));
        }
    }
    assert!(b.receipts(10).await.unwrap().is_empty());
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn pin_and_certificate_identity_fail_without_offer() {
    let temp = tempfile::tempdir().unwrap();
    let a = Service::start(config(&temp.path().join("a")))
        .await
        .unwrap();
    let mut cfg = config(&temp.path().join("b"));
    cfg.pin = Some("1234".into());
    let b = Service::start(cfg).await.unwrap();
    let source = temp.path().join("file.bin");
    fs::write(&source, b"abc").unwrap();
    let mut wrong = peer(&b);
    wrong.fingerprint = "0".repeat(64);
    assert_eq!(
        a.start_send(wrong, vec![source.clone()], None)
            .unwrap()
            .wait()
            .await
            .error,
        Some(ErrorCode::IdentityMismatch)
    );
    assert_eq!(
        a.start_send(peer(&b), vec![source], Some("bad".into()))
            .unwrap()
            .wait()
            .await
            .error,
        Some(ErrorCode::Authentication)
    );
    assert!(b.pending_offers().is_empty());
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn hash_mismatch_truncation_and_retry_never_expose_partial() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let mut events = b.subscribe();
    let session = prepare(&a, &b, file("file.bin", 3, Some("0".repeat(64)))).await;
    let error = upload(&a, &b, &session, b"abc".to_vec()).await.unwrap_err();
    assert_eq!(sender::map_error(error), ErrorCode::ChecksumMismatch);
    b.cancel_receive(&session.session_id).await;
    next(&mut events, |e| matches!(e, EventKind::SessionEnded { session_id } if session_id == &session.session_id)).await;
    let snapshot = b.transfer_snapshot(&session.session_id, None, 64).unwrap();
    assert_eq!(snapshot.transfer.error, Some(ErrorCode::Cancelled));
    assert_eq!(snapshot.files[0].error, Some(ErrorCode::ChecksumMismatch));
    assert!(b.receipts(10).await.unwrap().is_empty());
    // Failed-file retry is a new explicit session, retaining no partial data.
    let session = prepare(&a, &b, file("file.bin", 3, None)).await;
    assert!(upload(&a, &b, &session, b"ab".to_vec()).await.is_err());
    next(&mut events, |e| matches!(e, EventKind::SessionEnded { session_id } if session_id == &session.session_id)).await;
    let snapshot = b.transfer_snapshot(&session.session_id, None, 64).unwrap();
    assert_eq!(snapshot.transfer.error, Some(ErrorCode::Truncated));
    assert_eq!(snapshot.files[0].error, Some(ErrorCode::Truncated));
    assert!(b.receipts(10).await.unwrap().is_empty());
    let session = prepare(&a, &b, file("file.bin", 3, None)).await;
    upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    let receipts = b.receipts(10).await.unwrap();
    assert_eq!(receipts.len(), 1);
    assert!(!receipts[0].peer_hash_present);
    assert_eq!(
        fs::read(b.received_path(&receipts[0].id).await.unwrap()).unwrap(),
        b"abc"
    );
    a.shutdown().await;
    b.shutdown().await;
}

fn terminal_journal() -> crate::snapshot::Journal {
    let mut journal = crate::snapshot::Journal::new();
    journal.apply(&EventKind::Offer {
        offer: Offer {
            session_id: "terminal-session".into(),
            alias: "Owned fixture".into(),
            peer_fingerprint: "0".repeat(64),
            files: ["bad", "pending", "kept"]
                .into_iter()
                .map(|id| OfferedFile {
                    id: id.into(),
                    name: format!("{id}.bin"),
                    size: 3,
                    sha256: None,
                })
                .collect(),
        },
    });
    journal
}

#[test]
fn terminal_file_error_survives_session_end() {
    for code in [
        ErrorCode::ChecksumMismatch,
        ErrorCode::Truncated,
        ErrorCode::TimedOut,
        ErrorCode::NoSpace,
        ErrorCode::Io,
    ] {
        let mut journal = terminal_journal();
        journal.apply(&EventKind::Failed {
            transfer_id: "terminal-session".into(),
            file_id: Some("bad".into()),
            code,
        });
        journal.apply(&EventKind::SessionEnded {
            session_id: "terminal-session".into(),
        });
        let page = journal.files("terminal-session", None, 64).unwrap();
        assert_eq!(page.transfer.error, Some(code));
        assert_eq!(
            page.files.iter().find(|f| f.id == "bad").unwrap().error,
            Some(code)
        );
    }
}

#[test]
fn terminal_batch_failure_preserves_file_cause_and_committed_receipt() {
    for code in [ErrorCode::Cancelled, ErrorCode::TimedOut] {
        let mut journal = terminal_journal();
        journal.apply(&EventKind::Committed {
            receipt: Receipt {
                id: "owned-receipt".into(),
                session_id: "terminal-session".into(),
                file_id: "kept".into(),
                name: "kept.bin".into(),
                size: 3,
                sha256: "0".repeat(64),
                peer_hash_present: false,
            },
        });
        journal.apply(&EventKind::Failed {
            transfer_id: "terminal-session".into(),
            file_id: Some("bad".into()),
            code: ErrorCode::ChecksumMismatch,
        });
        journal.apply(&EventKind::Failed {
            transfer_id: "terminal-session".into(),
            file_id: None,
            code,
        });
        journal.apply(&EventKind::SessionEnded {
            session_id: "terminal-session".into(),
        });
        let page = journal.files("terminal-session", None, 64).unwrap();
        assert_eq!(page.transfer.error, Some(code));
        let get = |id| page.files.iter().find(|f| f.id == id).unwrap();
        assert_eq!(get("bad").error, Some(ErrorCode::ChecksumMismatch));
        assert_eq!(get("pending").error, Some(code));
        assert_eq!(get("kept").phase, FilePhase::Committed);
        assert_eq!(get("kept").error, None);
        assert_eq!(get("kept").receipt_id.as_deref(), Some("owned-receipt"));
    }
}

#[test]
fn terminal_unknown_failure_falls_back_without_poisoning_commits() {
    let mut journal = terminal_journal();
    journal.apply(&EventKind::SessionEnded {
        session_id: "terminal-session".into(),
    });
    assert_eq!(
        journal
            .files("terminal-session", None, 64)
            .unwrap()
            .transfer
            .error,
        Some(ErrorCode::RemoteFailure)
    );
    let mut journal = terminal_journal();
    for id in ["bad", "pending", "kept"] {
        journal.apply(&EventKind::Committed {
            receipt: Receipt {
                id: format!("receipt-{id}"),
                session_id: "terminal-session".into(),
                file_id: id.into(),
                name: format!("{id}.bin"),
                size: 3,
                sha256: "0".repeat(64),
                peer_hash_present: false,
            },
        });
    }
    journal.apply(&EventKind::Failed {
        transfer_id: "terminal-session".into(),
        file_id: Some("kept".into()),
        code: ErrorCode::ChecksumMismatch,
    });
    journal.apply(&EventKind::SessionEnded {
        session_id: "terminal-session".into(),
    });
    let page = journal.files("terminal-session", None, 64).unwrap();
    assert_eq!(page.transfer.phase, Phase::Completed);
    assert_eq!(page.transfer.error, None);
    assert!(page
        .files
        .iter()
        .all(|f| f.phase == FilePhase::Committed && f.error.is_none()));
}

#[tokio::test]
async fn stalled_upload_cancel_and_shutdown_clean_staging() {
    use futures_util::{stream, StreamExt};
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    for local_cancel in [true, false] {
        let session = prepare(&a, &b, file("slow.bin", 1024, None)).await;
        let mut events = b.subscribe();
        let stream =
            stream::once(async { Ok::<_, std::io::Error>(bytes::Bytes::from_static(b"abc")) })
                .chain(stream::pending());
        let client = a.inner.client(Some(b.fingerprint().into())).unwrap();
        let port = b.address().port();
        let id = session.session_id.clone();
        let token = session.files["test-file"].clone();
        let task = tokio::spawn(async move {
            client
                .upload(
                    ProtocolType::Https,
                    "127.0.0.1",
                    port,
                    None,
                    &id,
                    "test-file",
                    &token,
                    localsend::reqwest::Body::wrap_stream(stream),
                    tokio_util::sync::CancellationToken::new(),
                )
                .await
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        if local_cancel {
            b.cancel_receive(&session.session_id).await;
        }
        let failure = next(&mut events, |e| matches!(e, EventKind::Failed { .. })).await;
        assert!(matches!(
            failure,
            EventKind::Failed {
                code: ErrorCode::Cancelled | ErrorCode::TimedOut,
                ..
            }
        ));
        let _ = task.await.unwrap();
        assert!(b.receipts(10).await.unwrap().is_empty());
    }
    let session = prepare(&a, &b, file("slow.bin", 1024, None)).await;
    let client = a.inner.client(Some(b.fingerprint().into())).unwrap();
    let port = b.address().port();
    let token = session.files["test-file"].clone();
    let task = tokio::spawn(async move {
        client
            .upload(
                ProtocolType::Https,
                "127.0.0.1",
                port,
                None,
                &session.session_id,
                "test-file",
                &token,
                localsend::reqwest::Body::wrap_stream(stream::pending::<
                    std::io::Result<bytes::Bytes>,
                >()),
                tokio_util::sync::CancellationToken::new(),
            )
            .await
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    tokio::time::timeout(Duration::from_secs(3), b.shutdown())
        .await
        .unwrap();
    let _ = task.await;
    assert_eq!(
        fs::read_dir(temp.path().join("b/.incoming"))
            .unwrap()
            .count(),
        0
    );
    a.shutdown().await;
}

#[tokio::test]
async fn malformed_metadata_space_and_path_attacks_declined() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    for name in [
        "../escape",
        "C:\\escape",
        "/tmp/a",
        "a/b",
        "NUL",
        "a:stream",
        "trailing.",
        "file\n",
    ] {
        let payload = PrepareUploadRequestDtoV2 {
            info: a.inner.register(),
            files: HashMap::from([("test-file".into(), file(name, 3, None))]),
        };
        let error = a
            .inner
            .client(Some(b.fingerprint().into()))
            .unwrap()
            .prepare_upload(
                ProtocolType::Https,
                "127.0.0.1",
                b.address().port(),
                None,
                payload,
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await
            .err()
            .unwrap();
        assert_eq!(sender::map_error(error), ErrorCode::Declined);
    }
    assert!(b.pending_offers().is_empty());
    b.shutdown().await;
    let mut cfg = config(&temp.path().join("full"));
    cfg.min_free_bytes = u64::MAX;
    let b = Service::start(cfg).await.unwrap();
    let payload = PrepareUploadRequestDtoV2 {
        info: a.inner.register(),
        files: HashMap::from([("test-file".into(), file("ok.bin", 3, None))]),
    };
    assert!(a
        .inner
        .client(Some(b.fingerprint().into()))
        .unwrap()
        .prepare_upload(
            ProtocolType::Https,
            "127.0.0.1",
            b.address().port(),
            None,
            payload,
            None,
            tokio_util::sync::CancellationToken::new()
        )
        .await
        .is_err());
    assert!(b.recent_events().iter().any(|e| matches!(
        e.kind,
        EventKind::Failed {
            code: ErrorCode::NoSpace,
            ..
        }
    )));
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn bounded_metadata_and_tls_session_binding() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let identity = localsend::reqwest::Identity::from_pem(
        format!("{}\n{}", a.inner.identity.cert, a.inner.identity.key).as_bytes(),
    )
    .unwrap();
    let raw = localsend::reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .identity(identity)
        .no_proxy()
        .build()
        .unwrap();
    let response = raw
        .post(format!(
            "https://{}/api/localsend/v2/prepare-upload",
            b.address()
        ))
        .body(vec![b' '; 1024 * 1024 + 1])
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 413);
    let other = localsend::crypto::cert::generate_self_signed().unwrap();
    let session = prepare(&a, &b, file("ok.bin", 3, None)).await;
    let client = LsHttpClientV2::try_new(
        &other.private_key_pem,
        &other.certificate_pem,
        Some(b.fingerprint().into()),
        Some(Duration::from_secs(5)),
    )
    .unwrap();
    // Same loopback IP, valid token, different certificate: no upload/cancel authority.
    let result = client
        .upload(
            ProtocolType::Https,
            "127.0.0.1",
            b.address().port(),
            None,
            &session.session_id,
            "test-file",
            &session.files["test-file"],
            b"abc".to_vec().into(),
            tokio_util::sync::CancellationToken::new(),
        )
        .await;
    assert!(result.is_err());
    client
        .cancel(
            ProtocolType::Https,
            "127.0.0.1",
            b.address().port(),
            &session.session_id,
        )
        .await
        .unwrap();
    upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    assert_eq!(b.receipts(10).await.unwrap().len(), 1);
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn restart_recovers_only_owned_incomplete_transactions_and_lease() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    let cfg = config(&root);
    let service = Service::start(cfg.clone()).await.unwrap();
    assert!(matches!(
        Service::start(cfg.clone()).await,
        Err(ErrorCode::Busy)
    ));
    service.shutdown().await;
    for parent in [".incoming", ".outgoing", "received"] {
        let prefix = if parent == "received" {
            "file-"
        } else {
            "txn-"
        };
        let dir = root
            .join(parent)
            .join(format!("{prefix}{}", Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("data"), b"partial").unwrap();
    }
    let service = Service::start(cfg).await.unwrap();
    assert!(service.receipts(10).await.unwrap().is_empty());
    assert_eq!(fs::read_dir(root.join(".incoming")).unwrap().count(), 0);
    assert_eq!(fs::read_dir(root.join(".outgoing")).unwrap().count(), 0);
    assert_eq!(fs::read_dir(root.join("received")).unwrap().count(), 0);
    service.shutdown().await;
}

#[tokio::test]
async fn commit_failure_cannot_return_success_and_overflow_is_explicit() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let session = prepare(&a, &b, file("ok.bin", 3, None)).await;
    fs::remove_dir(temp.path().join("b/received")).unwrap();
    fs::write(temp.path().join("b/received"), b"blocked").unwrap();
    assert!(upload(&a, &b, &session, b"abc".to_vec()).await.is_err());
    let mut events = b.subscribe();
    for _ in 0..300 {
        b.inner.emit(EventKind::Progress {
            transfer_id: "test".into(),
            file_id: "file".into(),
            bytes: 0,
            total: 1,
        });
    }
    assert!(matches!(
        events.recv().await,
        Err(broadcast::error::RecvError::Lagged(_))
    ));
    assert!(b.recent_events().iter().any(|e| matches!(
        e.kind,
        EventKind::Failed {
            code: ErrorCode::UnsafeStorage,
            ..
        }
    )));
    a.shutdown().await;
    b.shutdown().await;
}

#[test]
fn rejects_unsafe_storage_and_names() {
    let temp = tempfile::tempdir().unwrap();
    fs::write(temp.path().join("user-photo"), b"untouched").unwrap();
    assert!(matches!(
        storage::Storage::open(temp.path()),
        Err(ErrorCode::UnsafeStorage)
    ));
    assert_eq!(
        fs::read(temp.path().join("user-photo")).unwrap(),
        b"untouched"
    );
    for name in ["..", ".", "CON", "com1.jpg", "LPT9", "a ", "x\\y", ""] {
        assert!(!model::safe_name(name));
    }
    assert!(model::safe_name("照片😀.mov"));
}

#[test]
fn atomic_publication_refuses_existing_target() {
    let temp = tempfile::tempdir().unwrap();
    let storage = storage::Storage::open(temp.path()).unwrap();
    let receipt = Receipt {
        id: Uuid::new_v4().to_string(),
        session_id: "session".into(),
        file_id: "file".into(),
        name: "original.bin".into(),
        size: 3,
        sha256: "0".repeat(64),
        peer_hash_present: false,
    };
    let first = storage.transaction(false).unwrap();
    fs::write(first.path().join("data"), b"old").unwrap();
    storage
        .commit(&first.path().join("data"), &receipt)
        .unwrap();
    let second = storage.transaction(false).unwrap();
    fs::write(second.path().join("data"), b"new").unwrap();
    assert!(storage
        .commit(&second.path().join("data"), &receipt)
        .is_err());
    assert_eq!(
        fs::read(storage.data_path(&receipt.id).unwrap()).unwrap(),
        b"old"
    );
    assert_eq!(fs::read(second.path().join("data")).unwrap(), b"new");
}

#[cfg(windows)]
#[test]
fn windows_publication_waits_for_short_locks_and_bounds_persistent_failure() {
    use std::os::windows::fs::OpenOptionsExt;
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let destination = temp.path().join("published");
    fs::create_dir(&source).unwrap();
    let data = source.join("data");
    fs::write(&data, b"opaque bytes").unwrap();
    let locked = fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(&data)
        .unwrap();
    let started = std::time::Instant::now();
    assert_eq!(storage::publish(&source, &destination), Err(ErrorCode::Io));
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(source.is_dir());
    assert!(!destination.exists());
    let unlock = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        drop(locked);
    });
    storage::publish(&source, &destination).unwrap();
    unlock.join().unwrap();
    assert_eq!(fs::read(destination.join("data")).unwrap(), b"opaque bytes");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("data"), b"replacement").unwrap();
    assert!(storage::publish(&source, &destination).is_err());
    assert_eq!(fs::read(destination.join("data")).unwrap(), b"opaque bytes");
}

#[tokio::test]
async fn accepted_idle_session_expires_and_accept_cancel_race_does_not_leak_slot() {
    let temp = tempfile::tempdir().unwrap();
    let a = Service::start(config(&temp.path().join("a")))
        .await
        .unwrap();
    let mut cfg = config(&temp.path().join("b"));
    cfg.idle_timeout = Duration::from_millis(150);
    let b = Service::start(cfg).await.unwrap();
    let mut events = b.subscribe();
    prepare(&a, &b, file("idle.bin", 3, None)).await;
    next(&mut events, |e| {
        matches!(
            e,
            EventKind::Failed {
                code: ErrorCode::TimedOut,
                ..
            }
        )
    })
    .await;
    for _ in 0..20 {
        let client = a.inner.client(Some(b.fingerprint().into())).unwrap();
        let port = b.address().port();
        let payload = PrepareUploadRequestDtoV2 {
            info: a.inner.register(),
            files: HashMap::from([("test-file".into(), file("race.bin", 3, None))]),
        };
        let mut events = b.subscribe();
        let request = tokio::spawn(async move {
            client
                .prepare_upload(
                    ProtocolType::Https,
                    "127.0.0.1",
                    port,
                    None,
                    payload,
                    None,
                    tokio_util::sync::CancellationToken::new(),
                )
                .await
        });
        let EventKind::Offer { offer } =
            next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
        else {
            unreachable!()
        };
        b.decide(&offer.session_id, Decision::Accept).unwrap();
        b.cancel_receive(&offer.session_id).await;
        let _ = request.await;
    }
    let session = prepare(&a, &b, file("finally.bin", 3, None)).await;
    upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    assert_eq!(b.receipts(10).await.unwrap().len(), 1);
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn duplicate_names_limits_and_receipt_paging() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let source = temp.path().join("same.bin");
    fs::write(&source, b"abc").unwrap();
    let duplicate = temp.path().join("other");
    fs::create_dir(&duplicate).unwrap();
    let duplicate = duplicate.join("SAME.BIN");
    fs::write(&duplicate, b"def").unwrap();
    assert_eq!(
        a.start_send(peer(&b), vec![source, duplicate], None)
            .unwrap()
            .wait()
            .await
            .error,
        Some(ErrorCode::InvalidInput)
    );
    // Duplicate remote names and a size overflow are rejected before asking the user.
    let mut first = file("same.bin", 3, None);
    let mut second = first.clone();
    second.id = "other-id".into();
    second.file_name = "SAME.BIN".into();
    for files in [
        HashMap::from([
            (first.id.clone(), first.clone()),
            (second.id.clone(), second),
        ]),
        {
            first.size = u64::MAX;
            HashMap::from([(first.id.clone(), first)])
        },
    ] {
        let payload = PrepareUploadRequestDtoV2 {
            info: a.inner.register(),
            files,
        };
        assert!(a
            .inner
            .client(Some(b.fingerprint().into()))
            .unwrap()
            .prepare_upload(
                ProtocolType::Https,
                "127.0.0.1",
                b.address().port(),
                None,
                payload,
                None,
                tokio_util::sync::CancellationToken::new()
            )
            .await
            .is_err());
    }
    for _ in 0..3 {
        let session = prepare(&a, &b, file("same.bin", 3, None)).await;
        upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    }
    let first = b.receipts(2).await.unwrap();
    assert_eq!(first.len(), 2);
    let last = b
        .receipts_after(Some(first[1].id.clone()), 2)
        .await
        .unwrap();
    assert_eq!(last.len(), 1);
    assert!(last[0].id > first[1].id);
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn broken_http_body_at_exact_metadata_size_is_not_committed() {
    use futures_util::{stream, StreamExt};
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let session = prepare(&a, &b, file("incomplete-framing.bin", 3, None)).await;
    let mut events = b.subscribe();
    let stream = stream::once(async { Ok::<_, std::io::Error>(bytes::Bytes::from_static(b"abc")) })
        .chain(stream::once(async {
            tokio::time::sleep(Duration::from_millis(100)).await;
            Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "injected body failure",
            ))
        }));
    assert!(upload(
        &a,
        &b,
        &session,
        localsend::reqwest::Body::wrap_stream(stream)
    )
    .await
    .is_err());
    next(&mut events, |e| {
        matches!(
            e,
            EventKind::Failed {
                file_id: Some(_),
                ..
            }
        )
    })
    .await;
    assert!(b.receipts(10).await.unwrap().is_empty());
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn sender_cancel_and_outgoing_limit() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let source = temp.path().join("cancel.bin");
    fs::write(&source, b"abc").unwrap();
    let mut events = b.subscribe();
    let job = a.start_send(peer(&b), vec![source.clone()], None).unwrap();
    next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await;
    job.cancel();
    assert_eq!(job.wait().await.error, Some(ErrorCode::Cancelled));
    next(&mut events, |e| matches!(e, EventKind::SessionEnded { .. })).await;
    assert!(b.pending_offers().is_empty());
    assert!(b.receipts(10).await.unwrap().is_empty());
    let second = a.start_send(peer(&b), vec![source.clone()], None).unwrap();
    let third = a.start_send(peer(&b), vec![source.clone()], None).unwrap();
    assert!(matches!(
        a.start_send(peer(&b), vec![source], None),
        Err(ErrorCode::Busy)
    ));
    second.cancel();
    third.cancel();
    let _ = second.wait().await;
    let _ = third.wait().await;
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn snapshot_recovers_accepted_progress_after_event_overflow() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let session = prepare(&a, &b, file("recover.bin", 3, None)).await;
    let mut slow = b.subscribe();
    for _ in 0..300 {
        b.inner.emit(EventKind::Progress {
            transfer_id: session.session_id.clone(),
            file_id: "test-file".into(),
            bytes: 2,
            total: 3,
        });
    }
    assert!(matches!(
        slow.recv().await,
        Err(broadcast::error::RecvError::Lagged(_))
    ));
    let snapshot = b.snapshot(None, 1).unwrap();
    let file = b.transfer_snapshot(&session.session_id, None, 1).unwrap();
    assert_eq!(snapshot.sequence, file.sequence);
    assert_eq!(snapshot.instance_id, b.instance_id());
    assert_eq!(file.transfer.phase, Phase::Transferring);
    assert_eq!(file.files[0].bytes, 2);
    assert_eq!(file.files[0].name, "recover.bin");
    assert!(b.pending_offers().is_empty());
    upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    let file = b.transfer_snapshot(&session.session_id, None, 1).unwrap();
    assert_eq!(file.files[0].phase, FilePhase::Committed);
    assert!(file.files[0].receipt_id.is_some());
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn managed_delete_leases_and_shutdown_are_coordinated() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let session = prepare(&a, &b, file("leased.bin", 3, None)).await;
    upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    let receipt = b.receipts(1).await.unwrap().remove(0);
    let first = b.acquire_receipt(&receipt.id).await.unwrap();
    let second = b.acquire_receipt(&receipt.id).await.unwrap();
    assert_eq!(b.delete_receipt(&receipt.id).await, Err(ErrorCode::Busy));
    drop(first);
    assert_eq!(b.delete_receipt(&receipt.id).await, Err(ErrorCode::Busy));
    assert_eq!(fs::read(second.path()).unwrap(), b"abc");
    let cfg = b.inner.config.clone();
    let closing = tokio::spawn(b.shutdown());
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!closing.is_finished());
    assert!(matches!(
        Service::start(cfg.clone()).await,
        Err(ErrorCode::Busy)
    ));
    drop(second);
    tokio::time::timeout(Duration::from_secs(3), closing)
        .await
        .unwrap()
        .unwrap();
    let b = Service::start(cfg).await.unwrap();
    let path = b.received_path(&receipt.id).await.unwrap();
    // Unknown contents fail closed before atomic deletion is attempted.
    fs::write(path.parent().unwrap().join("unknown"), b"keep").unwrap();
    assert_eq!(
        b.delete_receipt(&receipt.id).await,
        Err(ErrorCode::UnsafeStorage)
    );
    assert!(path.exists());
    fs::remove_file(path.parent().unwrap().join("unknown")).unwrap();
    b.delete_receipt(&receipt.id).await.unwrap();
    assert!(!path.exists());
    assert!(b.receipts(1).await.unwrap().is_empty());
    assert!(b.acquire_receipt(&receipt.id).await.is_err());
    assert_eq!(
        b.delete_receipt("../escape").await,
        Err(ErrorCode::InvalidInput)
    );
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn export_is_verified_no_replace_and_cannot_target_private_storage() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let session = prepare(&a, &b, file("opaque.bin", 3, None)).await;
    upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    let receipt = b.receipts(1).await.unwrap().remove(0);
    let destination = temp.path().join("export");
    fs::create_dir(&destination).unwrap();
    let path = b
        .export_receipt(&receipt.id, destination.clone())
        .await
        .unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"abc");
    assert_eq!(hash_file(&path).await.unwrap(), receipt.sha256);
    assert_eq!(
        b.export_receipt(&receipt.id, destination).await.err(),
        Some(ErrorCode::AlreadyExists)
    );
    assert_eq!(fs::read(&path).unwrap(), b"abc");
    assert_eq!(
        b.export_receipt(&receipt.id, temp.path().join("b/received"))
            .await
            .err(),
        Some(ErrorCode::UnsafeStorage)
    );
    assert!(b.received_path(&receipt.id).await.unwrap().exists());
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn port_collision_is_actionable_and_releases_the_root() {
    let temp = tempfile::tempdir().unwrap();
    let socket = tokio::net::TcpSocket::new_v4().unwrap();
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawSocket;
        use windows_sys::Win32::Networking::WinSock::{
            setsockopt, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
        };
        let exclusive = 1i32;
        // SAFETY: a live, unbound socket and a valid four-byte option buffer.
        assert_eq!(
            unsafe {
                setsockopt(
                    socket.as_raw_socket() as usize,
                    SOL_SOCKET,
                    SO_EXCLUSIVEADDRUSE,
                    (&exclusive as *const i32).cast(),
                    4,
                )
            },
            0
        );
    }
    socket.bind("0.0.0.0:0".parse().unwrap()).unwrap();
    let occupied = socket.listen(1).unwrap();
    let mut cfg = config(&temp.path().join("collision"));
    cfg.bind = format!("127.0.0.1:{}", occupied.local_addr().unwrap().port())
        .parse()
        .unwrap();
    assert!(matches!(
        Service::start(cfg.clone()).await,
        Err(ErrorCode::PortInUse)
    ));
    cfg.bind = "127.0.0.1:0".parse().unwrap();
    let service = Service::start(cfg).await.unwrap();
    service.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn many_small_files_close_handles_before_directory_publication() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let mut paths = Vec::new();
    for i in 0..128u32 {
        let path = temp.path().join(format!("small-{i}.bin"));
        fs::write(&path, i.to_le_bytes()).unwrap();
        paths.push(path);
    }
    let peer = a.probe(b.address()).await.unwrap();
    let mut events = b.subscribe();
    let job = a.start_send(peer, paths, None).unwrap();
    let EventKind::Offer { offer } =
        next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    let sent = job.wait().await;
    assert_eq!(sent.error, None);
    assert_eq!(sent.files.len(), 128);
    let mut cursor = None;
    let mut checked = 0;
    loop {
        let page = b.receipts_after(cursor, 64).await.unwrap();
        let more = page.len() == 64;
        cursor = page.last().map(|r| r.id.clone());
        for r in page {
            let lease = b.acquire_receipt(&r.id).await.unwrap();
            assert_eq!(hash_file(lease.path()).await.unwrap(), r.sha256);
            checked += 1;
        }
        if !more {
            break;
        }
    }
    assert_eq!(checked, 128);
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn retry_excludes_acked_files_pins_identity_and_rejects_changed_sources() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let first = temp.path().join("重试-1.bin");
    let second = temp.path().join("重试-2.bin");
    fs::write(&first, vec![1u8; 8 * 1024 * 1024]).unwrap();
    fs::write(&second, vec![2u8; 8 * 1024 * 1024]).unwrap();
    let peer = a.probe(b.address()).await.unwrap();
    let mut offers = b.subscribe();
    let mut sender = a.subscribe();
    let job = a
        .start_send(peer.clone(), vec![first.clone(), second.clone()], None)
        .unwrap();
    let id = job.id.clone();
    let EventKind::Offer { offer } =
        next(&mut offers, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    next(&mut sender, |e| matches!(e, EventKind::FileSent { .. })).await;
    a.cancel_send(&id).unwrap();
    let report = job.wait().await;
    assert_eq!(report.files.len(), 1);
    assert_eq!(report.error, Some(ErrorCode::Cancelled));
    let acked = &report.files[0].name;
    let remaining = if acked == "重试-1.bin" {
        &second
    } else {
        &first
    };
    let original = fs::read(remaining).unwrap();
    let forged = Peer {
        address: peer.address,
        fingerprint: "0".repeat(64),
    };
    assert!(matches!(
        a.retry_send(&id, forged, None),
        Err(ErrorCode::IdentityMismatch)
    ));
    fs::write(remaining, vec![3u8; original.len()]).unwrap();
    let changed = a.retry_send(&id, peer.clone(), None).unwrap();
    let changed_id = changed.id.clone();
    assert!(matches!(
        a.retry_send(&id, peer.clone(), None),
        Err(ErrorCode::InvalidInput)
    ));
    assert_eq!(changed.wait().await.error, Some(ErrorCode::SourceChanged));
    fs::write(remaining, original).unwrap();
    let retry = a.retry_send(&changed_id, peer, None).unwrap();
    let EventKind::Offer { offer } =
        next(&mut offers, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    assert_eq!(offer.files.len(), 1);
    assert_ne!(&offer.files[0].name, acked);
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    let retry = retry.wait().await;
    assert_eq!(retry.error, None);
    assert_eq!(retry.files.len(), 1);
    assert_ne!(&retry.files[0].name, acked);
    assert_eq!(
        b.receipts(8)
            .await
            .unwrap()
            .iter()
            .filter(|r| &r.name == acked)
            .count(),
        1
    );
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn unavailable_discovery_interface_preserves_direct_https() {
    let temp = tempfile::tempdir().unwrap();
    let a = Service::start(config(&temp.path().join("a")))
        .await
        .unwrap();
    let mut cfg = config(&temp.path().join("b"));
    cfg.bind = "0.0.0.0:0".parse().unwrap();
    let b = Service::start(cfg).await.unwrap();
    // Select an IPv4 address the OS cannot bind; never modify an interface.
    let absent = (1..=254)
        .map(|n| std::net::Ipv4Addr::new(10, 254, 254, n))
        .find(|ip| std::net::UdpSocket::bind((*ip, 0)).is_err())
        .unwrap();
    assert_eq!(
        b.start_discovery(Some(absent)).await.err(),
        Some(ErrorCode::DiscoveryUnavailable)
    );
    let discovery = b.discovery_snapshot();
    assert!(!discovery.enabled);
    assert_eq!(discovery.error, Some(ErrorCode::DiscoveryUnavailable));
    let remote = format!("127.0.0.1:{}", b.address().port()).parse().unwrap();
    let peer = a.probe(remote).await.unwrap();
    let path = temp.path().join("fallback.bin");
    fs::write(&path, b"direct HTTPS survives multicast failure").unwrap();
    let mut events = b.subscribe();
    let job = a.start_send(peer, vec![path.clone()], None).unwrap();
    let EventKind::Offer { offer } =
        next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    assert_eq!(job.wait().await.error, None);
    let receipt = b.receipts(1).await.unwrap().remove(0);
    let lease = b.acquire_receipt(&receipt.id).await.unwrap();
    assert_eq!(
        hash_file(lease.path()).await.unwrap(),
        hash_file(&path).await.unwrap()
    );
    drop(lease);
    b.stop_discovery().await;
    assert!(b.discovery_snapshot().error.is_none());
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cut_tls_connection_retries_only_remaining_file_at_new_endpoint() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_util::sync::CancellationToken;
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let target = b.address();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = listener.local_addr().unwrap();
    let cut = CancellationToken::new();
    let stop = CancellationToken::new();
    let cut_task = cut.clone();
    let stop_task = stop.clone();
    // Test-only opaque TLS relay. Slow client->server bytes so the cut occurs
    // after a partial second file, without altering the host network or TLS.
    let relay = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                _ = stop_task.cancelled() => break,
                _ = connections.join_next(), if !connections.is_empty() => {},
                accepted = listener.accept() => {
                    let (mut client, _) = accepted.unwrap();
                    let cut = cut_task.clone();
                    let stop = stop_task.clone();
                    connections.spawn(async move {
                        let mut server = tokio::net::TcpStream::connect(target).await.unwrap();
                        let (mut client_read, mut client_write) = client.split();
                        let (mut server_read, mut server_write) = server.split();
                        let forward = async {
                            let mut buffer = [0u8; 16 * 1024];
                            loop {
                                let n = client_read.read(&mut buffer).await?;
                                if n == 0 { return Ok::<(), std::io::Error>(()); }
                                server_write.write_all(&buffer[..n]).await?;
                                tokio::time::sleep(Duration::from_millis(1)).await;
                            }
                        };
                        let reverse = tokio::io::copy(&mut server_read, &mut client_write);
                        tokio::select! { _ = cut.cancelled() => {}, _ = stop.cancelled() => {}, _ = forward => {}, _ = reverse => {} }
                    });
                }
            }
        }
        connections.shutdown().await;
    });
    let first = temp.path().join("link-first.bin");
    let second = temp.path().join("link-second.bin");
    fs::write(&first, vec![1u8; 2 * 1024 * 1024]).unwrap();
    fs::write(&second, vec![2u8; 2 * 1024 * 1024]).unwrap();
    let expected = HashMap::from([
        ("link-first.bin", hash_file(&first).await.unwrap()),
        ("link-second.bin", hash_file(&second).await.unwrap()),
    ]);
    let peer = a.probe(proxy).await.unwrap();
    assert_eq!(peer.fingerprint, b.fingerprint());
    let mut receive_events = b.subscribe();
    let mut send_events = a.subscribe();
    let job = a
        .start_send(peer, vec![first.clone(), second.clone()], None)
        .unwrap();
    let failed_id = job.id.clone();
    let EventKind::Offer { offer } = next(&mut receive_events, |e| {
        matches!(e, EventKind::Offer { .. })
    })
    .await
    else {
        unreachable!()
    };
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    let EventKind::FileSent { file: acked, .. } = next(&mut send_events, |e| {
        matches!(e, EventKind::FileSent { .. })
    })
    .await
    else {
        unreachable!()
    };
    next(&mut receive_events, |e| matches!(e, EventKind::Progress { file_id, bytes, total, .. } if file_id != &acked.id && *bytes > 0 && bytes < total)).await;
    cut.cancel();
    let report = job.wait().await;
    assert!(matches!(
        report.error,
        Some(ErrorCode::Network | ErrorCode::TimedOut)
    ));
    assert_eq!(report.files.len(), 1);
    assert_eq!(report.files[0].id, acked.id);
    stop.cancel();
    relay.await.unwrap();
    b.shutdown().await;
    assert_eq!(
        fs::read_dir(temp.path().join("b/.incoming"))
            .unwrap()
            .count(),
        0
    );

    // Same persisted identity at a different reachable address; the old endpoint
    // remains occupied by a test listener so the OS cannot select its port again.
    let _old_endpoint = tokio::net::TcpListener::bind(target).await.unwrap();
    let b = Service::start(config(&temp.path().join("b")))
        .await
        .unwrap();
    assert_ne!(b.address(), target);
    let receipts = b.receipts(8).await.unwrap();
    assert_eq!(receipts.len(), 1);
    assert_eq!(receipts[0].name, acked.name);
    let impostor = Service::start(Config::new(temp.path().join("other-identity")))
        .await
        .unwrap();
    let wrong_peer = a.probe(impostor.address()).await.unwrap();
    assert!(matches!(
        a.retry_send(&failed_id, wrong_peer, None),
        Err(ErrorCode::IdentityMismatch)
    ));
    assert!(impostor.pending_offers().is_empty());
    impostor.shutdown().await;
    let restored_peer = a.probe(b.address()).await.unwrap();
    let mut events = b.subscribe();
    let retry = a.retry_send(&failed_id, restored_peer, None).unwrap();
    let EventKind::Offer { offer } =
        next(&mut events, |e| matches!(e, EventKind::Offer { .. })).await
    else {
        unreachable!()
    };
    assert_eq!(offer.files.len(), 1);
    assert_ne!(offer.files[0].name, acked.name);
    b.decide(&offer.session_id, Decision::Accept).unwrap();
    let report = retry.wait().await;
    assert_eq!(report.error, None);
    assert_eq!(report.files.len(), 1);
    let receipts = b.receipts(8).await.unwrap();
    assert_eq!(receipts.len(), 2);
    for receipt in receipts {
        let lease = b.acquire_receipt(&receipt.id).await.unwrap();
        assert_eq!(
            hash_file(lease.path()).await.unwrap(),
            expected[receipt.name.as_str()]
        );
    }
    assert_eq!(hash_file(&first).await.unwrap(), expected["link-first.bin"]);
    assert_eq!(
        hash_file(&second).await.unwrap(),
        expected["link-second.bin"]
    );
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test]
async fn foreign_and_damaged_inbox_entries_do_not_block_restart() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    for name in ["one.bin", "two.bin"] {
        let session = prepare(&a, &b, file(name, 3, None)).await;
        upload(&a, &b, &session, b"abc".to_vec()).await.unwrap();
    }
    let receipts = b.receipts(8).await.unwrap();
    assert_eq!(receipts.len(), 2);
    let cfg = b.inner.config.clone();
    b.shutdown().await;
    let root = temp.path().join("b");
    for dir in ["received", ".incoming", ".outgoing"] {
        fs::write(root.join(dir).join(".DS_Store"), b"finder").unwrap();
    }
    // Truncate one received file so its receipt no longer verifies.
    let damaged = root
        .join("received")
        .join(format!("file-{}", receipts[0].id));
    fs::write(damaged.join("data"), b"a").unwrap();
    let b = Service::start(cfg).await.unwrap();
    let listed = b.receipts(8).await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, receipts[1].id);
    // Nothing this store does not own is deleted.
    assert!(root.join("received/.DS_Store").exists());
    assert!(damaged.join("data").exists());
    a.shutdown().await;
    b.shutdown().await;
}

#[test]
fn session_deadline_grows_with_payload() {
    let cfg = Config::new(std::path::PathBuf::new());
    assert_eq!(cfg.session_deadline(0), cfg.session_timeout);
    assert_eq!(
        cfg.session_deadline(16 * 1024 * 1024 * 1024),
        cfg.session_timeout + Duration::from_secs(16 * 1024)
    );
}

#[tokio::test]
async fn racing_session_ends_report_once() {
    let temp = tempfile::tempdir().unwrap();
    let (a, b) = pair(temp.path()).await;
    let session = prepare(&a, &b, file("race.bin", 3, None)).await;
    // The live stream (what the Dart worker sees) is not deduplicated like the journal.
    let mut events = b.subscribe();
    tokio::join!(
        b.cancel_receive(&session.session_id),
        b.cancel_receive(&session.session_id),
        b.inner
            .cancel_session(&session.session_id, ErrorCode::TimedOut),
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    let (mut failed, mut ended) = (0, 0);
    while let Ok(event) = events.try_recv() {
        match event.kind {
            EventKind::Failed { transfer_id, .. } if transfer_id == session.session_id => {
                failed += 1
            }
            EventKind::SessionEnded { session_id } if session_id == session.session_id => {
                ended += 1
            }
            _ => {}
        }
    }
    assert_eq!((failed, ended), (1, 1));
    a.shutdown().await;
    b.shutdown().await;
}
