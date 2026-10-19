# Transfer C ABI 1.2 (P2.0 / P2.1 / P2.2)

Independent adapter for `../xdremux-transfer`, built with Rust 1.97.1. Outputs `xdremux_transfer.dll` (Windows x64) or `libxdremux_transfer.so` (Android ARM64). It owns a background Tokio runtime per handle. It does not load the image engine, implement Flutter UI, package an APK, grant network permissions or enable discovery. Core provenance/license obligations are in [UPSTREAM.md](../xdremux-transfer/UPSTREAM.md).

## Calls and ownership

The exact C signatures are in [include/xdremux_transfer.h](include/xdremux_transfer.h). `abi_version()` returns `0x00010002` (major in the upper 16 bits). Version 1.1 added advisory `check_space`; 1.2 adds `export_receipt` and `already_exists`. Exported signatures are unchanged. Callers must reject an unsupported major version and tolerate additional JSON fields. The P2.2 Dart application requires minor ≥2. Requests reject unknown fields; invalid UTF-8/JSON, oversized input and invalid limits return `InvalidInput`.

| Status | Meaning |
|---|---|
| 0 | Accepted / success; async operation errors arrive separately |
| 1 | InvalidInput, including an unknown string allocation |
| 2 | InvalidHandle, including a released/stale handle |
| 3 | Busy: capacity exhausted, or release before Stopped |
| 4 | Closed: service is stopping/stopped |
| 5 | TooSmall: first complete record/header cannot fit the poll byte limit |
| 6 | Internal: caught boundary panic or unavailable runtime/registry |

`create(UTF8, length, &handle)` copies/deserializes config and starts a background thread. Config: `{"root":"ABSOLUTE_PRIVATE_PATH","bind":"127.0.0.1:0","alias":"XDRemux","pin":null}`. Only `root` is required; its parent must exist. The directory must satisfy the core's private-storage contract. Key generation, recovery and listening happen asynchronously. Creation can succeed followed by `start_failed`; always poll. No raw runtime, service or file pointers cross the ABI.

`submit(handle, UTF8, length, &operation)` owns all parsed arguments before returning. Success means queued, **not completed**. Results are tagged with the operation ID. Commands can complete out of order; wait for a result before dependent commands. File bytes never cross this ABI. `probe` is discovery only; the caller must confirm the returned certificate before `send`.

`poll(handle, max_events, max_bytes, &string)` drains whole records without waiting for network/disk operations. The return is UTF-8 JSON followed by NUL. `max_bytes` includes that NUL. TooSmall or Busy drains nothing. Pass the returned pointer exactly once to this library's `free_string`, never the image library/free/malloc. NULL free is accepted. Unknown addresses and immediate repeated free are rejected without dereferencing; stale pointer reuse remains forbidden because allocator addresses can be reused. Do not mutate returned buffers. No exported API can validate arbitrary non-null caller pointers: the C caller must supply valid readable input and aligned writable, nonoverlapping output memory for the call.

`stop(handle)` is idempotent and independent of command queue capacity. Finish external reads/copies first: stop revokes all adapter receipt leases. It closes queues, completes queued requests with Closed, cancels sends, joins active operations, drops leases, awaits core shutdown, and destroys the runtime. Poll `phase == 3`, then call `release(handle)`. Release joins the service thread epilogue and removes the numeric handle. Free outstanding strings and release **all** handles before unloading the library. Calling stop during startup remembers the request but waits for key generation/recovery already in progress; it is not a hard I/O deadline. Disk operations may delay shutdown. An unexpected runtime panic produces a fatal record and tears down the runtime; no continuation is promised.

ABI entry points catch Rust unwinding panics. The adapter rejects compilation with `panic=abort`. This does not recover from invalid caller memory, process termination or allocator abort. No global panic hook is installed by the library.

## Commands

Every request has `"command"` plus the listed fields. Optional fields can be omitted or null. Stable async errors use the core's snake_case error codes, never OS paths or remote exception strings.

