# Changelog

## [0.3.0] - 2026-08-20

### Added

- **Extract app icon from the Apps list**: long-press any app → "提取图标" → iOS share sheet lets the user save the PNG to Photos / Files / AirDrop. The share sheet materializes a temporary file with a meaningful name (e.g. `Filza Mod 图标.png`) so the destination path is sensible.
- **LiveClean UUID display**: each LiveClean row now shows the container UUID beneath the subtitle (monospaced, single line, truncated). The Reclaim screen for that guest shows the same UUID under the app name (also selectable for copy).
- **UUID search**: the LiveClean `.searchable` box now matches on the container UUID in addition to display name / bundle id / host name.

### Fixed

- **Shared apps invisible to LiveClean**: apps that were "Shared" via LiveContainer's Share App flow store their container under `Documents/Shared/Data/Application/<UUID>/` instead of the private `Documents/Data/Application/<UUID>/`. Discovery now walks both trees and labels unmatched shared guests as `<LiveContainer> (共享)`.

## [0.2.0] - 2026-08-20

### Fixed

- **Duplicate LiveClean rows**: the same guest appeared twice because the primary `.app`/LCAppInfo pass and the fallback `LCContainerInfo.plist` pass each inserted a row for the same UUID. Discovery now keeps a single `[uuid: LiveContainerGuest]` map across both passes.
- **Icon missing on the per-guest Reclaim screen**: `ReclaimAppView` only knew about SpringBoard icons from `AppListViewModel.icons`, which doesn't include LiveContainer guests (their `bundleIdentifier` is the synthetic `host::bundleId::uuid`). It now accepts a `guestIcon: Data?` parameter, and `LiveCleanTabView` passes the guest's pre-decoded icon bytes through.

### Added

- **LiveClean search bar**: filter the LiveClean list by display name, bundle id, or host name via `.searchable`.

## [0.1.9] - 2026-08-20

### Fixed

- **LiveClean guests still showed the UUID**: the v0.1.8 join used the `appIdentifier` field from `LCContainerInfo.plist`, but that field stores the container UUID in some LiveContainer builds, so the join against `.app` Info.plist never matched. Discovery is now driven from the `.app` side: it enumerates `Documents/Applications/*.app/`, reads `Info.plist` for the real `CFBundleDisplayName` + `CFBundleIdentifier` + icon, and reads each `.app/LCAppInfo.plist` for `LCDataUUID` (plus the `LCContainers` array for per-account extras) to join back to `Documents/Data/Application/<UUID>/`. `LCContainerInfo.plist` is kept as a fallback for fork layouts that don't carry `LCAppInfo`.

### Changed

- **Chinese localization (FileBrowserView)**: all menus, / selection bar, / context menus, / alerts (rename / new file/folder / password / delete), / share + compress + import progress copy are now Simplified Chinese.

## [0.1.8] - 2026-08-20

### Added

- **Real guest app name + icon in LiveClean**: the list now shows each LiveContainer guest's `CFBundleDisplayName` (from `Documents/Applications/<name>.app/Info.plist`) and its pre-decoded icon, instead of the raw UUID + shippingbox placeholder. Discovery tries `LCContainerInfo.plist` `name` first, then falls back to the guest `.app`'s `Info.plist`. Icons are loaded once inside the sandbox extension and shipped to the UI as `Data` so they survive handle release.

### Changed

- **Chinese localization**: App 列表、空间回收（含安全/会话/保留分区与汇总）、回收空间（ReclaimAppView）、备份列表、恢复确认、属性面板、十六进制编辑、文本查看、备份视图、应用详情（容器访问、容器内容、备份/恢复、重置应用数据）等均改为 Simplified Chinese。FileBrowserView 的菜单/对话框留给下一轮。

## [0.1.7] - 2026-08-20

### Fixed

- **LiveClean found no guest apps**: LiveContainer stores guest containers at `Documents/Data/Application/<UUID>/`, not `Documents/Data/<UUID>/` (the extra `Application/` level was missing). Discovery now walks `Documents/Data` recursively (max depth 2) and accepts both the current `Application/<UUID>` layout and the older flat `<UUID>` layout.
- **Hidden failure reason**: a container-open error was swallowed and surfaced as the generic "No guest apps found" message. LiveClean now distinguishes "LiveContainer not installed" / "could not open the LiveContainer container (<reason>)" / "no guest apps installed".

### Changed

- **Chinese localization**: all LiveClean UI strings, tab names (应用 / 空间回收 / 容器清理 / 备份 / 设置), pairing setup, error and empty states, and the settings form are now in Simplified Chinese.

## [0.1.6] - 2026-08-20

Production IPA after 0.1.5. Build uses the Xcode iPhoneOS SDK so the bundled `libidevice_ffi` (QUICKit/AFFoundation) links cleanly.

### Added

