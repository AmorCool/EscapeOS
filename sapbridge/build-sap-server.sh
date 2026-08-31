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
UNICORN_SRC="$SCRIPT_DIR/.unicorn-src"
UNICORN_BUILD_WIN="$SCRIPT_DIR/.unicorn-build-win"
OUT_DIR="$SCRIPT_DIR/dist"
MINGW_CC="x86_64-w64-mingw32-gcc"
MINGW_RC="x86_64-w64-mingw32-windres"

mkdir -p "$OUT_DIR"

echo "==> [S1/3] Preparing Unicorn $UNICORN_TAG source (windows cross)"
if [ ! -d "$UNICORN_SRC/.git" ]; then
  rm -rf "$UNICORN_SRC"
  git clone --depth 1 --branch "$UNICORN_TAG" https://github.com/unicorn-engine/unicorn.git "$UNICORN_SRC"
fi

echo "==> [S2/3] Building libunicorn.a for windows/amd64 (mingw cross)"
if [ ! -f "$UNICORN_BUILD_WIN/libunicorn.a" ]; then
  cmake -S "$UNICORN_SRC" -B "$UNICORN_BUILD_WIN" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER="$MINGW_CC" \
    -DCMAKE_RC_COMPILER="$MINGW_RC" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DUNICORN_BUILD_TESTS=OFF \
    -DUNICORN_BUILD_SAMPLES=OFF \
    -DUC_ARCH=x86_64 \
    -DUC_MODE=x86_64
  cmake --build "$UNICORN_BUILD_WIN" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi
[ -f "$UNICORN_BUILD_WIN/libunicorn.a" ] || { echo "error: windows libunicorn.a not produced"; exit 1; }

echo "==> [S3/3] Building EscapeSapServer.exe (GOOS=windows, cgo mingw)"
export CGO_ENABLED=1
export GOOS=windows
export GOARCH=amd64
export CC="$MINGW_CC"
export CGO_CFLAGS="-I$UNICORN_SRC/include"
export CGO_LDFLAGS="-L$UNICORN_BUILD_WIN -lunicorn"
go build -trimpath -o "$OUT_DIR/EscapeSapServer.exe" ./cmd/server

ls -la "$OUT_DIR/EscapeSapServer.exe"
echo "==> done: $OUT_DIR/EscapeSapServer.exe"
