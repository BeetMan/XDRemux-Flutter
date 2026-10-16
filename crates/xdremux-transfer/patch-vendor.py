"""Reapply XDRemux's small protocol patch to a pristine pinned LocalSend core.

Usage: python patch-vendor.py <localsend-checkout>/packages/core
Source checkout must be af0416be50770a97760f7070684bc667b759a15c.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

source = Path(sys.argv[1]).resolve()
revision = "af0416be50770a97760f7070684bc667b759a15c"
assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == revision
subprocess.run(["git", "-C", str(source), "diff", "--exit-code", "HEAD", "--", "."], check=True, stdout=subprocess.DEVNULL)
assert not subprocess.check_output(["git", "-C", str(source), "ls-files", "--others", "--exclude-standard", "--", "."], text=True).strip(), "Untracked upstream files"
target = Path(__file__).resolve().parent / "vendor" / "localsend"
for directory in ["src", "assets", "examples"]:
    shutil.copytree(source / directory, target / directory, dirs_exist_ok=True)
shutil.copyfile(source / "Cargo.toml", target / "Cargo.toml")
shutil.copyfile(source.parent.parent / "LICENSE", target / "LICENSE")
original = {str(p.relative_to(target)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(target.rglob("*")) if p.is_file() and p.name != "upstream-files.json"}
(target / "upstream-files.json").write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")

def patch(name, old, new):
    path = target / "src" / name
    text = path.read_text(encoding="utf-8")
    assert old in text, (name, old[:100])
    path.write_text(text.replace(old, new), encoding="utf-8")

patch("http/server/common/save.rs", "pub enum FileUploadTarget {", """pub enum FileUploadTarget {
    /// XDRemux: the consumer commits only after a clean HTTP body, then acknowledges.
    Transactional {
        binary_tx: mpsc::Sender<Bytes>,
        body_done_tx: oneshot::Sender<bool>,
        result_rx: oneshot::Receiver<Result<(), TransactionError>>,
    },""")
patch("http/server/common/save.rs", "/// Channel capacity", """/// XDRemux: stable outcome without exposing storage paths or remote strings.
#[derive(Debug)]
pub enum TransactionError { Failed, HashMismatch }

/// Channel capacity""")
patch("http/server/common/save.rs", "    use sha2::{Digest, Sha256};", """    // XDRemux: distinguish a clean EOF from a broken body before allowing commit.
    let target = match target {
        FileUploadTarget::Transactional { binary_tx, body_done_tx, result_rx } => {
            let mut body = req.into_body();
            let mut clean = true;
            while let Some(frame) = body.frame().await {
                match frame {
                    Ok(frame) => {
                        if let Ok(data) = frame.into_data() {
                            if !data.is_empty() && binary_tx.send(data).await.is_err() {
                                clean = false;
                                break;
                            }
                        }
                    }
                    Err(_) => { clean = false; break; }
                }
            }
            drop(binary_tx);
            let _ = body_done_tx.send(clean);
            return match result_rx.await {
                Ok(Ok(())) if clean => SaveResult::Success,
                Ok(Err(TransactionError::HashMismatch)) => SaveResult::HashMismatch,
                _ => SaveResult::Failed,
            };
        }
        other => other,
    };
    use sha2::{Digest, Sha256};""")
patch("http/server/common/save.rs", "    let (binary_tx, result_rx, app_result_tx) = match target {", "    let (binary_tx, result_rx, app_result_tx) = match target {\n        FileUploadTarget::Transactional { .. } => unreachable!(),")
patch("http/server/common/collect_to_json.rs", "let bytes = self.collect().await?.to_bytes();", """// XDRemux: bound metadata allocation and a stalled metadata request.
        let bytes = tokio::time::timeout(std::time::Duration::from_secs(10),
            http_body_util::Limited::new(self, 1024 * 1024).collect()).await
            .map_err(|_| AppError::Status(hyper::StatusCode::REQUEST_TIMEOUT))?
            .map_err(|_| AppError::Status(hyper::StatusCode::PAYLOAD_TOO_LARGE))?.to_bytes();""")
patch("http/server/common/session.rs", "pub(crate) sender_ip: PeerIp,", "pub(crate) sender_ip: PeerIp,\n    // XDRemux: bind the session to the authenticated TLS identity too.\n    pub(crate) sender_fingerprint: Option<String>,")
patch("http/server/v2.rs", "            sender_ip: client_info.ip,", "            sender_ip: client_info.ip,\n            sender_fingerprint: client_info.cert_fingerprint(),")
patch("http/server/v2.rs", "session.sender_ip != client_info.ip", "session.sender_ip != client_info.ip || session.sender_fingerprint != client_info.cert_fingerprint()")
patch("http/server/v2.rs", "if pending.sender_ip == client_info.ip", "if pending.sender_ip == client_info.ip && pending.sender_fingerprint == client_info.cert_fingerprint()")
patch("http/server/v2.rs", "session.sender_ip == client_info.ip =>", "session.sender_ip == client_info.ip && session.sender_fingerprint == client_info.cert_fingerprint() =>")
patch("http/server/v2.rs", "    CancelReceived {", "    CancelReceived {\n        cert_fingerprint: Option<String>,")
patch("http/server/v2.rs", ".send(ServerEventV2::CancelReceived {", ".send(ServerEventV2::CancelReceived {\n                    cert_fingerprint: client_info.cert_fingerprint(),")

# Keep legacy entry point for the vendored examples; application chooses bind address.
patch("http/server/mod.rs", "    ipv6_bound: bool,", "    ipv6_bound: bool,\n    bind_ip: IpAddr,")
patch("http/server/mod.rs", "pub async fn start_with_port(", """pub async fn start_with_port(
    port: u16, tls_config: Option<TlsConfig>, info: ClientInfo,
    internal_config: Option<InternalConfig>, v2_config: Option<ServerConfigV2>,
    web_config: Option<WebConfig>, stop_rx: oneshot::Receiver<()>,
) -> anyhow::Result<ServerHandle> {
    start_with_address(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), port), tls_config,
        info, internal_config, v2_config, web_config, stop_rx).await
}

/// XDRemux: explicit interface binding; no implicit additional listener.
pub async fn start_with_address(""")
patch("http/server/mod.rs", "pub async fn start_with_address(\n    port: u16,", "pub async fn start_with_address(\n    address: SocketAddr,")
patch("http/server/mod.rs", "let ipv4_socket_addr = SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), port);", "let ipv4_socket_addr = address;")
patch("http/server/mod.rs", "let ipv6_listener = match bind_ipv6_only(ipv6_socket_addr) {", "let ipv6_listener = if !address.ip().is_unspecified() || address.is_ipv6() { None } else { match bind_ipv6_only(ipv6_socket_addr) {")
patch("http/server/mod.rs", "    };\n    let ipv6_bound = ipv6_listener.is_some();", "    }};\n    let ipv6_bound = ipv6_listener.is_some();")
patch("http/server/mod.rs", "        ipv6_bound,", "        ipv6_bound,\n        bind_ip: address.ip(),")
patch("http/server/mod.rs", "        match slot.as_ref() {\n            Some(SessionStateV2::Active(session)) if session.session_id == session_id => {", """        match slot.as_ref() {
            Some(SessionStateV2::Pending(session)) if session.session_id == session_id => {
                session.cancel.cancel();
                true
            }
            Some(SessionStateV2::Active(session)) if session.session_id == session_id => {""")
patch("http/server/v2.rs", "        *slot = Some(SessionStateV2::Active(UploadSessionV2 {", """        // XDRemux: a local cancellation may race the decision response.
        if cancelled.is_cancelled() || !matches!(slot.as_ref(), Some(SessionStateV2::Pending(p)) if p.session_id == session_id) {
            return Err(AppError::Status(StatusCode::FORBIDDEN));
        }
        *slot = Some(SessionStateV2::Active(UploadSessionV2 {""")
patch("http/server/v2.rs", "clear_pending_session(&self.v2).await", "clear_pending_session(&self.v2, &self.session_id).await")
patch("http/server/v2.rs", "clear_pending_session(&v2).await", "clear_pending_session(&v2, &session_id).await")
patch("http/server/v2.rs", "async fn clear_pending_session(v2: &V2State)", "async fn clear_pending_session(v2: &V2State, session_id: &str)")
patch("http/server/v2.rs", "matches!(*slot, Some(SessionStateV2::Pending(_)))", "matches!(slot.as_ref(), Some(SessionStateV2::Pending(p)) if p.session_id == session_id)")
patch("http/server/mod.rs", "    let mut accept_backoff = ACCEPT_BACKOFF_MIN;", "    // XDRemux: bound unauthenticated and idle connections too.\n    let slots = Arc::new(tokio::sync::Semaphore::new(64));\n    let mut accept_backoff = ACCEPT_BACKOFF_MIN;")
patch("http/server/mod.rs", "        let tls_acceptor = tls_acceptor.clone();", "        let Ok(permit) = slots.clone().try_acquire_owned() else { drop(tcp_stream); continue; };\n        let tls_acceptor = tls_acceptor.clone();")
patch("http/server/mod.rs", "        connections.spawn(async move {", "        connections.spawn(async move {\n            let _permit = permit;")
patch("http/server/mod.rs", "let tls_stream = match tls_acceptor.accept(tcp_stream).await {", "let tls_stream = match tokio::time::timeout(std::time::Duration::from_secs(5), tls_acceptor.accept(tcp_stream)).await {" )
patch("http/server/mod.rs", "                Ok(tls_stream) => tls_stream,", "                Ok(Ok(tls_stream)) => tls_stream,")
patch("http/server/mod.rs", "                Err(err) => {\n                    tracing::warn!(\"TLS handshake error: {err:#}\");", "                _ => {\n                    tracing::warn!(\"TLS handshake failed\");")
# Bound successful peer JSON too; drop untrusted error bodies without retaining them.
path = target / "src/http/client/v2.rs"
text = path.read_text(encoding="utf-8")
text = "// XDRemux modification: bound peer JSON responses; see UPSTREAM.md.\n" + re.sub(r"res\.json::<([^>]+)>\(\)\.await\?", r"super::bounded_json::<\1>(res).await?", text)
path.write_text(text, encoding="utf-8")
path = target / "src/http/client/mod.rs"
text = path.read_text(encoding="utf-8")
start = text.index("        let body = self.text().await.unwrap_or_default();")
text = text[:start] + """        // XDRemux: no untrusted error strings or unbounded response allocations.
        Err(ClientError::StatusCode(StatusCodeError {status, message: None}))
    }
}

pub(super) async fn bounded_json<T: serde::de::DeserializeOwned>(mut response: Response) -> Result<T, ClientError> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len().saturating_add(chunk.len()) > 1024 * 1024 {
            return Err(ClientError::Other(anyhow::anyhow!("Metadata limit exceeded")));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(serde_json::from_slice(&bytes)?)
}
"""
path.write_text(text, encoding="utf-8")
# Method return type read from upstream, so insert just before interface enumeration.
path = target / "src/http/server/mod.rs"
text = path.read_text(encoding="utf-8")
pos = text.index("pub fn local_addresses")
brace = text.index("{", pos)
text = text[:brace+1] + "\n        if !self.bind_ip.is_unspecified() { return vec![SocketAddr::new(self.bind_ip, self.port)]; }" + text[brace+1:]
path.write_text(text, encoding="utf-8")

# Upstream diagnostics contain paths, metadata and token-bearing URLs. The wrapper
# exposes only typed, redacted events. Remove macro arguments from compilation.
for path in (target / "src").rglob("*.rs"):
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r"tracing::(?:info|warn|error|debug|trace)!\s*\(")
    changed = False
    while match := pattern.search(text):
        depth, quote, escape, i = 1, False, False, match.end()
        while depth:
            c = text[i]
            if quote:
                if escape: escape = False
                elif c == "\\": escape = True
                elif c == '"': quote = False
            elif c == '"': quote = True
            elif c == '(': depth += 1
            elif c == ')': depth -= 1
            i += 1
        text = text[:match.start()] + "()" + text[i:]
        changed = True
    if changed:
        path.write_text("// XDRemux modification: diagnostics replaced by redacted wrapper events.\n" + text, encoding="utf-8")
path = target / "src/lib.rs"
text = path.read_text(encoding="utf-8")
path.write_text("// XDRemux: redaction leaves diagnostic-only variables unused.\n#![allow(unused_variables, unused_imports, unused_assignments, dead_code)]\n" + text, encoding="utf-8")
print("Patched pinned LocalSend core:", revision)
