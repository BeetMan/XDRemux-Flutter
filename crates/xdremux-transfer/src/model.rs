use serde::{Deserialize, Serialize};
use std::{net::SocketAddr, path::PathBuf, time::Duration};

pub type Result<T> = std::result::Result<T, ErrorCode>;

/// Stable, redacted errors: never propagate OS paths, remote messages or tokens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidInput,
    UnsafeStorage,
    Busy,
    Declined,
    NoSpace,
    Io,
    Network,
    Cancelled,
    TimedOut,
    ChecksumMismatch,
    Truncated,
    IdentityMismatch,
    RemoteFailure,
    Closed,
    SourceChanged,
    Authentication,
}
impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ErrorCode {}
impl From<std::io::Error> for ErrorCode {
    fn from(error: std::io::Error) -> Self {
        #[cfg(windows)]
        let full = matches!(error.raw_os_error(), Some(39 | 112));
        #[cfg(not(windows))]
        let full = matches!(error.raw_os_error(), Some(28 | 122));
        if full {
            Self::NoSpace
        } else {
            Self::Io
        }
    }
}

#[derive(Clone)]
pub struct Config {
    /// Must be an application-private directory. Service takes an exclusive lease.
    pub root: PathBuf,
    pub bind: SocketAddr,
    pub alias: String,
    pub pin: Option<String>,
    pub max_files: usize,
    pub max_file_bytes: u64,
    pub max_session_bytes: u64,
    pub min_free_bytes: u64,
    pub max_parallel_files: usize,
    pub max_outgoing: usize,
    pub event_capacity: usize,
    pub decision_timeout: Duration,
    pub idle_timeout: Duration,
    pub session_timeout: Duration,
    pub request_timeout: Duration,
}
impl Config {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            bind: "127.0.0.1:0".parse().unwrap(),
            alias: "XDRemux".into(),
            pin: None,
            max_files: 1024,
            max_file_bytes: 16 * 1024 * 1024 * 1024,
            max_session_bytes: 64 * 1024 * 1024 * 1024,
            min_free_bytes: 64 * 1024 * 1024,
            max_parallel_files: 2,
            max_outgoing: 2,
            event_capacity: 128,
            decision_timeout: Duration::from_secs(30),
            idle_timeout: Duration::from_secs(30),
            session_timeout: Duration::from_secs(1800),
            request_timeout: Duration::from_secs(300),
        }
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if self.alias.is_empty()
            || self.alias.len() > 128
            || self.alias.chars().any(char::is_control)
            || self
                .pin
                .as_ref()
                .is_some_and(|p| p.is_empty() || p.len() > 128 || p.chars().any(char::is_control))
            || !(1..=1024).contains(&self.max_files)
            || self.max_file_bytes == 0
            || self.max_session_bytes < self.max_file_bytes
            || !(1..=16).contains(&self.max_parallel_files)
            || !(1..=16).contains(&self.max_outgoing)
            || !(8..=4096).contains(&self.event_capacity)
            || [
                self.decision_timeout,
                self.idle_timeout,
                self.session_timeout,
                self.request_timeout,
            ]
            .iter()
            .any(|d| d.is_zero() || *d > Duration::from_secs(86400))
        {
            Err(ErrorCode::InvalidInput)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Peer {
    pub address: SocketAddr,
    /// Caller must confirm/trust this certificate before sending file data.
    pub fingerprint: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OfferedFile {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub sha256: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Offer {
    pub session_id: String,
    pub alias: String,
    pub peer_fingerprint: String,
    pub files: Vec<OfferedFile>,
}
#[derive(Clone, Copy, Debug)]
pub enum Decision {
    Accept,
    Decline,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Receipt {
    pub id: String,
    pub session_id: String,
    pub file_id: String,
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub peer_hash_present: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EventKind {
    Offer {
        offer: Offer,
    },
    Accepted {
        session_id: String,
    },
    Progress {
        transfer_id: String,
        file_id: String,
        bytes: u64,
        total: u64,
    },
    Committed {
        receipt: Receipt,
    },
    Failed {
        transfer_id: String,
        file_id: Option<String>,
        code: ErrorCode,
    },
    SessionEnded {
        session_id: String,
    },
    Sent {
        transfer_id: String,
        report: SendReport,
    },
    Prepared {
        transfer_id: String,
        files: Vec<SentFile>,
    },
    Stopped,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub sequence: u64,
    #[serde(flatten)]
    pub kind: EventKind,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SentFile {
    pub name: String,
    pub size: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SendReport {
    pub files: Vec<SentFile>,
    pub error: Option<ErrorCode>,
}

pub(crate) fn safe_name(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    !name.is_empty()
        && name.len() <= 240
        && name != "."
        && name != ".."
        && !name.ends_with(['.', ' '])
        && !name
            .chars()
            .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c))
        && !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$")
        && !(stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.as_bytes()[3].is_ascii_digit())
}
pub(crate) fn valid_hash(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit())
}
