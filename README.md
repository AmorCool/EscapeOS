<div align="center">

<img src="docs/brand/icon.png" alt="EscapeOS" width="128" height="128">

# EscapeOS

On-device sideloading and device-management suite for iOS 18 and later. It reaches app Data containers through a path-scoped sandbox escape and drives privileged device services through a LocalDevVPN + pairing-file tunnel. No jailbreak.

**Sideload the IPA with [iPASide](https://github.com/pwnapplehat/iPASide)** (Windows). iPASide creates the same kind of pairing file as [iLoader](https://iloader.site/docs/) and places `pairingFile.plist` after install. An iLoader file can be imported instead. After that, the PC is not required — EscapeOS talks to this iPhone over LocalDevVPN.

</div>

## What it does

### Files, backup & restore

- Lists every installed app (system included) over the pairing-file tunnel, with search by name or bundle ID and an A–Z jump index.
- Browses an app Data container (`Documents`, `Library`, `tmp`) after consuming a `bad_query` sandbox extension for that container UUID.
- Creates, previews, edits, and shares files in that container (share keeps the original name). Compress makes a zip of the current directory. Tap zip, 7z, tar, gz, bz2, xz, lz4, lzma, or deb to extract; encrypted zip and 7z ask for a password. RAR is not unpackable. Select in the top right for multi-select Copy, Cut, Paste, Compress, Duplicate, and Delete. Copy Path / Copy Bundle ID put text on the system clipboard and show a confirmation.
- Opens a file with the right viewer: text, image, PDF, media, hex (in-place byte editing under 512 KB), or a plist editor for `.plist` files.
- Shows full file properties — SHA-256, UTType, POSIX permissions, owner/group, executable bit, symlink target — read while the sandbox extension is held.
- Browses the AFC media root (`/var/mobile/media`: DCIM, Downloads, Recordings) to upload, download, rename, move, create directories, and delete, plus a text editor for small files.
- Lists apps that enabled document sharing and opens their Documents tree.
- Exports a zip + `manifest.json` (SHA-256 per file) into Files → On My iPhone → EscapeSpace → Backups, and restores that archive into the same app's current container.
- **Reclaim** ranks apps by cache/tmp size and can empty Safe buckets (`tmp`, `Library/Caches`, `Library/Logs`, `Library/SplashBoard`, `Library/GPUCache`). Session buckets (Cookies, HTTPStorages, WebKit, Saved Application State) are opt-in per app. Documents, Preferences, and Application Support are never reclaimed. The same cleanup runs against apps installed inside LiveContainer.
- **Reset App Data** on an app's detail screen empties that app's Documents, Library, and tmp. It does not touch Keychain or App Groups.

### App Store sideload (Apple ID)

- Browses App Store charts and search results and opens app detail pages, backed by Apple's public iTunes Search / Lookup / RSS endpoints, with the full 134-region storefront table.
- Signs in with real Apple ID accounts through a local SAP login, keeps multiple accounts, and picks which one downloads. An account health check reports the `dsid` / `passwordToken` / cookie count that Apple requires before it will hand over a package.
- Lists a full version history per app and can download a specific historical version.
- Reads the purchase history (DMAP) of a signed-in account — read-only, searchable by name, bundle ID, or app ID.

### Free stores (no sign-in)

- **i4** source: topic and chart listings, app detail with the full history-version list and the vendor's own privacy section. Packages are the vendor's already-signed IPAs.
- **Niuwa** source: a second catalog with China and US regions, with search, detail pages, and direct download of the free link.

### Downloads & install

- **Download manager** for every source, with a persistent ledger, resume, and per-item actions (copy the App Store link, extract the original IPA URL).
- **IPA sideload**: pick an IPA (local file or URL) → Apple ID login → sign → install over the tunnel.
- **Signed IPA install**: hand an already-signed IPA to `installation_proxy` — new install, overwrite, or downgrade (installd allows downgrades that the App Store client refuses). Encrypted packages go through the SINF path.
- Writes the current pairing file into other sideload tools on the device (SideStore, LiveContainer, Feather, StikDebug) so they reuse the same pairing identity.
- Sends a provisioning profile to the device for installation from Settings, and installs carrier `.ipcc` files through the same system pipeline as Finder / iTunes.
- Downloads the developer disk image (DDI) and the kernelcache for the connected device.

### Cleanup & storage

- **Device slim**: the 7-item space breakdown plus system-cache / temp-file cleanup, and a "larger apps" table with app size and document size per app.
- **Storage detail** panel reads the NVMe controller directly through `diagnostics_relay`.
- Reclaim and device-slim scans measure first and delete nothing until you confirm.

### Device tools

- **Device info**: model, system, CPU, storage, and the rest of the hardware panel.
- **Battery health**: health, cycle count, capacity, serial number, charger and adapter readings.
- **Device control**: respring (SIGKILL or web-crash), reboot, shut down, or enter recovery mode.
- **Process manager**: list, suspend, and kill device processes.
- **Enable JIT**: launch an app in debug mode. **Launch apps** starts any installed app in the foreground.
- **Increase memory limit**: raises an app's memory cap through the Apple Developer API.
- **Certificates**: list and revoke the Apple ID's iOS development certificates. **App expiry** manages `.mobileprovision` expiry. **Profiles** lists and deletes configuration profiles via `misagent`.
- **MDM**: sandbox-escape strategies with profile backup / restore (personal testing only; the device may refuse on newer iOS).
- **Configurations**: lock-screen footnote and the supervised-mode panels (app hiding, notification and restriction tweaks, web clips).
- **Domain blocker**: generates a DNS-blocking profile for any domain list.
- **Crash analysis**: reads the on-device crash and diagnostic logs, with batch export and delete.
- **SSH debug server**: connects over the LAN for log and diagnostic access. **PiP keep-alive** keeps the app alive in the background.
- **Device toggles**: developer mode (enable only — iOS has no remote way to turn it off) and LAN Wi-Fi pairing.

### Gestalt & modules

- **Gestalt**: reads and edits MobileGestalt values with automatic backup before each apply.
- **Modules**: imports, enables, runs, and uninstalls on-device modules distributed as signed packages, with per-module settings and logs.

### Extras

- **Virtual location**: map-based location simulation with routes, a joystick for continuous movement, saved places, and an optional Bluetooth panel. Runs as a single-device self-tunnel session and keeps simulating after you leave the page.
- **Wallpapers**: imports wallpaper packages and applies them to PosterBoard.
- **Ringtones**: import, export, rename, delete, and preview ringtone files inside the media directory.
- **Dialer theme**: replaces the dialer keyboard artwork in the telephony container.

## What it does not do

- Other apps' Keychain data. (EscapeOS keeps its own Apple ID credentials in its own Keychain entries; it never reads another app's.)
- Other apps' App Groups. LiveContainer guest containers are reachable only through the container extensions the host app grants.
- Arbitrary system paths (`/var/mobile`, parent container directories). The file browser is limited to app Data containers and, over AFC, the media root.
- The app's signed `.app` bundle (Data container only).
- Anything the tunnel services do not expose. There is no jailbreak, no root shell, and no arbitrary write to system locations — privileged operations are limited to what `lockdownd`, DVT, MCInstall, `misagent`, and `installation_proxy` accept.
- iOS 15, 16, or 17 (the IPA will not install; `MinimumOSVersion` is 18.0).

