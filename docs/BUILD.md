# Building EscapeOS

This repository carries two build tracks. Only the first one produces the IPA that ships.

| Track | Defined by | Status | Output |
|---|---|---|---|
| **Xcode 26 native** (default) | `.github/workflows/build-xcode.yml` | **Active in CI** | `EscapeSpace-<version>-xcode-unsigned.ipa` |
| **Theos** | `Makefile` | Local only — no CI workflow | `EscapeSpace-<version>.ipa` (from a `.deb`) |

`.github/workflows/build-xcode.yml` is the **only** workflow in the tree, so a `v*` tag starts
exactly one run. The Theos CI workflow and the separate MHA (MobileHouseArrest) workflow were
deleted; the Theos track survives only as the local `Makefile` path described in section 2.

---

## 1. Xcode 26 native — the shipping track

### Trigger

`.github/workflows/build-xcode.yml` runs on a `v*` tag push, or on manual
`workflow_dispatch`. Branch pushes do **not** build; day-to-day commits on `migrate-xcode`
produce no CI run.

A `v*` tag therefore starts exactly one workflow, and that workflow does everything in a single
run: build, package the unsigned IPA, and publish the GitHub Release.

### What the job does

Runner: `macos-latest`. Job name: `xcode-build`. Permissions: `contents: write` and
`actions: read`.

1. **Checkout**, then **restore file mtimes** from commit history (`git-restore-mtime`). Without
   this, every checkout gives all sources "now" as mtime, Xcode considers the cached
   `DerivedData` stale, and the incremental build cache is worthless.
2. **Select Xcode 26** — newest `/Applications/Xcode_26*.app`, falling back to the newest
   `Xcode*.app`.
3. **Install tooling** via Homebrew: `xcodegen`, `ldid`, `cmake`.
4. **Restore caches** — SAP assets + `DerivedData`, the Rust toolchain, the Cargo registry, and
   sccache. The Cargo and sccache caches use the shared `escapeos-build-cache` scope so they are
   visible to the Theos track too.
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
10. **Package the IPA** — move `EscapeSpace.app` into `Payload/` and `zip -r` from the parent
    directory, so the archive root is `Payload/EscapeSpace.app/...`.
11. **Verify SAP assets** inside the IPA (`SAPAssets/CommerceKit`, `SAPAssets/CoreFP`); a missing
    bundle means Apple ID sign-in will fail at runtime.
12. **Publish the Release** — only on a `v*` tag. Creates
    `EscapeSpace <tag> (Xcode native)` if absent, otherwise re-uploads the asset with
    `--clobber`.

### Output

```
EscapeSpace-<MARKETING_VERSION>-xcode-unsigned.ipa
```

The version in the file name is read from the `MARKETING_VERSION` line of `project.yml`. For
reference, `v0.3.410` published a single asset of 50,595,671 bytes.

### Why the IPA is unsigned

The build deliberately skips code signing:

- `CODE_SIGNING_ALLOWED=NO` and friends mean no Apple certificate or provisioning profile is
  involved anywhere in the pipeline.
- `ldid` is installed by the setup step but is **never invoked**. The step name is stale — an
  earlier revision applied entitlements with it, and the current script explicitly does not,
  because the Homebrew `ldid` asserts on the main binary in CI (`ldid.cpp(852)`) and the shipped
  artifact is not meant to be signed.
- Instead, `EscapeSpace.entitlements` is copied into the `.app` next to the binary, so the
  sideloading tool you use (Sideloadly, ESign, TrollStore) applies it. The file grants
  `get-task-allow`, `com.apple.wifi.manager-access`, and `com.apple.wifi.join-any`.

### Building locally on a Mac

CI is the supported path; a local build needs three generated artifacts that only the CI steps
produce. With Xcode 26 and `brew install xcodegen`:

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
`SWIFT_VERSION = 5.0`, `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` for the version.

Sources are declared at **directory** level (`EscapeOS`, `ZSign`, `Resources`, and the vendored
packages), so new `.swift` files need no project registration. The Theos track is the opposite —
see below.

---

## 2. Theos track

`Makefile` builds the same app with Theos. Its source list is **explicit**
(`EscapeSpace_FILES`), so any new `.swift` file must be added there for this track to see it.

Relevant settings: `TARGET = iphone:clang:16.5:18.0`, `ARCHS = arm64`,
`APPLICATION_NAME = EscapeSpace`, `EscapeSpace_CODESIGN_FLAGS = -SEscapeSpace.entitlements`.

### Local build (Linux / WSL)

```sh
export THEOS=~/theos
make clean package
```

This is what `README.md` documents. The default target pins the **iPhoneOS 16.5 SDK**, because
Apple's 18+/26+ SDKs require Apple Clang and fail under Linux clang.

`EscapeOS/Tunnel/libidevice_ffi.a` is not in git (see the dependencies section). Place it at
`EscapeOS/Tunnel/libidevice_ffi.a` before `make package`, or the link step fails.

There is no CI variant of this track any more. If you ever re-add one, remember that a `v*`-tag
workflow would run on the same tag as the Xcode track and publish a second IPA into the same
Release.

---

## 3. Dependencies and generated inputs

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

## 4. iOS 26 SDK and the tab bar

The floating Liquid Glass tab bar is applied automatically when the app is **linked against the
iOS 26 SDK**, which means Xcode 26. This is an OS-level "linked on or after" rule; runtime hacks
and custom blur styling cannot substitute for it.

The build SDK is raised to 26 while the deployment target stays at 18.0, so iOS 18 devices can
still install the result. Do **not** set `UIDesignRequiresCompatibility` in `Info.plist` for
release builds — that flag opts out of Liquid Glass.

---

## 5. When a build fails

CI is the only compiler this project has (there is no local Xcode on the development machine), so
failures are read from the run, not from a local log:

1. Find the run by `head_sha` — the run-list API is cached and will hand you a stale run.
2. Check each step's conclusion first, then read the failure annotations, which carry
   `file:line` and the compiler message.
3. The workflow also uploads `xcodegen-and-build-logs` (`xcodegen.log`, `xcodebuild.log`,
   `rust-build.log`) and `xcode-package-log` as artifacts, as a fallback when the job log is
   unavailable.

`docs/releasing.md` has the exact commands.
