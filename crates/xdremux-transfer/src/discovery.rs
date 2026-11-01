//! Bounded IPv4 multicast hints, confirmed by HTTPS before presentation.
use crate::{model::*, service::Inner};
use localsend::{
    http::dto_v2::RegisterDtoV2,
    model::discovery::ProtocolType,
    multicast::{self, MulticastConfig, MulticastDevice, MulticastEvent},
    util::interface::InterfaceFilter,
};
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, Mutex as AsyncMutex};
use tokio_util::sync::CancellationToken;

const PEERS: usize = 128;
const TTL: Duration = Duration::from_secs(90);
#[derive(Clone)]
struct Candidate {
    address: SocketAddr,
    fingerprint: String,
}
struct Run {
    cancel: CancellationToken,
    done: oneshot::Receiver<()>,
    announce: mpsc::Sender<()>,
}
#[derive(Default)]
struct State {
    enabled: bool,
    error: Option<ErrorCode>,
    peers: HashMap<String, (DiscoveredPeer, Instant)>,
    input: Option<mpsc::Sender<Candidate>>,
}
#[derive(Default)]
pub(crate) struct Discovery {
    state: Mutex<State>,
    run: AsyncMutex<Option<Run>>,
}

fn valid_address(ip: IpAddr) -> bool {
    matches!(ip, IpAddr::V4(v) if v.is_private() || v.is_link_local())
}
impl Discovery {
    pub fn snapshot(&self) -> DiscoverySnapshot {
        let mut state = self.state.lock().unwrap();
        state.peers.retain(|_, (_, seen)| seen.elapsed() < TTL);
        let mut peers: Vec<_> = state.peers.values().map(|(p, _)| p.clone()).collect();
        peers.sort_by(|a, b| a.peer.fingerprint.cmp(&b.peer.fingerprint));
        DiscoverySnapshot {
            enabled: state.enabled,
            error: state.error,
            peers,
        }
    }
    pub fn registered(&self, ip: IpAddr, info: &RegisterDtoV2) {
        if info.protocol != ProtocolType::Https
            || !valid_address(ip)
            || info.port == 0
            || !valid_hash(&info.fingerprint)
        {
            return;
        }
        if let Some(input) = &self.state.lock().unwrap().input {
            let _ = input.try_send(Candidate {
                address: SocketAddr::new(ip, info.port),
                fingerprint: info.fingerprint.to_uppercase(),
            });
        }
    }
    pub async fn start(
        inner: &Arc<Inner>,
        interface: Option<Ipv4Addr>,
    ) -> Result<DiscoverySnapshot> {
        if inner.stop.is_cancelled() {
            return Err(ErrorCode::Closed);
        }
        if inner.config.bind.ip().is_loopback() {
            return Err(ErrorCode::InvalidInput);
        }
        if interface.is_some_and(|ip| !valid_address(ip.into())) {
            return Err(ErrorCode::InvalidInput);
        }
        let discovery = &inner.discovery;
        let mut guard = discovery.run.lock().await;
        if let Some(run) = guard.as_ref() {
            if discovery.state.lock().unwrap().error.is_none() {
                let _ = run.announce.try_send(());
                return Ok(discovery.snapshot());
            }
        }
        if let Some(run) = guard.take() {
            run.cancel.cancel();
            let _ = run.done.await;
        }
        let (tx, mut udp) = mpsc::channel(64);
        let (stop_tx, stop_rx) = oneshot::channel();
        let handle = multicast::start(
            MulticastConfig {
                group: multicast::DEFAULT_MULTICAST_GROUP,
                group_v6: None,
                port: multicast::DEFAULT_PORT,
                interface_filter: InterfaceFilter {
                    whitelist: interface.map(|v| vec![v.to_string()]),
                    blacklist: None,
                },
                device: MulticastDevice {
                    alias: inner.config.alias.clone(),
                    version: "2.2".into(),
                    device_model: Some("XDRemux".into()),
                    device_type: Some(localsend::model::discovery::DeviceType::Headless),
                    fingerprint: inner.identity.fingerprint.clone(),
                    port: inner.server.port(),
                    protocol: ProtocolType::Https,
                    download: false,
                },
                event_tx: tx,
            },
            stop_rx,
        )
        .await
        .map_err(|_| {
            discovery.state.lock().unwrap().error = Some(ErrorCode::DiscoveryUnavailable);
            ErrorCode::DiscoveryUnavailable
        })?;
        let handle = Arc::new(handle);
        let cancel = inner.stop.child_token();
        let (input_tx, mut input) = mpsc::channel::<Candidate>(64);
        let (announce_tx, mut announce_rx) = mpsc::channel(1);
        let (done_tx, done) = oneshot::channel();
        *discovery.state.lock().unwrap() = State {
            enabled: true,
            input: Some(input_tx),
            ..State::default()
        };
        *guard = Some(Run {
            cancel: cancel.clone(),
            done,
            announce: announce_tx,
        });
        let owner = inner.clone();
        inner.tasks.spawn(async move {
            let announcements = async {
                let mut timer = tokio::time::interval(Duration::from_secs(30));
                loop {
                    tokio::select! { _ = timer.tick() => {}, _ = announce_rx.recv() => {} }
                    handle.announce().await;
                }
            };
            let receiver = async {
                let mut cooldown: HashMap<SocketAddr, Instant> = HashMap::new();
                loop {
                    let candidate = tokio::select! {
                        event = udp.recv() => match event {
                            Some(MulticastEvent::Discovered { ip, message, .. }) if message.protocol == ProtocolType::Https && message.port != 0 && valid_address(ip) && valid_hash(&message.fingerprint) && message.version.starts_with("2.") => Candidate { address: SocketAddr::new(ip, message.port), fingerprint: message.fingerprint.to_uppercase() },
                            Some(MulticastEvent::SocketsFailed) | None => { owner.discovery.state.lock().unwrap().error = Some(ErrorCode::DiscoveryUnavailable); return; },
                            _ => continue,
                        },
                        event = input.recv() => match event { Some(c) => c, None => return },
                    };
                    if candidate.fingerprint.eq_ignore_ascii_case(&owner.identity.fingerprint) { continue; }
                    cooldown.retain(|_, at| at.elapsed() < Duration::from_secs(10));
                    if cooldown.contains_key(&candidate.address) || cooldown.len() >= 256 { continue; }
                    cooldown.insert(candidate.address, Instant::now());
                    if let Ok(peer) = verify(&owner, &candidate).await {
                        let mut state = owner.discovery.state.lock().unwrap();
                        state.peers.retain(|_, (_, at)| at.elapsed() < TTL);
                        if state.peers.len() >= PEERS && !state.peers.contains_key(&peer.peer.fingerprint) {
                            if let Some(oldest) = state.peers.iter().min_by_key(|(_, (_, at))| *at).map(|(id, _)| id.clone()) { state.peers.remove(&oldest); }
                        }
                        state.peers.insert(peer.peer.fingerprint.clone(), (peer, Instant::now()));
                    }
                }
            };
            tokio::select! { _ = cancel.cancelled() => {}, _ = receiver => {} , _ = announcements => {} }
            let _ = stop_tx.send(());
            handle.wait_stopped().await;
            let mut state = owner.discovery.state.lock().unwrap();
            state.enabled = false;
            state.input = None;
            state.peers.clear();
            let _ = done_tx.send(());
        });
        Ok(discovery.snapshot())
    }
    pub async fn stop(&self) {
        let mut guard = self.run.lock().await;
        if let Some(run) = guard.take() {
            run.cancel.cancel();
            let _ = run.done.await;
        }
        *self.state.lock().unwrap() = State::default();
    }
}

