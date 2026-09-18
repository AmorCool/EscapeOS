# idevice-ffi

C ABI bindings that let the EscapeOS app drive an iPhone over **Remote Pairing / RSD** and the
lockdown service family — from Swift, with no jailbreak.

This crate is the only Rust component that ends up inside the app. It is compiled as a **single
`staticlib`** (see `[lib] crate-type` in `Cargo.toml`) and linked into the app as
`EscapeOS/Tunnel/libidevice_ffi.a`. The app-side declarations live in
[`idevice.h`](idevice.h) and [`plist.h`](plist.h).

## What it wraps

| Dependency | Purpose |
|---|---|
| [`jkcoxson/idevice`](https://github.com/jkcoxson/idevice) — pinned to a git rev, not crates.io | The device protocols: lockdown, AFC, `installation_proxy`, `installcoordination_proxy`, DVT, `misagent`, RSD, tunneld, house arrest, and so on. |
| [`isideload`](https://github.com/AmorCool/isideload) — AmorCool fork | Apple ID session plus IPA signing. Only the sign-only path (`Sideloader::sign_app`) is used; it never touches the device. |
| [`mlua`](https://crates.io/crates/mlua), `vendored` Lua 5.4 | The in-app Lua host used by the module sandbox. Vendored so the Lua C sources compile into the same static library — one Rust static lib avoids duplicate `std` symbols. |

`idevice.h` is inherited from upstream; the service-level entry points this app actually calls are
added alongside it. Read the header before adding a bridge — several calls carry explicit
thread-affinity contracts (for example the stream/adapter pair must stay on one thread, and the
handle is not thread-safe).

## Feature flags

`default = ["full", "ring"]`. `full` turns on every protocol module; `ring` selects the rustls
crypto provider.

Two things that are easy to get wrong:

- **rustls provider conflict.** `isideload`'s dependency chain pulls in `aws-lc-rs`, while this
  crate asks for `ring`. With both provider features enabled, rustls fails at runtime with
  *"Could not automatically determine the process-level CryptoProvider"*. The FFI entry point
  therefore installs the `ring` provider explicitly instead of relying on auto-detection.
- **Two `idevice` versions coexist on purpose.** `isideload` pins the crates.io `idevice` while
  this crate pins a git revision. The symbols differ, so there is no link conflict.

## Building

`libidevice_ffi.a` is **not committed** (see `.gitignore`). Either download it from the GitHub
Release that ships the IPA, or build it yourself and place it at
`EscapeOS/Tunnel/libidevice_ffi.a` before building the app.

```sh
cd rust/idevice-ffi
cargo build --release --target aarch64-apple-ios
```

Cross-compiling `mlua`'s vendored Lua needs a C toolchain pointed at the iOS SDK.

## Upstream

The bindings track `jkcoxson/idevice` on a best-effort basis.
