use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf};
use transfer_core::{Config, ErrorCode, Peer, Result};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Create {
    root: PathBuf,
    bind: Option<SocketAddr>,
    alias: Option<String>,
    pin: Option<String>,
}
impl Create {
    pub fn config(self) -> Result<Config> {
        if !self.root.is_absolute() || self.root.as_os_str().len() > 4096 {
            return Err(ErrorCode::InvalidInput);
        }
        let mut c = Config::new(self.root);
        if let Some(bind) = self.bind {
            c.bind = bind;
        }
        if let Some(alias) = self.alias {
            c.alias = alias;
        }
        c.pin = self.pin;
        if c.alias.is_empty()
            || c.alias.len() > 128
            || c.alias.chars().any(char::is_control)
            || c.pin
                .as_ref()
                .is_some_and(|p| p.is_empty() || p.len() > 128 || p.chars().any(char::is_control))
        {
            return Err(ErrorCode::InvalidInput);
        }
        Ok(c)
    }
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    CheckSpace {
        bytes: u64,
        reserve: u64,
    },
    SendReport {
        transfer_id: String,
    },
    Probe {
        address: SocketAddr,
    },
    Send {
        peer: Peer,
        paths: Vec<PathBuf>,
        pin: Option<String>,
    },
    Decide {
        transfer_id: String,
        accept: bool,
    },
    CancelSend {
        transfer_id: String,
    },
    CancelReceive {
        transfer_id: String,
    },
    Snapshot {
        after: Option<String>,
        limit: usize,
    },
    Transfer {
        transfer_id: String,
        after: Option<String>,
        limit: usize,
    },
    Receipts {
        after: Option<String>,
        limit: usize,
    },
    AcquireReceipt {
        receipt_id: String,
    },
    ReleaseReceipt {
        lease_id: u64,
    },
    DeleteReceipt {
        receipt_id: String,
    },
    Operation {
        operation_id: u64,
    },
}
impl Request {
    pub fn priority(&self) -> bool {
        matches!(
            self,
            Self::CancelSend { .. } | Self::CancelReceive { .. } | Self::ReleaseReceipt { .. }
        )
    }
    pub fn validate(&self) -> Result<()> {
        let id_ok = |s: &str| !s.is_empty() && s.len() <= 128 && !s.chars().any(char::is_control);
        let page_ok = |after: &Option<String>, limit: usize| {
            (1..=64).contains(&limit) && after.as_ref().is_none_or(|s| id_ok(s))
        };
        let valid = match self {
            Self::CheckSpace { .. } => true,
            Self::Send { peer, paths, pin } => {
                !paths.is_empty()
                    && paths.len() <= 1024
                    && paths
                        .iter()
                        .all(|p| p.is_absolute() && p.as_os_str().len() <= 4096)
                    && peer.fingerprint.len() == 64
                    && peer.fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
                    && pin.as_ref().is_none_or(|p| id_ok(p))
            }
            Self::SendReport { transfer_id }
            | Self::Decide { transfer_id, .. }
            | Self::CancelSend { transfer_id }
            | Self::CancelReceive { transfer_id } => id_ok(transfer_id),
            Self::Transfer {
                transfer_id,
                after,
                limit,
            } => id_ok(transfer_id) && page_ok(after, *limit),
            Self::Snapshot { after, limit } | Self::Receipts { after, limit } => {
                page_ok(after, *limit)
            }
            Self::AcquireReceipt { receipt_id } | Self::DeleteReceipt { receipt_id } => {
                uuid::Uuid::parse_str(receipt_id).is_ok()
            }
            Self::Probe { address } => address.port() != 0 && !address.ip().is_unspecified(),
            Self::ReleaseReceipt { lease_id } => *lease_id != 0,
            Self::Operation { operation_id } => *operation_id != 0,
        };
        if valid {
            Ok(())
        } else {
            Err(ErrorCode::InvalidInput)
        }
    }
}
