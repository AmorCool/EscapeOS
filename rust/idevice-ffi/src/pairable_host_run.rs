//! iOS 27 device-initiated wireless pairing host (pairable-host responder).
//!
//! This is an independent reimplementation against the public `idevice` API
//! (jkcoxson/idevice, BSD-3). The mDNS advertisement is delegated to the
//! caller — the Swift/ObjC side publishes `_remotepairing-pairable-host._tcp`
//! via `NetService` (Bonjour), which avoids the iOS multicast entitlement that
//! a Rust mDNS daemon would require.
//!
//! Flow:
//!   1. Bind a TCP listener and emit `ready_cb` with the service id, port and
//!      TXT records so the caller can advertise the service over Bonjour.
//!   2. Block until the device discovers and connects to the port, then drive
//!      `PairableHost::accept`.
//!   3. `pin_cb` is invoked once with the 6-digit setup code; the caller shows
//!      it in the app UI for the user to type on the device.
//!   4. On success the freshly generated `RpPairingFile` is written to
//!      `out_path` and its `host_alt_irk` is returned so the caller can persist
//!      it (lets an already-paired device recognise this host next time).

use std::ffi::{c_char, c_void, CStr, CString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::ptr;

use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use tokio::net::TcpListener;

use crate::run_sync_local;

/// Emitted by `si_run_host` right after the listener is bound, so the caller
/// can advertise the pairable-host service over Bonjour. The `txt_*` arrays and
/// `service_id` point to C strings that are only valid for the duration of the
/// callback — copy them immediately.
pub type SiReadyCb = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;

/// Emitted once with the 6-digit setup PIN to display in the UI.
pub type SiPinCb = Option<extern "C" fn(pin: *const c_char, ctx: *mut c_void)>;

#[repr(C)]
pub struct SiPairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
    pub host_alt_irk_hex: *mut c_char,
}

impl SiPairResult {
    fn empty() -> Self {
        Self {
            error: ptr::null_mut(),
            device_name: ptr::null_mut(),
            device_model: ptr::null_mut(),
            device_udid: ptr::null_mut(),
            pairing_file_path: ptr::null_mut(),
            host_alt_irk_hex: ptr::null_mut(),
        }
    }
}

struct Paired {
    name: String,
    model: String,
    udid: String,
    path: String,
    host_alt_irk_hex: String,
}

unsafe fn cstr(s: String) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(ptr::null_mut())
}

unsafe fn opt_str(p: *const c_char, d: &str) -> String {
    if p.is_null() {
        d.to_string()
    } else {
        match CStr::from_ptr(p).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => d.to_string(),
        }
    }
}

