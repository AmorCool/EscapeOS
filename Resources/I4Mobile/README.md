# Resources/I4Mobile —— 爱思移动端内嵌 IPA（移植材料）

本目录存放从爱思助手 PC 端 9.0 安装包中提取的 3 个「爱思移动端」IPA，
用于把爱思 PC 端「安装爱思移动端」这套做法**移植**进 EscapeSpace
（见 `EscapeOS/Engine/I4MobileInstallService.swift`）。

## 为什么本文件存在

`.gitignore` 第 2 行是 `*.ipa` —— IPA 文件本身**不进 git**。本 `README.md`
作为**目录锚定文件**，让 `Resources/I4Mobile/` 这个目录结构能被 git 跟踪，
并如实记录目录里应当存在哪几个包及其元数据。

**IPA 需在打包前物理放到本目录**（本机交付，随仓库工作区一起走）。若缺失，
`I4MobileInstallService` 会如实报告「资源缺失」并抛错，不会静默跳过。

## 三个包的元数据（实测，非推测）

| 文件 | bundle id | 版本 | 主二进制 | sinf | 加密 | 大小 |
|------|-----------|------|----------|------|------|------|
| `217.ipa`   | `rn.notes.best`      | 2.1.7 | `AsTools`    | `SC_Info/AsTools.sinf`    | cryptid=1 | 26.4 MB |
| `220.ipa`   | `com.ownbook.notes`  | 2.2.0 | `Runner`     | `SC_Info/Runner.sinf`     | cryptid=1 | 33.2 MB |
| `photo.ipa` | `com.MK.AwsomeFiles` | 1.5   | `AwsomeFiles`| `SC_Info/AwsomeFiles.sinf`| 见下注 | 3.2 MB |

注：`photo.ipa` 的主二进制是 **FAT**（`0xCAFEBABE`，2 slices，arch0 = armv7），
`IPAPackageInspector` 对 FAT 读不出 `cryptid`，故判为 `.unknown`（≠ 未加密）。
这不影响 sinf 提取：`extractSINF` 只按 `Info.plist` 的 `CFBundleExecutable` 定位，
与主二进制是否 FAT 无关。

## 三个包的共同特征

- 都是 **FairPlay 加密包**（`cryptid != 0`），依赖爱思的**共享 Apple ID**
  `share_appleid003@163.com` 授权；
- 都**自带** `SC_Info/*.sinf`（现成的授权令牌，1056 字节）—— 因此安装时**不需要**
  现取 sinf，也不需要任何服务端；
- 都含顶层 `iTunesMetadata.plist`。

## 安装通道（移植自爱思 PC 端）

`installation_proxy` 的 `Install` 命令 + `ClientOptions`：

```
PackageType:     "Customer"
ApplicationSINF: <包内 SC_Info/<exe>.sinf 字节>
iTunesMetadata:  <包内 iTunesMetadata.plist 字节>
```

IPA 先经 AFC 上传到设备 `/PublicStaging/`（AFC 根 = `/var/mobile/media`），
再交 installd 处理。这与爱思 PC 端「装移动端」用的是同一条通道，
复用 `IPAInstallService.installWithSINF`。

## 诚实边界（装之前必须知道）

- 这三个包是爱思的**共享账号**签的，只有该 Apple ID `authorizeMachine` 过的设备
  才可能解密运行。本机（当前设备）若**未被该共享账号授权**，即使装上，
  运行期 `fairplayOpen()` 也可能失败而**闪退**（即 `-42112` 一类）。
- `I4MobileInstallService` 会在安装前检测本机是否已用共享账号授权过该包，
  并把结论如实写进返回值；**不承诺「装上就能跑」**。
- 本目录不含任何分发包下载地址，也不联网。
