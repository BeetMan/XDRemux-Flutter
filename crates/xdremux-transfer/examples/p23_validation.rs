//! Explicit, loopback-only synthetic scale validation. Never accepts user files.
use std::{
    collections::HashMap,
    fs,
    io::{Seek, SeekFrom, Write},
    path::PathBuf,
    sync::Arc,
    time::Instant,
};
use tokio_util::sync::CancellationToken;
use xdremux_transfer::{hash_file, Config, Decision, EventKind, Service};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 || args[1] != "--synthetic-test-only" {
        return Err("Expected --synthetic-test-only ABSOLUTE_REPORT".into());
    }
    let report = PathBuf::from(&args[2]);
    if !report.is_absolute() {
        return Err("Absolute report path required".into());
    }
    let parent = fs::canonicalize(report.parent().ok_or("Report parent missing")?)?;
    let temp = tempfile::Builder::new()
        .prefix("p23-owned-")
        .tempdir_in(&parent)?;
    if !fs::canonicalize(temp.path())?.starts_with(&parent) {
        return Err("Unexpected test root".into());
    }
    let source = temp.path().join("sources");
    fs::create_dir(&source)?;
    let a = Service::start(Config::new(temp.path().join("sender"))).await?;
    let b = Arc::new(Service::start(Config::new(temp.path().join("receiver"))).await?);
    let peer = a.probe(b.address()).await?;
    let mut events = b.subscribe();
    let stop = CancellationToken::new();
    let token = stop.clone();
    let receiver = b.clone();
    let decisions = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = token.cancelled() => break,
                event = events.recv() => match event {
                    Ok(e) => if let EventKind::Offer { offer } = e.kind {
                        assert!(offer.files.iter().all(|f| f.name.starts_with("p23-")));
                        receiver.decide(&offer.session_id, Decision::Accept).unwrap();
                    },
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {},
                    Err(_) => break,
                }
            }
        }
    });
    let mut rounds = Vec::new();
    for (label, count, bytes) in [
        ("baseline", 1usize, 16u64 * 1024 * 1024),
        ("large", 1, 2u64 * 1024 * 1024 * 1024),
        ("many", 1000, 1024),
    ] {
        fs::write(
            report.with_extension("stage.json"),
            serde_json::to_vec(&serde_json::json!({"stage":label}))?,
        )?;
        let mut paths = Vec::new();
        let mut expected = HashMap::new();
        for index in 0..count {
            let name = format!("p23-{label}-{index:04}.bin");
            let path = source.join(&name);
            let mut file = fs::File::create(&path)?;
            file.set_len(bytes)?;
            file.write_all(b"P23 synthetic opaque fixture")?;
            file.seek(SeekFrom::End(-8))?;
            file.write_all(&(index as u64).to_le_bytes())?;
            file.sync_all()?;
            expected.insert(name, hash_file(&path).await?);
            paths.push(path);
        }
        let start = Instant::now();
        let job = a.start_send(peer.clone(), paths.clone(), None)?;
        let id = job.id.clone();
        let sent = job.wait().await;
        let transfer_ms = start.elapsed().as_millis();
        if sent.error.is_some() {
            fs::write(
                report.with_extension("failure.json"),
                serde_json::to_vec_pretty(
                    &serde_json::json!({"round":label,"sent":sent,"receiverEvents":b.recent_events(),"senderEvents":a.recent_events()}),
                )?,
            )?;
        }
        assert_eq!(sent.error, None);
        assert_eq!(sent.files.len(), count);
        let mut cursor = None;
        let mut observed = 0;
        loop {
            let page = a.transfer_snapshot(&id, cursor.as_deref(), 64)?;
            observed += page.files.len();
            cursor = page.next;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(observed, count);
        let verify = Instant::now();
        let mut cursor = None;
        let mut checked = 0;
        loop {
            let page = b.receipts_after(cursor, 64).await?;
            let more = page.len() == 64;
            cursor = page.last().map(|r| r.id.clone());
            for receipt in page {
                if let Some(hash) = expected.get(&receipt.name) {
                    assert_eq!(&receipt.sha256, hash);
                    assert_eq!(receipt.size, bytes);
                    let lease = b.acquire_receipt(&receipt.id).await?;
                    assert_eq!(&hash_file(lease.path()).await?, hash);
                    checked += 1;
                }
            }
            if !more {
                break;
            }
        }
        assert_eq!(checked, count);
        for path in &paths {
            assert_eq!(
                hash_file(path).await?,
                expected[path.file_name().unwrap().to_str().unwrap()]
            );
        }
        rounds.push(serde_json::json!({"kind":label,"files":count,"bytesPerFile":bytes,"totalBytes":bytes * count as u64,"snapshotFiles":observed,"diskHashesMatch":true,"sourceUnchanged":true,"transferMs":transfer_ms,"verificationMs":verify.elapsed().as_millis()}));
        fs::write(
            report.with_extension("progress.json"),
            serde_json::to_vec_pretty(&rounds)?,
        )?;
    }
    stop.cancel();
    decisions.await?;
    a.shutdown().await;
    Arc::try_unwrap(b).ok().unwrap().shutdown().await;
    fs::write(
        &report,
        serde_json::to_vec_pretty(
            &serde_json::json!({"passed":true,"scope":"Windows/native loopback HTTPS synthetic scale; not device throughput","rounds":rounds}),
        )?,
    )?;
    println!("P23 scale validation passed");
    Ok(())
}
