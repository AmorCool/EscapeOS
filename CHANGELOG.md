# Changelog

## [0.2.14] - 2026-08-21

### Changed

- **项目更名 EscapeOS → EscapeSpace**. 应用名（二进制 / `CFBundleExecutable` / `CFBundleDisplayName` / `control` Name / `@main` 结构体）统一改为 EscapeSpace；设置页「关于」行、各项备份路径提示文案（「文件 → 我的iPhone → EscapeSpace → Backups」）、限制说明与错误提示中的可见产品名同步更新。Bundle ID（`com.ipaside.escapeos`）保持不变，以免破坏已建立的配对文件与备份。源码目录 `EscapeOS/` 与内部错误域、日志串、`EscapeOS-Bridging-Header.h`、持久化元数据键 `escapeOSVersion` 等有意保留，避免影响既有备份兼容性与隧道认证。
- **移除设置页「诊断（调试用）」区块**. 删除 AppGroup 探测按钮、结果滚动视图、分享结果与相关状态 / 方法（`runProbe` / `shareProbeResult` / `isoTimestamp`），并删除引擎文件 `Engine/AppGroupProbe.swift`。该探测仅用于前期研究取证，对普通用户无意义。
- **应用列表移除右侧 A–Z 字母跳转索引**. 删去覆盖在列表右侧的蓝色字母条与 `sectionIndex` / `jumpToLetter` 逻辑，列表恢复普通滚动（应用仍按名称分组）。
- **更新 App 图标**. 替换为新的垃圾桶（回收）风格图标，重新生成 1024×1024 主图与全套 `Resources/AppIcon*.png` 尺寸。

## [0.2.13] - 2026-08-21

### Fixed

- **空间回收 UI 进一步消除割裂感**. 「空间回收」主列表的总览卡片此前数字为默认黑色、与图标/胶囊的主题橙脱节，现在把可回收总量数字也使用 `AppTheme.accent`，让整张卡片颜色统一；卡片同时取消透明背景，融入列表分组样式。
- **回收空间详情页操作统一**. 「浏览文件」「备份数据」现在使用一致的主题橙色文字；底部的「回收 N MB」从普通列表行改为固定在底部的 prominent 按钮，与批量回收页面的底部栏风格一致，避免同一页出现多种按钮语言。

## [0.2.12] - 2026-08-21

### Added
- **应用列表 · 全部应用 / 系统应用 / 三方应用 分栏 + 筛选器**. 列表顶部新增分段控件（全部应用 / 系统应用 / 三方应用），配合原有搜索框按名称 / Bundle ID 过滤。系统应用此前被 `ApplicationType != "User"` 过滤掉，现已不再丢弃——底层 `installation_proxy_get_apps` 的 `application_type` 本就是 `NULL`（即 "Any"），系统应用一直都在返回数据里。系统应用行带「系统」胶囊徽标，且为只读展示（无用户 Data 容器，不提供浏览 / 回收 / 卸载）。

### Changed
- **消除「割裂感」**. 「空间回收」单 App 详情页的「浏览文件」「备份数据」按钮此前是系统默认蓝色、而「回收」是主题橙，视觉不统一。现统一套用 `AppTheme.accent`，「保留」分类也复用与「安全 / 会话」一致的 `bucketRow` 样式（带图标 + 角色色胶囊），整页配色一致。
- **构建链接 iOS 26 SDK 以启用液态玻璃（Liquid Glass）**. CI 在构建前切到 Xcode 26.3（`/Applications/Xcode_26*.app`），使 App 链接 iOS 26 SDK，iOS 26 设备上的标签栏 / 控件会自动呈现液态玻璃效果（Apple "linked on or after" 规则）。**部署目标仍保持 18.0**，因此 iOS 18 设备仍可正常安装——并未把 `MinimumOSVersion` 提高到 26，否则会挡掉你的 iOS 18 设备。

## [0.2.11] - 2026-08-21

### Changed

