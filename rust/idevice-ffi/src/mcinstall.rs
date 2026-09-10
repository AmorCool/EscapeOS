//! MCInstall 协议 + 隧道句柄桥（v0.3.105）
//!
//! `com.apple.mobile.MCInstall.shim.remote` 的 SetWiFiPowerState
//! （pymobiledevice3 `profile set-wifi-power` 同款）。
//!
//! 架构：Swift 建 rp_pairing 隧道 → `lua_host_set_mcinstall_handles` 把
//! AdapterHandle/RsdHandshakeHandle **所有权移交给 Rust** → Rust 走
//! `adapter.connect(port)`（隧道内多路复用，非裸 TCP——裸 TCP 会被拒）
//! → 手写 XML plist 帧（4B BE 长度）→ RSDCheckin 三步握手 → SetWiFiPowerState。

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr::null_mut;
use std::sync::Mutex;

// 与 FFI 的 lockdown.rs 完全同款导入：
// - `lockdown::LockdownClient` 是 crate 根再导出的公开路径
// - `RsdService as _` 匿名导入 trait 才能调 connect_rsd（避免与 crates.io 版同名 trait 冲突）
use idevice::{IdeviceError, ReadWrite, RsdService as _, lockdown::LockdownClient};
use crate::pairing_file::{IdevicePairingFile, idevice_pairing_file_read};
use crate::run_sync_local;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

// ffi_err! 必须显式导入：#[macro_export] 宏虽在 crate 根，但 macro_rules 是文本序作用域，
// 本模块在 lib.rs 中声明于 errors.rs 之前，不导入就报 cannot find macro（v0.3.247 实锤，
// adapter.rs 同款显式导入见 adapter.rs 头部）
use crate::{
    core_device_proxy::AdapterHandle, ffi_err, rsd::RsdHandshakeHandle, IdeviceFfiError,
};

pub(crate) const PLIST_HEADER: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\
<plist version=\"1.0\">";
const MC_SERVICE_LOCKDOWN: &str = "com.apple.mobile.MCInstall";
#[allow(dead_code)]
const MC_SERVICE_RSD: &str = "com.apple.mobile.MCInstall.shim.remote";

// ---- 隧道句柄桥（Swift 移交所有权）----

static MC_TUNNEL: Mutex<Option<(usize, usize)>> = Mutex::new(None);
static MC_PAIRING: Mutex<Option<String>> = Mutex::new(None);

/// Swift 建好隧道后调用：移交 adapter/handshake 所有权（Swift 不再释放）
///
/// # Safety
/// 两个指针必须是本库分配的有效句柄；移交后 Swift 不得再使用或释放。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lua_host_set_mcinstall_handles(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    pairing_path: *const c_char,
) {
    if !pairing_path.is_null() {
        let s = unsafe { CStr::from_ptr(pairing_path) }.to_string_lossy().into_owned();
        *MC_PAIRING.lock().unwrap() = Some(s);
    }
    if adapter.is_null() || handshake.is_null() {
        return;
    }
    let mut guard = MC_TUNNEL.lock().unwrap();
    // 释放上次未消耗的句柄（防泄漏）
    if let Some((old_a, old_h)) = *guard {
        unsafe {
            drop(Box::from_raw(old_a as *mut AdapterHandle));
            drop(Box::from_raw(old_h as *mut RsdHandshakeHandle));
        }
    }
    *guard = Some((adapter as usize, handshake as usize));
}

fn take_mcinstall_handles() -> Option<(*mut AdapterHandle, *mut RsdHandshakeHandle)> {
    let mut guard = MC_TUNNEL.lock().unwrap();
    let (a, h) = (*guard)?;
    // ⚠️ 必须取走并清空：否则槽位残留悬垂指针，下次注册时"释放旧句柄"
    //    会二次释放已释放内存 → 崩溃（v0.3.105 闪退根因）。
    *guard = None;
    Some((a as *mut AdapterHandle, h as *mut RsdHandshakeHandle))
}

// ---- XML plist 协议（对齐 idevice crate send_plist/read_plist 实现）----

async fn send_xml(stream: &mut Box<dyn ReadWrite>, xml: &str) -> Result<(), IdeviceError> {
    let len = xml.len() as u32;
    stream
        .write_all(&len.to_be_bytes())
        .await
        ?;
    stream
        .write_all(xml.as_bytes())
        .await
        ?;
    stream
        .flush()
        .await
        ?;
    Ok(())
}

async fn read_plist_xml(stream: &mut Box<dyn ReadWrite>) -> Result<String, IdeviceError> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        ?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > 4 * 1024 * 1024 {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "plist 长度异常: {}",
            len
        )));
    }
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        ?;
    String::from_utf8(body)
        .map_err(|e| IdeviceError::UnexpectedResponse(format!("plist 非 UTF-8: {}", e)))
}

