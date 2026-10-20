# XDRemux transfer service (P1–P2.3)

An independent Rust workspace implementing LocalSend v2 HTTPS file transfers. It does not depend on or initialize the image engine. Root Cargo manifests and image dependencies remain independent; Flutter optionally packages a separately built transfer library. LocalSend core provenance and patches are documented in [UPSTREAM.md](UPSTREAM.md).

## API and lifecycle

Run the async API on an application's background Tokio runtime. `Service::start(Config)` starts mTLS listeners only at the configured address. The default is **loopback with an ephemeral port**; callers explicitly choose a LAN address. `Service::address()` reports the actual port. `shutdown(self).await` cancels work, closes listeners, joins transfer workers and releases the storage lease before returning. Drop all `ReceiptLease` guards before awaiting shutdown; it waits for outstanding readers. Dropping a service requests the same cleanup asynchronously; keep the runtime alive until cleanup finishes. The independent [C ABI adapter](../xdremux-transfer-ffi/README.md) supplies its own runtime; the [P2.1 Dart worker](../../apps/flutter/lib/services/transfer/README.md) handles polling and checkpoint handoff. Windows/Android UI and release application evidence are recorded under docs/testing/local-transfer-p22.md and local-transfer-p23.md.

```rust,ignore
let mut config = Config::new(app_private_dir.join("transfer"));
config.bind = "192.168.1.20:53318".parse()?;
let service = Service::start(config).await?;
let mut events = service.subscribe();
// Surface EventKind::Offer to the user, then explicitly:
service.decide(&offer.session_id, Decision::Accept)?;
// For sending, show/confirm the actual certificate identity returned by probe.
let peer = service.probe(remote_address).await?;
let transfer = service.start_send(confirmed_peer, paths, optional_pin)?;
let report = transfer.wait().await;
service.shutdown().await;
```

There is no automatic accept path in the service. PIN is optional additional authorization. Aliases are display text; they confer no trust. `probe` exchanges metadata over HTTPS without a previously trusted fingerprint. `start_send` requires a caller-confirmed SHA-256 certificate fingerprint and pins all file metadata/upload requests to it; there is no HTTP fallback. The Flutter transfer page implements explicit fingerprint confirmation. A pinning-handshake failure after discovery reports `Network`; a known fingerprint mismatch found during the preflight probe reports `IdentityMismatch`.

`cancel_receive(id).await` closes the commit gate before returning. Files committed earlier remain available. `SendHandle::cancel()` is idempotent; dropping a send handle cancels it. `wait()` returns ACKed files plus a stable optional error. Use explicit `retry_send` on a retained failed job to exclude ACKed files, pin the same identity and verify previously prepared source hashes. PINs are never retained; stop or terminal eviction discards retry plans. A lost success response can leave a committed receiver file without a sender ACK; reconcile receipts before retrying uncertain results. No automatic retry, overwrite or exactly-once guarantee is implied. The sender's overall deadline includes snapshot preparation; per-request and receiver idle/decision/session deadlines are configurable.

Events carry a fresh `instance_id` per service start, increasing sequence numbers and a bounded broadcast queue. Slow observers receive `RecvError::Lagged`; resync `snapshot(after,limit)`, `transfer_snapshot(id,after,limit)` and persistent `receipts_after(last_id,limit)`. Summary/file pages (1–64 entries) capture state and observed sequence atomically with event publication. They retain all active jobs and the last 32 terminal jobs, with an explicit terminal eviction counter. `send_report(id)` reconstructs the ACKed files and final error while that terminal job is retained; it returns Busy while active. `pending_offers` and bounded `recent_events` remain available. Progress is coalesced every 512 KiB and at the last nonempty chunk. `recent_events` excludes progress and is not an audit log. Pages are sorted by ID, not time; repeat reconciliation and apply newer events to include records created during a scan. Only committed receipts persist across service restart.

`SendStarted` establishes the preparing job. `SentFile.id` links `Prepared`, `Progress.file_id`, `FileSent` and terminal `SendReport.files`; file order is not an identity. `Prepared` identifies completed immutable snapshots; `FileSent` marks each receiver ACK. `Committed` means available in the private inbox; it does not imply gallery import. `Sent` means protocol ACKs from the receiver; third-party receiver durability is controlled by that application. `cancel_send(id)` exposes cancellation without requiring the original `SendHandle`.

## File and storage contract

The root must be an application-private directory on a local filesystem supporting atomic no-replace rename and filesystem leases. Use app data, never a user-selected general photo directory or a network share. An exclusive filesystem lease prevents a second service from using/cleaning the same root. New Unix roots use mode 0700 and identities use 0600; Windows inherits the app directory's ACL. Existing parent/root privacy is the caller's responsibility. Concurrent malicious local writers with permission to alter that directory are outside this contract; link checks are defense in depth, not a directory-handle sandbox.

