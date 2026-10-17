//! LocalSend-compatible async service. Run on a Tokio runtime, off the UI thread.
//! File payloads are opaque bytes; this crate never invokes a media converter.
mod model;
mod sender;
mod service;
mod snapshot;
mod storage;
pub use model::*;
pub use sender::SendHandle;
pub use service::Service;
pub use storage::hash_file;
pub use storage::ReceiptLease;
#[cfg(test)]
mod tests;
