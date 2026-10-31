#[cfg(not(feature = "transport"))]
fn main() {
    println!("transport disabled");
}

#[cfg(feature = "transport")]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    use clap::{Parser, Subcommand};
    use std::{path::PathBuf, time::Duration};
    use xdremux_transfer_poc::transport::{send_files, Identity, Receiver};

    #[derive(Parser)]
    #[command(about = "XDRemux isolated LocalSend v2 HTTPS test harness")]
    struct Args {
        #[command(subcommand)]
        command: Command,
    }
    #[derive(Subcommand)]
    enum Command {
        Receive {
            #[arg(long)]
            dir: PathBuf,
            #[arg(long, default_value_t = 53318)]
            port: u16,
            #[arg(long, default_value_t = 120)]
            seconds: u64,
            #[arg(long)]
            notify_host: Option<String>,
            #[arg(long, default_value_t = 53317)]
            notify_port: u16,
            #[arg(long)]
            pin: Option<String>,
            /// Explicit test-only opt-in: accepts only xdremux-poc-* basenames.
            #[arg(long, required = true)]
            accept_test_files: bool,
            #[arg(long)]
            report: PathBuf,
        },
        Send {
            #[arg(long)]
            host: String,
            #[arg(long, default_value_t = 53318)]
            port: u16,
            #[arg(long)]
            pin: Option<String>,
            #[arg(long)]
            fingerprint: Option<String>,
            #[arg(long)]
            report: PathBuf,
            #[arg(required = true)]
            files: Vec<PathBuf>,
        },
    }
    match Args::parse().command {
        Command::Receive {
            dir,
            port,
            seconds,
            pin,
            accept_test_files: _,
            report,
            notify_host,
            notify_port,
        } => {
            anyhow::ensure!((1..=3600).contains(&seconds), "seconds must be 1..3600");
            let receiver = Receiver::start(dir, port, pin, false).await?;
            println!(
                "{}",
                serde_json::json!({"event":"ready", "port": receiver.port(), "fingerprint": receiver.fingerprint(), "startup_ms":receiver.startup_ms})
            );
            if let Some(host) = notify_host {
                receiver.register_with(&host, notify_port).await?;
            }
            tokio::time::sleep(Duration::from_secs(seconds)).await;
            let result = receiver.stop().await?;
            std::fs::write(report, serde_json::to_vec_pretty(&result)?)?;
            anyhow::ensure!(!result.is_empty(), "no files received");
            anyhow::ensure!(
                result.iter().all(|file| file.success),
                "one or more received files failed"
            );
        }
        Command::Send {
            host,
            port,
            pin,
            fingerprint,
            report,
            files,
        } => {
            let identity = Identity::new("XDRemux PoC sender")?;
            let result = send_files(
                &identity,
                &host,
                port,
                pin.as_deref(),
                fingerprint,
                &files,
                false,
            )
            .await?;
            std::fs::write(report, serde_json::to_vec_pretty(&result)?)?;
            println!(
                "{}",
                serde_json::json!({"event":"sent", "files":result.len()})
            );
        }
    }
    Ok(())
}
