# Changelog

## [0.2.45] - 2026-08-26

### Changed

- **回退 v0.2.45/v0.2.46 并重新设计**：按用户反馈回退到 v0.2.44 重新做，不再强套 Lara 风格，保持 EscapeOS 原有视觉语言。
- **「更多」设置入口改为右上角齿轮**：`MoreView` 移除列表中的「设置」行，在导航栏右上角添加 `gearshape` 图标；点击后以 `.sheet` 弹出 `SettingsForm`（带「完成」按钮），不再 push 到新页面。
- **「空间回收」分段控件压缩**：`SpaceReclaimView` 顶部 Picker 减少内边距，背景与列表一致，避免额外视觉层级。
- **选择模式底部操作条抬高**：`ReclaimTabView` 与 `LiveCleanTabView` 的 `batchBar` 增加底部内边距，按钮不再贴底，避免被 tab bar / home indicator 遮挡；`LiveCleanTabView` 的清理按钮也统一为 `borderedProminent` 样式，减少两页割裂感。

## [0.2.44] - 2026-08-26

### Changed

- **「空间回收」与「容器管理」合并为单 tab + 分段（分栏）**. 原「空间回收」tab 现承载一个分段控件：`常规清理`（原系统应用回收 `ReclaimTabView`）与 `容器管理`（原 LiveContainer 内应用 `LiveCleanTabView`）。独立的「容器管理」tab 已移除，二者共用同一份底层 `ReclaimAppView` 详情页，标题统一为「空间回收」。
- 新增 `EscapeOS/Views/SpaceReclaimView.swift` 作为合并容器；`Makefile` 注册新源文件。

### Fixed / Optimized

- **CI 编译时间进一步缩短**. 在原有 Rust registry/target 缓存（方案四）基础上，新增缓存 `Theos` 全量 checkout 与 Rust 工具链（`~/.rustup` + `~/.cargo/bin`），并对克隆/安装步骤做缓存命中跳过，预计每次构建省 2–3 分钟。

### Changed

- 版本号 `0.2.43 → 0.2.44`（`control` 与 `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 同步）。

## [0.2.43] - 2026-08-26

### Added

- **「更多 → 设置」新增导出配对文件功能**. 在 `SettingsForm` 中新增「导出配对文件」按钮：如果 `Documents/pairingFile.plist` 存在，调用系统 `UIActivityViewController` 分享该文件（AirDrop / 文件 / 微信等）；不存在时提示「当前没有可导出的配对文件」。

### Fixed

- **借鉴 LiveContainer 修复配对文件导入失败**. 真机反馈在 LiveContainer 内只有开启 LC 的「修复文件选择器」才能导入配对文件。根因是 SwiftUI `.fileImporter` 返回的是 security-scoped 原始 URL，在 LC 沙盒中 `startAccessingSecurityScopedResource()` 会失败。新增 `EscapeOS/Views/PairingFilePicker.swift`：
  - 使用 `UIDocumentPickerViewController` 并设置 `asCopy: true`，让系统在返回前先把文件复制到 App 沙盒，从而绕过 LC 的文件选择器 hook。
  - 用 `pairingFilePicker(isPresented:onPicked:)` 替换 `PairingSetupView` 的 `.fileImporter`。
  - 取消选择不再显示错误。
- **修复「空间回收 / 容器管理」会话分类里 Cookies 图标不显示**. `DesignSystem.swift` 中 Cookies 行原本使用 `cookie` SF Symbol；在部分 iOS 18.0 真机上该符号缺失导致图标空白。改为运行时检测 `UIImage(systemName: "cookie")`，缺失时回退到 `doc.text` 作为兜底。

### Changed

- 版本号 `0.2.42 → 0.2.43`（`control` 与 `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 同步）。
- `Makefile` 注册新源文件 `EscapeOS/Views/PairingFilePicker.swift`。

## [0.2.42] - 2026-08-26

### Added

- **移植 StikPair 后台保活机制到 iOS 27 无线配对页**。真机反馈 v0.2.41 广播「过一会就消失」，因此把原版 StikPair 的 **Background keep-alive** 两个开关汉化并移植到 EscapeSpace：
  - `EscapeOS/Services/BackgroundAudioManager.swift`：持续播放 0 音量 PCM 缓冲区并占用 `AVAudioSession`，让系统认为 App「正在播放音频」，延缓 Bonjour 被 SRP sweeper 回收。
  - `EscapeOS/Services/BackgroundLocationManager.swift`：以极低精度 + 最大距离过滤持续请求位置更新，让系统认为 App「正在使用位置服务」，同样用于后台保活。
  - `EscapeOS/Services/WirelessKeepAlive.swift`：组合音频/位置两种机制，并申请 `beginBackgroundTask` 延长后台存活时间。
  - 在 `RootView` 的无线配对 sheet 中新增「后台保活」卡片，含「静默音频」与「位置更新」两个开关（默认关闭，避免未授权弹窗），开关状态持久化到 `@AppStorage`。配对开始时按用户选择启动保活，配对成功 / sheet 关闭时停止。
