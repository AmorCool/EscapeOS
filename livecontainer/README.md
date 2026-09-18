# EscapeOS × LiveContainer：MobileGestalt 沙盒扩展方案

> **这是什么**：在 **LiveContainer（LC）** 里运行 EscapeOS 时，让 MobileGestalt 读写不再报 `error 0`
> 的一套**独立补丁 + 说明**。它需要改 **LiveContainer 的源码**（本仓库只提供 `.patch`），
> EscapeOS 侧的改动**已在 `EscapeOS/Engine/MCM/GestaltEngine.swift` 里**。
>
> **时效性提醒**：本文早期版本提到过 `livecontainer` / `mha` 两个分支与 `v0.2.18` / `v0.2.19`
> 两个版本号 —— **那些分支已不存在**（当前仓库只有 `migrate-xcode`），版本号也早已推进到 `0.3.x`。
> 下文**只保留仍然成立的技术内容**；补丁本身**未在本仓库内验证**（它作用于 LC 源码，需在 Mac 上应用）。

## 1. 问题：`error 0` 的根因

iOS 26 + LiveContainer 下，EscapeOS 编辑 MobileGestalt 一直报 `error 0`。经真机日志定位，三条路都不通：

1. **MHA 身份在 LC 下不可能成立**：LC 把 App 重签成自己的身份 `com.kdt.livecontainer.*`，
   `SecTaskCopySigningIdentifier` 永远是这个，不是 `com.apple.mobile.MobileHouseArrest`。
   所以 MHA 特权容器路由（class 13 `BQMCMActivate`）从根上走不通。
2. **bad_query 三条路全 -4**：containermanagerd 路线（`container_copy_sandbox_token`）在 iOS 26
   被内核拒绝，返回 -4 = 沙盒扩展签发失败。
3. **LC 默认的书签机制到不了系统路径**：LiveContainer 用安全作用域书签
   （`NSURLBookmarkCreationSecurityScope` + `startAccessingSecurityScopedResource`）给 guest 授权，
   但签发方（LC 主程序）自身沙盒也访问不了
   `/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/...`，
   书签对系统路径无效。

结论：**要读写 MobileGestalt，进程必须持有针对该路径的沙盒扩展（token）。** 在免费 LC 框架内唯一
可行的做法是 —— 由 **LiveContainer 主程序（host）用更低层的 `sandbox_extension_issue_file`
直接签发**该路径的扩展，再把 token 交给 EscapeOS（guest）用 `sandbox_extension_consume` 消费。
这正是 Nyxian 绕过安全书签改用的机制。

## 2. 补丁做了什么（只限 EscapeOS，按 bundle id 限定）

- **Host 侧** `MultitaskSupport/AppSceneViewController.m`：当启动的 guest `bundleId` 是
  `com.apple.mobile.MobileHouseArrest`（或含 `escapeos`）时，调用
  `sandbox_extension_issue_file("com.apple.app-sandbox.read-write",
  "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache", 0)`
  签发扩展，把 token 塞进 `appInfo[@"mgSandboxToken"]`（复用已有的 extension 传参通道）。
- **Guest 侧** `LiveProcess/main.m`：启动后读取 `appInfo[@"mgSandboxToken"]`，调
  `sandbox_extension_consume(token)` 在本进程激活扩展。

以上两处**都在补丁文件里**，作用于 LC 源码。

### EscapeOS 侧（**本仓库已实现，无需再改**）

EscapeOS 的 `load()` / `write()` 本来就走直接文件 API（`Data(contentsOf:)` / `open(O_WRONLY)`），
只要进程拿到扩展即可成功。需要改的只有一件事：**`load()` 里的 `grantExtension`（bad_query）闸门
必须是非致命的** —— 否则 bad_query 返回 -4 仍会弹 `error 0`。

这一点已在 `EscapeOS/Engine/MCM/GestaltEngine.swift` 落实（见该文件里
"`grantExtension` (bad_query) is best-effort ONLY" 那段注释与 `direct-access probe: readable=…` 日志）。
**⇒ 使用本仓库当前版本时，不需要再为 LC 单独出一版 EscapeOS。**

## 3. 应用补丁（在你本机 Mac 的 LiveContainer 源码上）

```bash
cd <LiveContainer 源码根>
git apply /path/to/livecontainer-mobilegestalt-sandbox-extension.patch
# 若因空白报错：
# patch -p1 < /path/to/livecontainer-mobilegestalt-sandbox-extension.patch
```

只改上面两个文件，其他 guest App 不受影响。

## 4. 构建 LiveContainer（Mac + Xcode）

1. 用你自己的签名证书打开 `LiveContainer.xcodeproj`（或 `LiveContainer.xcworkspace`）。
2. 常规构建并安装到设备（侧载）。LC 自带的 entitlements 已含 app-group，无需额外改。
3. 装好后，把**本仓库构建的 EscapeOS IPA**（见仓库 Releases）通过 LC 安装进容器。

> 关键点：EscapeOS 必须是**已经带非致命 `grantExtension` 闸门**的版本
> （本仓库当前代码即是），否则已拿到的扩展会被自己白白挡掉。

## 5. 验证（关键：看真机日志，不再猜）

打开 EscapeOS → Gestalt 页 → Load。然后用 **Xcode → Window → Devices and Simulators** 或
**Console.app** 抓设备日志，搜 `MobileGestalt` / `LC` / `LiveProcess`：

- 期望看到：
  - `[LC] issued MobileGestalt sandbox extension for EscapeOS (bundle ...)`
  - `[LiveProcess] consumed MobileGestalt sandbox extension, handle=<正数>`
  - EscapeOS 日志出现 `direct-access probe: readable=true` 和 `MobileGestalt loaded`
  → **成功，`error 0` 解决。**
- 若看到：
  - `[LC] sandbox_extension_issue_file returned NULL ...` → 平台策略拒绝 LC 主程序给系统路径签发
    扩展（免费侧载身份不够）。此时需要换**带特殊 entitlement 的企业/自签证书**，或退回
    「真实 App Group / 升 iOS 27」路线。
  - `[LiveProcess] sandbox_extension_consume failed ...` → token 传输或消费失败，检查
    `appInfo` 传参是否完整。

## 6. 失败回退

若 `issue_file` 返回 NULL（平台拒绝），本方案在免费侧载下不可行。替代正路：

1. 给 EscapeOS 配**真实 App Group**（Apple 开发者后台注册 + 重签进 LC 的 profile 含该
   entitlement），走 iOS 26 的 class-7 App Group 牺牲路由（Jade 即用此路）。
2. 等设备升 **iOS 27**（Mond 路线，bad_query 直连 SystemGroup 可用）。

## 7. 文件清单

| 文件 | 作用 |
|---|---|
| `livecontainer-mobilegestalt-sandbox-extension.patch` | LC 源码补丁（host + guest 两处），**作用于 LC 仓库，不在本仓库内生效** |
| `EscapeOS/Engine/MCM/GestaltEngine.swift` | 本仓库已实现：非致命 `grantExtension` 闸门 + `direct-access probe` 日志 |
