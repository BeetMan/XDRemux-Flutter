//! Versioned C boundary. Only validated numeric handles cross the ABI.
#![deny(unsafe_op_in_unsafe_fn)]
#[cfg(panic = "abort")]
compile_error!("The transfer ABI requires panic=unwind");
mod protocol;
mod runtime;

use runtime::{Command, Entry, STOPPED, STOPPING};
use serde_json::json;
use std::{
    collections::HashMap,
    ffi::{c_char, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
};

const OK: i32 = 0;
const INVALID: i32 = 1;
const HANDLE: i32 = 2;
const BUSY: i32 = 3;
const CLOSED: i32 = 4;
const TOO_SMALL: i32 = 5;
const INTERNAL: i32 = 6;
const INPUT_MAX: usize = 64 * 1024;
const OUTPUT_MAX: usize = 2 * 1024 * 1024;
static IDS: AtomicU64 = AtomicU64::new(1);
static HANDLES: OnceLock<Mutex<HashMap<u64, Arc<Entry>>>> = OnceLock::new();
static BUFFERS: OnceLock<Mutex<HashMap<usize, CString>>> = OnceLock::new();
fn handles() -> &'static Mutex<HashMap<u64, Arc<Entry>>> {
    HANDLES.get_or_init(Mutex::default)
}
fn buffers() -> &'static Mutex<HashMap<usize, CString>> {
    BUFFERS.get_or_init(Mutex::default)
}
fn entry(handle: u64) -> std::result::Result<Arc<Entry>, i32> {
    handles()
        .lock()
        .map_err(|_| INTERNAL)?
        .get(&handle)
        .cloned()
        .ok_or(HANDLE)
}
fn next_id() -> std::result::Result<u64, i32> {
    IDS.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
        .map_err(|_| BUSY)
}
fn boundary(f: impl FnOnce() -> std::result::Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => OK,
        Ok(Err(code)) => code,
        Err(_) => INTERNAL,
    }
}
fn output_valid<T>(p: *mut T) -> bool {
    !p.is_null() && (p as usize).is_multiple_of(std::mem::align_of::<T>())
}
unsafe fn parse<T: serde::de::DeserializeOwned>(
    p: *const u8,
    len: usize,
) -> std::result::Result<T, i32> {
    if p.is_null() || len == 0 || len > INPUT_MAX {
        return Err(INVALID);
    }
    // SAFETY: caller supplies a readable buffer for len bytes for this call only.
    serde_json::from_slice(unsafe { std::slice::from_raw_parts(p, len) }).map_err(|_| INVALID)
}

#[no_mangle]
pub extern "C" fn xdremux_transfer_abi_version() -> u32 {
    1 << 16
}

/// # Safety
/// Input is readable for len bytes; out is an aligned writable u64. No overlap.
#[no_mangle]
pub unsafe extern "C" fn xdremux_transfer_create(
    input: *const u8,
    len: usize,
    out: *mut u64,
) -> i32 {
    boundary(|| {
        if !output_valid(out) {
            return Err(INVALID);
        }
        unsafe {
            *out = 0;
        }
        let config = unsafe { parse::<protocol::Create>(input, len)? }
            .config()
            .map_err(|_| INVALID)?;
        let mut all = handles().lock().map_err(|_| INTERNAL)?;
        if all.len() >= 4 {
            return Err(BUSY);
        }
        let id = next_id()?;
        let (entry, rx, px) = Entry::new();
        let worker = entry.clone();
        let thread = std::thread::Builder::new()
            .name("xdremux-transfer".into())
            .spawn(move || runtime::run(worker, config, rx, px))
            .map_err(|_| INTERNAL)?;
        *entry.thread.lock().map_err(|_| INTERNAL)? = Some(thread);
        all.insert(id, entry);
        unsafe {
            *out = id;
        }
        Ok(())
    })
}

/// # Safety
/// Input is readable for len bytes; out is an aligned writable u64. No overlap.
#[no_mangle]
pub unsafe extern "C" fn xdremux_transfer_submit(
    handle: u64,
    input: *const u8,
    len: usize,
    out: *mut u64,
) -> i32 {
    boundary(|| {
        if !output_valid(out) {
            return Err(INVALID);
        }
        unsafe {
            *out = 0;
        }
        let request = unsafe { parse::<protocol::Request>(input, len)? };
        request.validate().map_err(|_| INVALID)?;
        let entry = entry(handle)?;
        if entry.phase.load(Ordering::Acquire) >= STOPPING {
            return Err(CLOSED);
        }
        let id = next_id()?;
        let sender = if request.priority() {
            &entry.priority
        } else {
            &entry.commands
        };
        sender
            .try_send(Command { id, request })
            .map_err(|e| match e {
                tokio::sync::mpsc::error::TrySendError::Full(_) => BUSY,
                tokio::sync::mpsc::error::TrySendError::Closed(_) => CLOSED,
            })?;
        unsafe {
            *out = id;
        }
        Ok(())
    })
}