- Sender copies each source in 64 KiB chunks and hashes the copy. It checks the open source handle's length and modification time before/after copying. Mutation after `Prepared` cannot alter uploaded bytes. Metadata checks detect ordinary concurrent edits; they cannot prove a source was unchanged against a writer that restores timestamps. Files remain opaque, including HEIC auxiliary/private bytes and trailing data.
- Receiver uses a four-slot chunk channel, limited concurrent file workers and private `txn-<UUID>` staging directories. Clean HTTP EOF, exact declared length and any supplied SHA-256 must pass before `flush`/`sync_all` and final publication. No supplied hash is recorded as `peer_hash_present=false`; a local computed hash is still available.
- Data and its completed `receipt.json` are published together by atomically renaming the staged directory to `received/file-<UUID>/`. File payload is `data`. Publication uses Windows `MoveFileExW` without replacement, Linux/Android `renameat2(RENAME_NOREPLACE)` or Apple `renamex_np(RENAME_EXCL)`; unsupported operations fail closed. No hard links or racy exists/rename fallback are used. Sender names are metadata only. Receipts never supply filesystem paths; `received_path(receipt_id)` resolves validated committed data. Same names in a batch are rejected case-insensitively; later sessions create independent IDs and never overwrite previous data. Stage and inbox share a filesystem. Publication and receipt reads are serialized.
- Files and receipt contents are flushed before ACK. Unix also syncs directories; Windows flushes file handles but does not promise directory/power-loss durability. Process-crash recovery removes owned staging and inbox directories lacking a marker; fully published data is retained. A malformed published receipt or managed symlink/reparse point fails closed and preserves evidence. Recovery never recursively traverses an unknown directory.
- Default caps: 1024 files, 16 GiB/file, 64 GiB/session, 64 MiB free-space reserve, two incoming file workers, two outgoing jobs, 128 events. Names are limited to 240 UTF-8 bytes, IDs to 128, alias/PIN to 128, metadata to 1 MiB. Traversal, drive/ADS names, reserved device names, controls, trailing dots/spaces and duplicate names are rejected. Preview-bearing offers are currently declined. Free-space preflight is advisory; OS no-space failures are also mapped to `NoSpace`.

P2.0 adds `acquire_receipt(id)` returning a `ReceiptLease` with validated receipt metadata and an immutable path. Keep the guard for an entire read/copy, then drop it. `delete_receipt(id)` returns Busy while any guard exists. It validates owned children, atomically moves the receipt directory into owned transaction storage, then removes it without recursive traversal; startup cleans any remaining tombstone. If an I/O failure occurs after moving, refresh receipts before retrying. Legacy `received_path` is only a momentary lookup and does not protect subsequent reads from deletion. Shutdown waits for guards and rejects new readers once closing begins. No automatic deletion, export, queue handoff or file decoding is performed. Incoming sessions are capped at 16 in addition to existing connection/file-worker limits.

Logs never include payloads, PINs, tokens or full source paths. Events/receipts intentionally include display filenames and certificate identities; the UI must avoid forwarding them into telemetry. Paths returned by lease APIs are private and must likewise remain out of telemetry.

P2.2 exposes explicit `export_receipt(id, directory)` for desktop documents. The destination is an existing plain directory outside private storage. Export holds a receipt lease, checks free space, streams a verified copy into destination-local staging, flushes/syncs and publishes without replacing an existing name (`AlreadyExists`). The private original remains available. There is no automatic export or gallery insertion; Android document URIs use the application's separate SAF bridge.

## Build, test and native harness

```powershell
cargo +1.97.1 test --manifest-path crates/xdremux-transfer/Cargo.toml --locked -j 2
cargo +1.97.1 fmt --manifest-path crates/xdremux-transfer/Cargo.toml -p xdremux-transfer -- --check
cargo +1.97.1 clippy --manifest-path crates/xdremux-transfer/Cargo.toml --all-targets --no-deps --locked -- -D warnings
cargo +1.97.1 build --manifest-path crates/xdremux-transfer/Cargo.toml --locked --release --example transfer
```

The `transfer` example is **test-only** and requires `--accept-test-files` to accept `xdremux-poc-*` names. Its receiver is time-bounded. Production must show every offer to the user. Positional commands:

```text
transfer receive ROOT BIND SECONDS REPORT --accept-test-files [NOTIFY_ADDRESS]
transfer send ROOT PEER FINGERPRINT REPORT FILE...
```

ROOT's parent must already exist. Use the fingerprint printed by the receiver's ready record. The sender also supports the explicit `discover-test-only` value for controlled interoperability tests; this is not production pairing.

For Android ARM64 set `CC_aarch64_linux_android` and `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` to the NDK's `aarch64-linux-android24-clang.cmd`, and `AR_aarch64_linux_android` to `llvm-ar.exe`; build the example with `--target aarch64-linux-android`. Then run `scripts/run-android.ps1` with `-AndroidHost`, `-WindowsHost`, `-AdbPath`, `-FixtureDirectory`, `-WindowsBinary` and `-AndroidBinary`. It accepts only ASCII `xdremux-poc-*` fixtures, tests both directions over LAN HTTPS with explicit fingerprints, and independently checks final disk lengths/hashes on both hosts. ADB is used for deployment/control/verification only. Logs and private test stores are under ignored `target/runs/`; bounded remote test directories are retained for inspection.

Windows/Android **native/shell** evidence is separate from Flutter application integration, OS permissions, firewall, background operation and gallery behavior. P2.3 covers Windows/Android app multicast discovery and Windows native/ABI scale checks (2 GiB, 1000 files); Android scale, older clients, the full network/platform matrix, Apple and HarmonyOS runtime remain pending.

P2.3 adds optional bounded IPv4 multicast discovery through `start_discovery(interface)`, `discovery_snapshot()` and `stop_discovery()`. Multicast hints are verified over HTTPS before presentation; they confer no trust. The application still confirms fingerprints. Only RFC1918/private and IPv4 link-local candidates are discovered, with 128 peers, 90 s TTL and bounded probes/queues. Manual direct transfer remains available if discovery fails. See the [ABI contract](../xdremux-transfer-ffi/README.md) for exact bounds.

On receive, Tokio in-flight writes finish before the owned standard file handle is flushed, synced and closed in a blocking worker, then the directory is published. Windows publication retries only OS access/sharing/lock conflicts (5/32/33), up to eight attempts with 450 ms total backoff, always using no-replace MoveFileExW. Persistent failures retain the existing Io outcome; no ACK is emitted. External filesystem operations may exceed backoff time.
