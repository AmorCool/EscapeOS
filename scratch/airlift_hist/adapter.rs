// Jackson Coxson

use std::ffi::{CStr, c_char};
use std::ptr::null_mut;

use idevice::tcp::handle::StreamHandle;
use idevice::IdeviceError;
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

/// 通过 `ReadWriteOpaque` 流发送一条 XML，**长度前缀的字节序可指定**。
///
/// # 为什么需要这个（2026-09-19）
/// RSD 握手（`RSDCheckin` / 服务表）已实测是大端 4 字节长度前缀，用
/// [`stream_send_xml`] 即可。但设备端 **AirTraffic（atc）服务**的帧字节序不同：
/// 真机日志里 `stream_recv_xml` 读 `ReadyForSync` 响应时报
/// `plist 长度异常: 3087007744`（= `0xB8000000`），而同样的 4 个字节
/// `B8 00 00 00` 按小端读是 **184** —— 一个完全合理的 plist 大小。
/// ⇒ AT 链路的帧字节序必须**可切换**，且不能靠猜（见 [`stream_recv_xml_auto`]）。
///
/// 其余行为与 [`stream_send_xml`] 完全一致。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；`xml` 必须是有效的 NUL 结尾 C 字符串。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_send_xml_ordered(
    stream_handle: *mut ReadWriteOpaque,
    xml: *const c_char,
    little_endian: bool,
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
        let prefix = if little_endian {
            len.to_le_bytes()
        } else {
            len.to_be_bytes()
        };
        stream.write_all(&prefix).await?;
        stream.write_all(xml.as_bytes()).await?;
        stream.flush().await?;
        Ok::<(), IdeviceError>(())
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => {
            tracing::error!("stream_send_xml_ordered failed: {e}");
            ffi_err!(e)
        }
    }
}

/// 通过 `ReadWriteOpaque` 流读取一条 XML，**自动探测长度前缀的字节序**。
///
/// 判定规则（先读 4 字节，两种解释都试）：
/// · 若大端解释落在 `1..=8MiB` → 视为大端，`*used_little_endian = false`；
/// · 否则若小端解释落在同一区间 → 视为小端，`*used_little_endian = true`；
/// · 两者都不合法 → 返回 `UnexpectedResponse`，**错误信息里带上这 4 个字节的原始十六进制**
///   以及两种解释的数值（形如 `raw=B8 00 00 00 be=3087007744 le=184`）——
///   这样一次真机运行就能拿到确证，而不是靠猜字节序反复试。
///
/// ⚠️ 存在两种解释都合法的歧义（例如 `00 00 01 00`：be=256 / le=65536）。
/// 这里**优先大端**：RSD 握手实测就是大端，先按已知事实解释；
/// 若真机上探测结果不对，错误信息里的 raw 十六进制足以定位。
///
/// 成功后把正文写成 NUL 结尾的 C 字符串存入 `out`
/// （调用方用 `idevice_string_free` 释放）。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；`out` 必须是有效指针；
/// `used_little_endian` 可为 NULL（此时只跳过回写，不影响解析逻辑）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_recv_xml_auto(
    stream_handle: *mut ReadWriteOpaque,
    out: *mut *mut c_char,
    used_little_endian: *mut bool,
) -> *mut IdeviceFfiError {
    if stream_handle.is_null() || out.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let inner = unsafe { &mut (*stream_handle).inner };
    let Some(stream) = inner.as_mut() else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };

    let res: Result<(String, bool), IdeviceError> = run_sync(async move {
        // ⚠️ **必须有超时。** `read_exact` 在设备一条消息都不发时会**永久阻塞**。
        // AT 阶段的第一步恰恰就是「只读」—— 等设备主动发来 `SyncAllowed`。
        // 没有超时的话，只要设备不发，这条线程就永远卡在 protocolQueue 上，
        // 而调用方已经把 `protocolProbeStarted` 置了 true ⇒ airlift 在整个 App
        // 生命周期内**永久失效**（还占着一个线程）。宁可报错，不可挂死。
        let frame = async {
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).await?;
            let be = u32::from_be_bytes(len_buf);
            let le = u32::from_le_bytes(len_buf);
            let max_len = 8 * 1024 * 1024;
            let (len, little) = if (1..=max_len).contains(&be) {
                (be, false)
            } else if (1..=max_len).contains(&le) {
                (le, true)
            } else {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "格式无法识别: raw={:02X} {:02X} {:02X} {:02X} be={be} le={le}",
                    len_buf[0], len_buf[1], len_buf[2], len_buf[3]
                )));
            };
            let mut buf = vec![0u8; len as usize];
            stream.read_exact(&mut buf).await?;
            let text = String::from_utf8(buf)
                .map_err(|_| IdeviceError::UnexpectedResponse("plist 正文非 UTF-8".into()))?;
            Ok::<(String, bool), IdeviceError>((text, little))
        };

        match tokio::time::timeout(std::time::Duration::from_secs(15), frame).await {
            Ok(result) => result,
            Err(_) => Err(IdeviceError::UnexpectedResponse(
                "读超时：15s 内设备没有发来完整的一帧".into(),
            )),
        }
    });

    match res {
        Ok((s, little)) => {
            let c = std::ffi::CString::new(s).unwrap_or_default();
            unsafe {
                *out = c.into_raw();
                if !used_little_endian.is_null() {
                    *used_little_endian = little;
                }
            }
            null_mut()
        }
        Err(e) => {
            tracing::error!("stream_recv_xml_auto failed: {e}");
            ffi_err!(e)
        }
    }
}

