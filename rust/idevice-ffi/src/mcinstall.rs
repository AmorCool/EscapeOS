//! MCInstall 客户端绑定（v0.3.102）
//!
//! `com.apple.mobile.MCInstall`（RSD: `com.apple.mobile.MCInstall.shim.remote`）
//! —— 走 RSD 隧道发送 `SetWiFiPowerState`（pymobiledevice3
//! `profile set-wifi-power` 同款请求），供 Lua 宿主 host.wifi_power 控制射频。
//! App 无 wifi entitlement，直调 MobileWiFi 是空操作 → 必须经设备自己的服务。
//!
//! 协议（对齐 idevice crate send_plist/read_plist 实现）：
//! - 帧：4 字节大端长度 + XML plist 体
//! - RSD checkin：发 RSDCheckin → 收两个响应（RSDCheckin / StartService）

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr::null_mut;

use idevice::{IdeviceError, ReadWrite};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::{
    IdeviceFfiError, core_device_proxy::AdapterHandle, ffi_err, provider::IdeviceProviderHandle,
    rsd::RsdHandshakeHandle, run_sync_local,
};

const PLIST_HEADER: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\
<plist version=\"1.0\">";

/// MCInstall 服务客户端（保持原始流，手动实现协议）
pub struct McInstallClient {
    /// 底层设备连接（已过 RSD checkin）
    pub stream: Box<dyn ReadWrite>,
}

impl McInstallClient {
    pub fn new(stream: Box<dyn ReadWrite>) -> Self {
        Self { stream }
    }

    /// 发送 XML plist（4B BE 长度前缀）
    async fn send_xml(&mut self, xml: &str) -> Result<(), IdeviceError> {
        let len = xml.len() as u32;
        self.stream
            .write_all(&len.to_be_bytes())
            .await
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("IO: {}", e)))?;
        self.stream
            .write_all(xml.as_bytes())
            .await
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("IO: {}", e)))?;
        self.stream
            .flush()
            .await
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("IO: {}", e)))?;
        Ok(())
    }

    /// 读取一条 plist（4B BE 长度 + 体），返回 XML 文本
    async fn read_plist_xml(&mut self) -> Result<String, IdeviceError> {
        let mut len_buf = [0u8; 4];
        self.stream
            .read_exact(&mut len_buf)
            .await
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("IO: {}", e)))?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len == 0 || len > 4 * 1024 * 1024 {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "plist 长度异常: {}",
                len
            )));
        }
        let mut body = vec![0u8; len];
        self.stream
            .read_exact(&mut body)
            .await
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("IO: {}", e)))?;
        String::from_utf8(body)
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("plist 非 UTF-8: {}", e)))
    }

    /// RSD checkin（三步握手）
    async fn rsd_checkin(&mut self) -> Result<(), IdeviceError> {
        self.send_xml(&format!(
            "{}<dict><key>Label</key><string>EscapeSpaceMCInstall</string>\
             <key>ProtocolVersion</key><string>2</string>\
             <key>Request</key><string>RSDCheckin</string></dict></plist>",
            PLIST_HEADER
        ))
        .await?;
        let r1 = self.read_plist_xml().await?;
        if !r1.contains("RSDCheckin") {
            return Err(IdeviceError::UnexpectedResponse(
                "RSDCheckin 响应不匹配".into(),
            ));
        }
        let r2 = self.read_plist_xml().await?;
        if !r2.contains("StartService") {
            return Err(IdeviceError::UnexpectedResponse(
                "StartService 响应不匹配".into(),
            ));
        }
        Ok(())
    }

    /// SetWiFiPowerState（pymobiledevice3 profile set-wifi-power 同款请求）
    /// 成功返回设备响应文本；失败返回 IdeviceError。
    pub async fn set_wifi_power(&mut self, state: bool) -> Result<String, IdeviceError> {
        let on = if state { "true" } else { "false" };
        self.send_xml(&format!(
            "{}<dict><key>PowerState</key><{} /><key>RequestType</key>\
             <string>SetWiFiPowerState</string></dict></plist>",
            PLIST_HEADER, on
        ))
        .await?;
        let reply = self.read_plist_xml().await?;
        if reply.contains("<key>Error</key>") {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "SetWiFiPowerState 设备返回 Error: {}",
                reply
            )));
        }
        if reply.starts_with("bplist00") {
            return Err(IdeviceError::UnexpectedResponse(
                "设备返回二进制 plist（暂不支持解析）".into(),
            ));
        }
        Ok(reply)
    }
}

pub struct McInstallClientHandle(pub McInstallClient);

/// 通过 RSD 连接 MCInstall 服务
///
/// # Safety
/// `provider`/`handshake` 必须是本库分配的有效句柄；`client` 必须是非空指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_connect_rsd(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut *mut McInstallClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res: Result<McInstallClient, IdeviceError> = run_sync_local(async move {
        let provider_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        <McInstallClient as idevice::RsdService>::connect_rsd(provider_ref, handshake_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(McInstallClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// 释放 MCInstall 客户端
///
/// # Safety
/// `client` 必须是本库分配的有效句柄，调用后不得再使用。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_client_free(client: *mut McInstallClientHandle) {
    if !client.is_null() {
        drop(Box::from_raw(client));
    }
}

/// SetWiFiPowerState（pymobiledevice3 profile set-wifi-power 同款）
///
/// # Arguments
/// * [`client`] - MCInstall 客户端句柄
/// * [`state`] - true = 开 WiFi，false = 关
/// * [`out_reply`] - 成功时写入设备响应文本（XML）；可为 NULL
///
/// # Safety
/// `client` 必须是有效句柄；`out_reply` 非空时由调用方用 mcinstall_string_free 释放。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_set_wifi_power(
    client: *mut McInstallClientHandle,
    state: bool,
    out_reply: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<String, IdeviceError> =
        run_sync_local(async move { unsafe { &mut (*client) }.0.set_wifi_power(state).await });

    match res {
        Ok(reply) => {
            if !out_reply.is_null() {
                if let Ok(c) = CString::new(reply) {
                    unsafe { *out_reply = c.into_raw() };
                }
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// 释放 mcinstall 返回的字符串
///
/// # Safety
/// `p` 必须是本库分配的字符串指针，调用后不得再使用。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mcinstall_string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