/// Bind a listener, hand advertising details to the caller via `ready_cb`, wait
/// for the device, drive pairing through `pin_cb`, and write the pairing file
/// to `out_path`. Blocks the calling thread until pairing completes or fails.
///
/// # Safety
/// All `*const c_char` args must be null or valid C strings; `out` must be a
/// valid, writable `SiPairResult`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    ready_cb: SiReadyCb,
    pin_cb: SiPinCb,
    ctx: *mut c_void,
    out: *mut SiPairResult,
) -> i32 {
    if out.is_null() {
        return 2;
    }
    *out = SiPairResult::empty();

    let bind_addr = opt_str(bind_addr, "0.0.0.0");
    let name = opt_str(name, "EscapeOS");
    let model = opt_str(model, "Mac17,7");
    let out_path = opt_str(out_path, "rp_pairing_file.plist");
    let saved_alt_irk = parse_alt_irk(&opt_str(host_alt_irk_hex, ""));
    let pin_cb = pin_cb;
    let ready_cb = ready_cb;
    let ctx = ctx;

    let res = run_sync_local(run(
        bind_addr,
        port,
        name,
        model,
        out_path,
        saved_alt_irk,
        ready_cb,
        pin_cb,
        ctx,
    ));
    match res {
        Ok(p) => {
            (*out).device_name = cstr(p.name);
            (*out).device_model = cstr(p.model);
            (*out).device_udid = cstr(p.udid);
            (*out).pairing_file_path = cstr(p.path);
            (*out).host_alt_irk_hex = cstr(p.host_alt_irk_hex);
            0
        }
        Err(e) => {
            (*out).error = cstr(e);
            1
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run(
    bind_addr: String,
    port: u16,
    name: String,
    model: String,
    out_path: String,
    saved_alt_irk: Option<[u8; 16]>,
    ready_cb: SiReadyCb,
    pin_cb: SiPinCb,
    ctx: *mut c_void,
) -> Result<Paired, String> {
    let ip: IpAddr = bind_addr
        .parse()
        .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let listener = TcpListener::bind(SocketAddr::new(ip, port))
        .await
        .map_err(|e| format!("failed to bind {bind_addr}:{port}: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("no local addr: {e}"))?
        .port();

    // Reuse the host key pair across pairings so any pairing files this app has
    // already written into other apps stay valid. A re-pair just replaces the
    // device's record for this identifier.
    let mut pairing_file = match RpPairingFile::read_from_file(&out_path).await {
        Ok(mut existing) => {
            existing.alt_irk = None;
            existing
        }
        Err(_) => RpPairingFile::generate(&name),
    };
    let mut host_info = PairableHostInfo::generate(&name, &model);
    if let Some(alt_irk) = saved_alt_irk {
        host_info.alt_irk = alt_irk;
    }
    let host_alt_irk = host_info.alt_irk;
    let service_identifier = pairing_file.identifier.clone();

    emit_ready(ready_cb, ctx, &service_identifier, port, &host_info);

    let (stream, _peer) = listener
        .accept()
        .await
        .map_err(|e| format!("accept failed: {e}"))?;

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let peer = host
        .accept(&mut pairing_file, move |pin: String| {
            let pin_cb = pin_cb;
            let ctx = ctx;
            async move {
                if let Some(cb) = pin_cb {
                    if let Ok(c) = CString::new(pin) {
                        cb(c.as_ptr(), ctx);
                    }
                }
            }
        })
        .await
        .map_err(|e| format!("pairing failed: {e:?}"))?;

    pairing_file
        .write_to_file(&out_path)
        .await
        .map_err(|e| format!("failed to write pairing file: {e}"))?;

    let size = tokio::fs::metadata(&out_path)
        .await
        .map(|m| m.len())
        .unwrap_or(0);
    if size == 0 {
        return Err(format!(
            "handshake completed but pairing file at {out_path} is missing or zero bytes"
        ));
    }

    Ok(Paired {
        name: peer.name,
        model: peer.model,
        udid: peer.remotepairing_udid,
        path: out_path,
        host_alt_irk_hex: hex(&host_alt_irk),
    })
}

fn emit_ready(
    ready_cb: SiReadyCb,
    ctx: *mut c_void,
    service_id: &str,
    port: u16,
    host_info: &PairableHostInfo,
) {
    let Some(cb) = ready_cb else { return };
    let records = host_info.mdns_txt_records(service_id);
    let mut keys: Vec<CString> = Vec::with_capacity(records.len());
    let mut vals: Vec<CString> = Vec::with_capacity(records.len());
    for (k, v) in &records {
        keys.push(CString::new(k.as_str()).unwrap_or_default());
        vals.push(CString::new(v.as_str()).unwrap_or_default());
    }
    let key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
    let val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();
    let Ok(id_c) = CString::new(service_id) else {
        return;
    };
    // SAFETY: `keys`/`vals` (and thus their pointers) stay alive until the
    // callback returns; the caller must copy the strings synchronously.
    cb(
        ctx,
        id_c.as_ptr(),
        port,
        key_ptrs.as_ptr(),
        val_ptrs.as_ptr(),
        records.len(),
    );
}

/// Read back the 32-char hex `si_run_host` handed out last time. Anything that
/// isn't exactly 16 bytes of hex is ignored (a fresh alt_irk costs
/// recognition, not correctness).
fn parse_alt_irk(hex: &str) -> Option<[u8; 16]> {
    if hex.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

fn hex(bytes: &[u8; 16]) -> String {
    let mut s = String::with_capacity(32);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Free the heap strings inside a `SiPairResult`.
///
/// # Safety
/// `r` must be null or a `SiPairResult` previously populated by `si_run_host`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_result_free(r: *mut SiPairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_model,
        (*r).device_udid,
        (*r).pairing_file_path,
        (*r).host_alt_irk_hex,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = SiPairResult::empty();
}