- **LiveClean** tab cleans cache and temp files of apps installed *inside* LiveContainer (and `livecontainer2`/`livecontainer3` instances). It reuses the Reclaim engine — Safe buckets only (`tmp`, `Library/Caches`, logs, splash snapshots, GPU cache). Session data (cookies, WebKit, HTTP storage) and kept data (Documents, Preferences, Application Support) are never touched. Multi-instance aware: each guest app is surfaced from its `LCContainerInfo.plist` and ranked by reclaimable Safe bytes, with batch reclaim.

## [0.1.5] - 2026-08-17

Production IPA after 0.1.4. Hardware-checked on iPhone 17, iOS 26.5.1 (list, browse, Reclaim skip-on-denied, Reset App Data).

### Added

- **Reclaim** tab ranks apps by Safe cache/tmp bytes. Per-app Reclaim Space from App Detail. Batch reclaims Safe buckets only. Session buckets (cookies, WebKit, HTTP storage) are opt-in with a second confirm. Reclaim never deletes Documents, Preferences, or Application Support. Opening an app after a tab scan reuses those Safe sizes instead of measuring again. Locked cache files (permission denied) are skipped instead of failing the whole reclaim.
- **Reset App Data** on App Detail empties Documents, Library, and tmp for that app (not Keychain). Resetting EscapeOS itself also warns that the pairing file will be deleted.

## [0.1.4] - 2026-08-17

Production IPA after 0.1.3. Hardware-checked on iPhone 17, iOS 26.5.1 (list, browse, pairing place, extract, A–Z).

### Added

- Password prompt when extracting an encrypted zip (ZipCrypto and WinZip AES-128/192/256) or encrypted 7z (AES-256, including encrypted names).
- Extract via vendored [SWCompression](https://github.com/tsolomko/SWCompression) 4.8.6: 7z, tar, gzip, bzip2, xz, lz4, lzma, tgz/tbz/txz, and deb. Password zip uses EscapeOS’s own reader. Password 7z uses AES-256 + SHA-256 (same as 7-Zip). RAR is not included (RARLab unrar license).

### Changed

- A–Z letters stay on the right edge; the Apps list scrollbar is hidden so the index receives taps.
- File rows are tappable across the whole cell. Deleting a **file** does not confirm; **folders** still confirm. File viewer Save no longer shows a success alert.
- Removed unused UIKit tab-bar shell (Theos ships SwiftUI `TabView`). `.tar.lz4` / `.tar.lzma` unwrap like the other tarballs.

### Fixed

- Archive member paths cannot leave the extract folder (`..`, `\`, absolute names in gzip headers).
- Password prompt always shows **Extract** (iOS 26 hides disabled alert actions, so an empty-field disable left only Cancel).
- Import Pairing File uses the same Files picker types as Import from Files, so `pairingFile.plist` and iLoader `.mobiledevicepairing` can be selected.

## [0.1.3] - 2026-08-16

Production IPA after 0.1.1. Hardware-checked on iPhone 17, iOS 26.5.1 (list, browse, pairing place).

### Added

- **Compress** in the file browser (long-press or Select → More) zips files and folders into the current folder.
- **Extract** for zip / IPA: tap the archive (or Extract in the menu) to unpack a folder next to it. Open as Hex stays on the menu.

### Fixed

- Share / Save to Files keeps the original filename (no `shared_` prefix). Folders share as `FolderName.zip`.
- Empty Apps list says “No apps found.” instead of a blank search miss.

A–Z jump is the same small index as 0.1.1 (no extra inset beside search).

v0.1.0 and v0.1.1 are unchanged on GitHub.

## [0.1.1] - 2026-08-16

### Added

- **Apps search** and an **A–Z jump index** on the right edge of the app list.
- **Copy confirmation** (banner + haptic) for Bundle ID, name, path, SHA-256, and file Copy/Cut.

v0.1.0 is unchanged on GitHub. This is a new tag and IPA.

## [0.1.0] - 2026-08-14

First public sideload IPA.

- App list via LocalDevVPN. iOS 26.4+ uses Remote Pairing/RSD (`10.7.0.1:49152`); iOS 18 falls back to lockdown loopback (`10.7.0.1:62078`). No USB while using the app.
- Path-scoped Data-container browse, edit, share, backup zip + restore. Select for multi-select Copy/Cut/Paste/Duplicate/Delete; Copy Path, Copy Bundle ID, and Copy SHA-256.
- Pairing setup names EscapeOS and iPASide. iLoader is not required; iPASide writes the same merged pairing file as iLoader and places `pairingFile.plist`.
- README shows the app icon with transparent corners (no black frame).
- Supported container access follows [bad_query](https://github.com/forcequitOS/bad_query): **iOS 26.0–26.6.1** and **iOS 27.0 beta 4**. Later 26.x / 27.x builds are unsupported. IPA `MinimumOSVersion` is 18.0; iOS 18 listing is in code, untested. Hardware-verified: iPhone 17, **iOS 26.5.1**.
- Verified on iPhone 17, iOS 26.5.1, with iPASide placing the pairing file after install (list, browse, Select/copy-paste, backup).