- **新增后台模式与权限描述**：`Resources/Info.plist` 增加 `UIBackgroundModes = [audio, location]`，并补充 `NSLocationWhenInUseUsageDescription` / `NSLocationAlwaysAndWhenInUseUsageDescription` 汉化说明。

### Changed

- 版本号 `0.2.41 → 0.2.42`（`control` 与 `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 同步）。

## [0.2.41] - 2026-08-26

### Fixed

- **Bonjour 广播 "一会就消失" / 配对设备看不到 EscapePair**. 实测 iOS 18 设备开发模式里 mDNS 注册确实出现一会儿随后被系统 SRP 清理；根因是 `EscapeOS/Tunnel/WirelessPairing.m` 里 `si_ready_cb` 的 15 秒 `dispatch_semaphore_wait` 把 Rust worker thread 给阻塞了——iOS 18 上 `NSNetService.publish` 的 delegate 回调（`netServiceDidPublish:` / `didNotPublish:`）常常不触发 / 多分钟后才触发，导致后续 `listener.accept()` 永远接不到设备连接。可观测外部表现：sheet 显示「正在广播」但设备侧开发者模式短暂亮一下「StikPair/iloader/idevice_pair-XXX」之类相邻服务，EscapePair 不可见。本版修法：
  1. **不再阻塞 Rust thread**：删掉 semaphore 等待，改成 dispatch 到主队列 publish 完就返回，Rust 持续 `accept()`。
  2. **NSTimer 30 s 心跳**：每 30 秒调一次 `stopAdvertising` + `publish`，强制 SRP 重新注册，避免系统 SRP sweeper 回收。
  3. **NSLog 关键节点**：在 `publish begin` / `netServiceDidPublish` / `didNotPublish` / `stopAdvertising` 处输出 `name= / port=`，Console.app 连真机可直接看 SRP 状态，方便定位再次出现的同类问题。
  4. **Sheet 关闭可靠 teardown**：`.sheet(...) { wirelessSheetContent.onDisappear { ... } }` 显式 `wirelessEngine?.stop()` + `wirelessEngine = nil`，原来「取消 / 完成 / 关闭」按钮都只是 `showWirelessPairing = false` 靠 ARC 释放，可能不及时停止 NSNetService；现在 显式 stop 后 NSNetService 立即解注册。Sheet content 也抽出到 `wirelessSheetContent` 计算属性，便于重复用 `.onDisappear` hook。
- **`rust/idevice-ffi/.cargo/config.toml` 漏 commit**. 上一版 commit message 自称加了 `[net] git-fetch-with-cli = true` 与重试配置，实际没写文件。这次补上在仓库根 `.cargo/config.toml`（Cargo 自动按目录就近读取），同样配置 `git-fetch-with-cli = true` + `jobs = 2`，避免 libgit2 在 macos-15 runner 上偶发 TLS 错误。

### Changed

- 版本号 `0.2.40 → 0.2.41`（`control` 与 `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 同步）。

## [0.2.40] - 2026-08-26

### Changed

- **iOS 27 无线配对广播名称**. 之前 `mDNS service instance name` 直接用 Rust `pairing_file.identifier` (UUID 前缀如 `7b591c…`)，在 iOS 开发者模式的「配对设备」列表里看不到（StikPair、iloader、idevice_pair-* 等可读名字都能看到）。改为 `EscapePair-{serviceID 后 6 位}`（如 `EscapePair-7b591c`），既人类可读又对单一 host 稳定，多台同 App 设备也不会撞名。涉及 `EscapeOS/Tunnel/WirelessPairing.m` (`si_ready_cb`)。

### Added

