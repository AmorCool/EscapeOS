// Jackson Coxson
//
// 注：airlift 漏洞利用（EscapeOS/Engine/Exploits/AirliftExploit.swift）已整体删除。
// 本文件**不再属于 airlift**，只保留 `adapter_connect` —— 它是通用 adapter API 的一部分：
// SSH 只读诊断探针 `EscapeOS/Tunnel/EscCDProbe.c`（`cdprobe` 命令）依赖它，
// 在 CoreDeviceProxy 隧道内新开一条流给 `rsd_handshake_new`。
// 原先只服务 airlift 的 adapter_send / adapter_recv / adapter_close / adapter_pcap /
// adapter_stream_close 与全部 stream_* 函数已随 airlift 一并删除。

use std::ptr::null_mut;

use idevice::IdeviceError;

use crate::core_device_proxy::AdapterHandle;
use crate::{IdeviceFfiError, ReadWriteOpaque, ffi_err, run_sync};

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
