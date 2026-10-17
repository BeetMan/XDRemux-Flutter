use super::*;
use std::time::{Duration, Instant};

fn poll(handle: u64) -> serde_json::Value {
    let mut ptr = std::ptr::null_mut();
    assert_eq!(
        unsafe { xdremux_transfer_poll(handle, 128, OUTPUT_MAX as u32, &mut ptr) },
        OK
    );
    let v = serde_json::from_slice(unsafe { std::ffi::CStr::from_ptr(ptr) }.to_bytes()).unwrap();
    assert_eq!(xdremux_transfer_free_string(ptr), OK);
    assert_eq!(xdremux_transfer_free_string(ptr), INVALID);
    v
}
fn create(config: serde_json::Value) -> u64 {
    let bytes = config.to_string();
    let mut handle = 0;
    assert_eq!(
        unsafe { xdremux_transfer_create(bytes.as_ptr(), bytes.len(), &mut handle) },
        OK
    );
    handle
}
fn wait_phase(handle: u64, phase: u8) -> serde_json::Value {
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let value = poll(handle);
        if value["phase"] == phase {
            return value;
        }
        assert!(Instant::now() < until, "state deadline: {value}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn lifecycle_bounds_loss_and_real_resource_release() {
    let temp = tempfile::tempdir().unwrap();
    let cfg = json!({"root":temp.path().join("store")});
    let h = create(cfg.clone());
    assert_eq!(xdremux_transfer_release(h), BUSY);
    let ready = wait_phase(h, runtime::RUNNING);
    let peer: std::net::SocketAddr = ready["ready"]["address"].as_str().unwrap().parse().unwrap();
    let old_instance = ready["instance_id"].clone();
    let e = entry(h).unwrap();
    for _ in 0..400 {
        e.push(json!({"kind":"test","data":"x".repeat(1024)}));
    }
    let mut ptr = std::ptr::null_mut();
    assert_eq!(
        unsafe { xdremux_transfer_poll(h, 1, 256, &mut ptr) },
        TOO_SMALL
    );
    assert!(ptr.is_null());
    let page = poll(h);
    assert!(page["lost"].as_u64().unwrap() > 0);
    assert_eq!(page["records"].as_array().unwrap().len(), 128);
    let input = b"{\"command\":\"snapshot\",\"limit\":64}";
    let mut op = 0;
    assert_eq!(
        unsafe { xdremux_transfer_submit(h, input.as_ptr(), input.len(), &mut op) },
        OK
    );
    assert_ne!(op, 0);
    assert_eq!(
        unsafe { xdremux_transfer_submit(h, input.as_ptr(), INPUT_MAX + 1, &mut op) },
        INVALID
    );
    assert_eq!(
        unsafe { xdremux_transfer_submit(h, std::ptr::null(), 1, &mut op) },
        INVALID
    );
    assert_eq!(xdremux_transfer_stop(h), OK);
    assert_eq!(xdremux_transfer_stop(h), OK);
    wait_phase(h, STOPPED);
    // Port and on-disk exclusive lease are both released before Stopped.
    let socket = std::net::TcpListener::bind(peer).unwrap();
    drop(socket);
    assert_eq!(xdremux_transfer_release(h), OK);
    assert_eq!(xdremux_transfer_release(h), HANDLE);
    assert_eq!(xdremux_transfer_stop(h), HANDLE);
    let second = create(cfg);
    let ready = wait_phase(second, runtime::RUNNING);
    assert_ne!(ready["instance_id"], old_instance);
    assert_eq!(xdremux_transfer_stop(second), OK);
    wait_phase(second, STOPPED);
    assert_eq!(xdremux_transfer_release(second), OK);
    // Stop during startup still waits for owned startup resources.
    let third = create(json!({"root":temp.path().join("early-stop")}));
    assert_eq!(xdremux_transfer_stop(third), OK);
    wait_phase(third, STOPPED);
    assert_eq!(xdremux_transfer_release(third), OK);
    assert_eq!(xdremux_transfer_free_string(std::ptr::null_mut()), OK);
    assert_eq!(
        xdremux_transfer_free_string(std::ptr::dangling_mut::<c_char>()),
        INVALID
    );
}

#[test]
fn priority_channel_and_stop_do_not_wait_for_normal_capacity() {
    let (e, _rx, _px) = Entry::new();
    for id in 1..=32 {
        e.commands
            .try_send(Command {
                id,
                request: protocol::Request::Snapshot {
                    after: None,
                    limit: 1,
                },
            })
            .unwrap();
    }
    assert!(e
        .commands
        .try_send(Command {
            id: 33,
            request: protocol::Request::Snapshot {
                after: None,
                limit: 1
            }
        })
        .is_err());
    assert!(e
        .priority
        .try_send(Command {
            id: 34,
            request: protocol::Request::CancelReceive {
                transfer_id: "test".into()
            }
        })
        .is_ok());
    e.stop.cancel();
    assert!(e.stop.is_cancelled());
}
