use crate::protocol::Request;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc, Mutex,
    },
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use transfer_core::{Config, Decision, ErrorCode, ReceiptLease, Result, Service};

pub const QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub const RECORD_BYTES: usize = 1024 * 1024;
pub const RUNNING: u8 = 1;
pub const STOPPING: u8 = 2;
pub const STOPPED: u8 = 3;
pub struct Command {
    pub id: u64,
    pub request: Request,
}
pub struct Queue {
    pub sequence: u64,
    pub lost: u64,
    pub bytes: usize,
    pub records: VecDeque<String>,
}
struct Completed {
    id: u64,
    value: Value,
    bytes: usize,
}
pub struct Entry {
    pub thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    pub instance: String,
    pub phase: AtomicU8,
    pub stop: CancellationToken,
    pub commands: mpsc::Sender<Command>,
    pub priority: mpsc::Sender<Command>,
    pub queue: Mutex<Queue>,
    pub ready: Mutex<Value>,
    leases: Mutex<BTreeMap<u64, ReceiptLease>>,
    results: Mutex<VecDeque<Completed>>,
}
impl Entry {
    pub fn new() -> (Arc<Self>, mpsc::Receiver<Command>, mpsc::Receiver<Command>) {
        let (commands, rx) = mpsc::channel(32);
        let (priority, px) = mpsc::channel(32);
        (
            Arc::new(Self {
                thread: Mutex::new(None),
                instance: uuid::Uuid::new_v4().to_string(),
                phase: AtomicU8::new(0),
                stop: CancellationToken::new(),
                commands,
                priority,
                queue: Mutex::new(Queue {
                    sequence: 0,
                    lost: 0,
                    bytes: 0,
                    records: VecDeque::new(),
                }),
                ready: Mutex::new(Value::Null),
                leases: Mutex::new(BTreeMap::new()),
                results: Mutex::new(VecDeque::new()),
            }),
            rx,
            px,
        )
    }
    pub fn push(&self, value: Value) {
        let mut q = self.queue.lock().unwrap_or_else(|p| p.into_inner());
        q.sequence += 1;
        let record = json!({"sequence":q.sequence,"body":value}).to_string();
        if record.len() > RECORD_BYTES {
            q.lost += 1;
            return;
        }
        while q.records.len() >= 256 || q.bytes + record.len() > QUEUE_BYTES {
            let old = q.records.pop_front().unwrap();
            q.bytes -= old.len();
            q.lost += 1;
        }
        q.bytes += record.len();
        q.records.push_back(record);
    }
    fn complete(&self, id: u64, result: Result<Value>, retain: bool) {
        let value = match result {
            Ok(data) => json!({"kind":"result","operation_id":id,"data":data,"error":null}),
            Err(error) => json!({"kind":"result","operation_id":id,"data":null,"error":error}),
        };
        if retain {
            let bytes = value.to_string().len();
            let mut results = self.results.lock().unwrap();
            while results.len() >= 64
                || results.iter().map(|r| r.bytes).sum::<usize>() + bytes > QUEUE_BYTES
            {
                if results.pop_front().is_none() {
                    break;
                }
            }
            if bytes <= RECORD_BYTES {
                results.push_back(Completed {
                    id,
                    value: value.clone(),
                    bytes,
                });
            }
        }
        self.push(value);
    }
}

pub fn run(
    entry: Arc<Entry>,
    config: Config,
    rx: mpsc::Receiver<Command>,
    px: mpsc::Receiver<Command>,
) {
    // This thread owns the runtime; its destruction precedes the externally visible Stopped state.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(4)
            .enable_all()
            .build();
        match runtime {
            Ok(runtime) => runtime.block_on(worker(entry.clone(), config, rx, px)),
            Err(_) => entry.push(json!({"kind":"start_failed","error":"io"})),
        }
    }));
    if result.is_err() {
        entry
            .leases
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clear();
        entry.push(json!({"kind":"fatal","error":"internal"}));
    }
    entry.push(json!({"kind":"stopped"}));
    entry.phase.store(STOPPED, Ordering::Release);
}

