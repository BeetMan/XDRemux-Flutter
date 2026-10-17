use crate::model::*;
use std::collections::{BTreeMap, VecDeque};

pub(crate) const TERMINAL_LIMIT: usize = 32;
pub(crate) struct Transfer {
    summary: TransferSummary,
    files: BTreeMap<String, FileState>,
}
pub(crate) struct Journal {
    pub instance_id: String,
    pub sequence: u64,
    pub history: VecDeque<Event>,
    transfers: BTreeMap<String, Transfer>,
    terminals: VecDeque<String>,
    evicted: u64,
}
impl Journal {
    pub fn new() -> Self {
        Self {
            instance_id: uuid::Uuid::new_v4().to_string(),
            sequence: 0,
            history: VecDeque::new(),
            transfers: BTreeMap::new(),
            terminals: VecDeque::new(),
            evicted: 0,
        }
    }
    fn finish(&mut self, id: &str, error: Option<ErrorCode>) {
        let Some(t) = self.transfers.get_mut(id) else {
            return;
        };
        if matches!(t.summary.phase, Phase::Completed | Phase::Failed) {
            return;
        }
        t.summary.error = t.summary.error.or(error);
        t.summary.phase = if t.summary.error.is_some() {
            Phase::Failed
        } else {
            Phase::Completed
        };
        for f in t.files.values_mut() {
            if !matches!(f.phase, FilePhase::Sent | FilePhase::Committed) {
                f.phase = FilePhase::Failed;
                f.error = t
                    .summary
                    .error
                    .or(f.error)
                    .or(Some(ErrorCode::RemoteFailure));
            }
        }
        self.terminals.push_back(id.to_owned());
        while self.terminals.len() > TERMINAL_LIMIT {
            self.transfers.remove(&self.terminals.pop_front().unwrap());
            self.evicted += 1;
        }
    }
    pub fn apply(&mut self, event: &EventKind) {
        match event {
            EventKind::SendStarted {
                transfer_id,
                file_count,
            } => {
                self.transfers.insert(
                    transfer_id.clone(),
                    Transfer {
                        summary: TransferSummary {
                            id: transfer_id.clone(),
                            direction: Direction::Send,
                            phase: Phase::Preparing,
                            file_count: *file_count,
                            error: None,
                            alias: None,
                            peer_fingerprint: None,
                        },
                        files: BTreeMap::new(),
                    },
                );
            }
            EventKind::Offer { offer } => {
                self.transfers.insert(
                    offer.session_id.clone(),
                    Transfer {
                        summary: TransferSummary {
                            id: offer.session_id.clone(),
                            direction: Direction::Receive,
                            phase: Phase::Pending,
                            file_count: offer.files.len(),
                            error: None,
                            alias: Some(offer.alias.clone()),
                            peer_fingerprint: Some(offer.peer_fingerprint.clone()),
                        },
                        files: offer
                            .files
                            .iter()
                            .map(|f| {
                                (
                                    f.id.clone(),
                                    FileState {
                                        id: f.id.clone(),
                                        name: f.name.clone(),
                                        size: f.size,
                                        sha256: f.sha256.clone(),
                                        bytes: 0,
                                        phase: FilePhase::Waiting,
                                        error: None,
                                        receipt_id: None,
                                    },
                                )
                            })
                            .collect(),
                    },
                );
            }
            EventKind::Prepared { transfer_id, files } => {
                if let Some(t) = self.transfers.get_mut(transfer_id) {
                    t.summary.phase = Phase::Pending;
                    t.files = files
                        .iter()
                        .map(|f| {
                            (
                                f.id.clone(),
                                FileState {
                                    id: f.id.clone(),
                                    name: f.name.clone(),
                                    size: f.size,
                                    sha256: Some(f.sha256.clone()),
                                    bytes: 0,
                                    phase: FilePhase::Waiting,
                                    error: None,
                                    receipt_id: None,
                                },
                            )
                        })
                        .collect();
                }
            }
            EventKind::Accepted { session_id } => {
                if let Some(t) = self.transfers.get_mut(session_id) {
                    t.summary.phase = Phase::Accepted;
                }
            }
            EventKind::Progress {
                transfer_id,
                file_id,
                bytes,
                ..
            } => {
                if let Some(t) = self.transfers.get_mut(transfer_id) {
                    if matches!(t.summary.phase, Phase::Completed | Phase::Failed) {
                        return;
                    }
                    t.summary.phase = Phase::Transferring;
                    if let Some(f) = t.files.get_mut(file_id) {
                        if !matches!(f.phase, FilePhase::Sent | FilePhase::Committed) {
                            f.bytes = (*bytes).min(f.size);
                            f.phase = FilePhase::Transferring;
                        }
                    }
                }
            }
            EventKind::FileSent { transfer_id, file } => {
                if let Some(f) = self
                    .transfers
                    .get_mut(transfer_id)
                    .and_then(|t| t.files.get_mut(&file.id))
                {
                    f.bytes = f.size;
                    f.phase = FilePhase::Sent;
                    f.error = None;
                }
            }
            EventKind::Committed { receipt } => {
                if let Some(f) = self
                    .transfers
                    .get_mut(&receipt.session_id)
                    .and_then(|t| t.files.get_mut(&receipt.file_id))
                {
                    f.bytes = f.size;
                    f.phase = FilePhase::Committed;
                    f.error = None;
                    f.sha256 = Some(receipt.sha256.clone());
                    f.receipt_id = Some(receipt.id.clone());
                }
            }
            EventKind::Failed {
                transfer_id,
                file_id,
                code,
            } => {
                if let Some(t) = self.transfers.get_mut(transfer_id) {
                    if matches!(t.summary.phase, Phase::Completed | Phase::Failed) {
                        return;
                    }
                    // A late failed request must not overwrite a committed file.
                    if let Some(id) = file_id {
                        if let Some(f) = t.files.get_mut(id) {
                            if !matches!(f.phase, FilePhase::Committed | FilePhase::Sent) {
                                f.phase = FilePhase::Failed;
                                f.error = Some(*code);
                            }
                        }
                    } else {
                        t.summary.error = Some(*code);
                    }
                }
            }
            EventKind::SessionEnded { session_id } => {
                let incomplete = self
                    .transfers
                    .get(session_id)
                    .is_some_and(|t| t.files.values().any(|f| f.phase != FilePhase::Committed));
                self.finish(session_id, incomplete.then_some(ErrorCode::RemoteFailure));
            }
            EventKind::Sent {
                transfer_id,
                report,
            } => self.finish(transfer_id, report.error),
            EventKind::ReceiptDeleted { .. } | EventKind::Stopped => {}
        }
    }
    pub fn page(&self, after: Option<&str>, limit: usize) -> Result<SnapshotPage> {
        if !(1..=64).contains(&limit) {
            return Err(ErrorCode::InvalidInput);
        }
        let mut items = self
            .transfers
            .iter()
            .filter(|(id, _)| after.is_none_or(|a| id.as_str() > a));
        let transfers: Vec<_> = items
            .by_ref()
            .take(limit)
            .map(|(_, t)| t.summary.clone())
            .collect();
        let next = if items.next().is_some() {
            transfers.last().map(|t| t.id.clone())
        } else {
            None
        };
        Ok(SnapshotPage {
            instance_id: self.instance_id.clone(),
            sequence: self.sequence,
            evicted: self.evicted,
            transfers,
            next,
        })
    }
    pub fn report(&self, id: &str) -> Result<SendReport> {
        let t = self.transfers.get(id).ok_or(ErrorCode::InvalidInput)?;
        if t.summary.direction != Direction::Send {
            return Err(ErrorCode::InvalidInput);
        }
        if !matches!(t.summary.phase, Phase::Completed | Phase::Failed) {
            return Err(ErrorCode::Busy);
        }
        Ok(SendReport {
            error: t.summary.error,
            files: t
                .files
                .values()
                .filter(|f| f.phase == FilePhase::Sent)
                .map(|f| SentFile {
                    id: f.id.clone(),
                    name: f.name.clone(),
                    size: f.size,
                    sha256: f.sha256.clone().unwrap_or_default(),
                })
                .collect(),
        })
    }
    pub fn files(&self, id: &str, after: Option<&str>, limit: usize) -> Result<TransferPage> {
        if !(1..=64).contains(&limit) {
            return Err(ErrorCode::InvalidInput);
        }
        let t = self.transfers.get(id).ok_or(ErrorCode::InvalidInput)?;
        let mut items = t
            .files
            .iter()
            .filter(|(id, _)| after.is_none_or(|a| id.as_str() > a));
        let files: Vec<_> = items.by_ref().take(limit).map(|(_, f)| f.clone()).collect();
        let next = if items.next().is_some() {
            files.last().map(|f| f.id.clone())
        } else {
            None
        };
        Ok(TransferPage {
            instance_id: self.instance_id.clone(),
            sequence: self.sequence,
            transfer: t.summary.clone(),
            files,
            next,
        })
    }
}
