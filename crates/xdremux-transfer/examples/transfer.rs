//! Bounded, TEST-ONLY native harness. Production must surface each Offer to a user.
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use xdremux_transfer::{Config, Decision, ErrorCode, EventKind, Peer, Service};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() < 4 {
        return Err("receive ROOT BIND SECONDS REPORT --accept-test-files [NOTIFY_ADDRESS]; send ROOT PEER FINGERPRINT REPORT FILE...".into());
    }
    let mut config = Config::new(PathBuf::from(&args[1]));
    config.max_file_bytes = 256 * 1024 * 1024;
    config.max_session_bytes = 1024 * 1024 * 1024;
    if args[0] == "receive" {
        if args.len() < 6 || args[5] != "--accept-test-files" {
            return Err(ErrorCode::InvalidInput.into());
        }
        config.bind = args[2].parse()?;
        let seconds: u64 = args[3].parse()?;
        if !(1..=3600).contains(&seconds) {
            return Err(ErrorCode::InvalidInput.into());
        }
        let service = Service::start(config).await?;
        let mut events = service.subscribe();
        println!(
            "{}",
            serde_json::json!({"event":"ready","port":service.address().port(),"fingerprint":service.fingerprint()})
        );
        if let Some(address) = args.get(6) {
            service.probe(address.parse()?).await?;
        }
        let deadline = tokio::time::sleep(Duration::from_secs(seconds));
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                _=&mut deadline=>break,
                result=events.recv()=>{
                    match result {
                        Ok(event)=>if let EventKind::Offer{offer}=event.kind {
                            let decision=if offer.files.iter().all(|f|f.name.starts_with("xdremux-poc-")){Decision::Accept}else{Decision::Decline};
                            let _=service.decide(&offer.session_id,decision);
                        },
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_))=>{
                            for offer in service.pending_offers(){let _=service.decide(&offer.session_id,Decision::Decline);}
                        }
                        Err(_)=>break,
                    }
                }
            }
        }
        let receipts = service.receipts(1024).await?;
        let output = serde_json::to_vec_pretty(&receipts)?;
        service.shutdown().await;
        std::fs::write(&args[4], output)?;
        if receipts.is_empty() {
            return Err(ErrorCode::RemoteFailure.into());
        }
    } else if args[0] == "send" {
        if args.len() < 6 {
            return Err(ErrorCode::InvalidInput.into());
        }
        let paths: Vec<_> = args[5..].iter().map(PathBuf::from).collect();
        if !paths.iter().all(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|s| s.starts_with("xdremux-poc-"))
        }) {
            return Err(ErrorCode::InvalidInput.into());
        }
        let address: SocketAddr = args[2].parse()?;
        let service = Service::start(config).await?;
        let peer = if args[3] == "discover-test-only" {
            service.probe(address).await?
        } else {
            Peer {
                address,
                fingerprint: args[3].clone(),
            }
        };
        let result = service.start_send(peer, paths, None)?.wait().await;
        service.shutdown().await;
        std::fs::write(&args[4], serde_json::to_vec_pretty(&result)?)?;
        if let Some(error) = result.error {
            return Err(error.into());
        }
        println!(
            "{}",
            serde_json::json!({"event":"sent","files":result.files.len()})
        );
    } else {
        return Err(ErrorCode::InvalidInput.into());
    }
    Ok(())
}