## Compatibility

The IPA will install on iOS 18.0 or later (`MinimumOSVersion` 18.0). **Opening another app's Data container** uses [bad_query](https://github.com/forcequitOS/bad_query), whose upstream range is **iOS 26.0 through 26.6.1**, plus **iOS 27.0 beta 4** only. Builds outside that list are unsupported, not assumed.

| System | `bad_query` (browse / backup) | App listing (LocalDevVPN) | Hardware |
|---|---|---|---|
| iOS 18.0 – 18.x | Untested upstream (“might also work”). | In this build: lockdown loopback `10.7.0.1:62078`. | **Not tested here** |
| iOS 26.0 – 26.3 | Upstream: yes (26.0–26.6.1). | Remote Pairing listing is a **26.4+** recipe; lockdown on these builds is untested. | **Not tested here** |
| iOS 26.4 – 26.6.1 | Upstream: yes. | Remote Pairing / RSD `10.7.0.1:49152`. | **Verified** 26.5.1 (iPhone 17: list, browse, Select/copy-paste, backup, pairing place, Compress/Extract, share names, Reclaim, Reset App Data) |
| iOS 26.7 and later | **Unsupported** (outside bad_query). | — | — |
| iOS 27.0 beta 4 | Upstream: yes. | Untested here. | **Not tested here** |
| iOS 27.0 beta 5 and later | **Unsupported** (outside bad_query). | — | — |