| Command | Fields | Success data |
|---|---|---|
| `probe` | `address` (`IP:port`) | `{address,fingerprint}` |
| `send` | confirmed `peer`, absolute `paths`, optional `pin` | `{transfer_id}`; later `sent` event / `send_report` |
| `decide` | `transfer_id`, `accept` boolean | null |
| `cancel_send` | `transfer_id` | null; await `sent` for final report |
| `cancel_receive` | `transfer_id` | null after commit gate closes; already committed files remain |
| `snapshot` | optional `after`, `limit` 1–64 | instance, observed sequence, evicted count, summaries, next cursor |
| `transfer` | `transfer_id`, optional `after`, `limit` 1–64 | summary plus file page (IDs, names, hash, bytes, phase, error, receipt ID) |
| `send_report` | `transfer_id` | ACKed files with IDs and terminal error; Busy while active |
| `receipts` | optional `after`, `limit` 1–64 | committed receipt array; pass last receipt ID for another page |
| `check_space` | `bytes`, `reserve` (unsigned integers) | null if the service-root filesystem has sufficient free bytes; advisory only, OS write errors still apply |
| `acquire_receipt` | `receipt_id` | `{lease_id,path,receipt}`; lease ID equals the known operation ID |
| `release_receipt` | `lease_id` | null; unknown/already released lease is InvalidInput |
| `delete_receipt` | `receipt_id` | null; Busy while any reader lease exists |
| `export_receipt` | `receipt_id`, absolute destination `directory` | `{path}` after verified streaming copy, flush/sync and atomic no-replace publication |
| `operation` | `operation_id` | cached result or `{status:"unknown"}`; this query does not consume cache entries |

`acquire_receipt` protects the immutable, extensionless `data` file until explicit release or stop. The caller may stream-read/copy it, must not mutate or rename it, and must not delete private directories. Do not assume a cached acquire result means the lease remains live after release/stop. If its output was lost, release using the acquire operation ID. A completed independent copy belongs to the application's checkpoint/export system. See the [Dart worker, controller and checkpoint handoff](../../apps/flutter/lib/services/transfer/README.md).

Desktop export requires an existing plain directory outside private transfer storage. It acquires a read lease, checks destination space (payload +64 MiB), hashes a 64 KiB streaming copy, verifies length/SHA-256, syncs and publishes without overwriting an existing name. Ordinary failures clean staging; process death can leave an owned `.xdremux-export-*` temporary directory in the chosen destination. An error after publication can leave a complete file: verify/refresh before retrying. Android SAF uses its own leased native stream and provider readback; URI strings are never treated as filesystem paths by this ABI.

Deletion validates the receipt and exactly the owned data/receipt children, atomically moves the directory into owned transaction storage, then removes its files. A crash after the move leaves an invisible tombstone cleaned at startup. A disk error after the move can report Io although the file is already absent; refresh receipts before retrying. Repeated delete of a missing receipt reports Io. Unknown children and links fail closed.

## Events and recovery

Poll returns `{instance_id, phase, ready, last_sequence, lost, records:[{sequence,body}]}`. Phases: 0 starting, 1 running, 2 stopping, 3 stopped. `ready` persists the actual listener address, certificate fingerprint and **core** instance ID even if the ready record is lost. `last_sequence` is the latest produced bridge record, **not** the cursor of the last drained record. Process each record's own sequence. `lost` is cumulative bridge overflow count. Body kinds include `ready`, `start_failed`, `event`, `result`, `resync_required`, `fatal`, `stopped`. A result is `{kind:"result",operation_id,data,error}`. A core event is nested as `{kind:"event",event:{instance_id,sequence,kind,...}}`.

Bridge sequence and core sequence are different streams. Compare sequences only within their respective instance IDs. Core snapshots and their observed sequence are captured under the same lock as state/event publication. `send_started` establishes a preparing job; `prepared`, `progress`, `file_sent`, `sent` and reports use the same file IDs. Receive states include pending, accepted, progress, committed and ended/failed; successful files remain successful after a later session cancellation.