#[allow(dead_code)]
async fn rsd_checkin(stream: &mut Box<dyn ReadWrite>) -> Result<(), IdeviceError> {
    send_xml(
        stream,
        &format!(
            "{}<dict><key>Label</key><string>EscapeSpaceMCInstall</string>\
             <key>ProtocolVersion</key><string>2</string>\
             <key>Request</key><string>RSDCheckin</string></dict></plist>",
            PLIST_HEADER
        ),
    )
    .await?;
    let r1 = read_plist_xml(stream).await?;
    if !r1.contains("RSDCheckin") {
        return Err(IdeviceError::UnexpectedResponse(
            "RSDCheckin 响应不匹配".into(),
        ));
    }
    let r2 = read_plist_xml(stream).await?;
    if !r2.contains("StartService") {
        return Err(IdeviceError::UnexpectedResponse(
            "StartService 响应不匹配".into(),
        ));
    }
    Ok(())
}

// ---- base64（手写，避免新增依赖把 Cargo.lock 打翻）----

const B64_ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64_ALPHABET[((n >> 18) & 63) as usize] as char);
        out.push(B64_ALPHABET[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { B64_ALPHABET[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64_ALPHABET[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn b64_decode(s: &str) -> Option<Vec<u8>> {
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    let mut out = Vec::new();
    for ch in s.bytes() {
        match ch {
            b'=' | b'\n' | b'\r' | b' ' | b'\t' => continue,
            b'A'..=b'Z' => acc = (acc << 6) | (ch - b'A') as u32,
            b'a'..=b'z' => acc = (acc << 6) | (ch - b'a' + 26) as u32,
            b'0'..=b'9' => acc = (acc << 6) | (ch - b'0' + 52) as u32,
            b'+' => acc = (acc << 6) | 62,
            b'/' => acc = (acc << 6) | 63,
            _ => return None,
        }
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xFF) as u8);
        }
    }
    Some(out)
}

/// 提取 plist XML 里 `<key>K</key><data>B64</data>` 的二进制值
fn plist_data_field(xml: &str, key: &str) -> Option<Vec<u8>> {
    let key_tag = format!("<key>{}</key>", key);
    let rest = &xml[xml.find(&key_tag)?..];
    let start = rest.find("<data>")? + "<data>".len();
    let tail = &rest[start..];
    let end = tail.find("</data>")?;
    b64_decode(&tail[..end])
}

fn mdm_field<'a>(xml: &'a str, key: &str, open: &str, close: &str) -> Option<&'a str> {
    let key_tag = format!("<key>{}</key>", key);
    let rest = &xml[xml.find(&key_tag)?..];
    let start = rest.find(open)? + open.len();
    let tail = &rest[start..];
    let end = tail.find(close)?;
    Some(&tail[..end])
}

fn is_ack(reply: &str) -> bool {
    mdm_field(reply, "Status", "<string>", "</string>") == Some("Acknowledged")
        || reply.contains("Acknowledged")
}

fn describe_mdm_error(reply: &str) -> String {
    let code = mdm_field(reply, "ErrorCode", "<integer>", "</integer>");
    let domain = mdm_field(reply, "ErrorDomain", "<string>", "</string>");
    let desc = mdm_field(reply, "LocalizedDescription", "<string>", "</string>")
        .or_else(|| mdm_field(reply, "USEnglishDescription", "<string>", "</string>"));
    match (code, domain, desc) {
        (Some(c), Some(d), Some(s)) => format!("设备拒绝：{} {}（{}）", d, c, s),
        _ => format!(
            "设备应答无 Acknowledged：{}",
            reply.chars().take(200).collect::<String>()
        ),
    }
}

// ---- PKCS7 签名回调（Swift 提供，Escalate 时用） ----
//
// Rust 侧不引加密依赖（避免把 Cargo.lock 打翻）；证书/私钥与 PKCS7 签名都走已
// 链接的 libcrypto（ZSign 同款）。Swift 启动时注册一次，Rust 在 Escalate 中回调。

type Pkcs7SignFn = unsafe extern "C" fn(
    data: *const u8,
    data_len: c_int,
    der_out: *mut *mut u8,
    der_len: *mut c_int,
) -> c_int;

static PKCS7_SIGN_FN: Mutex<Option<Pkcs7SignFn>> = Mutex::new(None);

/// 注册 PKCS7 签名回调（幂等，后注册覆盖前者）。
///
/// # Safety
/// `f` 必须是有效的 C 函数指针；Swift 侧负责其生命周期（静态闭包）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_set_pkcs7_sign_fn(f: Pkcs7SignFn) {
    *PKCS7_SIGN_FN.lock().unwrap() = Some(f);
}

