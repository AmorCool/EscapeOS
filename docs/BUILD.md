# Building EscapeOS

This repository carries exactly **one** build track.

| Track | Defined by | Status | Output |
|---|---|---|---|
| **Xcode 27 native** | `.github/workflows/build-xcode.yml` | **Active** | `EscapeSpace-<version>-xcode-unsigned.ipa` + `EscapeSpace-Tunnel-<version>-xcode-unsigned.ipa` |

`.github/workflows/build-xcode.yml` is the **only** workflow in the tree, so a `v*` tag starts
exactly one run.

The two other tracks that used to exist are **gone**: the Theos track (its `Makefile` and its CI
workflow `build.yml`) and the MHA / MobileHouseArrest track (`mha-build.yml`). Both CI workflows
had been `disabled_manually` for a long time before the files were deleted. Only the Xcode track
ever produced the shipping IPA.

---

## 1. Xcode 27 native — the shipping track

### Trigger

`.github/workflows/build-xcode.yml` runs on a `v*` tag push, or on manual
`workflow_dispatch`. Branch pushes do **not** build; day-to-day commits on `migrate-xcode`
produce no CI run.

A `v*` tag therefore starts exactly one workflow, and that workflow does everything in a single
run: it either reuses a successful build of the same commit or compiles from scratch, then
packages the unsigned IPA and publishes the GitHub Release.

### What the job does

Runner: `xcode-27` (a self-hosted image label — **not** `macos-latest`). The workflow has two
jobs: `promote` (decides whether a prior successful build of the same commit can be reused) and
`xcode-build` (compile + package). Permissions: `contents: write` and `actions: read`.

1. **Checkout**, then **restore file mtimes** from commit history (`git-restore-mtime`). Without
   this, every checkout gives all sources "now" as mtime, Xcode considers the cached
   `DerivedData` stale, and the incremental build cache is worthless.
2. **Select Xcode 27** — prefer the newest `/Applications/Xcode_27*.app`, falling back to the
   newest `Xcode_26*.app`, then to any `Xcode*.app`. A following step installs the Metal
   toolchain, which Xcode 27 ships as a separate component
   (`xcodebuild -downloadComponent MetalToolchain`; the repo has `EscapeOS/Views/LiquidGlassOrb.metal`).
3. **Install tooling** via Homebrew: `xcodegen`, `cmake` (no `ldid` — it was removed from the
   dependency list).
4. **Restore caches** — SAP assets + `DerivedData`, the Rust toolchain, the Cargo registry, and
   sccache. The Cargo and sccache caches use the shared `escapeos-build-cache` scope.
5. **Build `libidevice_ffi.a`** for `aarch64-apple-ios` from the vendored `rust/idevice-ffi`
   source, unless the cross-run artifact cache reports a source-hash hit. Then assemble
   `rust-libs/libidevice_ffi.xcframework` and copy `idevice.h` to `EscapeOS/Tunnel/`.
6. **Sync bundled modules** — shallow-clone `AmorCool/module-esc` and copy `modules/*` into
   `Resources/BundledModules/`.
7. **Build `libcrypto.a`** from OpenSSL 3.3.2 (`iphoneos-cross no-asm`), cached in
   `openssl-build/`. ZSign's ad-hoc re-signing needs it.
8. **`xcodegen generate`** — `project.yml` produces `EscapeSpace.xcodeproj`.
9. **`xcodebuild build`** with `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGN_IDENTITY=""`,
   `CODE_SIGNING_REQUIRED=NO`, `-derivedDataPath build`. Compiled errors are re-emitted as
   `::error::` annotations, because the anonymous API can read annotations but not the job log.
10. **Package the IPAs (dual version)** — from the one compiled `EscapeSpace.app`, produce two
    archives by copying the app into `Payload/` and `zip -r` from the parent directory, so each
    archive root is `Payload/EscapeSpace.app/...`:
    - **standard**: bundle `EscapeSpace.entitlements` (no Network Extension rights);
    - **tunnel**: bundle `EscapeSpace-Tunnel.entitlements` on the app **and**
      `EscapeOSTunnel.entitlements` inside `PlugIns/EscapeOSTunnel.appex`, both granting
      `packet-tunnel-provider`.

    The two IPAs are byte-identical except for the entitlements files they carry — no second
    compile happens.
11. **Verify SAP assets** inside *both* IPAs (`SAPAssets/CommerceKit`, `SAPAssets/CoreFP`); a
    missing bundle means Apple ID sign-in will fail at runtime. The tunnel IPA is additionally
    checked for the Network Extension entitlement on both the app and the `.appex`.
12. **Publish the Release** — only on a `v*` tag. Creates
    `EscapeSpace <tag> (Xcode native)` if absent, otherwise re-uploads the assets with
    `--clobber`. Both IPAs are attached.

### Output

```
EscapeSpace-<MARKETING_VERSION>-xcode-unsigned.ipa
EscapeSpace-Tunnel-<MARKETING_VERSION>-xcode-unsigned.ipa
```

The version in each file name is read from the `MARKETING_VERSION` line of `project.yml`. For
reference, `v0.3.410` published a single asset of 50,595,671 bytes (before the tunnel build
existed).

### Why the IPA is unsigned

The build deliberately skips code signing:

- `CODE_SIGNING_ALLOWED=NO` and friends mean no Apple certificate or provisioning profile is
  involved anywhere in the pipeline.
