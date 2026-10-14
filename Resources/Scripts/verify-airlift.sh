#!/bin/bash
# Verify that the built AirliftFFI.xcframework carries the symbols TequilaDash
# relies on.  Run after build-airlift-xcframework.sh.
#
# Symbol names in a Mach-O static archive are stored as plain null-terminated
# byte strings in the object string tables, regardless of which LLVM version
# produced the objects.  The Xcode-supplied nm cannot parse the
# compiler_builtins objects emitted by newer Rust and crashes with an
# "Unknown attribute kind" error, which would make these symbols look missing.
# So the authoritative check is a raw byte scan of each archive with grep -a
# (which never depends on nm's LLVM version).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

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
NM="$(find_nm || true)"

for library in \
  rust-libs/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a \
  rust-libs/AirliftFFI.xcframework/ios-arm64-simulator/libairlift_ffi.a
do
  if [ ! -f "$library" ]; then
    echo "Airlift library not found: $library" >&2
    exit 1
  fi
  for symbol in al_exploit_read_file al_bytes_free al_set_target_host al_exploit_write_dir; do
    if grep -aq "_${symbol}" "$library"; then
      continue
    fi
    if [ -n "${NM:-}" ] && "$NM" -gU "$library" 2>/dev/null | grep -q "_${symbol}"; then
      continue
    fi
    echo "Airlift library is missing $symbol: $library (nm=$NM)" >&2
    echo "Available _al_ symbols via raw scan:" >&2
    grep -ao "_al_[A-Za-z_][A-Za-z0-9_]*" "$library" | sort -u | head -n 40 || true
    exit 1
  done
done

echo "AirliftFFI symbols verified: al_exploit_read_file al_bytes_free al_set_target_host al_exploit_write_dir"