/// Nonblocking bounded drain. TooSmall/Busy leaves every queued record intact.
/// # Safety
/// out is an aligned writable char pointer. Free the returned string with this library.
#[no_mangle]
pub unsafe extern "C" fn xdremux_transfer_poll(
    handle: u64,
    max_events: u32,
    max_bytes: u32,
    out: *mut *mut c_char,
) -> i32 {
    boundary(|| {
        if !output_valid(out) {
            return Err(INVALID);
        }
        unsafe {
            *out = std::ptr::null_mut();
        }
        if !(1..=128).contains(&max_events) || !(256..=OUTPUT_MAX).contains(&(max_bytes as usize)) {
            return Err(INVALID);
        }
        let entry = entry(handle)?;
        let mut q = entry.queue.lock().map_err(|_| INTERNAL)?;
        let mut value = json!({"instance_id":entry.instance,"phase":entry.phase.load(Ordering::Acquire),
            "ready":*entry.ready.lock().map_err(|_| INTERNAL)?,"last_sequence":q.sequence,"lost":q.lost}).to_string();
        value.pop();
        value.push_str(",\"records\":[");
        let mut count = 0;
        for record in q.records.iter().take(max_events as usize) {
            if value.len() + record.len() + usize::from(count > 0) + 3 > max_bytes as usize {
                if count == 0 {
                    return Err(TOO_SMALL);
                }
                break;
            }
            if count > 0 {
                value.push(',');
            }
            value.push_str(record);
            count += 1;
        }
        value.push_str("]}");
        if value.len() + 1 > max_bytes as usize {
            return Err(TOO_SMALL);
        }
        let string = CString::new(value).map_err(|_| INTERNAL)?;
        let mut allocated = buffers().lock().map_err(|_| INTERNAL)?;
        if allocated.len() >= 64
            || allocated
                .values()
                .map(|s| s.as_bytes_with_nul().len())
                .sum::<usize>()
                + string.as_bytes_with_nul().len()
                > 16 * 1024 * 1024
        {
            return Err(BUSY);
        }
        let ptr = string.as_ptr() as *mut c_char;
        allocated.insert(ptr as usize, string);
        for _ in 0..count {
            q.bytes -= q.records.pop_front().unwrap().len();
        }
        unsafe {
            *out = ptr;
        }
        Ok(())
    })
}

/// Stop revokes every receipt lease. Callers must finish external reads before stop.
#[no_mangle]
pub extern "C" fn xdremux_transfer_stop(handle: u64) -> i32 {
    boundary(|| {
        let entry = entry(handle)?;
        let _ = entry
            .phase
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |p| {
                (p < STOPPING).then_some(STOPPING)
            });
        entry.stop.cancel();
        Ok(())
    })
}
#[no_mangle]
pub extern "C" fn xdremux_transfer_release(handle: u64) -> i32 {
    boundary(|| {
        let mut all = handles().lock().map_err(|_| INTERNAL)?;
        if all
            .get(&handle)
            .ok_or(HANDLE)?
            .phase
            .load(Ordering::Acquire)
            != STOPPED
        {
            return Err(BUSY);
        }
        let entry = all.remove(&handle).ok_or(HANDLE)?;
        // Join the thread epilogue as well, so the library may be unloaded after release.
        if let Some(thread) = entry.thread.lock().map_err(|_| INTERNAL)?.take() {
            thread.join().map_err(|_| INTERNAL)?;
        }
        Ok(())
    })
}
/// Accepts NULL. Unknown/already freed addresses are rejected without dereferencing.
/// Caller still must not reuse stale addresses (allocator addresses can be reused).
#[no_mangle]
pub extern "C" fn xdremux_transfer_free_string(ptr: *mut c_char) -> i32 {
    boundary(|| {
        if ptr.is_null() {
            return Ok(());
        }
        buffers()
            .lock()
            .map_err(|_| INTERNAL)?
            .remove(&(ptr as usize))
            .ok_or(INVALID)?;
        Ok(())
    })
}

#[cfg(test)]
mod tests;
