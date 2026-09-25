use std::{
    ffi::{CStr, c_void},
    ptr::null_mut,
};

use idevice::{
    IdeviceError, IdeviceService, RsdService, provider::IdeviceProvider,
    springboardservices::SpringBoardServicesClient,
};
use plist_ffi::plist_t;

use crate::{
    IdeviceFfiError, IdeviceHandle, core_device_proxy::AdapterHandle, ffi_err,
    provider::IdeviceProviderHandle, rsd::RsdHandshakeHandle, run_sync, run_sync_local,
};

pub struct SpringBoardServicesClientHandle(pub SpringBoardServicesClient);

/// Connects to the Springboard service using a provider
///
/// # Arguments
/// * [`provider`] - An IdeviceProvider
/// * [`client`] - On success, will be set to point to a newly allocated SpringBoardServicesClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_connect(
    provider: *mut IdeviceProviderHandle,
    client: *mut *mut SpringBoardServicesClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || client.is_null() {
        tracing::error!("Null pointer provided");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<SpringBoardServicesClient, IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider).0 };
        SpringBoardServicesClient::connect(provider_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(SpringBoardServicesClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => {
            // If connection failed, the provider_box was already forgotten,
            // so we need to reconstruct it to avoid leak
            let _ = unsafe { Box::from_raw(provider) };
            ffi_err!(e)
        }
    }
}