Start polling before requesting snapshots. If bridge `lost` increases or a `resync_required` record arrives, rescan summary/file pages and persistent receipts, deduplicate by transfer/file/receipt ID, then apply newer core events. Pages are live observations, not one frozen database transaction. UUID cursors sort by ID, not commit time; new entries can sort before a cursor. Repeat reconciliation when sequences change or overflow recurs. Retain all active jobs and the last **32 terminal jobs** per runtime; `evicted` makes terminal eviction explicit. Terminal reports are reconstructible from these jobs. Only committed receipts survive restart; the application must save any longer history itself.

The last 64 completed operation results are recoverable, capped at 4 MiB. `unknown` can mean pending, evicted or nonexistent: **never infer a mutation failed or replay it automatically**. A lost send result can be reconciled with transfer snapshots; acquire has a caller-known lease ID; deletion requires a receipt rescan. No exactly-once promise.

## Bounds

- 4 handles/process; each runtime has 2 async worker threads and at most 4 blocking threads.
- Input JSON ≤64 KiB; paths ≤4096 native code units; up to 1024 paths, further limited by JSON size.
- 32 normal queued commands, 8 executing normal commands; 32 reserved priority commands, 4 executing priority commands. Cancellation/lease release use priority; stop uses a separate token.
- 32 live receipt leases/handle. Core defaults allow 2 outgoing transfers and at most 16 incoming sessions.
- Bridge queue ≤256 records **and** 4 MiB; one record ≤1 MiB; overflow drops oldest records and increments `lost`, never truncates a record.
- Poll 1–128 records, 256 bytes–2 MiB. Output allocations across the process: ≤64 buffers and ≤16 MiB. Free promptly; allocator exhaustion returns Busy without draining.
- History and snapshots contain filenames, certificate identities and (for leased reads) private paths. Keep them out of telemetry. Do not log request JSON, which can contain PINs and source paths.

These are bounded synchronous calls with brief mutex/JSON work, not lock-free real-time guarantees. Dart should load the library and poll in a persistent worker isolate. Snapshot/list/receipt I/O stays on the native runtime.

## Build and validation

From the repository root:

```powershell
cargo +1.97.1 test --manifest-path crates/xdremux-transfer-ffi/Cargo.toml --locked -j 2
cargo +1.97.1 fmt --manifest-path crates/xdremux-transfer-ffi/Cargo.toml -- --check
cargo +1.97.1 clippy --manifest-path crates/xdremux-transfer-ffi/Cargo.toml --all-targets --no-deps --locked -- -D warnings
cargo +1.97.1 build --manifest-path crates/xdremux-transfer-ffi/Cargo.toml --release --locked -j 2
python crates/xdremux-transfer-ffi/scripts/smoke.py crates/xdremux-transfer-ffi/target/release/xdremux_transfer.dll --report crates/xdremux-transfer-ffi/target/windows-smoke.json
```

Use the P1 NDK environment variables with `--target aarch64-linux-android` for Android. `scripts/android_smoke.c` loads the real `.so` with `dlopen`; compile with the NDK API-24 clang and `-ldl`, then deploy that binary and library to a new `/data/local/tmp/` test directory. Invoke `android_abi_smoke LIBRARY_ABSOLUTE_PATH NEW_PRIVATE_ROOT` with an existing root parent. It checks three start/stop cycles on the same root/port, certificate persistence, changing instances, snapshots and allocation/handle errors. It does not install an app or test application permissions. Windows `smoke.py` tests real HTTPS transfers through the DLL, independent byte hashes, leases, deletion, paging, output caps and shutdown while waiting for peer acceptance.

Do not format the vendored LocalSend source. Root/image manifests and Flutter packaging remain separate. Apple linking/signing and HarmonyOS execution are deferred.
