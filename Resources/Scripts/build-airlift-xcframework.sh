#!/bin/bash
# Build the patched AirliftFFI.xcframework for EscapeOS.
#
# Why this exists (research finding, not a guess):
#   The binary that AirBeep commits under Vendor/AirCard is a *pre-patch* build:
#   it does not contain al_exploit_read_file / al_bytes_free / al_set_target_host.
#   AirBeep's own CI rebuilds the xcframework from AirCard-iOS source every run
#   (clone @ pinned commit + apply airlift-read-file.patch + build-ios.sh), then
#   runs verify-airlift.sh.  EscapeOS follows the exact same path so the shipped
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
BUILD_ROOT="$BUILD_PARENT/escapeos-aircard-$AIRCARD_COMMIT"
PATCH_FILE="$ROOT/Resources/Scripts/airlift-read-file.patch"
OUTPUT_DIR="$ROOT/rust-libs"

# AirCard's build script otherwise defaults to a beta Xcode app that is not
# present on the GitHub runner. setup-xcode has already selected the right one.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

rm -rf "$BUILD_ROOT"
git clone --quiet --filter=blob:none "$AIRCARD_REPO" "$BUILD_ROOT"
git -C "$BUILD_ROOT" checkout --quiet --detach "$AIRCARD_COMMIT"

# Make the Rust LLVM nm available so verify-airlift.sh can inspect the
# patch-added symbols. The Xcode nm cannot read Rust's compiler_builtins
# objects (LLVM version mismatch).
if command -v rustup >/dev/null 2>&1; then
  rustup component add llvm-tools-preview 2>/dev/null || true
fi

git -C "$BUILD_ROOT" apply --check --3way "$PATCH_FILE"
git -C "$BUILD_ROOT" apply --3way "$PATCH_FILE"

"$BUILD_ROOT/build-ios.sh"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/AirliftFFI.xcframework"
cp -R "$BUILD_ROOT/AirliftFFI.xcframework" "$OUTPUT_DIR/AirliftFFI.xcframework"

echo "Built patched AirliftFFI from AirCard-iOS $AIRCARD_COMMIT"
find "$OUTPUT_DIR/AirliftFFI.xcframework" -type f -print
