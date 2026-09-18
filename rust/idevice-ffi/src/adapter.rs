// Jackson Coxson

use std::ffi::{CStr, c_char};
use std::ptr::null_mut;

use idevice::tcp::handle::StreamHandle;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::core_device_proxy::AdapterHandle;
use crate::{IdeviceFfiError, ReadWriteOpaque, ffi_err, run_sync};

pub struct AdapterStreamHandle(pub StreamHandle);

/// Connects the adapter to a specific port
///
/// # Arguments
/// * [`adapter_handle`] - The adapter handle
/// * [`port`] - The port to connect to
/// * [`stream_handle`] - A pointer to allocate the new stream to
///
/// # Returns
/// Null on success, an IdeviceFfiError otherwise
///
/// # Safety
/// `handle` must be a valid pointer to a handle allocated by this library.
/// Any stream allocated must be used in the same thread as the adapter. The handles are NOT thread
/// safe.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adapter_connect(
    adapter_handle: *mut AdapterHandle,
    port: u16,
    stream_handle: *mut *mut ReadWriteOpaque,
) -> *mut IdeviceFfiError {
    if adapter_handle.is_null() || stream_handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let adapter = unsafe { &mut (*adapter_handle).0 };
    let res = run_sync(async move { adapter.connect(port).await });

    match res {
        Ok(r) => {
            let boxed = Box::new(ReadWriteOpaque {
                inner: Some(Box::new(r)),
            });
            unsafe { *stream_handle = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => {
            tracing::error!("Adapter connect failed: {e}");
            ffi_err!(e)
        }
    }
}

/// Enables PCAP logging for the adapter
///
/// # Arguments
/// * [`handle`] - The adapter handle
/// * [`path`] - The path to save the PCAP file (null-terminated string)
///
/// # Returns
/// Null on success, an IdeviceFfiError otherwise
///
/// # Safety
/// `handle` must be a valid pointer to a handle allocated by this library
/// `path` must be a valid null-terminated string
#[cfg(feature = "tunnel_tcp_stack_pcap")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adapter_pcap(
    handle: *mut AdapterHandle,
    path: *const c_char,
) -> *mut IdeviceFfiError {
    if handle.is_null() || path.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let adapter = unsafe { &mut (*handle).0 };
    let c_str = unsafe { CStr::from_ptr(path) };
    let path_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    let res = run_sync(async move { adapter.pcap(path_str).await });

    match res {
        Ok(_) => null_mut(),
        Err(e) => {
            tracing::error!("Adapter pcap failed: {e}");
            ffi_err!(e)
        }
    }
}

/// Closes the adapter stream connection
///
/// # Arguments
/// * [`handle`] - The adapter stream handle
///
/// # Returns
/// Null on success, an IdeviceFfiError otherwise
///
/// # Safety
/// `handle` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adapter_stream_close(
    handle: *mut AdapterStreamHandle,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let adapter = unsafe { &mut (*handle).0 };
    run_sync(async move { adapter.close() });

    null_mut()
}

/// Stops the entire adapter TCP stack
///
/// # Arguments
/// * [`handle`] - The adapter handle
///
/// # Returns
/// Null on success, an IdeviceFfiError otherwise
///
/// # Safety
/// `handle` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adapter_close(handle: *mut AdapterHandle) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let adapter = unsafe { &mut (*handle).0 };
    run_sync(async move { adapter.close().await.ok() });

    null_mut()
}

/// Sends data through the adapter stream
///
/// # Arguments
/// * [`handle`] - The adapter stream handle
/// * [`data`] - The data to send
/// * [`length`] - The length of the data
///
/// # Returns
/// Null on success, an IdeviceFfiError otherwise
///
/// # Safety
/// `handle` must be a valid pointer to a handle allocated by this library
/// `data` must be a valid pointer to at least `length` bytes
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adapter_send(
    handle: *mut AdapterStreamHandle,
    data: *const u8,
    length: usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || data.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let adapter = unsafe { &mut (*handle).0 };
    let data_slice = unsafe { std::slice::from_raw_parts(data, length) };

    let res = run_sync(async move { adapter.write_all(data_slice).await });

    match res {
        Ok(_) => null_mut(),
        Err(e) => {
            tracing::error!("Adapter send failed: {e}");
            ffi_err!(e)
        }
    }
}