- **空间回收 UI 全面美化（参考 3105 设计语言）**. 新增 `DesignSystem.swift`：统一的暖橙主题色 `AppTheme.accent`（暗/亮自适应）、圆角图标 `AppRowIcon`、字节量胶囊 `SizePill`。「空间回收」tab 现在顶部展示可回收总量卡片；每个应用行右侧用胶囊高亮可安全回收的大小，扫描引导页改为带图标的醒目卡片。单 App 详情页每个分类（缓存 / 临时文件 / 日志 / GPU 缓存 / Cookies / WebKit 等）配对应 SF Symbol 与角色色（安全=绿、会话=橙、保留=灰），并以胶囊显示占用，分类勾选交互保持不变。仅改 UI，回收逻辑（`ReclaimService`）未变。

## [0.2.10] - 2026-08-20

### Fixed

- **设置页版本号显示错误**. `Resources/Info.plist` 中的 `CFBundleShortVersionString`/`CFBundleVersion` 长期停留在 `0.1.5 (5)`，与 `control` 不同步，导致「关于」行显示旧版本。本次同步为 `0.2.10 (10)`，避免用户误以为没装上新版本。

### Changed

- **诊断结果可滚动 + 支持分享**. v0.2.9 的诊断结果以固定高度 `Text` 展示，长报告会被截断、用户无法看到下方 C/D 策略与枚举结果。现在把结果文本包进 `ScrollView(.vertical)` 并固定高度 360pt，可上下滑动查看完整报告；同时在结果下方新增「分享结果」按钮，把当前探测文本写入临时 `.txt` 文件（命名 `EscapeOS-AppGroup-Probe-<时间戳>.txt`），调用系统分享面板导出到文件 App / 隔空投送 / 微信等。

## [0.2.9] - 2026-08-20

### Added

- **设置 · 隐藏的 AppGroup 探测按钮（诊断用）**. 在「设置」底部新增「诊断（调试用）」区块，含一个「AppGroup 探测」按钮：点按后通过 `bad_query` 的 App Group 路由（class 7 + `is_group` + `create=true`，绕过 lstat 存在性检查）尝试消费 LiveContainer 共享 App 沙盒（`AppGroup/LiveContainer/Shared/Data/Application`）的沙盒扩展，并直接列举该目录。探测同时尝试「直接路径假设」与「枚举 AppGroup 父目录后逐个 group 子目录下探」两种策略，把每个候选路径的「沙盒扩展是否成功 / 目录能否列举」结果以等宽字体显示出来。目的是在**无越狱真机**上一次点按拿到 AppGroup 共享 App 管理是否可行的实锤证据；普通用户无需理会。

## [0.2.8] - 2026-08-20

### Fixed

- **自定义恢复 · 搜索无结果时搜索栏消失**. v0.2.7 在搜索无匹配时把空状态放到 List 外部，导致 `.searchable` 搜索栏随 List 一起消失、键盘收回，用户无法继续输入或清空。现在只要存在可恢复目标，List 与搜索栏始终保留；无结果时把「未找到匹配「<关键词>」的应用。」提示作为 List 内部占位 Section 显示，搜索栏和焦点保持可用。

## [0.2.7] - 2026-08-20

### Added

- **备份标签页 · 批量删除支持全选**. 进入「选择」模式后，右上角在「取消」旁新增「全选 / 取消全选」切换：一键选中当前全部备份归档，再次点按取消全选；底部栏「已选 N 项」实时跟随。删除前仍需二次确认（不可撤销）。
- **自定义恢复 · 目标选择搜索栏**. 左上角「恢复」选好 zip、弹出「选择恢复目标」面板后，列表顶部新增 `.searchable` 搜索框，按应用名 / Bundle ID 过滤「应用」与「容器应用」两个区块；无匹配时显示「未找到匹配「<关键词>」的应用。」提示，方便在应用/容器较多时快速定位恢复目标。

## [0.2.6] - 2026-08-20

### Added