iOS 15, 16, and 17 cannot install this IPA.

## Requirements

On a compatible build above: phone + LocalDevVPN + Wi-Fi. No USB while using the app.

| | iOS 18 | iOS 26.4 – 26.6.1 |
|---|---|---|
| **App listing** | Lockdown loopback on `10.7.0.1:62078` (StikDebug 17.4–18 recipe). | Remote Pairing / RSD on `10.7.0.1:49152` (StikDebug 3.1+ / iOS 26.4 recipe). |
| **Pairing file** | USB-trust (lockdown) keys are enough. iPASide still writes Remote Pairing keys into the same file. | Lockdown-only files fail. File must include Remote Pairing keys (`identifier`, Ed25519 `public_key` / `private_key`). |

Also required:

- [LocalDevVPN](https://apps.apple.com/app/id6755608044) on default `10.7.0.1`
- Wi-Fi on
- Pairing file from [iPASide](https://github.com/pwnapplehat/iPASide) (Create keys / Place) or iLoader import. PC is only for minting and placing that file.

## Sideload

1. Install [iPASide](https://github.com/pwnapplehat/iPASide/releases/latest) on Windows.
2. Download `EscapeSpace-<version>-xcode-unsigned.ipa` from this repo's [Releases](https://github.com/AmorCool/EscapeOS/releases). The IPA is **unsigned** — your sideloading tool applies the bundled entitlements.
3. Sideload it with iPASide.
4. Trust the developer profile on the iPhone.
5. iPASide places `pairingFile.plist` automatically after sideload. To do it later: Settings → Pairing file → Place.
6. Unplug if you want. Install LocalDevVPN, connect it, leave Wi-Fi on, then open EscapeOS.

## Why a pairing file (not House Arrest)

House Arrest is a **PC → phone** lockdown service. iPASide uses it to write `pairingFile.plist` into EscapeOS's Documents (same path as Files sharing). That is how the pairing file *arrives*. It is not a way for EscapeOS, running on the iPhone, to see other apps.

A sideloaded app cannot enumerate other apps or their Data containers by itself (`LSApplicationWorkspace` and listing `/var/mobile/Containers/…` stay blocked). EscapeOS therefore:

1. Uses the pairing file over LocalDevVPN to talk to `installation_proxy` as a trusted host, which is what fills the app list and each Data-container path.
2. Opens that container with `bad_query` so Documents, Library, and tmp are all reachable. House Arrest's usual `VendDocuments` is Documents-only, and only for apps that enabled file sharing.

Without the pairing file there is no app list and no container paths to open. Keep using iPASide **Place** (or import an iLoader file). The PC is not needed after that.

## Build

One track builds this tree. Details in `docs/BUILD.md`.

**GitHub Actions — the shipping path.** Push a `v*` tag and `.github/workflows/build-xcode.yml` runs on `macos-latest` with Xcode 26 (iOS 26 SDK): `xcodegen generate` → `xcodebuild` → unsigned IPA → GitHub Release, all inside one workflow. The artifact is `EscapeSpace-<version>-xcode-unsigned.ipa`. No `ldid` pass is applied; `EscapeSpace.entitlements` ships inside the `.app` for the sideloading tool to apply.

It is also the **only** workflow in the repository — the old Theos and MHA (MobileHouseArrest) tracks have been removed, so a tag starts exactly one build.

**Native Xcode 26 on macOS.** Open the project on a Mac with Xcode 26 and archive against the iOS 26 SDK; linking against that SDK is what enables Liquid Glass. The deployment target stays at iOS 18.0.

`EscapeOS/Tunnel/libidevice_ffi.a` (~93 MB) is not in git — fetch it from the matching GitHub Release or rebuild `jkcoxson/idevice` for `aarch64-apple-ios` before building.

Common settings: product name `EscapeSpace`, bundle ID `com.ipaside.escapeos`, deployment target iOS 18.0, project generated by XcodeGen from `project.yml`.

After reinstalling, place `pairingFile.plist` again from the PC: iPASide Settings → Pairing file → Place (House Arrest), or share the file in Files.

## License

[GNU AGPL-3.0](LICENSE). Third-party origins are listed in [NOTICE](NOTICE): StikDebug adaptations (AGPL-3.0), `jkcoxson/idevice` (MIT), SWCompression / BitByteData (MIT), and `forcequitOS/bad_query` (no upstream license at adaptation time).
