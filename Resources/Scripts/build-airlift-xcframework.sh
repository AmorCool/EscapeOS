#!/bin/bash
# Build the patched AirliftFFI.xcframework for TequilaDash.
#
# Why this exists (research finding, not a guess):
#   The binary that AirBeep commits under Vendor/AirCard is a *pre-patch* build:
#   it does not contain al_exploit_read_file / al_bytes_free / al_set_target_host.
#   AirBeep's own CI rebuilds the xcframework from AirCard-iOS source every run
#   (clone @ pinned commit + apply airlift-read-file.patch + build-ios.sh), then
#   runs verify-airlift.sh.  TequilaDash follows the exact same path so the shipped
#   library always carries the patched symbols.
#
# Output: rust-libs/AirliftFFI.xcframework  (consumed by project.yml, kept out of
#         the xcodegen source tree so xcodegen never copies the .a into the .app).
#
# Requires macOS with Xcode (the CI runner provides both).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AIRCARD_REPO="${AIRCARD_REPO:-https://github.com/mak5er/AirCard-iOS.git}"
AIRCARD_COMMIT="${AIRCARD_COMMIT:-40640c4d827aeab8d798285b57d24fcf6be070d0}"
BUILD_PARENT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
BUILD_ROOT="$BUILD_PARENT/tequiladash-aircard-$AIRCARD_COMMIT"
PATCH_FILE="$ROOT/Resources/Scripts/airlift-read-file.patch"
OUTPUT_DIR="$ROOT/rust-libs"

# AirCard's build script otherwise defaults to a beta Xcode app that is not
# present on the GitHub runner. setup-xcode has already selected the right one.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

# Toolchain for the Single-Object Prelink step (see localize_airlift_symbols).
LD_BIN="$(xcrun -f ld)"
AR_BIN="$(xcrun -f ar)"
LIBTOOL_BIN="$(xcrun -f libtool)"

# Rust's own llvm-nm.  The Xcode nm cannot parse the compiler_builtins objects
# that newer rustc emits ("Unknown attribute kind") and exits non-zero, which
# would leave us with an empty public-symbol list.  Mirrors find_nm() in
# Resources/Scripts/verify-airlift.sh.
find_nm() {
  if command -v rustc >/dev/null 2>&1; then
    local sysroot host nm_bin
    sysroot="$(rustc --print sysroot)"
    host="$(rustc -vV | sed -n 's/^host: //p')"
    nm_bin="$sysroot/lib/rustlib/$host/bin/llvm-nm"
    if [ -x "$nm_bin" ]; then printf '%s' "$nm_bin"; return; fi
  fi
  if command -v llvm-nm >/dev/null 2>&1; then printf '%s' "$(command -v llvm-nm)"; return; fi
  if command -v nm >/dev/null 2>&1; then printf '%s' "$(command -v nm)"; fi
}