- **CI 缓存（措施 4 后半段）**. `.github/workflows/build.yml` 在 `Build libidevice_ffi.a` 之前插入 `actions/cache@v4`，按 `runner.os + hashFiles('rust/idevice-ffi/Cargo.lock')` 为键缓存 `~/.cargo/registry` / `~/.cargo/git` / `rust/idevice-ffi/target`。冷启动仍 5-6 min，**热命中降至 30s 左右**（总 ~3 min 节省 50%）；Cargo.toml / Cargo.lock 任一变更自动失效。同时在 `rust/idevice-ffi/.cargo/config.toml` 加 `[net] git-fetch-with-cli = true` 和 `[net] retry = 3` 提高网络抖动鲁棒性。

## [0.2.39] - 2026-08-25

### Added

- **真实的 iOS 27 无线配对引擎（host-pairing）**. 接入设备主动发起的无线配对：App 作为 pairable-host 通过系统 Bonjour 广播 `_remotepairing-pairable-host._tcp`，设备连接后驱动 rppairing 握手，App 内直接显示 6 位配对码（参考 SideInstaller 的 in-app PIN 卡片，区别于原版 StikPair 的系统通知），配对成功后把 `RpPairingFile` 写入 `Documents/pairingFile.plist`，`TunnelContext` 自动加载建立隧道。
  - 引擎以 Rust 重写于 `rust/idevice-ffi/src/pairable_host_run.rs`，经 cbindgen 风格的 C 接口（`si_run_host` / `si_result_free`）暴露，由 `EscapeOS/Tunnel/WirelessPairing.{h,m}` 桥接到 SwiftUI（`RootView` 的配对设置页）。mDNS 广播走系统 `NSNetService`（规避 Rust mDNS 守护进程所需的 iOS 多播 entitlement）。
  - `libidevice_ffi.a` 改为 **Rust 源码现场编译**：CI 在 `aarch64-apple-ios` 目标用 cargo 从 `idevice` crate（jkcoxson，BSD-3，pin `7bd551c`）构建，取代原先不含无线配对主机函数的 v0.1.5 预编译包；单一 `.a` 同时提供既有 `idevice_*` 函数与新 `si_*` 引擎函数，避免重复符号。
  - `Resources/Info.plist` 新增 `NSBonjourServices = _remotepairing-pairable-host._tcp` 与 `NSLocalNetworkUsageDescription`；host 的 `alt_irk` 持久化到 `UserDefaults`，使已配对设备下次仍能识别本机。`Pin` / 状态 / 成功 / 失败均以浅色圆角卡片 + 蓝色强调呈现（无棕色 / earthy 色调）。

### Changed