async fn worker(
    entry: Arc<Entry>,
    config: Config,
    mut rx: mpsc::Receiver<Command>,
    mut px: mpsc::Receiver<Command>,
) {
    // Startup may involve blocking key generation/recovery. Stop is remembered, never aborts that I/O.
    let service = match Service::start(config).await {
        Ok(s) => Arc::new(s),
        Err(error) => {
            entry.push(json!({"kind":"start_failed","error":error}));
            return;
        }
    };
    let ready = json!({"address":service.address(),"fingerprint":service.fingerprint(),"core_instance_id":service.instance_id()});
    *entry.ready.lock().unwrap() = ready.clone();
    entry.push(json!({"kind":"ready","data":ready}));
    // A concurrent stop must never be overwritten by a successful startup.
    let _ = entry
        .phase
        .compare_exchange(0, RUNNING, Ordering::AcqRel, Ordering::Acquire);
    let mut events = service.subscribe();
    let mut jobs = tokio::task::JoinSet::new();
    let mut urgent = tokio::task::JoinSet::new();
    let mut sends = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = entry.stop.cancelled() => break,
            cmd = px.recv(), if urgent.len() < 4 => if let Some(cmd) = cmd {
                dispatch(&entry, &service, cmd, &mut urgent, &mut sends);
            },
            event = events.recv() => match event {
                Ok(event) => {
                    let stopped = matches!(event.kind, transfer_core::EventKind::Stopped);
                    entry.push(json!({"kind":"event","event":event}));
                    if stopped { break }
                },
                Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => entry.push(json!({"kind":"resync_required","lost":count})),
                Err(_) => break,
            },
            _ = urgent.join_next(), if !urgent.is_empty() => {},
            _ = jobs.join_next(), if !jobs.is_empty() => {},
            _ = sends.join_next(), if !sends.is_empty() => {},
            cmd = rx.recv(), if jobs.len() < 8 => if let Some(cmd) = cmd {
                dispatch(&entry, &service, cmd, &mut jobs, &mut sends);
            },
        }
    }
    entry.phase.store(STOPPING, Ordering::Release);
    entry.stop.cancel();
    rx.close();
    px.close();
    while let Ok(cmd) = px.try_recv() {
        entry.complete(cmd.id, Err(ErrorCode::Closed), true);
    }
    while let Ok(cmd) = rx.try_recv() {
        entry.complete(cmd.id, Err(ErrorCode::Closed), true);
    }
    // Drop send waiters to cancel core jobs. Finish all blocking storage operations before closing.
    sends.abort_all();
    while sends.join_next().await.is_some() {}
    while urgent.join_next().await.is_some() {}
    while jobs.join_next().await.is_some() {}
    entry.leases.lock().unwrap().clear();
    match Arc::try_unwrap(service) {
        Ok(service) => service.shutdown().await,
        Err(_) => unreachable!("all command and send tasks were joined"),
    }
}

fn dispatch(
    entry: &Arc<Entry>,
    service: &Arc<Service>,
    cmd: Command,
    jobs: &mut tokio::task::JoinSet<()>,
    sends: &mut tokio::task::JoinSet<()>,
) {
    if let Request::Send { peer, paths, pin } = cmd.request {
        match service.start_send(peer, paths, pin) {
            Ok(send) => {
                entry.complete(cmd.id, Ok(json!({"transfer_id":send.id})), true);
                sends.spawn(async move {
                    let _ = send.wait().await;
                });
            }
            Err(error) => entry.complete(cmd.id, Err(error), true),
        }
        return;
    }
    let entry = entry.clone();
    let service = service.clone();
    jobs.spawn(async move {
        let retain = !matches!(cmd.request, Request::Operation { .. });
        let result = execute(&entry, &service, cmd.id, cmd.request).await;
        entry.complete(cmd.id, result, retain);
    });
}
async fn execute(entry: &Entry, service: &Service, id: u64, request: Request) -> Result<Value> {
    if entry.stop.is_cancelled() {
        return Err(ErrorCode::Closed);
    }
    match request {
        Request::CheckSpace { bytes, reserve } => {
            service.check_space(bytes, reserve).await?;
            Ok(Value::Null)
        }
        Request::SendReport { transfer_id } => Ok(json!(service.send_report(&transfer_id)?)),
        Request::Probe { address } => tokio::select! {
            _ = entry.stop.cancelled() => Err(ErrorCode::Closed),
            peer = service.probe(address) => Ok(json!(peer?)),
        },
        Request::Decide {
            transfer_id,
            accept,
        } => {
            service.decide(
                &transfer_id,
                if accept {
                    Decision::Accept
                } else {
                    Decision::Decline
                },
            )?;
            Ok(Value::Null)
        }
        Request::CancelSend { transfer_id } => {
            service.cancel_send(&transfer_id)?;
            Ok(Value::Null)
        }
        Request::CancelReceive { transfer_id } => {
            service.cancel_receive(&transfer_id).await;
            Ok(Value::Null)
        }
        Request::Snapshot { after, limit } => Ok(json!(service.snapshot(after.as_deref(), limit)?)),
        Request::Transfer {
            transfer_id,
            after,
            limit,
        } => Ok(json!(service.transfer_snapshot(
            &transfer_id,
            after.as_deref(),
            limit
        )?)),
        Request::Receipts { after, limit } => {
            Ok(json!(service.receipts_after(after, limit).await?))
        }
        Request::AcquireReceipt { receipt_id } => {
            let lease = service.acquire_receipt(&receipt_id).await?;
            let mut leases = entry.leases.lock().unwrap();
            if entry.stop.is_cancelled() {
                return Err(ErrorCode::Closed);
            }
            if leases.len() >= 32 {
                return Err(ErrorCode::Busy);
            }
            let result = json!({"lease_id":id,"path":lease.path(),"receipt":lease.receipt()});
            leases.insert(id, lease);
            Ok(result)
        }
        Request::ReleaseReceipt { lease_id } => {
            entry
                .leases
                .lock()
                .unwrap()
                .remove(&lease_id)
                .ok_or(ErrorCode::InvalidInput)?;
            Ok(Value::Null)
        }
        Request::DeleteReceipt { receipt_id } => {
            service.delete_receipt(&receipt_id).await?;
            Ok(Value::Null)
        }
        Request::Operation { operation_id } => {
            // Unknown includes pending/evicted IDs; never implies that a mutation did not run.
            Ok(entry
                .results
                .lock()
                .unwrap()
                .iter()
                .find(|r| r.id == operation_id)
                .map(|r| r.value.clone())
                .unwrap_or(json!({"status":"unknown"})))
        }
        Request::Send { .. } => unreachable!(),
    }
}
