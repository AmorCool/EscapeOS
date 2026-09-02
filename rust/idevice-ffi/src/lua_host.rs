//! EscapeOS Lua 模块宿主（v0.3.95 起步）。
//!
//! 架构（用户拍板）：解释器编进 App（跟随 App 签名），模块 = 纯 Lua 脚本
//! （数据，无代码签名问题，可热更新）。本 crate = 最小可用 Lua 5.4 (mlua vendored)。
//!
//! 里程碑 1 接口（结果写文件，宿主 SSH 通道可读）：
//!   int lua_host_eval(const char *code, const char *outPath)
//!       —— 表达式求值，把 "OK <值>" 或错误写入 outPath；返回 0=OK -1=Lua 错误
//!   int lua_host_exec(const char *code, const char *outPath)
//!       —— 执行语句块，把 "OK" 或错误写入 outPath；返回 0=OK -1=Lua 错误
//!
//! 安全说明：当前 Lua::new()（全库）仅验证链路；沙箱子集 + 白名单宿主函数
//! （fs/http/module 生命周期）为后续里程碑。

use mlua::{Lua, Value};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::io::Write;

unsafe fn arg(p: *const c_char) -> String {
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

fn write_out(path: &str, text: &str) {
    if let Ok(mut f) = std::fs::File::create(path) {
        let _ = f.write_all(text.as_bytes());
    }
}

/// 把宿主函数注册进 Lua 全局 `host` 表（里程碑 2：白名单宿主 API，模块脚本专用）。
fn register_host(lua: &Lua) -> mlua::Result<()> {
    let host = lua.create_table()?;
    let f_power = lua.create_function(|_, on: bool| Ok(wifi_set_power(on)))?;
    host.set("wifi_power", f_power)?;
    let f_get = lua.create_function(|_, ()| Ok(wifi_get_power()))?;
    host.set("wifi_enabled", f_get)?;
    lua.globals().set("host", host)
}

fn run(code: &str, out_path: &str, eval_mode: bool) -> c_int {
    let result = (|| -> Result<String, String> {
        let lua = Lua::new();
        register_host(&lua).map_err(|e| format!("HOST_REG_ERR {}", e))?;
        if eval_mode {
            match lua.load(code).eval::<Value>() {
                Ok(v) => Ok(format!("OK {}", format_value(&v))),
                Err(e) => Err(format!("EVAL_ERR {}", e)),
            }
        } else {
            lua.load(code).set_name("escapeos_module").exec()
                .map_err(|e| format!("EXEC_ERR {}", e))?;
            Ok("OK".to_string())
        }
    })();
    match result {
        Ok(text) => { write_out(out_path, &text); 0 }
        Err(text) => { write_out(out_path, &text); -1 }
    }
}

fn format_value(v: &Value) -> String {
    match v {
        Value::Nil => "nil".into(),
        Value::Boolean(b) => b.to_string(),
        Value::Integer(i) => i.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.to_str().unwrap_or("<binary string>").to_string(),
        Value::Table(t) => format!("table<{} entries>", t.raw_len()),
        other => format!("{:?}", other),
    }
}

/// 表达式求值：结果（OK <值> 或错误）写入 outPath。返回 0=OK；-1=Lua 错误。
#[unsafe(no_mangle)]
pub extern "C" fn lua_host_eval(code: *const c_char, out_path: *const c_char) -> c_int {
    if code.is_null() || out_path.is_null() { return -2; }
    let (code, out) = unsafe { (arg(code), arg(out_path)) };
    run(&code, &out, true)
}

/// 执行语句块：结果（OK 或错误）写入 outPath。返回 0=OK；-1=Lua 错误。
#[unsafe(no_mangle)]
pub extern "C" fn lua_host_exec(code: *const c_char, out_path: *const c_char) -> c_int {
    if code.is_null() || out_path.is_null() { return -2; }
    let (code, out) = unsafe { (arg(code), arg(out_path)) };
    run(&code, &out, false)
}

// ══════════════ 里程碑 2：宿主函数（WiFi 射频控制）══════════════════
// 底层走 MobileWiFi 私有框架（同 pymobiledevice3 `profile set-wifi-power` 的
// 设备端 API）：WiFiManagerClientCreate / SetPower / GetPower。
// dlopen 系统私有框架在进程内合法；LC/越狱环境可直调。

use libc::{c_char, c_void};
use std::sync::OnceLock;

#[repr(C)]
struct WifiApi {
    create: unsafe extern "C" fn(*const c_void, i32) -> *mut c_void,
    set_power: unsafe extern "C" fn(*mut c_void, i32) -> i32,
    get_power: unsafe extern "C" fn(*mut c_void) -> i32,
}

static WIFI: OnceLock<Option<WifiApi>> = OnceLock::new();

fn wifi_api() -> Option<&'static WifiApi> {
    WIFI.get_or_init(|| unsafe {
        let path = c"/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi";
        let h = libc::dlopen(path.as_ptr(), libc::RTLD_NOW);
        if h.is_null() {
            return None;
        }
        // 保持句柄不 dlclose（进程内常驻）
        let dlsym = |name: &CStr| libc::dlsym(h, name.as_ptr());
        let create = dlsym(c"WiFiManagerClientCreate")?;
        let set_power = dlsym(c"WiFiManagerClientSetPower")?;
        let get_power = dlsym(c"WiFiManagerClientGetPower")?;
        let api = WifiApi {
            create: std::mem::transmute(create),
            set_power: std::mem::transmute(set_power),
            get_power: std::mem::transmute(get_power),
        };
        Some(api)
    })
    .as_ref()
}

fn wifi_set_power(on: bool) -> String {
    unsafe {
        let api = match wifi_api() {
            Some(a) => a,
            None => return "err: MobileWiFi dlopen/符号解析失败".into(),
        };
        let mgr = (api.create)(std::ptr::null(), 0);
        if mgr.is_null() {
            return "err: WiFiManagerClientCreate 返回空".into();
        }
        let rc = (api.set_power)(mgr, if on { 1 } else { 0 });
        let cur = (api.get_power)(mgr);
        if rc == 0 {
            format!("ok: wifi_power({}) → 当前 {}", on, cur)
        } else {
            format!("err: SetPower 返回 {}", rc)
        }
    }
}

fn wifi_get_power() -> String {
    unsafe {
        let api = match wifi_api() {
            Some(a) => a,
            None => return "err: MobileWiFi 不可用".into(),
        };
        let mgr = (api.create)(std::ptr::null(), 0);
        if mgr.is_null() {
            return "err: create 失败".into();
        }
        format!("{}", (api.get_power)(mgr))
    }
}
