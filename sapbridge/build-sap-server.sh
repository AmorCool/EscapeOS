#!/usr/bin/env bash
# 构建 Windows 版 SAP 签名服务（EscapeSapServer.exe）——在 macOS CI 上交叉编译。
#
# 原理：Unicorn 2.1.0 用 mingw-w64 交叉编译出 windows/amd64 静态库，
# Go 服务（cmd/server）以 CGO_ENABLED=1 GOOS=windows CC=mingw 链接它，
# 产出免安装 exe——用户 PC 上直接跑，EscapeOS 走局域网调它签名。
# PC 原生 x86 无 JIT 限制（iOS 27 beta / StikDebug / 磁盘配额全部绕开）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UNICORN_TAG="2.1.0"
OUT_DIR="$SCRIPT_DIR/dist"
WIN_PKG_DIR="$SCRIPT_DIR/.unicorn-official-win"

mkdir -p "$OUT_DIR"

# v0.3.12：改用 unicorn 官方 Windows 构建包（windows_mingw64-static.7z）。
# 此前 mingw-w64 交叉编译的静态库在 uc_mem_map 时 native 崩溃（本机 Windows
# 实锤：Exception 0xc0000005 during cgo uc_mem_map），而官方包在本机全部
# 单元测试通过——交叉编译产物运行时不稳定，官方构建是正解。
PKG_URL="https://github.com/unicorn-engine/unicorn/releases/download/${UNICORN_TAG}/windows_mingw64-static.7z"
UC_INCLUDE="$WIN_PKG_DIR/include"
UC_LIB="$WIN_PKG_DIR/lib/libunicorn.a"

echo "==> [S1/3] Preparing official Unicorn $UNICORN_TAG windows/mingw64-static package"
if [ ! -f "$UC_LIB" ] || [ ! -f "$UC_INCLUDE/unicorn/unicorn.h" ]; then
  rm -rf "$WIN_PKG_DIR"
  mkdir -p "$WIN_PKG_DIR"
  if ! command -v 7z >/dev/null 2>&1; then
    brew list p7zip >/dev/null 2>&1 || brew install p7zip
  fi
  curl -sL -o "$WIN_PKG_DIR/unicorn.7z" "$PKG_URL"
  7z x -y -o"$WIN_PKG_DIR" "$WIN_PKG_DIR/unicorn.7z" >/dev/null
fi
[ -f "$UC_LIB" ] || { echo "error: official libunicorn.a missing"; exit 1; }
[ -f "$UC_INCLUDE/unicorn/unicorn.h" ] || { echo "error: official unicorn headers missing"; exit 1; }
ls -la "$UC_LIB"

echo "==> [S2/3] Building EscapeSapServer.exe (GOOS=windows, cgo + official libunicorn)"
export CGO_ENABLED=1
export GOOS=windows
export GOARCH=amd64
export CGO_CFLAGS="-I$UC_INCLUDE"
# 官方 mingw64 静态库 + 防御性系统库（unicorn 在 Windows 引用 winmm 等）
export CGO_LDFLAGS="-L$WIN_PKG_DIR/lib -lunicorn -lwinmm -lkernel32"
go build -trimpath -o "$OUT_DIR/EscapeSapServer.exe" ./cmd/server

ls -la "$OUT_DIR/EscapeSapServer.exe"
echo "==> done: $OUT_DIR/EscapeSapServer.exe"