/// 通过 `ReadWriteOpaque` 流发送**任意原始字节**（4 字节长度前缀 + 正文）。
///
/// # 为什么需要这个（2026-09-19）
/// 真机实测（v0.3.439）已确证：**AT 帧的正文不是 XML 文本，而是二进制 plist**
/// （`stream_recv_xml_auto` 能读出正文但报 `plist 正文非 UTF-8`）。
/// 所以发送端也不能再发 XML 文本 —— 必须把 plist 先序列化成 `bplist00` 再发。
/// [`stream_send_xml`] / [`stream_send_xml_ordered`] 只收 NUL 结尾的 C 字符串，
/// 二进制正文里必然含 `\0`，走不了那条路，故新增本函数。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；
/// `bytes` 必须指向至少 `len` 个可读字节。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_send_bytes(
    stream_handle: *mut ReadWriteOpaque,
    bytes: *const u8,
    len: usize,
    little_endian: bool,
) -> *mut IdeviceFfiError {
    if stream_handle.is_null() || bytes.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let inner = unsafe { &mut (*stream_handle).inner };
    let Some(stream) = inner.as_mut() else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };
    // 拷成 owned Vec：run_sync 的 future 要求 'static，不能借用调用方的缓冲区。
    let data = unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec();

    let res = run_sync(async move {
        let len32 = data.len() as u32;
        let prefix = if little_endian {
            len32.to_le_bytes()
        } else {
            len32.to_be_bytes()
        };
        stream.write_all(&prefix).await?;
        stream.write_all(&data).await?;
        stream.flush().await?;
        Ok::<(), IdeviceError>(())
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => {
            tracing::error!("stream_send_bytes failed: {e}");
            ffi_err!(e)
        }
    }
}

/// 通过 `ReadWriteOpaque` 流发送**裸字节**（**无任何长度前缀**）。
///
/// # 为什么需要这个（2026-09-19）
/// airlift 的 stage 步骤（`com.apple.streaming_zip_conduit`）线格式是
/// 「先发一条 plist 消息（4 字节长度前缀 + plist），**再把 zip 的原始字节整段发过去**」。
/// 上游 PoC 发 zip 用的是 `AMDServiceConnectionSend` —— **纯 socket send，没有帧头**
/// （`Sources/device_helper.m` 的 `SendAll()`）。所以这里必须有一个「不加长度前缀」的
/// 发送函数：若用 [`stream_send_bytes`]，设备会把那 4 字节长度前缀当成 zip 的开头，
/// 解压必然失败（zip 的第一个 local file header 签名必须正好是 `PK\x03\x04`）。
///
/// 其余行为（错误处理 / `flush` / `run_sync`）与 [`stream_send_bytes`] 完全一致。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；
/// `bytes` 必须指向至少 `len` 个可读字节。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_send_raw(
    stream_handle: *mut ReadWriteOpaque,
    bytes: *const u8,
    len: usize,
) -> *mut IdeviceFfiError {
    if stream_handle.is_null() || bytes.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let inner = unsafe { &mut (*stream_handle).inner };
    let Some(stream) = inner.as_mut() else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };
    // 拷成 owned Vec：run_sync 的 future 要求 'static，不能借用调用方的缓冲区。
    let data = unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec();

    let res = run_sync(async move {
        stream.write_all(&data).await?;
        stream.flush().await?;
        Ok::<(), IdeviceError>(())
    });

    match res {
        Ok(_) => null_mut(),
        Err(e) => {
            tracing::error!("stream_send_raw failed: {e}");
            ffi_err!(e)
        }
    }
}