/// Creates a new SpringBoardServicesClient via RSD
///
/// # Arguments
/// * [`provider`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
/// * [`client`] - On success, will be set to point to a newly allocated SpringBoardServicesClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_connect_rsd(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut *mut SpringBoardServicesClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res: Result<SpringBoardServicesClient, IdeviceError> = run_sync_local(async move {
        let provider_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        SpringBoardServicesClient::connect_rsd(provider_ref, handshake_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(SpringBoardServicesClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Creates a new SpringBoardServices client from an existing Idevice connection
///
/// # Arguments
/// * [`socket`] - An IdeviceSocket handle
/// * [`client`] - On success, will be set to point to a newly allocated SpringBoardServicesClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `socket` must be a valid pointer to a handle allocated by this library. The socket is consumed,
/// and may not be used again.
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_new(
    socket: *mut IdeviceHandle,
    client: *mut *mut SpringBoardServicesClientHandle,
) -> *mut IdeviceFfiError {
    if socket.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let socket = unsafe { Box::from_raw(socket) }.0;
    let r = SpringBoardServicesClient::new(socket);
    let boxed = Box::new(SpringBoardServicesClientHandle(r));
    unsafe { *client = Box::into_raw(boxed) };
    null_mut()
}

/// Gets the icon of the specified app by bundle identifier
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `bundle_identifier` - The identifiers of the app to get icon
/// * `out_result` - On success, will be set to point to a newly allocated png data
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `out_result` must be a valid, non-null pointer to a location where the result will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_get_icon(
    client: *mut SpringBoardServicesClientHandle,
    bundle_identifier: *const libc::c_char,
    out_result: *mut *mut c_void,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {out_result:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    let name_cstr = unsafe { CStr::from_ptr(bundle_identifier) };
    let bundle_id = match name_cstr.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidArg),
    };

    let res: Result<Vec<u8>, IdeviceError> =
        run_sync(async { client.0.get_icon_pngdata(bundle_id).await });

    match res {
        Ok(r) => {
            let len = r.len();
            let boxed_slice = r.into_boxed_slice();
            let ptr = boxed_slice.as_ptr();
            std::mem::forget(boxed_slice);

            unsafe {
                *out_result = ptr as *mut c_void;
                *out_result_len = len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Gets the home screen wallpaper preview as PNG image
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `out_result` - On success, will be set to point to newly allocated png image
/// * `out_result_len` - On success, will contain the size of the data in bytes
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `out_result` and `out_result_len` must be valid, non-null pointers
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_get_home_screen_wallpaper_preview(
    client: *mut SpringBoardServicesClientHandle,
    out_result: *mut *mut c_void,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {out_result:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    let res: Result<Vec<u8>, IdeviceError> =
        run_sync(async { client.0.get_home_screen_wallpaper_preview_pngdata().await });

    match res {
        Ok(r) => {
            let len = r.len();
            let boxed_slice = r.into_boxed_slice();
            let ptr = boxed_slice.as_ptr();
            std::mem::forget(boxed_slice);

            unsafe {
                *out_result = ptr as *mut c_void;
                *out_result_len = len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Gets the lock screen wallpaper preview as PNG image
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `out_result` - On success, will be set to point to newly allocated png image
/// * `out_result_len` - On success, will contain the size of the data in bytes
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `out_result` and `out_result_len` must be valid, non-null pointers
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_get_lock_screen_wallpaper_preview(
    client: *mut SpringBoardServicesClientHandle,
    out_result: *mut *mut c_void,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {out_result:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    let res: Result<Vec<u8>, IdeviceError> =
        run_sync(async { client.0.get_lock_screen_wallpaper_preview_pngdata().await });

    match res {
        Ok(r) => {
            let len = r.len();
            let boxed_slice = r.into_boxed_slice();
            let ptr = boxed_slice.as_ptr();
            std::mem::forget(boxed_slice);

            unsafe {
                *out_result = ptr as *mut c_void;
                *out_result_len = len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Gets the current interface orientation of the device
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `out_orientation` - On success, will contain the orientation value (0-4)
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `out_orientation` must be a valid, non-null pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_get_interface_orientation(
    client: *mut SpringBoardServicesClientHandle,
    out_orientation: *mut u8,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_orientation.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {out_orientation:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    let res = run_sync(async { client.0.get_interface_orientation().await });

    match res {
        Ok(orientation) => {
            unsafe {
                *out_orientation = orientation as u8;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Gets the home screen icon layout metrics
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `res` - On success, will point to a plist dictionary node containing the metrics
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `res` must be a valid, non-null pointer
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_get_homescreen_icon_metrics(
    client: *mut SpringBoardServicesClientHandle,
    res: *mut plist_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || res.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {res:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    let output = run_sync(async { client.0.get_homescreen_icon_metrics().await });

    match output {
        Ok(metrics) => {
            unsafe {
                *res =
                    plist_ffi::PlistWrapper::new_node(plist::Value::Dictionary(metrics)).into_ptr();
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Reads the whole home screen icon layout (SpringBoard `getIconState`).
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `format_version` - Optional C string: `"2"` = flat list (most complete),
///   `"1"`/`"3"` = fixed grid (trailing cells are `false` filler), `"4"` = row matrix.
///   Pass NULL for the device default. **读和写必须用同一个版本号**。
/// * `out_result` - On success, points to a newly allocated **binary plist** blob
/// * `out_result_len` - On success, contains the byte length of that blob
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `out_result` / `out_result_len` must be valid, non-null pointers
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_get_icon_state(
    client: *mut SpringBoardServicesClientHandle,
    format_version: *const libc::c_char,
    out_result: *mut *mut c_void,
    out_result_len: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_result.is_null() || out_result_len.is_null() {
        tracing::error!("Invalid arguments: {client:?}, {out_result:?}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };

    // 版本号按「可选 C 串」处理：NULL / 空串 / 非 UTF-8 都当「用设备默认」.
    // 只有真给了值才 Some(...)，避免把空串当成一个合法版本号发过去.
    let fmt: Option<String> = if format_version.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(format_version) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s.to_string()),
            Ok(_) => None,
            Err(_) => return ffi_err!(IdeviceError::FfiInvalidArg),
        }
    };

    let res: Result<Vec<u8>, IdeviceError> = run_sync(async move {
        let value = client.0.get_icon_state(fmt.as_deref()).await?;
        // 序列化成**二进制 plist** 交给 Swift（那边用 PropertyListSerialization 直接解析）.
        let mut buf: Vec<u8> = Vec::new();
        plist::to_writer_binary(&mut buf, &value).map_err(|e| {
            IdeviceError::UnexpectedResponse(format!("icon state 序列化失败：{e}"))
        })?;
        Ok(buf)
    });

    match res {
        Ok(r) => {
            let len = r.len();
            let boxed_slice = r.into_boxed_slice();
            let ptr = boxed_slice.as_ptr();
            std::mem::forget(boxed_slice);

            unsafe {
                *out_result = ptr as *mut c_void;
                *out_result_len = len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Writes a home screen icon layout back to SpringBoard (`setIconState`).
///
/// # Arguments
/// * `client` - A valid SpringBoardServicesClient handle
/// * `data` - A **binary plist** blob (通常就是 `get_icon_state` 拿到的、改过的那份)
/// * `len` - Byte length of `data`
/// * `format_version` - Optional C string, **必须与读的时候一致**；NULL = 不带版本号
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
/// `data` must point to at least `len` readable bytes
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_set_icon_state(
    client: *mut SpringBoardServicesClientHandle,
    data: *const u8,
    len: libc::size_t,
    format_version: *const libc::c_char,
) -> *mut IdeviceFfiError {
    if client.is_null() || data.is_null() || len == 0 {
        tracing::error!("Invalid arguments: {client:?}, {data:?}, {len}");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let client = unsafe { &mut *client };
    let bytes: Vec<u8> = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();

    let fmt: Option<String> = if format_version.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(format_version) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s.to_string()),
            Ok(_) => None,
            Err(_) => return ffi_err!(IdeviceError::FfiInvalidArg),
        }
    };

    let res: Result<(), IdeviceError> = run_sync(async move {
        let value: plist::Value = plist::from_bytes(&bytes).map_err(|e| {
            IdeviceError::UnexpectedResponse(format!("icon state 解析失败：{e}"))
        })?;
        match fmt.as_deref() {
            Some(v) => client.0.set_icon_state_with_version(value, Some(v)).await,
            None => client.0.set_icon_state(value).await,
        }
    });

    match res {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Frees an SpringBoardServicesClient handle
///
/// # Arguments
/// * [`handle`] - The handle to free
///
/// # Safety
/// `handle` must be a valid pointer to the handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn springboard_services_free(handle: *mut SpringBoardServicesClientHandle) {
    if !handle.is_null() {
        tracing::debug!("Freeing springboard_services_client");
        let _ = unsafe { Box::from_raw(handle) };
    }
}
