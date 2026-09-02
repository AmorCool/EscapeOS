// EscapeOS Lua 模块宿主桥接头（由 rust/lua-host 手工维护，与 lib.rs 导出逐一对应）。
#ifndef RUST_LUA_HOST_H
#define RUST_LUA_HOST_H

#ifdef __cplusplus
extern "C" {
#endif

// 表达式求值：把 "OK <值>" 或错误文本写入 outPath。返回 0=成功；-1=Lua 错误；-2=参数空。
int lua_host_eval(const char *code, const char *outPath);
// 执行语句块：把 "OK" 或错误文本写入 outPath。返回 0=成功；-1=Lua 错误；-2=参数空。
int lua_host_exec(const char *code, const char *outPath);

#ifdef __cplusplus
}
#endif

#endif
