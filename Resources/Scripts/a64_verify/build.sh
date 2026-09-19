#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A-64 验证 harness 的构建脚本（**临时**：验证通过后连同 workflow 一起删除）
#
#  只做两件事：
#    ① 按 Resources/Scripts/prepare.sap.py **完全同款**的参数编出 Unicorn TCI 解释器
#       （UC_ARCH_X86 / 解释模式 / 静态库）—— 参数从 prepare.sap.py 里**读出来**，
#       不在这里重复写死，避免两处漂移。
#    ② 用 MachImage.cpp + SapMachine.cpp（只取其中的 SapShims）+ main.cpp 编出验证程序。
#
#  用法：  ./build.sh [输出目录]        默认 <repo>/_build/a64_verify
#  产物：  <输出目录>/a64_verify
#
#  为什么不用 prepare.sap.py 直接编：它要求 DERIVED_FILE_DIR / PLATFORM_NAME /
#  TARGET_BUILD_DIR 等一整套 Xcode 环境变量，在裸 runner 上跑不起来。
#  这里只复刻它的 cmake 参数与「下载 → sha256 校验 → 解包」这一段。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$ROOT/_build/a64_verify}"
SAP_DIR="$ROOT/EscapeOS/Services/AppleAuth/SAP"
PREP="$ROOT/Resources/Scripts/prepare.sap.py"

mkdir -p "$OUT"

# ── 从 prepare.sap.py 读 REVISION / ARCHIVE_SHA256（避免两处写死漂移）─────────
read -r REVISION ARCHIVE_SHA256 < <(python3 - "$PREP" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("prep", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.REVISION, m.ARCHIVE_SHA256)
PY
)
echo "[build] unicorn revision = $REVISION"

# ── ① Unicorn（解释器，x86）─────────────────────────────────────────────────
UNICORN_SRC="$OUT/unicorn-src"
if [ ! -d "$UNICORN_SRC" ]; then
    TAR="$OUT/unicorn.tar.gz"
    if [ ! -f "$TAR" ]; then
        echo "[build] 下载 unicorn 源码…"
        curl -fsSL "https://codeload.github.com/Naville/unicorn/tar.gz/$REVISION" -o "$TAR"
    fi
    echo "$ARCHIVE_SHA256  $TAR" | shasum -a 256 -c -
    mkdir -p "$UNICORN_SRC"
    tar -xzf "$TAR" -C "$UNICORN_SRC" --strip-components=1
fi

UNICORN_BUILD="$OUT/unicorn-build"
if [ ! -f "$UNICORN_BUILD/libunicorn.a" ]; then
    echo "[build] 编 Unicorn（与 prepare.sap.py 同款参数）…"
    cmake -S "$UNICORN_SRC" -B "$UNICORN_BUILD" \
        -DUNICORN_INTERPRETER=ON -DUNICORN_ARCH=x86 -DUNICORN_BUILD_TESTS=OFF \
        -DUNICORN_INSTALL=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
    cmake --build "$UNICORN_BUILD" -j "$(sysctl -n hw.ncpu)"
fi

# ── ② harness ───────────────────────────────────────────────────────────────
echo "[build] 编 a64_verify…"
clang++ -std=gnu++20 -O1 -g \
    -I "$SAP_DIR" \
    -I "$UNICORN_SRC/include" \
    "$HERE/main.cpp" \
    "$SAP_DIR/MachImage.cpp" \
    "$SAP_DIR/SapMachine.cpp" \
    "$UNICORN_BUILD/libunicorn.a" \
    -lc++ \
    -o "$OUT/a64_verify"

echo "[build] 完成：$OUT/a64_verify"
