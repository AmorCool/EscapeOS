// Jackson Coxson

use std::ptr::null_mut;

use idevice::{
    Idevice, IdeviceError, IdeviceService, ReadWrite, RsdService as _, lockdown::LockdownClient,
    provider::IdeviceProvider,
};
use plist_ffi::plist_t;

use crate::{
    IdeviceFfiError, IdeviceHandle, IdevicePairingFile, core_device_proxy::AdapterHandle, ffi_err,
    provider::IdeviceProviderHandle, rsd::RsdHandshakeHandle, run_sync_local,
};

pub struct LockdowndClientHandle(pub LockdownClient);

/// Connects to lockdownd service using provider
///
/// # Arguments
/// * [`provider`] - An IdeviceProvider
/// * [`client`] - On success, will be set to point to a newly allocated LockdowndClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_connect(
    provider: *mut IdeviceProviderHandle,
    client: *mut *mut LockdowndClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || client.is_null() {
        tracing::error!("Null pointer provided");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<LockdownClient, IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider).0 };
        LockdownClient::connect(provider_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(LockdowndClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => {
            let _ = unsafe { Box::from_raw(provider) };
            ffi_err!(e)
        }
    }
}

/// Creates a new LockdownClient via RSD
///
/// # Arguments
/// * [`provider`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
/// * [`client`] - On success, will be set to point to a newly allocated LockdownClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_connect_rsd(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut *mut LockdowndClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res: Result<LockdownClient, IdeviceError> = run_sync_local(async move {
        let provider_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        LockdownClient::connect_rsd(provider_ref, handshake_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(LockdowndClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Creates a new LockdownClient via RSD using an **explicitly named** RSD service.
///
/// ## 为什么需要它
/// 上游 `idevice` crate 里 `LockdownClient` 实现的 `RsdService::rsd_service_name()` **写死**
/// 为 `com.apple.mobile.lockdown.remote.trusted`（受信版），该常量在 crate 内部，外部无法
/// 覆盖 —— `lockdownd_connect_rsd` 走的就是它。本函数把服务名**参数化**，让调用方能改连
/// `com.apple.mobile.lockdown.remote.untrusted`（未受信版；RSD 服务表里给「尚未配对的对端」
/// 用的那条，见 pymobiledevice3 `misc/RemoteXPC.md`）。
///
/// ## 实现范式（照 `mobileactivationd_deactivate_rsd` 的「RSD 服务表查表」路线）
/// RSD 通道**不支持** lockdownd 的 `StartService` RPC（本项目 v0.3.414~417 真机实证：
/// 设备对 StartService 直接关连接 ⇒ `BrokenPipe`），所以不能复用 `connect_rsd` 内部那条
/// `RsdHandshake::connect::<LockdownClient>`，必须自己走四步：
/// 1. RSD 服务表**本地查表**拿端口（按调用方给的服务名，不发 StartService）。
/// 2. `adapter.connect(port)` —— 在隧道内新开一条流（非裸 TCP）。
/// 3. `Idevice::new(stream, service_name)` + `rsd_checkin()` —— RSD 语义下的启动握手
///    （不发它设备会直接关连接；与上游 `from_stream` 逐句同构）。
/// 4. `LockdownClient::new(dev)` —— 包成 lockdown 客户端，此后 `lockdownd_pair` /
///    `lockdownd_get_value` 等既有 FFI 均可直接作用其上。
///
/// 端口**不硬编码**：一律从设备回的服务表里取（不同 iOS 版本可能不同；文档里的 52288
/// 只是一个参考值）。服务名不在表里时返回可定位的错误（列出表内含 "lockdown" 的服务名）。
///
/// # Arguments
/// * [`provider`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
/// * [`service_name`] - The RSD service name to connect to (null-terminated string),
///   e.g. `com.apple.mobile.lockdown.remote.untrusted`
/// * [`client`] - On success, will be set to point to a newly allocated LockdownClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
/// `service_name` must be a valid null-terminated string
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_connect_rsd_named(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    service_name: *const libc::c_char,
    client: *mut *mut LockdowndClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || service_name.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let service_name = match unsafe { std::ffi::CStr::from_ptr(service_name) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    let res: Result<LockdownClient, IdeviceError> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        // 1) RSD 服务表本地查表拿端口 —— 不发 lockdownd 的 StartService RPC.
        let port = match handshake_ref.services.get(&service_name) {
            Some(s) => s.port,
            None => {
                let mut related: Vec<String> = handshake_ref
                    .services
                    .keys()
                    .filter(|k| k.to_ascii_lowercase().contains("lockdown"))
                    .cloned()
                    .collect();
                related.sort();
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[lockdown配对][步骤1-服务表] RSD 服务表里找不到 {service_name}\
                     （表内共 {} 个服务；含 lockdown 的: {:?}）",
                    handshake_ref.services.len(),
                    related
                )));
            }
        };
        tracing::info!("lockdownd_connect_rsd_named: RSD 服务表命中 {service_name}, port={port}");

        // 2) 隧道内新开一条流连到该端口.
        let stream: Box<dyn ReadWrite> = match adapter_ref.connect(port).await {
            Ok(s) => Box::new(s),
            Err(e) => {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "[lockdown配对][步骤2-connect] adapter.connect({port}) 失败\
                     （服务 {service_name}）: {e:?}"
                )));
            }
        };

        // 3) RSDCheckin —— RSD 语义下真正的「启动服务」；与上游 `from_stream` 同构
        //    （`Idevice::new(stream, "")` + `rsd_checkin()`）。
        let mut dev = Idevice::new(stream, "");
        if let Err(e) = dev.rsd_checkin().await {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "[lockdown配对][步骤3-RSDCheckin] rsd_checkin 失败（服务 {service_name}）: {e:?}"
            )));
        }

        // 4) 包成 lockdown 客户端.
        Ok(LockdownClient::new(dev))
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(LockdowndClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Creates a new LockdowndClient from an existing Idevice connection
///
/// # Arguments
/// * [`socket`] - An IdeviceSocket handle.
/// * [`client`] - On success, will be set to point to a newly allocated LockdowndClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `socket` must be a valid pointer to a handle allocated by this library. The socket is consumed,
/// and maybe not be used again.
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_new(
    socket: *mut IdeviceHandle,
    client: *mut *mut LockdowndClientHandle,
) -> *mut IdeviceFfiError {
    if socket.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let socket = unsafe { Box::from_raw(socket) }.0;
    let r = LockdownClient::new(socket);
    let boxed = Box::new(LockdowndClientHandle(r));
    unsafe { *client = Box::into_raw(boxed) };
    null_mut()
}

/// Starts a session with lockdownd
///
/// # Arguments
/// * `client` - A valid LockdowndClient handle
/// * `pairing_file` - An IdevicePairingFile alocated by this library
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `pairing_file` must be a valid plist_t containing a pairing file
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_start_session(
    client: *mut LockdowndClientHandle,
    pairing_file: *mut IdevicePairingFile,
) -> *mut IdeviceFfiError {
    let res: Result<_, IdeviceError> = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };
        let pairing_file_ref = unsafe { &(*pairing_file).0 };

        client_ref.start_session(pairing_file_ref).await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Starts a service through lockdownd
///
/// # Arguments
/// * `client` - A valid LockdowndClient handle
/// * `identifier` - The service identifier to start (null-terminated string)
/// * `port` - Pointer to store the returned port number
/// * `ssl` - Pointer to store whether SSL should be enabled
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `identifier` must be a valid null-terminated string
/// `port` and `ssl` must be valid pointers
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_start_service(
    client: *mut LockdowndClientHandle,
    identifier: *const libc::c_char,
    port: *mut u16,
    ssl: *mut bool,
) -> *mut IdeviceFfiError {
    if identifier.is_null() || port.is_null() || ssl.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let identifier = unsafe { std::ffi::CStr::from_ptr(identifier) }
        .to_string_lossy()
        .into_owned();

    let res: Result<(u16, bool), IdeviceError> = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };
        client_ref.start_service(identifier).await
    });

    match res {
        Ok((p, s)) => {
            unsafe {
                *port = p;
                *ssl = s;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Pairs with the device using lockdownd
///
/// # Arguments
/// * `client` - A valid LockdowndClient handle
/// * `host_id` - The host ID (null-terminated string)
/// * `system_buid` - The system BUID (null-terminated string)
/// * `pairing_file` - On success, will be set to point to a newly allocated IdevicePairingFile handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `host_id` must be a valid null-terminated string
/// `system_buid` must be a valid null-terminated string
/// `pairing_file` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
#[cfg(feature = "pair")]
pub unsafe extern "C" fn lockdownd_pair(
    client: *mut LockdowndClientHandle,
    host_id: *const libc::c_char,
    system_buid: *const libc::c_char,
    host_name: *const libc::c_char,
    pairing_file: *mut *mut IdevicePairingFile,
) -> *mut IdeviceFfiError {
    if client.is_null() || host_id.is_null() || system_buid.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let host_id = unsafe {
        std::ffi::CStr::from_ptr(host_id)
            .to_string_lossy()
            .into_owned()
    };
    let system_buid = unsafe {
        std::ffi::CStr::from_ptr(system_buid)
            .to_string_lossy()
            .into_owned()
    };

    let host_name = if host_name.is_null() {
        None
    } else {
        Some(
            match unsafe { std::ffi::CStr::from_ptr(host_name) }.to_str() {
                Ok(v) => v,
                Err(_) => {
                    return ffi_err!(IdeviceError::FfiInvalidString);
                }
            },
        )
    };

    let res = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };

        client_ref.pair(host_id, system_buid, host_name).await
    });

    match res {
        Ok(pairing_file_res) => {
            let boxed_pairing_file = Box::new(IdevicePairingFile(pairing_file_res));
            unsafe { *pairing_file = Box::into_raw(boxed_pairing_file) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Gets a value from lockdownd
///
/// # Arguments
/// * `client` - A valid LockdowndClient handle
/// * `key` - The value to get (null-terminated string)
/// * `domain` - The value to get (null-terminated string)
/// * `out_plist` - Pointer to store the returned plist value
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `value` must be a valid null-terminated string
/// `out_plist` must be a valid pointer to store the plist
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_get_value(
    client: *mut LockdowndClientHandle,
    key: *const libc::c_char,
    domain: *const libc::c_char,
    out_plist: *mut plist_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_plist.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let value = if key.is_null() {
        None
    } else {
        Some(match unsafe { std::ffi::CStr::from_ptr(key) }.to_str() {
            Ok(v) => v,
            Err(_) => {
                return ffi_err!(IdeviceError::FfiInvalidString);
            }
        })
    };

    let domain = if domain.is_null() {
        None
    } else {
        Some(match unsafe { std::ffi::CStr::from_ptr(domain) }.to_str() {
            Ok(v) => v,
            Err(_) => {
                return ffi_err!(IdeviceError::FfiInvalidString);
            }
        })
    };

    let res: Result<plist::Value, IdeviceError> = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };
        client_ref.get_value(value, domain).await
    });

    match res {
        Ok(value) => {
            unsafe {
                *out_plist = plist_ffi::PlistWrapper::new_node(value).into_ptr();
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Tells the device to enter recovery mode
///
/// # Arguments
/// * `client` - A valid LockdowndClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_enter_recovery(
    client: *mut LockdowndClientHandle,
) -> *mut IdeviceFfiError {
    if client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<(), IdeviceError> = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };
        client_ref.enter_recovery().await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Sets a value in lockdownd  
///  
/// # Arguments  
/// * `client` - A valid LockdowndClient handle  
/// * `key` - The key to set (null-terminated string)  
/// * `value` - The value to set as a plist  
/// * `domain` - The domain to set in (null-terminated string, optional)  
///  
/// # Returns  
/// An IdeviceFfiError on error, null on success  
///  
/// # Safety  
/// `client` must be a valid pointer to a handle allocated by this library  
/// `key` must be a valid null-terminated string  
/// `value` must be a valid plist  
/// `domain` must be a valid null-terminated string or NULL  
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_set_value(
    client: *mut LockdowndClientHandle,
    key: *const libc::c_char,
    value: plist_t,
    domain: *const libc::c_char,
) -> *mut IdeviceFfiError {
    if client.is_null() || key.is_null() || value.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let key = match unsafe { std::ffi::CStr::from_ptr(key) }.to_str() {
        Ok(k) => k,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    let domain = if domain.is_null() {
        None
    } else {
        Some(match unsafe { std::ffi::CStr::from_ptr(domain) }.to_str() {
            Ok(d) => d,
            Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
        })
    };

    let value = unsafe { &mut *value }.borrow_self().clone();

    let res: Result<(), IdeviceError> = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };
        client_ref.set_value(key, value, domain).await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Frees a LockdowndClient handle
///
/// # Arguments
/// * [`handle`] - The handle to free
///
/// # Safety
/// `handle` must be a valid pointer to the handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lockdownd_client_free(handle: *mut LockdowndClientHandle) {
    if !handle.is_null() {
        tracing::debug!("Freeing lockdownd_client");
        let _ = unsafe { Box::from_raw(handle) };
    }
}
