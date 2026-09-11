// Jackson Coxson

use std::{ffi::c_void, ptr::null_mut};

use idevice::{
    IdeviceError, IdeviceService, RsdService, installation_proxy::InstallationProxyClient,
    provider::IdeviceProvider,
};
use plist_ffi::{PlistWrapper, plist_t};

use crate::{
    IdeviceFfiError, IdeviceHandle, core_device_proxy::AdapterHandle, ffi_err,
    provider::IdeviceProviderHandle, rsd::RsdHandshakeHandle, run_sync_local,
};

pub struct InstallationProxyClientHandle(pub InstallationProxyClient);

/// Automatically creates and connects to Installation Proxy, returning a client handle
///
/// # Arguments
/// * [`provider`] - An IdeviceProvider
/// * [`client`] - On success, will be set to point to a newly allocated InstallationProxyClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_connect(
    provider: *mut IdeviceProviderHandle,
    client: *mut *mut InstallationProxyClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || client.is_null() {
        tracing::error!("Null pointer provided");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<InstallationProxyClient, IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider).0 };
        InstallationProxyClient::connect(provider_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(InstallationProxyClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Creates a new InstallationProxyClient via RSD
///
/// # Arguments
/// * [`provider`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
/// * [`client`] - On success, will be set to point to a newly allocated InstallationProxyClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_connect_rsd(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut *mut InstallationProxyClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res: Result<InstallationProxyClient, IdeviceError> = run_sync_local(async move {
        let provider_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        InstallationProxyClient::connect_rsd(provider_ref, handshake_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(InstallationProxyClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Automatically creates and connects to Installation Proxy, returning a client handle
///
/// # Arguments
/// * [`socket`] - An IdeviceSocket handle
/// * [`client`] - On success, will be set to point to a newly allocated InstallationProxyClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `socket` must be a valid pointer to a handle allocated by this library. The socket is consumed,
/// and may not be used again.
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_new(
    socket: *mut IdeviceHandle,
    client: *mut *mut InstallationProxyClientHandle,
) -> *mut IdeviceFfiError {
    if socket.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let socket = unsafe { Box::from_raw(socket) }.0;
    let r = InstallationProxyClient::new(socket);
    let boxed = Box::new(InstallationProxyClientHandle(r));
    unsafe { *client = Box::into_raw(boxed) };
    null_mut()
}

/// Gets installed apps on the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`application_type`] - The application type to filter by (optional, NULL for "Any")
/// * [`bundle_identifiers`] - The identifiers to filter by (optional, NULL for all apps)
/// * [`out_result`] - On success, will be set to point to a newly allocated array of PlistRef
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `out_result` must be a valid, non-null pointer to a location where the result will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_get_apps(
    client: *mut InstallationProxyClientHandle,
    application_type: *const libc::c_char,
    bundle_identifiers: *const *const libc::c_char,
    bundle_identifiers_len: libc::size_t,
    out_result: *mut *mut c_void,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {out_result:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    let app_type = if application_type.is_null() {
        None
    } else {
        Some(
            match unsafe { std::ffi::CStr::from_ptr(application_type) }.to_str() {
                Ok(a) => a,
                Err(_) => {
                    return ffi_err!(IdeviceError::FfiInvalidString);
                }
            },
        )
    };

    let bundle_ids = if bundle_identifiers.is_null() {
        None
    } else {
        let ids = unsafe { std::slice::from_raw_parts(bundle_identifiers, bundle_identifiers_len) };
        Some(
            ids.iter()
                .map(|&s| {
                    unsafe { std::ffi::CStr::from_ptr(s) }
                        .to_string_lossy()
                        .to_string()
                })
                .collect::<Vec<String>>(),
        )
    };

    let res: Result<Vec<plist_t>, IdeviceError> = run_sync_local(async {
        client.0.get_apps(app_type, bundle_ids).await.map(|apps| {
            apps.into_values()
                .map(|v| PlistWrapper::new_node(v).into_ptr())
                .collect()
        })
    });

    match res {
        Ok(r) => {
            let mut r = r.into_boxed_slice();
            let ptr = r.as_mut_ptr();
            let len = r.len();
            std::mem::forget(r);

            unsafe {
                *out_result = ptr as *mut c_void;
                *out_result_len = len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Frees a handle
///
/// # Arguments
/// * [`handle`] - The handle to free
///
/// # Safety
/// `handle` must be a valid pointer to the handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_client_free(
    handle: *mut InstallationProxyClientHandle,
) {
    if !handle.is_null() {
        tracing::debug!("Freeing installation_proxy_client");
        let _ = unsafe { Box::from_raw(handle) };
    }
}

/// Installs an application package on the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`package_path`] - Path to the .ipa package in the AFC jail
/// * [`options`] - Optional installation options as a plist dictionary (can be NULL)
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `package_path` must be a valid C string
/// `options` must be a valid plist dictionary or NULL
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_install(
    client: *mut InstallationProxyClientHandle,
    package_path: *const libc::c_char,
    options: plist_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || package_path.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let package_path = unsafe { std::ffi::CStr::from_ptr(package_path) }
        .to_string_lossy()
        .into_owned();
    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        unsafe { &mut *client }
            .0
            .install(package_path, options)
            .await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Installs an application package on the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`package_path`] - Path to the .ipa package in the AFC jail
/// * [`options`] - Optional installation options as a plist dictionary (can be NULL)
/// * [`callback`] - Progress callback function
/// * [`context`] - User context to pass to callback
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `package_path` must be a valid C string
/// `options` must be a valid plist dictionary or NULL
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_install_with_callback(
    client: *mut InstallationProxyClientHandle,
    package_path: *const libc::c_char,
    options: plist_t,
    callback: extern "C" fn(progress: u64, context: *mut c_void),
    context: *mut c_void,
) -> *mut IdeviceFfiError {
    if client.is_null() || package_path.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let package_path = unsafe { std::ffi::CStr::from_ptr(package_path) }
        .to_string_lossy()
        .into_owned();
    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        let callback_wrapper = |(progress, context)| async move {
            callback(progress, context);
        };

        unsafe { &mut *client }
            .0
            .install_with_callback(package_path, options, callback_wrapper, context)
            .await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Upgrades an existing application on the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`package_path`] - Path to the .ipa package in the AFC jail
/// * [`options`] - Optional upgrade options as a plist dictionary (can be NULL)
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `package_path` must be a valid C string
/// `options` must be a valid plist dictionary or NULL
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_upgrade(
    client: *mut InstallationProxyClientHandle,
    package_path: *const libc::c_char,
    options: plist_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || package_path.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let package_path = unsafe { std::ffi::CStr::from_ptr(package_path) }
        .to_string_lossy()
        .into_owned();
    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        unsafe { &mut *client }
            .0
            .upgrade(package_path, options)
            .await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Upgrades an existing application on the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`package_path`] - Path to the .ipa package in the AFC jail
/// * [`options`] - Optional upgrade options as a plist dictionary (can be NULL)
/// * [`callback`] - Progress callback function
/// * [`context`] - User context to pass to callback
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `package_path` must be a valid C string
/// `options` must be a valid plist dictionary or NULL
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_upgrade_with_callback(
    client: *mut InstallationProxyClientHandle,
    package_path: *const libc::c_char,
    options: plist_t,
    callback: extern "C" fn(progress: u64, context: *mut c_void),
    context: *mut c_void,
) -> *mut IdeviceFfiError {
    if client.is_null() || package_path.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let package_path = unsafe { std::ffi::CStr::from_ptr(package_path) }
        .to_string_lossy()
        .into_owned();
    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        let callback_wrapper = |(progress, context)| async move {
            callback(progress, context);
        };

        unsafe { &mut *client }
            .0
            .upgrade_with_callback(package_path, options, callback_wrapper, context)
            .await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Uninstalls an application from the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`bundle_id`] - Bundle identifier of the application to uninstall
/// * [`options`] - Optional uninstall options as a plist dictionary (can be NULL)
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `bundle_id` must be a valid C string
/// `options` must be a valid plist dictionary or NULL
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_uninstall(
    client: *mut InstallationProxyClientHandle,
    bundle_id: *const libc::c_char,
    options: plist_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || bundle_id.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let bundle_id = unsafe { std::ffi::CStr::from_ptr(bundle_id) }
        .to_string_lossy()
        .into_owned();
    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        unsafe { &mut *client }
            .0
            .uninstall(bundle_id, options)
            .await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Uninstalls an application from the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`bundle_id`] - Bundle identifier of the application to uninstall
/// * [`options`] - Optional uninstall options as a plist dictionary (can be NULL)
/// * [`callback`] - Progress callback function
/// * [`context`] - User context to pass to callback
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `bundle_id` must be a valid C string
/// `options` must be a valid plist dictionary or NULL
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_uninstall_with_callback(
    client: *mut InstallationProxyClientHandle,
    bundle_id: *const libc::c_char,
    options: plist_t,
    callback: extern "C" fn(progress: u64, context: *mut c_void),
    context: *mut c_void,
) -> *mut IdeviceFfiError {
    if client.is_null() || bundle_id.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let bundle_id = unsafe { std::ffi::CStr::from_ptr(bundle_id) }
        .to_string_lossy()
        .into_owned();
    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        let callback_wrapper = |(progress, context)| async move {
            callback(progress, context);
        };

        unsafe { &mut *client }
            .0
            .uninstall_with_callback(bundle_id, options, callback_wrapper, context)
            .await
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Checks if the device capabilities match the required capabilities
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`capabilities`] - Array of plist values representing required capabilities
/// * [`capabilities_len`] - Length of the capabilities array
/// * [`options`] - Optional check options as a plist dictionary (can be NULL)
/// * [`out_result`] - Will be set to true if all capabilities are supported, false otherwise
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `capabilities` must be a valid array of plist values or NULL
/// `options` must be a valid plist dictionary or NULL
/// `out_result` must be a valid pointer to a bool
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_check_capabilities_match(
    client: *mut InstallationProxyClientHandle,
    capabilities: *const plist_t,
    capabilities_len: libc::size_t,
    options: plist_t,
    out_result: *mut bool,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let capabilities = if capabilities.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(capabilities, capabilities_len) }
            .iter()
            .map(|ptr| unsafe { &mut **ptr }.borrow_self().clone())
            .collect()
    };

    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res = run_sync_local(async {
        unsafe { &mut *client }
            .0
            .check_capabilities_match(capabilities, options)
            .await
    });

    match res {
        Ok(result) => {
            unsafe { *out_result = result };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Browses installed applications on the device
///
/// # Arguments
/// * [`client`] - A valid InstallationProxyClient handle
/// * [`options`] - Optional browse options as a plist dictionary (can be NULL)
/// * [`out_result`] - On success, will be set to point to a newly allocated array of PlistRef
/// * [`out_result_len`] - Will be set to the length of the result array
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `options` must be a valid plist dictionary or NULL
/// `out_result` must be a valid, non-null pointer to a location where the result will be stored
/// `out_result_len` must be a valid, non-null pointer to a location where the length will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_browse(
    client: *mut InstallationProxyClientHandle,
    options: plist_t,
    out_result: *mut *mut plist_t,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let options = if options.is_null() {
        None
    } else {
        Some(unsafe { &mut *options })
    }
    .map(|x| x.borrow_self().clone());

    let res: Result<Vec<plist_t>, IdeviceError> = run_sync_local(async {
        unsafe { &mut *client }.0.browse(options).await.map(|apps| {
            apps.into_iter()
                .map(|v| PlistWrapper::new_node(v).into_ptr())
                .collect()
        })
    });

    match res {
        Ok(r) => {
            let mut r = r.into_boxed_slice();
            let ptr = r.as_mut_ptr();
            let len = r.len();
            std::mem::forget(r);

            unsafe {
                *out_result = ptr;
                *out_result_len = len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// v0.3.281：instproxy Archive —— 把 App 归档到设备 `/PublicStaging/<bid>.ipa`
/// （归档包内即含 `iTunesMetadata.plist`），用于读取「安装来源 Apple ID」。
///
/// 通道来源：爱思助手同款——其 `idm_app.dll` 字符串实锤
/// （`/PublicStaging/` + `SkipUninstall` + `am_archive_app` + `iTunesMetadata`）。
/// `iTunesMetadata.plist` 只在 App 的 bundle 目录（非 Data 容器），AFC/house_arrest
/// 均不可达；Archive 是唯一非越狱可用的导出路径。
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `bundle_id` must be a valid NUL-terminated C string
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_archive(
    client: *mut InstallationProxyClientHandle,
    bundle_id: *const libc::c_char,
    skip_uninstall: bool,
) -> *mut IdeviceFfiError {
    if client.is_null() || bundle_id.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let bundle_id = match unsafe { std::ffi::CStr::from_ptr(bundle_id) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    let res: Result<(), IdeviceError> = run_sync_local(async {
        let client_ref = unsafe { &mut *client };

        // v0.3.283：Idevice::send_plist/read_plist 是 crate 私有（E0624 实锤），
        // 改用 pub 的 send_raw/read_raw + 长度前缀 XML plist 帧（对齐 mcinstall.rs，
        // 亦为 idevice crate property_list_service 的线格式）。
        let xml = format!(
            "{header}<dict><key>Command</key><string>Archive</string><key>ApplicationIdentifier</key><string>{bid}</string><key>ClientOptions</key><dict><key>SkipUninstall</key><{flag}/></dict></dict></plist>",
            header = crate::mcinstall::PLIST_HEADER,
            bid = bundle_id,
            flag = if skip_uninstall { "true" } else { "false" }
        );

        let mut frame = Vec::with_capacity(4 + xml.len());
        frame.extend_from_slice(&(xml.len() as u32).to_be_bytes());
        frame.extend_from_slice(xml.as_bytes());
        client_ref.0.idevice.send_raw(&frame).await?;

        loop {
            let len_buf = client_ref.0.idevice.read_raw(4).await?;
            let len = u32::from_be_bytes([len_buf[0], len_buf[1], len_buf[2], len_buf[3]]) as usize;
            if len == 0 || len > 8 * 1024 * 1024 {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "plist 长度异常: {}",
                    len
                )));
            }
            let body = client_ref.0.idevice.read_raw(len).await?;
            let value: plist::Value = plist::from_bytes(&body)
                .map_err(|e| IdeviceError::UnexpectedResponse(format!("plist 解析失败: {}", e)))?;
            let mut dict = match value {
                plist::Value::Dictionary(d) => d,
                _ => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "非字典响应".to_string(),
                    ))
                }
            };

            if let Some(e) = dict
                .remove("ErrorDescription")
                .and_then(|x| x.as_string().map(|s| s.to_string()))
            {
                return Err(IdeviceError::UnexpectedResponse(e));
            }
            if let Some(s) = dict
                .remove("Status")
                .and_then(|x| x.as_string().map(|s| s.to_string()))
                && s == "Complete"
            {
                break;
            }
        }
        Ok(())
    });

    match res {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// v0.3.284：instproxy **Lookup**（带 ReturnAttributes）——一次请求拿全部字段：
/// 基础信息 + StaticDiskUsage/DynamicDiskUsage（大小）+ Entitlements + iTunesMetadata。
///
/// 关键：大小字段只在 **Lookup** 的 ReturnAttributes 里返回（pymobiledevice3
/// installation.py 的 GET_APPS_ADDITIONAL_INFO 走 lookup，不走到 browse；
/// v0.3.279~283 的 browse 通道因此拿不到大小，胶囊恒为「—」）。
/// 结果以 binary plist 数组字节回传（调用方 idevice_data_free 释放）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn installation_proxy_lookup_apps(
    client: *mut InstallationProxyClientHandle,
    out_result: *mut *mut libc::c_void,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<Vec<u8>, IdeviceError> = run_sync_local(async {
        let client_ref = unsafe { &mut *client };

        let attrs = "<string>CFBundleIdentifier</string>                     <string>CFBundleDisplayName</string>                     <string>CFBundleName</string>                     <string>CFBundleShortVersionString</string>                     <string>ApplicationType</string>                     <string>UIFileSharingEnabled</string>                     <string>Path</string>                     <string>StaticDiskUsage</string>                     <string>DynamicDiskUsage</string>                     <string>iTunesMetadata</string>                     <string>CFBundleSize</string>                     <string>Entitlements</string>                     <string>ApplicationDSID</string>                     <string>ApplicationMissingDSID</string>                     <string>SignerIdentity</string>";

        let mut xml = String::new();
        xml.push_str(crate::mcinstall::PLIST_HEADER);
        xml.push_str("<dict><key>Command</key><string>Lookup</string><key>ClientOptions</key>");
        xml.push_str("<dict><key>ApplicationType</key><string>Any</string>");
        xml.push_str("<key>ReturnAttributes</key><array>");
        xml.push_str(attrs);
        xml.push_str("</array></dict></dict></plist>");

        let mut frame = Vec::with_capacity(4 + xml.len());
        frame.extend_from_slice(&(xml.len() as u32).to_be_bytes());
        frame.extend_from_slice(xml.as_bytes());
        client_ref.0.idevice.send_raw(&frame).await?;

        // 读响应（循环直到 Status=Complete；LookupResult 为 {bundleId: appDict}）
        let mut apps: Vec<plist::Value> = Vec::new();
        loop {
            let len_buf = client_ref.0.idevice.read_raw(4).await?;
            let len = u32::from_be_bytes([len_buf[0], len_buf[1], len_buf[2], len_buf[3]]) as usize;
            if len == 0 || len > 32 * 1024 * 1024 {
                return Err(IdeviceError::UnexpectedResponse(format!("plist 长度异常: {}", len)));
            }
            let body = client_ref.0.idevice.read_raw(len).await?;
            let value: plist::Value = plist::from_bytes(&body)
                .map_err(|e| IdeviceError::UnexpectedResponse(format!("plist 解析失败: {}", e)))?;
            let mut dict = match value {
                plist::Value::Dictionary(d) => d,
                _ => return Err(IdeviceError::UnexpectedResponse("非字典响应".to_string())),
            };

            if let Some(e) = dict
                .remove("ErrorDescription")
                .and_then(|x| x.as_string().map(|s| s.to_string()))
            {
                return Err(IdeviceError::UnexpectedResponse(e));
            }
            if let Some(res) = dict.remove("LookupResult")
                && let plist::Value::Dictionary(map) = res
            {
                for (_k, v) in map.into_iter() {
                    apps.push(v);
                }
            }
            if let Some(s) = dict
                .remove("Status")
                .and_then(|x| x.as_string().map(|s| s.to_string()))
                && s == "Complete"
            {
                break;
            }
            if !apps.is_empty() {
                break;
            }
        }

        let root = plist::Value::Array(apps);
        let mut buf: Vec<u8> = Vec::new();
        plist::to_writer_binary(&mut buf, &root)
            .map_err(|e| IdeviceError::UnexpectedResponse(format!("编码失败: {}", e)))?;
        Ok(buf)
    });

    match res {
        Ok(bytes) => {
            let mut boxed = bytes.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            let len = boxed.len();
            std::mem::forget(boxed);
            unsafe {
                *out_result = ptr as *mut libc::c_void;
                *out_result_len = len;
            }
            std::ptr::null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}