/// Receives data from the adapter stream
///
/// # Arguments
/// * [`handle`] - The adapter stream handle
/// * [`data`] - Pointer to a buffer where the received data will be stored
/// * [`length`] - Pointer to store the actual length of received data
/// * [`max_length`] - Maximum number of bytes that can be stored in `data`
///
/// # Returns
/// Null on success, an IdeviceFfiError otherwise
///
/// # Safety
/// `handle` must be a valid pointer to a handle allocated by this library
/// `data` must be a valid pointer to at least `max_length` bytes
/// `length` must be a valid pointer to a usize
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adapter_recv(
    handle: *mut AdapterStreamHandle,
    data: *mut u8,
    length: *mut usize,
    max_length: usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || data.is_null() || length.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let adapter = unsafe { &mut (*handle).0 };
    let res: Result<Vec<u8>, std::io::Error> = run_sync(async move {
        let mut buf = [0; 2048];
        let res = adapter.read(&mut buf).await?;
        Ok(buf[..res].to_vec())
    });

    match res {
        Ok(received_data) => {
            let received_len = received_data.len();
            if received_len > max_length {
                return ffi_err!(IdeviceError::FfiBufferTooSmall(received_len, max_length));
            }

            unsafe {
                std::ptr::copy_nonoverlapping(received_data.as_ptr(), data, received_len);
                *length = received_len;
            }

            null_mut()
        }
        Err(e) => {
            tracing::error!("Adapter recv failed: {e}");
            ffi_err!(e)
        }
    }
}

/// 通过 `ReadWriteOpaque` 流发送一条 XML（**4 字节大端长度前缀 + XML 正文**）。
///
/// # 为什么需要这个（2026-09-18）
/// airlift 漏洞利用要自己扮演 AirTraffic 主机端，需要向设备发 `RSDCheckin`
/// 与 AT 消息（都是 plist / XML）。而现有 FFI 里能发字节的 `adapter_send`
/// 只接受 `AdapterStreamHandle`，但 `adapter_connect` 返回的是 `ReadWriteOpaque`
/// —— **两者不通用，库里也没有任何转换函数**。所以补这一对。
///
/// 线格式与 `mcinstall.rs` 的 `send_xml` 一致（idevice property_list_service 线格式）。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；`xml` 必须是有效的 NUL 结尾 C 字符串。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_send_xml(
    stream_handle: *mut ReadWriteOpaque,
    xml: *const c_char,
) -> *mut IdeviceFfiError {
    if stream_handle.is_null() || xml.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let inner = unsafe { &mut (*stream_handle).inner };
    let Some(stream) = inner.as_mut() else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };
    let xml = match unsafe { CStr::from_ptr(xml) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    let res = run_sync(async move {
        let len = xml.len() as u32;
        stream.write_all(&len.to_be_bytes()).await?;
        stream.write_all(xml.as_bytes()).await?;
        stream.flush().await?;
        Ok::<(), IdeviceError>(())
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => {
            tracing::error!("stream_send_xml failed: {e}");
            ffi_err!(e)
        }
    }
}

/// 通过 `ReadWriteOpaque` 流读取一条 XML（先读 4 字节大端长度，再读正文）。
///
/// 成功后把正文写成 NUL 结尾的 C 字符串存入 `out`
/// （调用方用 `idevice_string_free` 释放）。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；`out` 必须是有效指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_recv_xml(
    stream_handle: *mut ReadWriteOpaque,
    out: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if stream_handle.is_null() || out.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let inner = unsafe { &mut (*stream_handle).inner };
    let Some(stream) = inner.as_mut() else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };

    let res: Result<String, IdeviceError> = run_sync(async move {
        let mut len_buf = [0u8; 4];
        stream.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;
        // 防御：长度异常直接报错（正常 plist 不会到 8MB）
        if len == 0 || len > 8 * 1024 * 1024 {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "plist 长度异常: {len}"
            )));
        }
        let mut buf = vec![0u8; len];
        stream.read_exact(&mut buf).await?;
        String::from_utf8(buf)
            .map_err(|_| IdeviceError::UnexpectedResponse("plist 正文非 UTF-8".into()))
    });

    match res {
        Ok(s) => {
            let c = std::ffi::CString::new(s).unwrap_or_default();
            unsafe { *out = c.into_raw() };
            null_mut()
        }
        Err(e) => {
            tracing::error!("stream_recv_xml failed: {e}");
            ffi_err!(e)
        }
    }
}