- **备份标签页 · 批量选择删除**. 新增「选择」模式（右上角）：进入后每行左侧显示勾选圈，点按整行切换选中，底部栏显示「已选 N 项」+「删除」；删除前二次确认（不可撤销）。非选择态仍保留右滑删除与右滑分享。
- **备份标签页 · 左上角自定义恢复**. 新增左上角「恢复」按钮，通过系统文档选择器（`UIDocumentPickerViewController`，限定 `.zip`）选任意一个 EscapeOS 备份压缩包；校验为合法备份（含 `backup.json`）后弹出**选择恢复目标**面板，分「应用」（系统已装应用）与「容器应用」（LiveContainer guest）两个区块、容器行带橙色「容器」胶囊区分。选中目标即发起恢复；可恢复到不同 UUID 沙盒的容器应用（借 v0.2.5 的 `preselectedGuest` 直接定位，不再二次弹沙盒选择）；若备份与目标应用不一致会给出覆盖风险警告。非 EscapeOS 备份或读取失败给出明确提示。

## [0.2.5] - 2026-08-20

### Added

- **备份标签页 · 容器应用显示图标**. `BackupMetadata` 新增可空的 `iconData` 字段，容器备份在导出时把 guest 的预解码图标（`LiveContainerGuest.iconData`）一并写入 `backup.json`。`BackupsListView` 的行图标优先渲染归档内 `iconData`，否则回退到系统图标缓存，解决容器应用备份显示灰色占位符的问题。`RestoreService.restore` 对容器备份改为按 guest bundle id（synthetic id 中间段）匹配，允许把备份恢复到**不同 UUID 沙盒**的同款应用。
- **备份标签页 · 备份文件名小字**. 每条备份记录下方新增一行 `caption2` 次级文本，显示归档文件全名（如 `应用名_backup_20260820_154501.zip`），便于核对。
- **备份标签页 · 右滑分享**. 备份行新增 `swipeActions`（trailing）的「分享」操作，通过 `UIActivityViewController` 把 `.zip` 归档通过隔空投送 / 文件 App 等导出。
- **容器备份 · 多 UUID 沙盒选择弹窗**. 恢复容器应用备份时，`RestoreService.candidateSandboxes` 按 host + guest bundle id 找出当前设备上该应用的所有 UUID 沙盒；当超过一个时，`RestoreView` 的确认页会列出这些沙盒（显示应用名 + UUID 目录名）并强制先选择目标，再写入对应沙盒的 `Documents/Data/Application/<UUID>/`。

## [0.2.4] - 2026-08-20

### Fixed

- **中文名应用备份文件名丢失前缀**. `BackupService.exportBackup` 原本用 `[^A-Za-z0-9_-]` 过滤文件名，会把中文（CJK）字符全部替换为 `_`，导致例如「抖音」变成 `__backup_...zip`。现在改用 `[^\p{L}\p{N}_-]` 保留所有 Unicode 字母/数字，中文应用正常显示为 `应用名_backup_...zip`；如果应用名过滤后为空则回退到 bundle id。

### Added

- **容器清理改名为容器管理**. `RootView` tab 与 `LiveCleanTabView` 导航标题统一改为「容器管理」，以涵盖浏览文件、备份等新增能力。
- **容器管理 · guest 应用支持备份数据**. `ReclaimAppView` 新增与「应用」页一致的「备份数据」按钮，走 `BackupViewModel` → `BackupService.exportBackup(isContainerApp: true)`。备份元数据新增 `isContainerApp` 标记，LiveContainer guest 以 synthetic `bundleIdentifier`（`host::bundleId::uuid`）+ `containerPath` 归档，与普通应用互不影响。
- **备份板块支持恢复容器应用并带小胶囊区分**. `RestoreService.eligibility` 识别 `metadata.isContainerApp`：不再去系统应用列表匹配 bundle id，而是校验记录的 `containerPath` 是否仍可通过 `SandboxEscape().withHandle` 访问，并构造合成 `InstalledApp` 作为恢复目标。`BackupsListView` 的备份行在标题旁显示橙色「容器」胶囊，空状态文案也提到「容器管理」页。

