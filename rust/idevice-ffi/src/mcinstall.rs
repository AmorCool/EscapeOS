//! MCInstall 客户端绑定（v0.3.102）
//!
//! `com.apple.mobile.MCInstall`（RSD: `com.apple.mobile.MCInstall.shim.remote`）
//! —— 走 RSD 隧道发送 `SetWiFiPowerState`（pymobiledevice3
//! `profile set-wifi-power` 同款请求），供 Lua 宿主 host.wifi_power 控制射频。
//! App 无 wifi entitlement，直调 MobileWiFi 是空操作 → 必须经设备自己的服务。

use std::ffi::{CStr, CString};
use std::ptr::null_mut;

use idevice::{Idevice, IdeviceError, IdeviceService, RsdService, ReadWrite};

use crate::{
    IdeviceFfiError, core_device_proxy::AdapterHandle, ffi_err, provider::IdeviceProviderHandle,
    rsd::RsdHandshakeHandle, run_sync_local,
};

/// MCInstall 服务客户端（com.apple.mobile.MCInstall）
pub struct McInstallClient {
    /// 底层设备连接（已建立 MCInstall 服务会话）
    pub idevice: Idevice,
}

impl McInstallClient {
    pub fn new(idevice: Idevice) -> Self {
        Self { idevice }
    }

    /// SetWiFiPowerState（pymobiledevice3 profile set-wifi-power 同款请求）
    /// 成功返回设备响应文本；失败返回 IdeviceError。
    pub async fn set_wifi_power(&mut self, state: bool) -> Result<String, IdeviceError> {
        let mut dict = plist::Dictionary::new();
        dict.insert(
            "RequestType".into(),
            plist::Value::String("SetWiFiPowerState".into()),
        );
        dict.insert("PowerState".into(), plist::Value::Boolean(state));
        self.idevice
            .send_plist(plist::Value::Dictionary(dict))
            .await?;
        let mut res = self.idevice.read_plist().await?;
        if let Some(err) = res.remove("Error") {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "SetWiFiPowerState Error: {:?}",
                err
            )));
        }
        Ok(format!("{:?}", res))
    }
}

#[cfg(feature = "rsd")]
impl RsdService for McInstallClient {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        std::borrow::Cow::Borrowed("com.apple.mobile.MCInstall.shim.remote")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let mut idevice = Idevice::new(stream, "EscapeSpaceMCInstall");
        idevice.rsd_checkin().await?;
        Ok(Self::new(idevice))
    }
}

impl IdeviceService for McInstallClient {
    fn service_name() -> std::borrow::Cow<'static, str> {
        std::borrow::Cow::Borrowed("com.apple.mobile.MCInstall")
    }

    #[allow(async_fn_in_trait)]
    async fn from_stream(idevice: Idevice) -> Result<Self, IdeviceError> {
        Ok(Self::new(idevice))
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
        McInstallClient::connect_rsd(provider_ref, handshake_ref).await
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
/// * [`out_reply`] - 成功时写入设备响应文本；可为 NULL
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

/// 从 C 字符串安全读取（供本模块使用）
fn cstr_to_string(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
