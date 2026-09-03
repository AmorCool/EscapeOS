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

use idevice::{IdeviceError, ReadWrite, pairing_file::PairingFile, services::lockdown::LockdownClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::{core_device_proxy::AdapterHandle, rsd::RsdHandshakeHandle, IdeviceFfiError};

const PLIST_HEADER: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
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

/// SetWiFiPowerState over 已建立的 MCInstall 流
pub async fn set_wifi_power_stream(
    stream: &mut Box<dyn ReadWrite>,
    state: bool,
) -> Result<String, IdeviceError> {
    let on = if state { "true" } else { "false" };
    send_xml(
        stream,
        &format!(
            "{}<dict><key>PowerState</key><{} /><key>RequestType</key>\
             <string>SetWiFiPowerState</string></dict></plist>",
            PLIST_HEADER, on
        ),
    )
    .await?;
    let reply = read_plist_xml(stream).await?;
    if reply.contains("<key>Error</key>") {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "设备返回 Error: {}",
            reply
        )));
    }
    Ok(reply)
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
    let pairing = PairingFile::read_from_file(&pairing_path)?;
    let _legacy = lockdown.start_session(&pairing).await?;
    // 3) 经 lockdownd 启动 MCInstall 服务（非 .shim.remote，无 entitlement 门禁）
    let (port, ssl) = lockdown.start_service(MC_SERVICE_LOCKDOWN).await?;
    if ssl {
        return Err(IdeviceError::UnexpectedResponse(
            "MCInstall 要求 SSL 会话，暂不支持".into(),
        ));
    }
    // 4) 通过隧道 adapter 连到服务端口，直发 plist（lockdown 启动的服务无需 RSDCheckin）
    let mut stream: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
    set_wifi_power_stream(&mut stream, on).await
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
