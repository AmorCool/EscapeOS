// Jackson Coxson

use std::ffi::CString;
use std::ffi::c_char;
use std::ptr::null_mut;

use idevice::IdeviceError;
use idevice::mobileactivationd::MobileActivationdClient;
use idevice::provider::IdeviceProvider;
// v0.3.530：`_rsd` 变体新增的导入（与 mcinstall.rs:19 完全同款）：
// - `Idevice` / `ReadWrite`：把 adapter 连出的流包成 Idevice，用 pub 的
//   `send_raw` / `read_raw` 自组 plist 帧（`send_plist` / `read_plist` 是 crate 私有）
// - `RsdService as _`：匿名导入 trait 才能调 `LockdownClient::connect_rsd`
//   （避免与 crates.io 版同名 trait 冲突）
use idevice::{Idevice, ReadWrite, RsdService as _, lockdown::LockdownClient};

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::{IdeviceFfiError, ffi_err, provider::IdeviceProviderHandle, run_sync_local};

/// lockdown 服务名 —— 与上游 `MobileActivationdInternal::service_name()` 以及
/// 爱思 `idm_aia.dll`（字符串 @`0x014330`）完全一致.
const MOBILEACTIVATIOND_SERVICE: &str = "com.apple.mobileactivationd";

/// Opaque handle wrapping a provider pointer for MobileActivationd.
/// The client is recreated per call since each request requires a new connection.
pub struct MobileActivationdClientHandle {
    provider: *mut IdeviceProviderHandle,
}

/// Creates a new MobileActivationd client handle from a provider
///
/// # Arguments
/// * [`provider`] - An IdeviceProvider (not consumed, must remain valid for the lifetime of the handle)
/// * [`client`] - On success, will be set to point to a newly allocated handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library.
/// The provider must remain valid for the lifetime of the returned handle.
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobileactivationd_connect(
    provider: *mut IdeviceProviderHandle,
    client: *mut *mut MobileActivationdClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || client.is_null() {
        tracing::error!("Null pointer provided");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let boxed = Box::new(MobileActivationdClientHandle { provider });
    unsafe { *client = Box::into_raw(boxed) };
    null_mut()
}

/// Gets the activation state of the device
///
/// # Arguments
/// * `client` - A valid MobileActivationd handle
/// * `state` - On success, will be set to a newly allocated C string with the activation state
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// The returned string must be freed with `idevice_string_free`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobileactivationd_get_state(
    client: *mut MobileActivationdClientHandle,
    state: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if client.is_null() || state.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let provider_ptr = unsafe { (*client).provider };
    let res: Result<String, IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider_ptr).0 };
        let ma_client = MobileActivationdClient::new(provider_ref);
        ma_client.state().await
    });
    match res {
        Ok(s) => match CString::new(s) {
            Ok(c_string) => {
                unsafe { *state = c_string.into_raw() };
                null_mut()
            }
            Err(_) => ffi_err!(IdeviceError::FfiInvalidString),
        },
        Err(e) => ffi_err!(e),
    }
}

/// Checks if the device is activated
///
/// # Arguments
/// * `client` - A valid MobileActivationd handle
/// * `activated` - On success, will be set to true if the device is activated
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobileactivationd_is_activated(
    client: *mut MobileActivationdClientHandle,
    activated: *mut bool,
) -> *mut IdeviceFfiError {
    if client.is_null() || activated.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let provider_ptr = unsafe { (*client).provider };
    let res: Result<bool, IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider_ptr).0 };
        let ma_client = MobileActivationdClient::new(provider_ref);
        ma_client.activated().await
    });
    match res {
        Ok(a) => {
            unsafe { *activated = a };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Deactivates the device
///
/// # Arguments
/// * `client` - A valid MobileActivationd handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobileactivationd_deactivate(
    client: *mut MobileActivationdClientHandle,
) -> *mut IdeviceFfiError {
    if client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let provider_ptr = unsafe { (*client).provider };
    let res: Result<(), IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider_ptr).0 };
        let ma_client = MobileActivationdClient::new(provider_ref);
        ma_client.deactivate().await
    });
    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// v0.3.530：反激活 —— RSD 通道变体（`mobileactivationd_deactivate` 的 RSD 版）.
