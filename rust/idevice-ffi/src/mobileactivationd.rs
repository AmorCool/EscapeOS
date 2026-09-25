// Jackson Coxson

use std::ffi::CString;
use std::ffi::c_char;
use std::ptr::null_mut;

use idevice::IdeviceError;
use idevice::mobileactivationd::MobileActivationdClient;
use idevice::provider::IdeviceProvider;
// v0.3.531：`_rsd` 变体改走「RSD 服务表 + adapter_connect + RSDCheckin」后的导入
// （与 mcinstall.rs:19 完全同款）：
// - `Idevice` / `ReadWrite`：把 adapter 连出的流包成 Idevice，用 pub 的
//   `send_raw` / `read_raw` 自组 plist 帧（`send_plist` / `read_plist` 是 crate 私有），
//   并用 pub 的 `rsd_checkin` 做 RSD 语义下的服务启动握手.
// 注：不再需要 `RsdService as _` / `lockdown::LockdownClient` ——
// 新路线不发 lockdownd 的 StartService RPC（RSD 通道不支持它）.
use idevice::{Idevice, ReadWrite};

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::{IdeviceFfiError, ffi_err, provider::IdeviceProviderHandle, run_sync_local};

/// lockdown 服务名 —— 与上游 `MobileActivationdInternal::service_name()` 以及
/// 爱思 `idm_aia.dll`（字符串 @`0x014330`）完全一致.
const MOBILEACTIVATIOND_SERVICE: &str = "com.apple.mobileactivationd";

/// RSD 服务表里的 `.shim.remote` 变体 —— RSD 广播名通常带此后缀
/// （先例：`com.apple.mobile.MCInstall.shim.remote`，见 mcinstall.rs:37）.
/// 待真机验证：服务表里到底登记的是标准名还是此后缀变体.
const MOBILEACTIVATIOND_SERVICE_SHIM: &str = "com.apple.mobileactivationd.shim.remote";

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