- 版本号 `0.2.38 → 0.2.39`（`control` 与 `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 同步）。

## [0.2.38] - 2026-08-25

### Added

- **配对文件导入：剪贴板粘贴**. 在「一次性设置 / 配对导入」界面新增「从剪贴板粘贴配对文件」按钮，直接读取系统剪贴板文本（XML plist 或纯文本配对文件）并导入，与文件导入共用同一套解析逻辑（`AppListViewModel.importPairingFile(from:)`）。
- **iOS 27 无线配对入口（UI 先行）**. 新增 iOS 27 版本检测（`ProcessInfo` major ≥ 27）；检测到 iOS 27 时，在配对界面额外显示一个「iOS 27 无线配对（无需电脑）」区块，说明配对码会直接显示在 App 内（参考 SideInstaller 的 in-app PIN 卡片做法，区别于原版 StikPair 的通知方式），并提供「开始无线配对」按钮。
  - 真实的 host-pairing 引擎（参考 SideInstaller 的 `si_pairing_run_host` + `pairPinCallback`）**于 v0.2.39 落地**：重构 CI 用 Rust 源码从 `idevice` crate（jkcoxson，BSD-3，pin `7bd551c`）现场编译 `libidevice_ffi.a`（取代原先不含无线配对主机函数的 v0.1.5 预编译包），新增 `si_run_host` 引擎函数；配对文件写入 `Documents/pairingFile.plist`，`TunnelContext` 自动加载。需 iOS 27 真机验证。
  - UI 配色遵循既定浅色卡片 + 蓝色强调（无棕色 / earthy 色调）。

## [0.2.37] - 2026-08-25

### Fixed

- **屏蔽域名入口图标真正显示**：上一版把图标设为 `shield.badge.xmark`，但在真机上渲染为空（该 SF Symbol 名称可能不存在或当前系统不支持）。已改为 `shield.fill`，确保在所有目标系统上都能正常显示。
- 同步更新 `DomainBlockerView` 顶部信息卡片的图标为 `shield.fill`，保持两处一致。

## [0.2.36] - 2026-08-25

### Fixed / Improved

- **屏蔽域名 UI/交互打磨**：根据用户截图反馈进行一轮精修。
  - 为「更多」中的「屏蔽域名」入口换上更显眼的 `shield.badge.xmark` 图标。
  - 修复 `MoreCard` 右侧出现双箭头的问题：移除 `MoreCard` 中手动的 `chevron.right`，仅保留 `NavigationLink` 自带的 disclosure indicator。
  - 在「默认屏蔽」section 头部新增「全部开启 / 全部关闭」批量按钮，可一键切换全部预设域名。
  - 重新设计「生成描述文件」区域：改为 Wallpaper 风格的浅色大圆角卡片 + 底部浅色胶囊按钮，图标使用蓝色，与整体 List 背景形成更干净的层次。
  - 把「载入描述文件（安装到设置）」改为 Safari 网页下载方式：启动一个本地 HTTP 服务器（`ProfileHTTPServer`），在 `127.0.0.1` 随机端口上提供 `.mobileconfig` 文件及一个自动跳转的下载页，然后调用 `UIApplication.shared.open` 在 Safari 中打开。Safari 加载页面后会自动下载描述文件并进入系统「设置」安装流程，更符合 iOS 描述文件的正常安装路径。
  - 保留「分享 / 保存到文件」作为兜底方案。

### Added

- 新增 `EscapeOS/Engine/ProfileHTTPServer.swift`：一个极简的本地 HTTP 服务器，仅用于向 Safari 提供 `.mobileconfig` 下载；支持随机端口、自动停止、后台任务保持。

## [0.2.35] - 2026-08-25

### Added

- **新增「更多 → 屏蔽域名」控制台**. 参考用户提供的 `iOS-Blocker.mobileconfig`，移植其 DNS 屏蔽思路：通过 `com.apple.dnsSettings.managed` 负载把域名写入 `SupplementalMatchDomains`，并指向不可达的本地 DoH 服务器（`https://127.0.0.1/dns-query`），使这些域名解析失败从而无法访问。
  - 默认屏蔽苹果系统更新 / 验证相关域名（`mesu.apple.com`、`gdmf.apple.com` 等共 26 个），已按用户要求移除 `www.baidu.com`；每条预设均可单独开关。
  - 新增「自定义域名」输入框，可随时添加任意要屏蔽的域名（自动去掉协议头 / 路径 / 端口，去重并小写），左滑可删除；自定义域名持久化保存在本机，重启应用后仍保留。
  - 点击「生成描述文件」后，将当前启用的域名清单写入 `Documents/DomainBlocker/blocked-domains.mobileconfig`，随后可「载入描述文件」通过 `UIDocumentInteractionController` 路由到系统「设置」安装，或「分享 / 保存到文件」后在「文件」App 中打开安装。
  - 新增 `EscapeOS/Views/DomainBlockerView.swift`：含 `DomainBlockerStore`（持久化）、`buildProfileXML`（生成 plist）、`ProfileInstaller`（描述文件安装桥接）。

## [0.2.34] - 2026-08-25

### Added

- **新增「更多 → 开发者镜像」：移植 StikDebug 的 Redownload DDI 功能**. 下载 Xcode_iOS_DDI_Personalized 的开发者镜像文件（`BuildManifest.plist`、`Image.dmg`、`Image.dmg.trustcache`）到 EscapeSpace 的 `Documents/DDI/` 目录，下载完成后自动打包为 `DMG.zip` 并弹出系统分享。
  - 新增 `EscapeOS/Views/DDIDownloadView.swift`：显示下载进度、文件清单、分享入口；使用 `URLSession.download` 下载，使用项目内已有的 `ZipWriter` 打包。
  - 在 `MoreView` 新增「开发者镜像」卡片入口，与「壁纸」「备份」「设置」保持统一卡片风格。
- **Gestalt 右上角菜单新增「备份 MobileGestalt」**. 在 `GestaltView` 的 `ellipsis.circle` 菜单中新增「备份 MobileGestalt」选项，点击后将当前读取到的 `com.apple.MobileGestalt.plist` 复制为带时间戳的临时文件并弹出分享。
  - 在 `GestaltEngine.swift` 新增 `exportShareableBackup()`，先校验 `loaded` 与可读性，再复制到 `tmp/MobileGestalt-yyyyMMdd-HHmmss.plist`。

### Changed

- `DesignSystem.swift` 新增可复用的 `ShareTarget` / `ShareSheet`，`BackupsListView` 中原有的私有定义已移除，避免与 DDI / Gestalt 分享功能重复定义。
- `GestaltView` 菜单项汉化：`Reload` → `重新加载`，`Refresh Extension` → `刷新扩展`。

