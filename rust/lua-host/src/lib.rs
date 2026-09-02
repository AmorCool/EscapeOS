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
use std::ffi::{CStr, CString};
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

fn run(code: &str, out_path: &str, eval_mode: bool) -> c_int {
    let result = (|| -> Result<String, String> {
        let lua = Lua::new().map_err(|e| format!("LUA_INIT_ERR {}", e))?;
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
#[no_mangle]
pub extern "C" fn lua_host_eval(code: *const c_char, out_path: *const c_char) -> c_int {
    if code.is_null() || out_path.is_null() { return -2; }
    let (code, out) = unsafe { (arg(code), arg(out_path)) };
    run(&code, &out, true)
}

/// 执行语句块：结果（OK 或错误）写入 outPath。返回 0=OK；-1=Lua 错误。
#[no_mangle]
pub extern "C" fn lua_host_exec(code: *const c_char, out_path: *const c_char) -> c_int {
    if code.is_null() || out_path.is_null() { return -2; }
    let (code, out) = unsafe { (arg(code), arg(out_path)) };
    run(&code, &out, false)
}