- `ldid` is **not installed at all** — it was dropped from the Homebrew install step on
  2026-09-18 because nothing in the pipeline ever invoked it. An earlier revision applied
  entitlements with it, but the Homebrew `ldid` asserts on the main binary in CI
  (`ldid.cpp(852)`) and the shipped artifact is not meant to be signed.
- Instead, an entitlements file is copied into the `.app` next to the binary, so the sideloading
  tool you use (Sideloadly, ESign, TrollStore) applies it:
  - the standard IPA carries `EscapeSpace.entitlements`, granting `get-task-allow`,
    `com.apple.wifi.manager-access`, and `com.apple.wifi.join-any`;
  - the tunnel IPA carries `EscapeSpace-Tunnel.entitlements` (the same three **plus**
    `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`) on the app, and
    `EscapeOSTunnel/EscapeOSTunnel.entitlements` inside the embedded `.appex`. Signing the tunnel
    build therefore needs a certificate that includes the Network Extension capability, and the
    signer must apply the extension's entitlements too.

### Building locally on a Mac

CI is the supported path; a local build needs three generated artifacts that only the CI steps
produce. With Xcode 27 and `brew install xcodegen`:

```sh
# 1. Rust FFI (see the workflow's "Build libidevice_ffi.a" and "Assemble ... xcframework" steps)
#    rust-libs/libidevice_ffi.xcframework must exist before xcodegen runs — project.yml links it.
# 2. OpenSSL static libcrypto for ios arm64 -> openssl-build/libcrypto.a
# 3. SAP assets: /usr/bin/python3 Resources/Scripts/prepare.sap.py  (runs as a preBuildScript)

xcodegen generate
xcodebuild build \
  -project EscapeSpace.xcodeproj \
  -scheme EscapeSpace-iOS \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

Key settings, all in `project.yml`: `PRODUCT_NAME = EscapeSpace`,
`PRODUCT_BUNDLE_IDENTIFIER = com.ipaside.escapeos`, `IPHONEOS_DEPLOYMENT_TARGET = 18.0`,
`SWIFT_VERSION = 6.0`, `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` for the version.

Sources are declared at **directory** level (`EscapeOS`, `ZSign`, `Resources`, and the vendored
packages), so new `.swift` files need no project registration. (`ZSign` is a **runtime**
dependency of the app — it signs native modules — so it stays even though the Theos track is
gone.)

If a second `v*`-tag workflow is ever added, remember it would run on the same tag and publish a
second IPA into the same Release.

---

## 2. Dependencies and generated inputs

| Item | Where it comes from | Notes |
|---|---|---|
| `EscapeOS/Tunnel/libidevice_ffi.a` | Built from `rust/idevice-ffi` in CI | **Git-ignored** (`.gitignore`). Never committed. |
| `rust/idevice-ffi/` | Vendored `jkcoxson/idevice` FFI (BSD-3) plus the `si_run_host` engine | Built for `aarch64-apple-ios`; `IPHONEOS_DEPLOYMENT_TARGET` is pinned to 18.0 to match the app. |
| `rust-libs/libidevice_ffi.xcframework` | Assembled by the Xcode workflow before `xcodegen generate` | Referenced by `project.yml`; absent from a fresh clone. |
| `openssl-build/libcrypto.a` | OpenSSL 3.3.2, `iphoneos-cross no-asm` | Needed by ZSign. Cached across runs. |
| `Resources/BundledModules/` | `AmorCool/module-esc`, cloned during the Xcode build | Folder reference in the bundle, so the `<id>/module.json` layout is preserved. |
| `Resources/SAPAssets/` | `Resources/Scripts/prepare.sap.py` (preBuildScript) | Unicorn + Apple SAP assets. Missing assets break Apple ID sign-in. |
| `Resources/AppIcon*.png`, `docs/brand/icon.png` | `python3 tools/generate_icons.py` | Regenerates the PNG set from `assets/EscapeOS-icon-master.png` (1024x1024, transparent corners). Requires Pillow. |

A prebuilt `libidevice_ffi.a` (97,089,368 bytes) still exists as an asset of the legacy
`pwnapplehat/EscapeOS` v0.1.5 release. The current repository's Releases carry **only the IPA** —
there is no `.a` to download from them.

---

## 3. iOS 26 SDK and the tab bar

The floating Liquid Glass tab bar is applied automatically when the app is **linked against the
iOS 26 SDK**, which in this repo means building with **Xcode 27** (its Swift 6.4 compiler; the
language mode stays at Swift 6.0). This is an OS-level "linked on or after" rule; runtime hacks
and custom blur styling cannot substitute for it.

The build SDK is raised to 26 while the deployment target stays at 18.0, so iOS 18 devices can
still install the result. Do **not** set `UIDesignRequiresCompatibility` in `Info.plist` for
release builds — that flag opts out of Liquid Glass.

---

## 4. When a build fails

CI is the only compiler this project has (there is no local Xcode on the development machine), so
failures are read from the run, not from a local log:

1. Find the run by `head_sha` — the run-list API is cached and will hand you a stale run.
2. Check each step's conclusion first, then read the failure annotations, which carry
   `file:line` and the compiler message.
3. The workflow also uploads `xcodegen-and-build-logs` (`xcodegen.log`, `xcodebuild.log`,
   `rust-build.log`) and `xcode-package-log` as artifacts, as a fallback when the job log is
   unavailable.

`docs/releasing.md` has the exact commands.
