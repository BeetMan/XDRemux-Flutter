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
    next(&mut sent_events, |e| {
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
    let port = b.address().port();
    a.shutdown().await;
    b.shutdown().await;
    let mut cfg = config(&temp.path().join("b"));
    cfg.bind.set_port(port);
    let restarted = Service::start(cfg).await.unwrap();
    assert_eq!(restarted.fingerprint(), fingerprint);
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
    let session = prepare(&a, &b, file("file.bin", 3, Some("0".repeat(64)))).await;
    let error = upload(&a, &b, &session, b"abc".to_vec()).await.unwrap_err();
    assert_eq!(sender::map_error(error), ErrorCode::ChecksumMismatch);
    assert!(b.receipts(10).await.unwrap().is_empty());
    b.cancel_receive(&session.session_id).await;
    // Failed-file retry is a new explicit session, retaining no partial data.
    let session = prepare(&a, &b, file("file.bin", 3, None)).await;
    assert!(upload(&a, &b, &session, b"ab".to_vec()).await.is_err());
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