## [0.2.33] - 2026-08-25

### Fixed

- **修复「更多」与「Gestalt」顶部重复标题**. `RootView` 给每个 tab 都包了 `NavigationView`，而 `MoreView` / `GestaltView` / `BackupsListView` 的 sheet 内部又自带导航容器，导致顶部出现两个标题。修复后：
  - 「更多」tab 只由 `RootView` 的 `NavigationView` 承载；`MoreView` 内部不再包 `NavigationView`。
  - 「Gestalt」tab 直接放 `GestaltView`（它自己使用 `NavigationStack` 推送 `AdvancedGestaltEditor`），`RootView` 不再额外包 `NavigationView`。
  - 两个页面均只保留一个 inline 标题，消除大段空白和重复。

### Changed

- **壁纸页 UI 按 Erosion 原版风格重做，并移除空状态多余导入按钮**.
  - 空状态卡片不再包含「导入 .tendies」按钮（底部已有悬浮胶囊导入按钮），卡片改为大圆角、纯白底、居中图标 + 标题 + 说明的简洁样式。
  - 壁纸包网格改为大圆角白色卡片，选中态使用强调色描边 + 右上角勾选标识，分类标签使用胶囊样式。
  - 页面背景使用 `systemGroupedBackground`，底部导入按钮改为浅色圆角胶囊（白色底 + 主色图标 + 阴影），与图 5 原版风格一致。
  - 功能保持不变：导入、选择、应用、删除、清空、打开 PosterBoard。

## [0.2.32] - 2026-08-25

### Added

- **新增「更多 → 壁纸」：移植 Erosion 的 Custom Wallpapers 功能**. 可将 `.tendies` 壁纸包导入并应用到系统 PosterBoard（支持 Collections / MercuryPoster / Videos 三类描述符）。
  - 新增 `EscapeOS/Views/Wallpaper/WallpaperModels.swift`（`TendiesObject`、`PBPath`）。
  - 新增 `WallpaperHandler.swift`：使用 EscapeOS 已有的 `ArchiveExtractor`/`ZipReader` 解压 `.tendies`，解析并随机化 descriptor identifier，持久化到 `Documents/Wallpapers`；通过 `bad_query_list` 自动发现 PosterBoard 容器路径。
  - 新增 `WallpaperView.swift`：卡片网格展示已导入壁纸包，点击切换启用/禁用，底部「导入 .tendies」+ 右上角菜单（打开 PosterBoard / 清空导入），工具栏「应用」将选中的描述符写入 PosterBoard 容器。
  - 所有 UI 与错误提示已汉化。
  - 打开 PosterBoard 使用 runtime `NSClassFromString("LSApplicationWorkspace")` + `performSelector`，避免链接私有 framework。

### Changed

- **优化「更多」页顶部大空白**. `MoreView` 与 `RootView` 的「更多」tab 标题由 `.large` 改为 `.inline`，消除大标题下方的大片空白；同时新增「壁纸」入口卡片。
- **优化 Gestalt 页顶部标题**. 移除 `GestaltView` 内部重复的「MobileGestalt」大标题，`RootView` 的 Gestalt tab 只保留一个紧凑的「Gestalt」inline 标题，界面更协调。

## [0.2.31] - 2026-08-24

### Changed

- **UI 全面统一为卡片/banner 风格（图 1 方向）**. 将「容器管理」你喜欢的卡片/banner 视觉语言（图标 + 标题 + 说明）扩展到全应用主要空/错/初始状态，消除居中灰字与居中蓝色大按钮的割裂感：
  - `LiveCleanTabView`：未扫描、扫描失败、未找到应用状态改为 `InfoActionCard`；诊断卡片与共享应用提示 banner 保留并统一卡片底色。
  - `ReclaimTabView`：未扫描/无应用状态改为 `InfoActionCard`；可回收总量卡片继续放在列表顶部。
  - `BackupsListView`：加载中、读取失败、暂无备份状态改为 `InfoActionCard`。
  - `FileBrowserView`：打开目录失败状态改为 `InfoActionCard`。
  - `CustomRestoreSheet`：未找到可恢复目标应用状态改为 `InfoActionCard`。
  - `RootView` 的 `ErrorStateView` / `EmptyStateView`（应用页错误/空状态）改为 `InfoActionCard`。