## [0.2.3] - 2026-08-20

### Added

- **容器清理 · 目标应用支持浏览文件**. 进入任一 LiveContainer guest 的详情（`ReclaimAppView`）后，新增与「应用」页一致的 **浏览文件** 入口：先用 `ContainerAccessModel` 校验容器可达（配对文件隧道 + `SandboxEscape().withHandle`），通过后再打开 `FileBrowserView(app:)`，可查看 / 复制 / 导出 / 删除该 guest 的 Documents、Library、tmp。该入口与回收空间共用同一权限闸门，guest 的 `containerPath`（即 `Documents/Data/Application/<UUID>/`）作为浏览根目录。顺带，「回收空间」页（系统应用与 guest 共用 `ReclaimAppView`）也获得了同样的浏览文件能力。

## [0.2.2] - 2026-08-20

### Fixed

- **Apps tab · 卸载在 iOS 26 上真正可用**. v0.2.1 在进程内通过 `dlopen("/usr/lib/libmis.dylib")` 直接调用 `MobileInstallationUninstall`。`installd`（该调用经 XPC 转发的目标）以调用方权限校验拒绝：EscapeOS 仅有 `get-task-allow`，没有 `com.apple.private.mobileinstallation.allow-uninstall`，于是返回 `-1`，界面表现为「卸载目标应用失败」。现在卸载改走 **配对文件 + LocalDevVPN 隧道**（`TunnelContext` → `installation_proxy_uninstall`，iOS 26.4+ 走 RPPairing、iOS 18 走 lockdown），与应用列表走的是同一套经配对文件认证的通道。`installd` 因信任的配对文件而放行，无需进程内私有 entitlement。iOS 仍可能弹出系统「删除 App」确认框，属正常，按成功处理。

## [0.2.1] - 2026-08-20

### Added

- **Apps tab · batch uninstall**. A new `选择` button enters multi-select mode (matches the Reclaim tab UX). Long-press a row to toggle; `全选` selects everything in the current search filter; a bottom bar shows the count and a destructive `卸载` button. Confirm + `AppListViewModel.uninstallBatch` → `UninstallService.uninstall(bundleId:)`, which calls `MobileInstallationUninstall` in `/usr/lib/libmis.dylib` (loaded with `dlopen`/`dlsym` at runtime so no private SDK is needed). The pairing file already places EscapeOS in `misagent`'s trust list — `installd` accepts the call and surfaces the system "Delete App" alert only when iOS requires explicit consent. Failures keep going through the batch and are summarized in one alert.
- **Search bar in Reclaim**. `ReclaimTabView` now has a `.searchable` box matching app name + bundle id (and a `没有匹配 "<q>" 的应用。` placeholder). It sits next to the existing 选择 batch UI.
- **Shared-app explanation banner in LiveClean**. LiveContainer's shared apps live under `AppGroup/LiveContainer/Shared/...` — a different iOS sandbox that EscapeOS's `bad_query` cannot escape into from inside LiveContainer's own Data container. The list now shows a `person.2.slash` banner explaining the workaround (Convert to Private inside LC → revisit), instead of pretending the apps are missing.

### Removed

- **Misleading `Documents/Shared/Data/` walk**. The previous build added a second fallback path at `Documents/Shared/Data/` — but LiveContainer stores its shared guests under **AppGroup**, not Documents. The path returned nothing and the host name "(共享)" leaked into the UI without identifying any apps. Discovery now walks only the private `Documents/Data` tree, exactly as the public LiveContainer source (`LCSharedUtils.m`) defines.

### Versioning

> This version is `0.2.1` (not `0.4.0` / `0.3.1`) following the project's no-jump convention — feature increments stay within the same minor (`0.2.x`) until a milestone justifies a minor bump.

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