/// 隧道内连 shim.remote 并完成 RSDCheckin，返回可用流
async fn mcinstall_connect(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &idevice::rsd::RsdHandshake,
) -> Result<Box<dyn ReadWrite>, IdeviceError> {
    let port = handshake
        .services
        .get(MC_SERVICE_RSD)
        .map(|s| s.port)
        .ok_or(IdeviceError::ServiceNotFound)?;
    let mut stream: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
    rsd_checkin(&mut stream).await?;
    Ok(stream)
}

/// Escalate（监督身份挑战应答）。对齐 pymobiledevice3 MobileConfigService.escalate：
/// ① SupervisorCertificate(证书 DER) → ② 用 PKCS7 附签 Challenge 回传 → ③ keybag 迁移。
/// **必须在同一条连接上完成**——escalate 状态是按连接记的。
async fn mcinstall_escalate(
    stream: &mut Box<dyn ReadWrite>,
    cert_der: &[u8],
) -> Result<(), IdeviceError> {
    send_xml(
        stream,
        &format!(
            "{}<dict><key>RequestType</key><string>Escalate</string>\
             <key>SupervisorCertificate</key><data>{}</data></dict></plist>",
            PLIST_HEADER,
            b64_encode(cert_der)
        ),
    )
    .await?;
    let r1 = read_plist_xml(stream).await?;
    if !is_ack(&r1) {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "Escalate 被拒绝：{}",
            describe_mdm_error(&r1)
        )));
    }
    let challenge = plist_data_field(&r1, "Challenge")
        .ok_or_else(|| IdeviceError::UnexpectedResponse("Escalate 应答缺少 Challenge".into()))?;

    let signer = *PKCS7_SIGN_FN.lock().unwrap();
    let signer = signer
        .ok_or_else(|| IdeviceError::UnexpectedResponse("未注册 PKCS7 签名回调".into()))?;
    let mut der: *mut u8 = null_mut();
    let mut der_len: c_int = 0;
    let rc = unsafe { signer(challenge.as_ptr(), challenge.len() as c_int, &mut der, &mut der_len) };
    if rc != 0 || der.is_null() || der_len <= 0 {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "PKCS7 签名失败（rc={}）",
            rc
        )));
    }
    let sig = unsafe { std::slice::from_raw_parts(der, der_len as usize) }.to_vec();
    // Swift 侧用 malloc 分配，Darwin 上与 libc::free 同一分配器
    unsafe { libc::free(der as *mut libc::c_void) };

    send_xml(
        stream,
        &format!(
            "{}<dict><key>RequestType</key><string>EscalateResponse</string>\
             <key>SignedRequest</key><data>{}</data></dict></plist>",
            PLIST_HEADER,
            b64_encode(&sig)
        ),
    )
    .await?;
    let r2 = read_plist_xml(stream).await?;
    if !is_ack(&r2) {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "EscalateResponse 被拒绝：{}",
            describe_mdm_error(&r2)
        )));
    }

    send_xml(
        stream,
        &format!(
            "{}<dict><key>RequestType</key><string>ProceedWithKeybagMigration</string>\
             </dict></plist>",
            PLIST_HEADER
        ),
    )
    .await?;
    let r3 = read_plist_xml(stream).await?;
    if !is_ack(&r3) {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "ProceedWithKeybagMigration 被拒绝：{}",
            describe_mdm_error(&r3)
        )));
    }
    Ok(())
}