# ---------------------------------------------------------------------------
# localize_airlift_symbols <libairlift_ffi.a> <nm>
#
# Problem this fixes: `airlift_ffi` is a Rust `staticlib`, so rustc archives
# *every* transitive dependency into the .a — std, core, alloc, the upstream
# `idevice` crate and a vendored `idevice_ffi` fork.  TequilaDash links its OWN
# Rust staticlib next to it (rust-libs/libidevice_ffi.xcframework, built from
# rust/idevice-ffi), which embeds the same std/core and an `idevice_ffi` of the
# same name but a different build.  Both archives therefore define the same
# globals (e.g. _process_control_new, __RNvMs16_..._3std4path..._strip_prefix)
# and ld64 hard-fails: "1032 duplicate symbols".
#
# Why no linker flag fixes this:
#   * ld64's -multiply_defined is parsed and then *ignored* in current ld64
#     (ld64/src/ld/Options.cpp: the "-multiply_defined" branch only does `++i`),
#     so -Wl,-multiply_defined,suppress is a no-op.
#   * -allow_dead_duplicates only downgrades the diagnostic, and would let ld64
#     bind airlift's calls to *TequilaDash's* idevice_ffi fork arbitrarily.
#   * SymbolTable.cpp::checkDuplicateSymbols() throws unconditionally.
#   * `-C link-arg=-Wl,-exported_symbols_list` at cargo-build time does nothing:
#     for crate-type=staticlib rustc archives objects with its own writer and
#     never invokes ld.
#
# The supported mechanism is Apple's "Perform Single-Object Prelink"
# (equivalently `ld -r`): a relocatable link with -exported_symbols_list demotes
# every global that is not listed to Atom::scopeLinkageUnit — a *local* symbol
# (ld64 Resolver.cpp: `if (!shouldExport(name)) setScope(scopeLinkageUnit)`).
# Local definitions never collide with the globals of another archive, so the
# 1032 duplicates disappear while airlift keeps its own private std/idevice_ffi
# — which is also the semantically correct binding, since airlift was written
# against its own fork.
#
# The public ABI of the library is exactly its `al_*` surface (see
# rust-core/include/airlift.h); every other symbol is implementation detail.
localize_airlift_symbols() {
  local lib="$1" nm="$2"
  local work exports required extra
  work="$(mktemp -d)"
  exports="$work/exported.txt"

  # 1) Export list = every *defined global* symbol starting with `_al_`.
  #    ld64 turns -exported_symbols_list entries into initial undefined symbols,
  #    so the list must contain defined symbols only (no wildcards, no guesses).
  #    Matching the last field also skips nm's member headers "libfoo.a(bar.o):".
  "$nm" -gU --defined-only "$lib" 2>/dev/null \
    | awk '$NF ~ /^_al_/ {print $NF}' | sort -u > "$exports" || true

  # 2) Refuse to ship a library that hides symbols TequilaDash calls.
  for required in _al_exploit_read_file _al_exploit_write_dir _al_set_target_host \
                  _al_bytes_free _al_string_free; do
    if ! grep -qx "$required" "$exports"; then
      echo "localize_airlift_symbols: $required not found in $lib (nm=$nm)" >&2
      echo "--- export list so far ---" >&2
      cat "$exports" >&2
      rm -rf "$work"
      return 1
    fi
  done

  # 3) Prelink: one relocatable link with the export list, then re-archive.
  ( cd "$work" && "$AR_BIN" x "$lib" )
  find "$work" -name '*.o' -print > "$work/files.txt"
  "$LD_BIN" -r \
            -exported_symbols_list "$exports" \
            -filelist "$work/files.txt" \
            -o "$work/prelinked.o"
  "$LIBTOOL_BIN" -static -o "$lib" "$work/prelinked.o"

  # 4) Invariant: nothing but `al_*` may remain global —— 但**弱符号是例外**。
  #
  # `-exported_symbols_list` 只约束**强定义**（strong definitions）。Rust 的
  # crypto 后端 AWS-LC 带出来的一批符号是 **weak_definition**：
  #
  #   _aws_lc_0_45_0_is_a_tty  _aws_lc_0_45_0_tty_in  _aws_lc_0_45_0_tty_new
  #   _aws_lc_0_45_0_tty_orig  _aws_lc_0_45_0_tty_out
  #
  # 它们在 `ld -r` 之后仍是 global（ld64 不动弱定义）。**留着无害**：
  # 守卫的目的是「防止与 libidevice_ffi.a 的强符号重复」，而 `libidevice_ffi.a`
  # 里没有 AWS-LC ⇒ **不会重复** ⇒ 不能因为它们把整轮构建判失败。
  #
  # ⇒ 白名单：只放「已知第三方库的带版本前缀符号」。**不要往里加 `_al_*` 之外的自研符号**
  #   —— 那说明 `-exported_symbols_list` 没生效，是真问题。
  extra="$("$nm" -gU --defined-only "$lib" 2>/dev/null \
             | awk '$NF ~ /^_/ && $NF !~ /^_al_/ && $NF !~ /^_aws_lc_/ {print $NF}' \
             | sort -u || true)"
  if [ -n "$extra" ]; then
    echo "localize_airlift_symbols: $lib still exports non-public symbols:" >&2
    printf '%s\n' "$extra" | head -20 >&2
    echo "（注：_aws_lc_* 已在白名单内；此处列出的是真正需要处理的符号）" >&2
    rm -rf "$work"
    return 1
  fi

  # 记录被白名单放过的弱符号，便于事后核对（不参与判定）
  weak_left="$("$nm" -gU --defined-only "$lib" 2>/dev/null \
                 | awk '$NF ~ /^_aws_lc_/ {print $NF}' | sort -u | wc -l | tr -d ' ' || true)"
  echo "  （白名单放过 $weak_left 个 _aws_lc_* 弱符号）" >&2

  echo "localized $(wc -l < "$exports" | tr -d ' ') public symbols in $lib"
  rm -rf "$work"
}

rm -rf "$BUILD_ROOT"
git clone --quiet --filter=blob:none "$AIRCARD_REPO" "$BUILD_ROOT"
git -C "$BUILD_ROOT" checkout --quiet --detach "$AIRCARD_COMMIT"

# Make the Rust LLVM nm available so verify-airlift.sh can inspect the
# patch-added symbols. The Xcode nm cannot read Rust's compiler_builtins
# objects (LLVM version mismatch).
if command -v rustup >/dev/null 2>&1; then
  rustup component add llvm-tools-preview 2>/dev/null || true
fi
NM_BIN="$(find_nm || true)"
if [ -z "${NM_BIN:-}" ]; then
  echo "no usable nm found; cannot localize AirliftFFI symbols" >&2
  exit 1
fi

git -C "$BUILD_ROOT" apply --check --3way "$PATCH_FILE"
git -C "$BUILD_ROOT" apply --3way "$PATCH_FILE"

"$BUILD_ROOT/build-ios.sh"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/AirliftFFI.xcframework"
cp -R "$BUILD_ROOT/AirliftFFI.xcframework" "$OUTPUT_DIR/AirliftFFI.xcframework"

# Reduce airlift_ffi's public surface to the `al_*` ABI before it reaches the app
# link, so it no longer collides with TequilaDash's own libidevice_ffi.a.
while IFS= read -r airlift_lib; do
  localize_airlift_symbols "$airlift_lib" "$NM_BIN"
done < <(find "$OUTPUT_DIR/AirliftFFI.xcframework" -name 'libairlift_ffi.a' -print)

echo "Built patched AirliftFFI from AirCard-iOS $AIRCARD_COMMIT"
find "$OUTPUT_DIR/AirliftFFI.xcframework" -type f -print