async fn verify(inner: &Arc<Inner>, candidate: &Candidate) -> Result<DiscoveredPeer> {
    let result = tokio::time::timeout(
        Duration::from_millis(1200),
        inner.client(None)?.register(
            ProtocolType::Https,
            &candidate.address.ip().to_string(),
            candidate.address.port(),
            inner.register(),
        ),
    )
    .await
    .map_err(|_| ErrorCode::TimedOut)?
    .map_err(crate::sender::map_error)?;
    let fingerprint = result
        .cert_fingerprint
        .filter(|v| v.eq_ignore_ascii_case(&candidate.fingerprint))
        .ok_or(ErrorCode::IdentityMismatch)?
        .to_uppercase();
    let alias = result.body.alias;
    if alias.len() > 128 || alias.chars().any(char::is_control) {
        return Err(ErrorCode::InvalidInput);
    }
    Ok(DiscoveredPeer {
        alias,
        peer: Peer {
            address: candidate.address,
            fingerprint,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn certificate_is_verified_before_a_hint_becomes_a_device() {
        let temp = tempfile::tempdir().unwrap();
        let service = crate::Service::start(Config::new(temp.path().join("peer")))
            .await
            .unwrap();
        let inner = &service.inner;
        let candidate = Candidate {
            address: service.address(),
            fingerprint: service.fingerprint().into(),
        };
        assert_eq!(
            verify(inner, &candidate).await.unwrap().peer.fingerprint,
            service.fingerprint()
        );
        let forged = Candidate {
            address: service.address(),
            fingerprint: "0".repeat(64),
        };
        assert_eq!(
            verify(inner, &forged).await.err(),
            Some(ErrorCode::IdentityMismatch)
        );
        assert_eq!(
            service.start_discovery(None).await.err(),
            Some(ErrorCode::InvalidInput)
        );
        service.shutdown().await;
    }
    #[test]
    fn rejects_non_unicast_hints_and_expires_snapshot() {
        for ip in [
            "127.0.0.1",
            "0.0.0.0",
            "224.0.0.167",
            "255.255.255.255",
            "::1",
        ] {
            assert!(!valid_address(ip.parse().unwrap()));
        }
        let discovery = Discovery::default();
        discovery.state.lock().unwrap().peers.insert(
            "expired".into(),
            (
                DiscoveredPeer {
                    alias: "old".into(),
                    peer: Peer {
                        address: "192.168.1.2:53319".parse().unwrap(),
                        fingerprint: "A".repeat(64),
                    },
                },
                Instant::now() - TTL,
            ),
        );
        assert!(discovery.snapshot().peers.is_empty());
    }
}
