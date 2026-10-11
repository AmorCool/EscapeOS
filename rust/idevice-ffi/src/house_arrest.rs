// Jackson Coxson

use std::{
    ffi::{CStr, c_char},
    ptr::null_mut,
};

use idevice::{
    IdeviceError, IdeviceService, RsdService, afc::AfcClient, house_arrest::HouseArrestClient,
    provider::IdeviceProvider,
};

use crate::{
    IdeviceFfiError, IdeviceHandle, afc::AfcClientHandle, core_device_proxy::AdapterHandle,
    ffi_err, provider::IdeviceProviderHandle, rsd::RsdHandshakeHandle, run_sync_local,
};

pub struct HouseArrestClientHandle(pub HouseArrestClient);

/// Connects to the House Arrest service using a TCP provider
///
/// # Arguments
/// * [`provider`] - An IdeviceProvider
/// * [`client`] - On success, will be set to point to a newly allocated HouseArrestClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_arrest_client_connect(
    provider: *mut IdeviceProviderHandle,
    client: *mut *mut HouseArrestClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || client.is_null() {
        tracing::error!("Null pointer provided");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res = run_sync_local(async {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider).0 };

        HouseArrestClient::connect(provider_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(HouseArrestClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Creates a new HouseArrestClient via RSD
///
/// # Arguments
/// * [`provider`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
/// * [`client`] - On success, will be set to point to a newly allocated HouseArrestClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_arrest_client_connect_rsd(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut *mut HouseArrestClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res: Result<HouseArrestClient, IdeviceError> = run_sync_local(async move {
        let provider_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        HouseArrestClient::connect_rsd(provider_ref, handshake_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(HouseArrestClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Creates a new HouseArrestClient from an existing Idevice connection
///
/// # Arguments
/// * [`socket`] - An IdeviceSocket handle
/// * [`client`] - On success, will be set to point to a newly allocated HouseArrestClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `socket` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_arrest_client_new(
    socket: *mut IdeviceHandle,
    client: *mut *mut HouseArrestClientHandle,
) -> *mut IdeviceFfiError {
    if socket.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let socket = unsafe { Box::from_raw(socket) }.0;
    let r = HouseArrestClient::new(socket);
    let boxed = Box::new(HouseArrestClientHandle(r));
    unsafe { *client = Box::into_raw(boxed) };
    null_mut()
}

/// Vends a container for an app
///
/// # Arguments
/// * [`client`] - The House Arrest client
/// * [`bundle_id`] - The bundle ID to vend for
/// * [`afc_client`] - The new AFC client for the underlying connection
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a allocated by this library
/// `bundle_id` must be a NULL-terminated string
/// `afc_client` must be a valid, non-null pointer where the new AFC client will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_arrest_vend_container(
    client: *mut HouseArrestClientHandle,
    bundle_id: *const c_char,
    afc_client: *mut *mut AfcClientHandle,
) -> *mut IdeviceFfiError {
    if client.is_null() || bundle_id.is_null() || afc_client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let bundle_id = unsafe { CStr::from_ptr(bundle_id) }.to_string_lossy().to_string();
    let client_ref = unsafe { Box::from_raw(client) }.0; // take ownership and drop

    // v0.3.xxx：vend 必须判应答（见 vend_checked 注释）——上游 vend 丢弃应答，
    // 失败会被推迟到第一次 AFC 命令，报成误导性的「创建文件失败」.
    let res: Result<AfcClient, IdeviceError> =
        run_sync_local(async move { vend_checked(client_ref, bundle_id, "VendContainer").await });

    match res {
        Ok(a) => {
            let a = Box::into_raw(Box::new(AfcClientHandle(a)));
            unsafe { *afc_client = a };
            null_mut()
        }
        Err(e) => {
            ffi_err!(e)
        }
    }
}

/// Vends documents for an app
///
/// # Arguments
/// * [`client`] - The House Arrest client
/// * [`bundle_id`] - The bundle ID to vend for
/// * [`afc_client`] - The new AFC client for the underlying connection
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `client` must be a allocated by this library
/// `bundle_id` must be a NULL-terminated string
/// `afc_client` must be a valid, non-null pointer where the new AFC client will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_arrest_vend_documents(
    client: *mut HouseArrestClientHandle,
    bundle_id: *const c_char,
    afc_client: *mut *mut AfcClientHandle,
) -> *mut IdeviceFfiError {
    if client.is_null() || bundle_id.is_null() || afc_client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let bundle_id = unsafe { CStr::from_ptr(bundle_id) }.to_string_lossy().to_string();
    let client_ref = unsafe { Box::from_raw(client) }.0; // take ownership and drop

    // v0.3.xxx：vend 必须判应答（见 vend_checked 注释）——上游 vend 丢弃应答，
    // 失败会被推迟到第一次 AFC 命令，报成误导性的「创建文件失败」.
    let res: Result<AfcClient, IdeviceError> =
        run_sync_local(async move { vend_checked(client_ref, bundle_id, "VendDocuments").await });

    match res {
        Ok(a) => {
            let a = Box::into_raw(Box::new(AfcClientHandle(a)));
            unsafe { *afc_client = a };
            null_mut()
        }
        Err(e) => {
            ffi_err!(e)
        }
    }
}

/// 发 house_arrest vend 并**判应答**，成功才返回 AFC 会话.
///
/// 上游 `idevice` crate 的 `HouseArrestClient::vend`
/// （`src/services/house_arrest.rs:92-102`）只 `send_plist` + `read_plist` 就
/// `AfcClient::new`，**丢弃应答** —— 设备回 `{Error: ...}`（如
/// `InstallationLookupFailed` / `ApplicationLookupFailed`）时仍给出一个 AFC 句柄，
/// 失败被推迟到第一次 AFC 命令，最终报成误导性的「创建文件失败」
/// （`FileSharingService.swift:1069`）。
///
/// 因 `Idevice::send_plist`/`read_plist` 是 crate 私有（E0624 实锤），此处照
/// `installation_proxy.rs` / `mobileactivationd.rs` 的既有范式，改用 pub 的
/// `send_raw`/`read_raw` + 4 字节大端长度前缀 plist 帧（= property_list_service 线格式）。
/// 收到应答后判 `Error`：有则返回真错误，绝不返回坏句柄.
async fn vend_checked(
    client: HouseArrestClient,
    bundle_id: String,
    command: &str,
) -> Result<AfcClient, IdeviceError> {
    let mut dev = client.idevice;
    let xml = format!(
        "{header}<dict><key>Command</key><string>{cmd}</string>\
         <key>Identifier</key><string>{bid}</string></dict></plist>",
        header = crate::mcinstall::PLIST_HEADER,
        cmd = command,
        bid = bundle_id
    );
    let mut frame = Vec::with_capacity(4 + xml.len());
    frame.extend_from_slice(&(xml.len() as u32).to_be_bytes());
    frame.extend_from_slice(xml.as_bytes());
    dev.send_raw(&frame).await?;

    let len_buf = dev.read_raw(4).await?;
    let len = u32::from_be_bytes([len_buf[0], len_buf[1], len_buf[2], len_buf[3]]) as usize;
    if len == 0 || len > 8 * 1024 * 1024 {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "house_arrest 应答长度异常: {len}"
        )));
    }
    let body = dev.read_raw(len).await?;
    let value: plist::Value = plist::from_bytes(&body).map_err(|e| {
        IdeviceError::UnexpectedResponse(format!("house_arrest 应答解析失败: {e}"))
    })?;
    let mut dict = match value {
        plist::Value::Dictionary(d) => d,
        _ => {
            return Err(IdeviceError::UnexpectedResponse(
                "house_arrest 应答非字典".to_string(),
            ))
        }
    };
    if let Some(err) = dict
        .remove("Error")
        .and_then(|x| x.as_string().map(|s| s.to_string()))
    {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "house_arrest vend 被拒（{command}）：{err}"
        )));
    }
    Ok(AfcClient::new(dev))
}

/// Frees an HouseArrestClient handle
///
/// # Arguments
/// * [`handle`] - The handle to free
///
/// # Safety
/// `handle` must be a valid pointer to the handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_arrest_client_free(handle: *mut HouseArrestClientHandle) {
    if !handle.is_null() {
        tracing::debug!("Freeing house_arrest_client");
        let _ = unsafe { Box::from_raw(handle) };
    }
}
