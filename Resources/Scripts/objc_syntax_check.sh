#!/usr/bin/env bash
# ObjC / C 源文件语法预检（WSL 系统 clang + iOS SDK）
#
# 【重要】本项目是 xcodegen + Xcode 工程，**与 Theos 无关**。
#   仓库里没有任何 Theos 工程文件（Makefile / control / *.mk 全无，
#   2026-09-18 已整体删除，只剩 Xcode 一条轨道）。
#
#   这里能用 clang 检查 ObjC/C，靠的是 **iOS SDK 里有 Darwin 头文件**，
#   跟 Theos 一点关系都没有。用的是系统自带的 /usr/bin/clang。
#
#   SDK 实际来源（实测 readlink）：
#     /opt/theos/sdks/iPhoneOS27.2.sdk
#       -> /root/.config/xcross/swift-sdks/xcross-darwin.artifactbundle/...
#   路径里带 theos 只是历史目录名，SDK 本身是 xcross 从 Xcode 里抽的。
#
# 能做到：语法、类型、头文件可见性、ARC 属性/方法是否存在、blocks 语法。
# 做不到：链接、Swift↔ObjC 桥接投影、真机行为（这些只能交 CI）。
#
# 用法（WSL 里、仓库根执行）：
#   bash Resources/Scripts/objc_syntax_check.sh --changed   本次 git 改动里的 .m/.c（默认）
#   bash Resources/Scripts/objc_syntax_check.sh --all       TequilaDash/ 下全部 .m/.c
#   bash Resources/Scripts/objc_syntax_check.sh FILE...     指定文件
#
# 退出码：0 = 全部通过；1 = 有语法错误；2 = 环境缺失。

set -u

CC=$(command -v clang || echo /usr/bin/clang)
SDK_DIR=$(ls -d /opt/theos/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1)

if [ ! -x "$CC" ]; then
  echo "找不到 clang: $CC"
  exit 2
fi
if [ -z "${SDK_DIR:-}" ]; then
  echo "找不到 /opt/theos/sdks/iPhoneOS*.sdk"
  exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
cd "$REPO" || exit 2

case "${1:---changed}" in
  --all)     FILES=$(git ls-files "TequilaDash/*.m" "TequilaDash/*.c" "TequilaDashTunnel/*.m") ;;
  --changed) FILES=$(git diff --name-only HEAD -- "*.m" "*.c" | grep -v "^vendor/" || true) ;;
  *)         FILES="$*" ;;
esac

if [ -z "${FILES:-}" ]; then
  echo "没有需要检查的 .m / .c 文件"
  exit 0
fi

echo "CC  = $CC"
echo "SDK = $SDK_DIR"
echo

FAIL=0
for f in $FILES; do
  [ -f "$f" ] || continue
  OUT=$("$CC" -fsyntax-only -fobjc-arc -fmodules \
        -x objective-c -target arm64-apple-ios18.0 -isysroot "$SDK_DIR" \
        -I TequilaDash -I TequilaDash/Engine -I TequilaDash/Tunnel \
        -I ZSign -I ZSign/common \
        -ferror-limit=20 "$f" 2>&1)
  if [ -n "$OUT" ]; then
    echo "FAIL  $f"
    echo "$OUT" | head -20
    FAIL=1
  else
    echo "OK    $f"
  fi
done

echo
if [ "$FAIL" -ne 0 ]; then
  echo "有语法错误（语法通过 != 能链接，链接与 Swift 桥接仍以 CI 为准）"
  exit 1
fi
echo "语法全部通过（语法通过 != 能链接，链接与 Swift 桥接仍以 CI 为准）"
exit 0