/// 通过 `ReadWriteOpaque` 流读取**一帧原始字节**（4 字节长度前缀 + 正文），
/// **不要求正文是 UTF-8**。
///
/// 判定规则与 [`stream_recv_xml_auto`] 完全一致（大端落在 `1..=8MiB` 用大端，
/// 否则小端落在同一区间用小端；两者都不合法则报错，错误信息带 raw 十六进制
/// 与两种解释）。
///
/// 成功后正文由 `libc::malloc` 分配并写入 `*out_bytes` / `*out_len`，
/// **调用方用 `free()` 释放**（与 C 运行时同源，不能用 `idevice_string_free`）。
///
/// ⚠️ 与 `stream_recv_xml_auto` 一样**必须有 15s 超时**：`read_exact` 无超时会在
/// 设备不发消息时**永久阻塞**，而调用方已把 `protocolProbeStarted` 置 true，
/// 会让 airlift 在整个 App 生命周期内永久失效。
///
/// # Safety
/// `stream_handle` 必须是由本库分配的有效句柄；
/// `out_bytes` / `out_len` 必须是有效指针；`used_little_endian` 可为 NULL。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stream_recv_frame_raw(
    stream_handle: *mut ReadWriteOpaque,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
    used_little_endian: *mut bool,
) -> *mut IdeviceFfiError {
    if stream_handle.is_null() || out_bytes.is_null() || out_len.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let inner = unsafe { &mut (*stream_handle).inner };
    let Some(stream) = inner.as_mut() else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };

    let res: Result<(Vec<u8>, bool), IdeviceError> = run_sync(async move {
        let frame = async {
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).await?;
            let be = u32::from_be_bytes(len_buf);
            let le = u32::from_le_bytes(len_buf);
            let max_len = 8 * 1024 * 1024;
            let (len, little) = if (1..=max_len).contains(&be) {
                (be, false)
            } else if (1..=max_len).contains(&le) {
                (le, true)
            } else {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "raw={:02X} {:02X} {:02X} {:02X} be={be} le={le}",
                    len_buf[0], len_buf[1], len_buf[2], len_buf[3]
                )));
            };
            let mut buf = vec![0u8; len as usize];
            stream.read_exact(&mut buf).await?;
            Ok::<(Vec<u8>, bool), IdeviceError>((buf, little))
        };

        match tokio::time::timeout(std::time::Duration::from_secs(15), frame).await {
            Ok(result) => result,
            Err(_) => Err(IdeviceError::UnexpectedResponse(
                "读超时：15s 内设备没有发来完整的一帧".into(),
            )),
        }
    });

    match res {
        Ok((buf, little)) => {
            // 用 libc::malloc 分配 —— 与 Swift 侧的 free() 同源（都是 libsystem_malloc）。
            let ptr = unsafe { libc::malloc(buf.len()) } as *mut u8;
            if ptr.is_null() {
                return ffi_err!(IdeviceError::UnexpectedResponse(
                    "malloc 分配收帧缓冲区失败".into()
                ));
            }
            unsafe {
                std::ptr::copy_nonoverlapping(buf.as_ptr(), ptr, buf.len());
                *out_bytes = ptr;
                *out_len = buf.len();
                if !used_little_endian.is_null() {
                    *used_little_endian = little;
                }
            }
            null_mut()
        }
        Err(e) => {
            tracing::error!("stream_recv_frame_raw failed: {e}");
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
        // 同 [`stream_recv_xml_auto`]：**读必须有超时**，否则设备不回就永久挂死。
        let frame = async {
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).await?;
            let len = u32::from_be_bytes(len_buf) as usize;
            // 防御：长度异常直接报错（正常 plist 不会到 8MB）。
            // 错误信息里带上 4 个原始字节 —— 否则只知道数字、不知道线上到底是什么。
            if len == 0 || len > 8 * 1024 * 1024 {
                return Err(IdeviceError::UnexpectedResponse(format!(
                    "plist 长度异常: {len}（raw={:02X} {:02X} {:02X} {:02X} le={}）",
                    len_buf[0],
                    len_buf[1],
                    len_buf[2],
                    len_buf[3],
                    u32::from_le_bytes(len_buf)
                )));
            }
            let mut buf = vec![0u8; len];
            stream.read_exact(&mut buf).await?;
            String::from_utf8(buf)
                .map_err(|_| IdeviceError::UnexpectedResponse("plist 正文非 UTF-8".into()))
        };

        match tokio::time::timeout(std::time::Duration::from_secs(15), frame).await {
            Ok(result) => result,
            Err(_) => Err(IdeviceError::UnexpectedResponse(
                "读超时：15s 内设备没有发来完整的一帧".into(),
            )),
        }
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