- **底部 tab 重构为 5 个，新增卡片式「更多」页**. 由原先的 6 tab（应用 / 空间回收 / 容器管理 / Gestalt / 备份 / 设置）改为 5 tab：
  - 应用 / 空间回收 / 容器管理 / Gestalt 保持独立 tab（**Gestalt 未被隐藏或移除**）。
  - 新增「更多」tab，使用卡片风格（不是简单列表）展示 备份 / 设置 两个入口，点击进入对应页面；点击「重置配对文件」后自动切回「应用」tab。
- **新增 `DesignSystem.swift` 共享组件**：`AppTheme`（暖橙强调色）、`AppRowIcon`（圆角图标底）、`InfoActionCard`（图标 + 标题 + 说明 + 可选按钮的卡片）、`SizePill`（字节量胶囊），供上述页面复用。

### Fixed

- **纠正「更多」页方向**. 之前误将「更多」做成简单列表，且错误地移除了 Gestalt tab。现按截图证据恢复：保留 Gestalt，并把「更多」页也统一为卡片/banner 风格。

## [0.2.30] - 2026-08-24

> 续接 **v0.2.28 基线**。0.2.15–0.2.28 为 MobileHouseArrest / MobileGestalt 系统路径写入方向的实验（已确认 iOS 26.6+ 平台封堵、不可行），按项目方向已放弃，故本次只保留「容器管理 / 共享应用」与 LiveContainer 的联动能力。

### Changed

- **包名回退为 EscapeSpace 原始 Bundle ID**. `control` 与 `Resources/Info.plist` 的 Bundle ID 由 `com.apple.mobile.MobileHouseArrest`（MHA 分支遗留）改回 `com.ipaside.escapeos`，与原始 EscapeSpace 身份一致；`EscapeSpace.entitlements` 仅含 `get-task-allow`，无需改动。版本号 `0.2.28 → 0.2.30`（`CFBundleShortVersionString` / `CFBundleVersion` 与 `control` 同步）。
- **「容器管理」共享应用显示真实名称 + 图标 + 绿色「共享」胶囊**. 之前共享（被 LiveContainer “转换”/converted）的容器应用只显示 UUID、无名称/图标，因为 EscapeOS 只在宿主的 `Documents/Applications` 下查 `.app`；而共享 guest 的 `.app` 实际位于 **AppGroup 的 `LiveContainer/Applications`**（文件夹名可能是裸 bundle id、无 `.app` 后缀）。现已：
  - `LiveContainerDiscovery` 在 AppGroup `LiveContainer/Applications` 下查找共享 guest 的 `.app`（放宽 `enumerateGuestBundles`：任意含 `Info.plist` 的目录均视为候选，兼容无后缀的裸 bundle id 目录），取回真实 `CFBundleDisplayName` / 图标 / Bundle ID，并标记 `isShared = true`。
  - `LiveCleanTabView` 对共享 guest 在名称旁渲染绿色「共享」胶囊，与普通（私有）guest 区分。

### Fixed

- **LiveContainerGuest 显式构造器**. 给 `LiveContainerGuest` 增加显式 `init(... isShared: Bool = false)`，解决部分 Swift 工具链不合成带默认值属性的 memberwise init 导致的级联编译错误（`compactMap` 返回类型无法推断 + `extra argument 'isShared' in call`），v0.2.29 构建失败即源于此；修复后 bump 至 `0.2.30` 重新出包。

### Added（LiveContainer 侧，随 LC 主分支 nightly 发布）

- **LiveContainer 设置新增「Guest Container Extension」开关**. 位于设置页（默认开启），绑定到 App Group 套件 `UserDefaults` 的 `LCContainerExtensionEnabled`。关闭后，经典启动路径（`LCBootstrap`）与多任务路径（`AppSceneViewController`）都不再为 EscapeOS 签发容器沙盒扩展，并下发 `ESC_LC_GRANT_STATUS=skipped:disabled`，使 EscapeOS 诊断可见「已禁用」。
- **多语言**. `Resources/Localizable.xcstrings` 新增 `lc.settings.containerExtension` 与 `lc.settings.containerExtensionDesc` 两键，覆盖 LC 全部 16 种 UI 语言（ar / de / en / es / fr / it / ja / ko / pl / pt-BR / ru / sv / tr / vi / zh-Hans / zh-Hant）。`LCSharedUtils` 的 `isEscapeOS` 识别同步改为 `com.ipaside.escapeos`。

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

## [0.1.1] - 2026-08-20

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
- Verified on iPhone 17, iOS 26.5.1, with iPASide placing the pairing file after install (list, browse, copy-paste, backup).