///
/// ## 为什么需要它
/// 上游 `MobileActivationdClient::new(provider)` 内部走 `IdeviceService::connect(provider)`，
/// 而该默认实现第一步就是 `provider.get_pairing_file()`（lockdown 配对文件）.
/// 本项目手上只有 RpPairingFile（RSD / 无线配对格式），`CDProbe.swift:36-45` 实测
/// `idevice_pairing_file_read` 会报 `failed to parse raw pairing file from bytes`，
/// 所以 provider 那条路在本项目里**永远连不上**，必须走 RSD 隧道.
///
/// ## 协议（与 libimobiledevice `mobileactivation_deactivate()` 逐字一致）
/// 1. `LockdownClient::connect_rsd(adapter, handshake)` —— RSD 上拿 lockdownd
///    （服务名 `com.apple.mobile.lockdown.remote.trusted`）.
/// 2. `start_service("com.apple.mobileactivationd")` —— 拿到隧道内的服务端口.
/// 3. `adapter.connect(port)` —— 在隧道内新开一条流连到该端口（非裸 TCP）.
/// 4. 发**二进制 plist** `{ Command = "DeactivateRequest" }`（4 字节大端长度前缀）.
///    libimobiledevice 用 `property_list_service_send_binary_plist`，
///    与爱思 `idm_aia.dll` 的构造点 `0x18000ca62` 一致.
/// 5. 读回一条 plist 应答；若含 `Error` 键则失败（libimobiledevice 的
///    `mobileactivation_check_result` 同款判定）.
///
/// 注：上游 Rust crate 的 `send_plist` 走 `to_writer_xml`（XML plist），
/// 但 `send_plist` / `read_plist` 是 crate 私有（本仓 `installation_proxy.rs:677` 已实锤 E0624），
/// 所以这里改用 `send_raw` / `read_raw` 自组帧 —— 顺带得以精确对齐
/// libimobiledevice 的**二进制**格式.
///
/// ## ⚠️ 安全警告（本函数只负责发指令，安全闸在上层）
/// 本函数会让设备**变成未激活状态**（回到 Hello / 激活界面）：
/// - 设备**带激活锁**时反激活后必须知道原 Apple ID 密码才能重新激活，**否则变砖**；
/// - 执行前必须关闭设备网络，否则 `mobileactivationd` 会立刻联网重新激活，白做；
/// - 不可逆. 上层 `ActivationService.swift` 已做「ActivationState == Activated」
///   + 「com.apple.fmip.IsAssociated == false」双重前置闸与不可跳过的确认弹窗.
///   **绝对不要在真机上裸调本函数.**
///
/// ## 待真机验证（静态看不出来，未在真机执行过）
/// - `start_service` 是否返回 `EnableServiceSSL = true`：若为 true，标准流程要再做一次
///   TLS 会话（`IdeviceService::connect` 的 `start_session`，需要 lockdown 配对文件，
///   本项目没有）. 这里按 `mcinstall.rs:446` 的先例**直接报错拒绝**，不静默降级 ——
///   USB / RSD 下通常不返回该键（上游注释：over USB, this option won't exist），
///   大概率不会命中.
/// - `start_service` 是否需要先 `lockdownd_start_session`：上游 `LockdownClient::start_service`
///   不检查 session，本仓 `lockdownd_get_value` 无 session 也能通；若真机回 `SessionInactive`，
///   需另找会话来源（我们没有 lockdown 配对文件）.
/// - 应答：libimobiledevice 会 `receive_plist` 读一条应答，读不到即 PLIST_ERROR；
///   但上游 Rust crate 的注释说「Deactivate 可能不给应答」. 本实现按 libimobiledevice
///   走「必须有应答」，若真机实测无应答，改成「超时即当成功 + 复查 `ActivationState`」.
///
/// # Arguments
/// * [`adapter`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `adapter` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobileactivationd_deactivate_rsd(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<(), IdeviceError> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        // 1) RSD 上拿 lockdownd（com.apple.mobile.lockdown.remote.trusted）
        let mut lockdown = LockdownClient::connect_rsd(adapter_ref, handshake_ref).await?;

        // 2) StartService("com.apple.mobileactivationd") → (端口, 是否需要 SSL)
        let (port, ssl) = lockdown.start_service(MOBILEACTIVATIOND_SERVICE).await?;
        if ssl {
            // 需要 TLS 会话，但我们没有 lockdown 配对文件、无法 start_session.
            // 不静默降级：宁可报错，也不要在「半安全」的通道上发不可逆指令.
            return Err(IdeviceError::UnexpectedResponse(
                "com.apple.mobileactivationd 要求 SSL 会话（EnableServiceSSL），本通道不支持".into(),
            ));
        }

        // 3) 隧道内新开一条流连到该端口（与 mcinstall.rs:452 同款；
        //    lockdownd 启动的服务无需 RSDCheckin）
        let stream: Box<dyn ReadWrite> = Box::new(adapter_ref.connect(port).await?);
        let mut dev = Idevice::new(stream, MOBILEACTIVATIOND_SERVICE);

        // 4) 发二进制 plist：4 字节大端长度前缀 + 二进制 plist 体
        //    （= libimobiledevice `property_list_service_send_binary_plist` 的线格式）
        let mut req = plist::Dictionary::new();
        req.insert(
            "Command".to_string(),
            plist::Value::String("DeactivateRequest".to_string()),
        );
        let mut body: Vec<u8> = Vec::new();
        plist::to_writer_binary(&mut body, &plist::Value::Dictionary(req)).map_err(|e| {
            IdeviceError::UnexpectedResponse(format!("序列化 DeactivateRequest 失败: {e}"))
        })?;
        let mut frame = Vec::with_capacity(4 + body.len());
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(&body);
        dev.send_raw(&frame).await?;

        // 5) 读回应答（同样 4 字节大端长度前缀），并检查 Error 键
        let len_buf = dev.read_raw(4).await?;
        let len = u32::from_be_bytes([len_buf[0], len_buf[1], len_buf[2], len_buf[3]]) as usize;
        if len == 0 || len > 8 * 1024 * 1024 {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "DeactivateRequest 应答长度异常: {len}"
            )));
        }
        let reply = dev.read_raw(len).await?;
        let value: plist::Value = plist::from_bytes(&reply).map_err(|e| {
            IdeviceError::UnexpectedResponse(format!("DeactivateRequest 应答解析失败: {e}"))
        })?;
        let dict = match value {
            plist::Value::Dictionary(d) => d,
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "DeactivateRequest 应答不是字典".into(),
                ));
            }
        };
        if let Some(e) = dict.get("Error") {
            let msg = match e {
                plist::Value::String(s) => s.clone(),
                other => format!("{other:?}"),
            };
            return Err(IdeviceError::UnexpectedResponse(format!(
                "mobileactivationd 拒绝 DeactivateRequest: {msg}"
            )));
        }
        Ok(())
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Frees a MobileActivationd client handle
///
/// # Arguments
/// * [`handle`] - The handle to free
///
/// # Safety
/// `handle` must be a valid pointer to the handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobileactivationd_client_free(handle: *mut MobileActivationdClientHandle) {
    if !handle.is_null() {
        tracing::debug!("Freeing MobileActivationdClientHandle");
        let _ = unsafe { Box::from_raw(handle) };
    }
}