/// v0.3.531：反激活 —— RSD 通道变体（`mobileactivationd_deactivate` 的 RSD 版）.
///
/// ## 为什么需要它
/// 上游 `MobileActivationdClient::new(provider)` 内部走 `IdeviceService::connect(provider)`，
/// 而该默认实现第一步就是 `provider.get_pairing_file()`（lockdown 配对文件）.
/// 本项目手上只有 RpPairingFile（RSD / 无线配对格式），`CDProbe.swift:36-45` 实测
/// `idevice_pairing_file_read` 会报 `failed to parse raw pairing file from bytes`，
/// 所以 provider 那条路在本项目里**永远连不上**，必须走 RSD 隧道.
///
/// ## v0.3.531 修了什么（v0.3.530 真机失败根因）
/// v0.3.530 用的是 `LockdownClient::connect_rsd` → `lockdown.start_service(...)`，
/// 真机回 `Socket(Custom { kind: BrokenPipe, error: "channel closed" })`.
/// 三个独立诊断 agent 收敛到同一结论：**RSD 通道不支持 lockdownd 的 StartService RPC**
/// （本项目 v0.3.414~417 真机实证：连「已知可用」的 `com.apple.afc` 也回同一个错；
/// pymobiledevice3 的 RSD 实现从设计上就绕开 StartService）.
/// 设备对这条 RPC 直接关连接 ⇒ `jktcp` 用户态 TCP 栈任务退出 ⇒ 下一次 I/O 报
/// `BrokenPipe("channel closed")`.
///
/// ## 协议（= 项目已在生产跑通的 `mcinstall_set_wifi_power_rsd` 同款范式）
/// 1. RSD 服务表**本地查表**拿端口（先标准名，再 `.shim.remote` 变体）—— 不发 StartService.
/// 2. `adapter.connect(port)` —— 在隧道内新开一条流连到该端口（非裸 TCP）.
/// 3. `Idevice::rsd_checkin()` —— RSD 语义下真正的「启动服务」；
///    **不发它设备会直接关连接**（v0.3.465 已定案）. 该调用发 XML plist
///    `{Label, ProtocolVersion:"2", Request:"RSDCheckin"}` 并读两条应答
///    （`Request == RSDCheckin` / `Request == StartService`）.
/// 4. 发**二进制 plist** `{ Command = "DeactivateRequest" }`（4 字节大端长度前缀）.
///    libimobiledevice 用 `property_list_service_send_binary_plist`，
///    与爱思 `idm_aia.dll` 的构造点 `0x18000ca62` 一致.
/// 5. 读回一条 plist 应答；若含 `Error` 键则失败（libimobiledevice 的
///    `mobileactivation_check_result` 同款判定）.
///
/// 注：上游 Rust crate 的 `send_plist` 走 `to_writer_xml`（XML plist），
/// 但 `send_plist` / `read_plist` 是 crate 私有（本仓 `installation_proxy.rs:677` 已实锤 E0624），
/// 所以第 4/5 步改用 `send_raw` / `read_raw` 自组帧 —— 顺带得以精确对齐
/// libimobiledevice 的**二进制**格式（`mobileactivationd` 要的是二进制 plist）.
///
/// ## 分步诊断（v0.3.531 新增，三个诊断 agent 一致的第一建议）
/// v0.3.530 所有失败都塌成同一个 `BrokenPipe`，等于在猜. 现在每一步失败都用
/// **不同的文案前缀**区分（`[反激活诊断][步骤N-…]`），一次真机即可定案：
/// 步骤1-服务表 / 步骤2-connect / 步骤3-RSDCheckin / 步骤4-发送 /
/// 步骤5-读应答 / 步骤6-解析 / 步骤7-设备拒绝.
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
/// - **服务表里到底登记的是哪个名字**：标准名 `com.apple.mobileactivationd`
///   还是 `.shim.remote` 变体 —— 静态查不到，只能真机看步骤1的报错文案
///   （文案里会列出表内含 "activation" 的服务名）.
/// - **该服务是否需要 RSDCheckin**：本实现按 RSD 正解一律先 `rsd_checkin`
///   （pymobiledevice3 的 RSD 路每条连接都做；本项目 `.shim.remote` 服务已实证
///   「不发 RSDCheckin 设备直接关连接」）. 若真机在步骤3报错，说明该服务不吃
///   RSDCheckin，需改成「connect 后直发指令」.
/// - **应答**：libimobiledevice 会 `receive_plist` 读一条应答，读不到即 PLIST_ERROR；
///   但上游 Rust crate 的注释说「Deactivate 可能不给应答」. 本实现按 libimobiledevice
///   走「必须有应答」（三份参照全都期待应答，上游注释被诊断 agent 认定为误导），
///   若真机实测无应答（步骤5超时），改成「超时即当成功 + 复查 `ActivationState`」.
/// - **SSL**：新路线不发 StartService，故无 `EnableServiceSSL` 应答；
///   RSD 服务在 pymobiledevice3 里被硬编码为 `EnableServiceSSL: False`，
///   本项目全部 RSD 服务（AFC/DVT/MCInstall）也都不做 TLS. 本实现不做 TLS.
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

        // 1) RSD 服务表**本地查表**拿端口 —— 不发 lockdownd 的 StartService RPC
        //    （RSD 通道不支持它，v0.3.414~417 真机实证）.
        //    先试标准名，再试 `.shim.remote` 变体（待真机验证登记的是哪个）.
        let svc_name = if handshake_ref.services.contains_key(MOBILEACTIVATIOND_SERVICE) {
            MOBILEACTIVATIOND_SERVICE
        } else if handshake_ref
            .services
            .contains_key(MOBILEACTIVATIOND_SERVICE_SHIM)
        {
            MOBILEACTIVATIOND_SERVICE_SHIM
        } else {
            // 步骤1：服务表里查不到 —— 把含 "activation" 的服务名列出来帮助定位.
            let mut related: Vec<String> = handshake_ref
                .services
                .keys()
                .filter(|k| k.to_ascii_lowercase().contains("activation"))
                .cloned()
                .collect();
            related.sort();
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[反激活诊断][步骤1-服务表] RSD 服务表里找不到 {MOBILEACTIVATIOND_SERVICE} \
                 或 {MOBILEACTIVATIOND_SERVICE_SHIM}（表内共 {} 个服务；含 activation 的: {:?}）",
                handshake_ref.services.len(),
                related
            )));
        };
        let port = match handshake_ref.services.get(svc_name) {
            Some(s) => s.port,
            None => {
                // 理论不可达（上面刚 contains_key 过）；避免索引 panic 跨 FFI.
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[反激活诊断][步骤1-服务表] 服务 {svc_name} 查表命中后取值失败"
                )));
            }
        };
        tracing::info!(
            "mobileactivationd_deactivate_rsd: RSD 服务表命中 {svc_name}, port={port}"
        );

        // 2) 隧道内新开一条流连到该端口（与 mcinstall.rs:262 同款）.
        let stream: Box<dyn ReadWrite> = match adapter_ref.connect(port).await {
            Ok(s) => Box::new(s),
            Err(e) => {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[反激活诊断][步骤2-connect] adapter.connect({port}) 失败\
                     （服务 {svc_name}）: {e:?}"
                )));
            }
        };
        let mut dev = Idevice::new(stream, MOBILEACTIVATIOND_SERVICE);

        // 3) RSDCheckin —— RSD 语义下真正的「启动服务」，不发设备会直接关连接
        //    （v0.3.465 已定案）. 与 mcinstall.rs:263 同款.
        if let Err(e) = dev.rsd_checkin().await {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[反激活诊断][步骤3-RSDCheckin] rsd_checkin 失败（服务 {svc_name}）: {e:?}"
            )));
        }

        // 4) 发二进制 plist：4 字节大端长度前缀 + 二进制 plist 体
        //    （= libimobiledevice `property_list_service_send_binary_plist` 的线格式）.
        let mut req = plist::Dictionary::new();
        req.insert(
            "Command".to_string(),
            plist::Value::String("DeactivateRequest".to_string()),
        );
        let mut body: Vec<u8> = Vec::new();
        if let Err(e) = plist::to_writer_binary(&mut body, &plist::Value::Dictionary(req)) {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[反激活诊断][步骤4-发送] 序列化 DeactivateRequest 失败: {e}"
            )));
        }
        let mut frame = Vec::with_capacity(4 + body.len());
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(&body);
        if let Err(e) = dev.send_raw(&frame).await {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[反激活诊断][步骤4-发送] 发送 DeactivateRequest 失败: {e:?}"
            )));
        }

        // 5) 读回应答（同样 4 字节大端长度前缀），并检查 Error 键.
        let len_buf = match dev.read_raw(4).await {
            Ok(b) => b,
            Err(e) => {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[反激活诊断][步骤5-读应答] 读取应答长度失败: {e:?}"
                )));
            }
        };
        let len = u32::from_be_bytes([len_buf[0], len_buf[1], len_buf[2], len_buf[3]]) as usize;
        if len == 0 || len > 8 * 1024 * 1024 {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[反激活诊断][步骤5-读应答] 应答长度异常: {len}"
            )));
        }
        let reply = match dev.read_raw(len).await {
            Ok(b) => b,
            Err(e) => {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[反激活诊断][步骤5-读应答] 读取应答体失败（长度 {len}）: {e:?}"
                )));
            }
        };
        let value: plist::Value = match plist::from_bytes(&reply) {
            Ok(v) => v,
            Err(e) => {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[反激活诊断][步骤6-解析] DeactivateRequest 应答解析失败: {e}"
                )));
            }
        };
        let dict = match value {
            plist::Value::Dictionary(d) => d,
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "[反激活诊断][步骤6-解析] DeactivateRequest 应答不是字典".into(),
                ));
            }
        };
        if let Some(e) = dict.get("Error") {
            let msg = match e {
                plist::Value::String(s) => s.clone(),
                other => format!("{other:?}"),
            };
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[反激活诊断][步骤7-设备拒绝] mobileactivationd 拒绝 DeactivateRequest: {msg}"
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