/// v0.3.249：通用 MCInstall 请求（隧道内直连 shim.remote → RSDCheckin →
/// 可选 Escalate → 发送 Swift 组装好的 plist 正文 → 原样返回设备应答）。
///
/// `request_xml` 是 **plist 正文**（`<dict>...</dict>`），不含 `<?xml?>` 头与
/// `</plist>` 收尾——Rust 侧统一拼装，Swift 不碰任何帧协议（v0.3.244 闪退教训）。
/// `cert_der`/`cert_der_len` 非空时先走 Escalate（监督通道）。
///
/// # Safety
/// `adapter`/`handshake` 必须是本库分配的有效句柄；`out_reply` 可为 NULL。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_request_rsd(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    request_xml: *const c_char,
    cert_der: *const u8,
    cert_der_len: c_int,
    out_reply: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || request_xml.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    if !cert_der.is_null() && cert_der_len <= 0 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let req = unsafe { CStr::from_ptr(request_xml) }.to_string_lossy().into_owned();
    let cert: Option<Vec<u8>> = if cert_der.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(cert_der, cert_der_len as usize) }.to_vec())
    };

    let res: Result<String, IdeviceError> = (|| {
        let handshake_ref = unsafe { &(*(handshake)).0 };
        let adapter_ref = unsafe { &mut (*(adapter)).0 };
        run_sync_local(async move {
            let mut stream = mcinstall_connect(adapter_ref, handshake_ref).await?;
            if let Some(cert) = &cert {
                mcinstall_escalate(&mut stream, cert).await?;
            }
            send_xml(
                &mut stream,
                &format!("{}{}</plist>", PLIST_HEADER, req),
            )
            .await?;
            read_plist_xml(&mut stream).await
        })
    })();

    match res {
        Ok(reply) => {
            if !out_reply.is_null() {
                let c = CString::new(reply).unwrap_or_default();
                unsafe { *out_reply = c.into_raw() };
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// 用移交的隧道句柄执行完整 MCInstall SetWiFiPowerState 流程
/// （adapter/handshake 所有权在此消耗：from_raw 后所有路径负责释放）
pub async fn mcinstall_power_with_handles(on: bool) -> Result<String, IdeviceError> {
    let (a, h) = take_mcinstall_handles()
        .ok_or(IdeviceError::ServiceNotFound)?; // Swift 未准备好隧道
    let (mut adapter, handshake) = unsafe {
        // 接管 Swift 移交的所有权（此后由本函数负责释放）
        let adapter = Box::from_raw(a);
        let handshake = Box::from_raw(h);
        (adapter.0, handshake.0)
    };

    let pairing_path = MC_PAIRING.lock().unwrap().clone()
        .ok_or(IdeviceError::ServiceNotFound)?;

    // 1) 隧道内连 lockdownd（RSD）——与 pymobiledevice3 完全同构
    let mut hs = handshake;
    let mut lockdown = LockdownClient::connect_rsd(&mut adapter, &mut hs).await?;
    // 2) 用配对文件起会话（获得与电脑端同等的 lockdown 权限）
    // FFI 自己的读取器（plist 格式）；PairingFile::read_from_file 只吃 raw 格式会报错
    let c_path = CString::new(pairing_path.as_str())
        .map_err(|_| IdeviceError::UnexpectedResponse("配对文件路径含 NUL".into()))?;
    let mut pf: *mut IdevicePairingFile = std::ptr::null_mut();
    // 注意：返回裸指针（非 Option）——null 表示成功
    let err = unsafe { idevice_pairing_file_read(c_path.as_ptr(), &mut pf) };
    if !err.is_null() {
        unsafe { crate::errors::idevice_error_free(err) };
        return Err(IdeviceError::UnexpectedResponse("读取配对文件失败".into()));
    }
    if pf.is_null() {
        return Err(IdeviceError::UnexpectedResponse("读取配对文件失败（空句柄）".into()));
    }
    let pairing: &_ = unsafe { &(*pf).0 };
    let _legacy = lockdown.start_session(pairing).await?;
    // 会话已建立，释放配对文件句柄
    drop(unsafe { Box::from_raw(pf) });
    // 3) 经 lockdownd 启动 MCInstall 服务（非 .shim.remote，无 entitlement 门禁）
    let (port, ssl) = lockdown.start_service(MC_SERVICE_LOCKDOWN).await?;
    if ssl {
        return Err(IdeviceError::UnexpectedResponse(
            "MCInstall 要求 SSL 会话，暂不支持".into(),
        ));
    }
    // 4) 通过隧道 adapter 连到服务端口，直发 plist（lockdown 启动的服务无需 RSDCheckin）
    let mut stream: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
    let on_str = if on { "true" } else { "false" };
    send_xml(
        &mut stream,
        &format!(
            "{}<dict><key>PowerState</key><{} /><key>RequestType</key>\n             <string>SetWiFiPowerState</string></dict></plist>",
            PLIST_HEADER, on_str
        ),
    )
    .await?;
    let reply = read_plist_xml(&mut stream).await?;
    if !is_ack(&reply) {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "SetWiFiPowerState 未被确认：{}",
            describe_mdm_error(&reply)
        )));
    }
    Ok(reply)
}

// ---- C 导出（供 Rust lua_host 使用 mcinstall_power_with_handles 前后的诊断）----

/// 读 MC_TUNNEL 状态（诊断用）：1=句柄已就绪 0=未就绪
///
/// # Safety
/// 无需指针参数。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_handles_ready() -> c_int {
    if MC_TUNNEL.lock().unwrap().is_some() { 1 } else { 0 }
}

/// 供字符串释放（保留给未来诊断导出）
///
/// # Safety
/// `p` 必须是本库分配的字符串指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

// 防止 CStr/CString 未使用告警（保留给未来诊断导出）
#[allow(dead_code)]
fn cstr_to_string(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
