//! Apple ID 登录 + IPA 签名，通过 `isideload` 的 sign-only 路径。
//!
//! 移植自 SideInstaller 的 rust-core/src/account.rs（si_apple_signin /
//! si_sign_ipa），供「IPA 侧载」功能使用：登录 Apple ID 拿到
//! `SignSession`，再用它把 IPA 签成带描述文件的 .app 包。安装本身走
//! 我们自己的 AFC + installation_proxy 隧道（见 Swift 侧）。
#![allow(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{
        AppleAccount, TwoFactorCallback, TwoFactorCallbackParams, TwoFactorCallbackResponse,
    },
    dev::{developer_session::DeveloperSession, devices::DevicesApi},
    sideload::{builder::MaxCertsBehavior, sideloader::Sideloader, SideloaderBuilder, TeamSelection},
    util::fs_storage::FsStorage,
};

/// `int (*)(void *ctx, char *out_buf, size_t buf_len)` — 把 2FA 验证码写进
/// `out_buf`（NUL 结尾）并返回 1；用户取消返回 0。
pub type TwoFactorCb =
    Option<extern "C" fn(ctx: *mut c_void, out_buf: *mut c_char, buf_len: usize) -> i32>;

/// 不透明句柄：持有 tokio runtime 与构建好的 Sideloader。
pub struct SignSession {
    rt: tokio::runtime::Runtime,
    sideloader: Sideloader,
    /// `Sideloader` 不暴露 machine_name，保留它以对齐 SideInstaller。
    #[allow(dead_code)]
    machine_name: String,
    #[allow(dead_code)]
    storage_dir: PathBuf,
}

// 只在自己的 runtime 里使用，Swift 侧单队列串行调用。
unsafe impl Send for SignSession {}

/// 包装 2FA 回调上下文，使其可跨线程。
pub(crate) struct TwoFaCtx(pub(crate) *mut c_void);
unsafe impl Send for TwoFaCtx {}
unsafe impl Sync for TwoFaCtx {}

unsafe fn opt(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    CStr::from_ptr(p).to_str().unwrap_or(default).to_string()
}

/// 构建桥接到 Swift 的 2FA 闭包（适配 isideload 0.2.25 的新回调签名：
/// `TwoFactorCallbackParams -> TwoFactorCallbackResponse`）。
pub(crate) fn make_2fa(cb: TwoFactorCb, ctx: TwoFaCtx) -> TwoFactorCallback {
    Box::new(move |_params: TwoFactorCallbackParams| {
        // 解构强制闭包捕获整个 TwoFaCtx（Send+Sync），而不是只捕获
        // 其 `*mut c_void` 字段（原始指针不是 Send/Sync）。
        let TwoFaCtx(ctx_ptr) = ctx;
        let Some(cb) = cb else {
            return TwoFactorCallbackResponse::Abort;
        };
        let mut buf = vec![0u8; 128];
        let rc = cb(ctx_ptr, buf.as_mut_ptr() as *mut c_char, buf.len());
        if rc == 0 {
            return TwoFactorCallbackResponse::Abort;
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        let s = String::from_utf8_lossy(&buf[..end]).trim().to_string();
        if s.is_empty() {
            TwoFactorCallbackResponse::Abort
        } else {
            TwoFactorCallbackResponse::SubmitCode(s)
        }
    })
}

/// 登录 Apple ID、打开开发者会话、构建 Sideloader。返回 0 表示成功；
/// 用 `si_sign_session_free` 释放 session。
///
/// # Safety
/// 所有 `*const c_char` 参数必须为 null 或合法的 C 字符串；out 指针必须有效。
#[allow(clippy::too_many_arguments)]
pub unsafe fn apple_signin(
    apple_id: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    machine_name: *const c_char,
    storage_dir: *const c_char,
    twofa_cb: TwoFactorCb,
    ctx: *mut c_void,
    out_session: *mut *mut SignSession,
    out_summary: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let apple_id = opt(apple_id, "");
    let password = opt(password, "");
    let anisette_url = opt(anisette_url, "https://ani.sidestore.io");
    let machine_name = opt(machine_name, "EscapeSpace");
    let storage_dir = opt(storage_dir, ".");
    let twofa = make_2fa(twofa_cb, TwoFaCtx(ctx));

    let result = catch_unwind(AssertUnwindSafe(|| {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("failed to start runtime: {e}"))?;

        let sideloader = rt.block_on(async {
            tracing::info!("Apple ID: building anisette provider ({anisette_url})");
            let anisette = RemoteV3AnisetteProvider::new(
                &anisette_url,
                Box::new(FsStorage::new(PathBuf::from(&storage_dir))),
                "0".to_string(),
            )
            .map_err(|e| format!("anisette provider: {e}"))?;

            tracing::info!("Apple ID: logging in {apple_id}");
            let mut account = AppleAccount::builder(&apple_id)
                .anisette_provider(anisette)
                .login(&password, twofa)
                .await
                .map_err(|e| format!("login failed: {e}"))?;
            tracing::info!("Apple ID: login OK; opening developer session");

            let dev_session = DeveloperSession::from_account(&mut account)
                .await
                .map_err(|e| format!("developer session: {e}"))?;
            tracing::info!("Developer session OK; building sideloader (first team)");

            let mut sideloader = SideloaderBuilder::new(dev_session, apple_id.clone())
                .team_selection(TeamSelection::First)
                .max_certs_behavior(MaxCertsBehavior::Error)
                .storage(Box::new(FsStorage::new(PathBuf::from(&storage_dir))))
                .machine_name(machine_name.clone())
                .build();

            let team = sideloader
                .get_team()
                .await
                .map_err(|e| format!("get_team: {e}"))?;
            let summary = format!(
                "team: {} ({})",
                team.name.as_deref().unwrap_or("<unnamed>"),
                team.team_id
            );
            Ok::<_, String>((sideloader, summary))
        })?;

        Ok::<_, String>((rt, sideloader))
    }));

    match result {
        Ok(Ok((rt, (sideloader, summary)))) => {
            let session = Box::new(SignSession {
                rt,
                sideloader,
                machine_name,
                storage_dir: PathBuf::from(&storage_dir),
            });
            *out_session = Box::into_raw(session);
            *out_summary = cstr(summary);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during Apple ID sign-in");
            2
        }
    }
}

/// 签名 `ipa_path` 处的 IPA，把签名后的 `.app` 包路径写入 `*out_signed_path`。
///
/// `udid` 会先注册到团队（空串跳过）——不注册 Apple 会以 8220 拒绝描述文件。
///
/// # Safety
/// `session` 必须是 `apple_signin` 返回的有效指针；out 指针有效。
pub unsafe fn sign_ipa(
    session: *mut SignSession,
    ipa_path: *const c_char,
    udid: *const c_char,
    device_name: *const c_char,
    out_signed_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if session.is_null() {
        *out_error = cstr("null session");
        return 2;
    }
    let session = &mut *session;
    let ipa_path = opt(ipa_path, "");
    let udid = opt(udid, "");
    let device_name = opt(device_name, "");

    let result = catch_unwind(AssertUnwindSafe(|| {
        session.rt.block_on(async {
            if udid.is_empty() {
                tracing::warn!(
                    "No device UDID provided; skipping registration — provisioning \
                     profile download may fail with developer error 8220."
                );
            } else {
                let team = session
                    .sideloader
                    .get_team()
                    .await
                    .map_err(|e| format!("device registration failed for UDID {udid}: {e}"))?;
                let name = if device_name.is_empty() {
                    "iPhone"
                } else {
                    device_name.as_str()
                };
                tracing::info!("Ensuring device {udid} ({name}) is registered on team {}", team.team_id);
                session
                    .sideloader
                    .get_dev_session()
                    .ensure_device_registered(&team, name, &udid, None)
                    .await
                    .map_err(|e| format!("device registration failed for UDID {udid}: {e}"))?;
                tracing::info!("Device {udid} is registered on the team");
            }

            tracing::info!("Signing IPA at {ipa_path}");
            let (signed, _special) = session
                .sideloader
                .sign_app(PathBuf::from(&ipa_path), None, false)
                .await
                .map_err(|e| format!("sign_app failed: {e}"))?;
            Ok::<_, String>(signed.to_string_lossy().to_string())
        })
    }));

    match result {
        Ok(Ok(path)) => {
            tracing::info!("Signed bundle at {path}");
            *out_signed_path = cstr(path);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during signing");
            2
        }
    }
}

/// 释放 `SignSession`。
///
/// # Safety
/// `session` 必须为 null 或 `apple_signin` 返回的指针。
pub unsafe fn sign_session_free(session: *mut SignSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

// ---------------------------------------------------------------------------
// C 字符串助手（移植自 SideInstaller 的 ffi_util.rs）
// ---------------------------------------------------------------------------

/// 分配一个调用方用 `si_string_free` 释放的 C 字符串。
pub fn cstr(s: impl Into<Vec<u8>>) -> *mut c_char {
    use std::ffi::CString;
    let c = CString::new(s).unwrap_or_default();
    unsafe { c.into_raw() }
}

/// 释放 `cstr` 产生的堆 C 字符串。
///
/// # Safety
/// `p` 必须为 null 或 `cstr`/`into_raw` 返回的指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_string_free(p: *mut c_char) {
    use std::ffi::CString;
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
