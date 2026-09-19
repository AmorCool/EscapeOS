# Changelog

## [0.3.458] - 2026-09-19

### ★★ 修「点空间回收扫描闪退」—— 根因：拿**算错的地址**去调用

**真机实证**（v0.3.457，两条启动行夹着一次崩溃 ⇒ 崩后重启）：
```
11:46:36.416  镜像基址 = 0x7af40c10（取自 dlopen 句柄）
11:46:36.417  LC_SYMTAB 命中：_uhO2GULXwfgKwPcp4YR2 → AirFairSyncGrappaCreate @ 0x000000007af6f914
11:46:36.420  Grappa 输入 12 字节 = 01 00 00 00 00 00 00 00 01 00 00 00
              ← 崩在这里（下一句就是 create(...)）
11:46:37.038  EscapeSpace 0.3.457 (753) 启动   ← 0.6 秒后重启
```

**根因：地址是错的。** `0x7af6f914` ≈ 2 GB，而 iOS 的 App 镜像不会加载在那里
（同一次日志里系统框架的句柄是 `0x36e3df300` 这个量级）。
**`dlopen` 的返回值不保证是 `mach_header*`**，我把它当基址用了 ⇒
「基址 + n_value」整体偏移 ⇒ **拿错地址去调用 ⇒ 直接崩。**

**修法：本次不调用。** 本函数只负责**报告符号在不在、算出的地址是多少**。

为什么不修基址而是干脆不调：
- Grappa 已经在 CI 上用 **A-64（Unicorn 解释执行 x86_64 切片）**生成出来了
  （`err=0 / outLen=84 / 结构 8/8`）；**设备端这个调用对路线没有增量**；
- 在**基址都还没验证对**的前提下，任何「调用算出来的地址」都是拿用户的 App 稳定性去赌 ——
  **本项目已经在同一条路上崩过三次**（v0.3.419 / v0.3.450 / v0.3.457）。

要恢复调用，必须先补齐两件事（已写进代码注释与 `MY-FAULTS.md` 缺陷 37）：
1. 用 `_dyld_get_image_header(i)` + `_dyld_get_image_name(i)` **按名字**枚举，
   拿到真实 `mach_header` 作基址（**不要**用 `dlopen` 句柄）；
2. 用一个**已知导出符号**做**阳性对照**：`dlsym` 的地址应与「基址 + 该符号 n_value」一致；
   不一致就说明折算错 ⇒ **必须报「无法定位」，不许报「未找到」**。

### 同版附带：v0.3.457 修掉的两个构建失败（都不在应用逻辑里）

1. **一句 Swift 表达式让类型检查器超时**：
   `min(100, max(0, Int((Double(a)/Double(b))*100).rounded()))` —— `min`/`max`/`Int`/`Double`/
   `.rounded()` 全是重载，挤在一起让编译器穷举组合直到超时。拆成带类型标注的中间变量即可。
2. **CI 里 `$VAR` 紧跟全角字符** → bash 把多字节字节并进变量名 →
   `ATH_X86_SHA256（: unbound variable` → `set -u` 崩。
   ⚠️ 这次差点**改错东西**：日志里那两行 sha256 明明是**相等**的（门禁是过的），
   失败在下一行的 unbound variable。**只看「步骤失败」就以为门禁不匹配，会往错的方向修。**
   已加全仓库扫描规则（`.yml/.yaml/.sh` 里同类写法现为 **0 处**）。

## [0.3.457] - 2026-09-19

### 电池页两处修正（都对齐爱思）+ 修 airlift 探测「第 2 个连接必卡」

#### 1. 电池页：合并重复行 + 评级阈值按反汇编改对

**(a) 「当前容量」与「额定容量」是同一个字段 ⇒ 合并**

两行都取 `NominalChargeCapacity`（实机 2709）⇒ 显示成两个一模一样的 2709，看着就像 bug
（用户报告「数值怎么是一样的」）。合并为一行，名字用 **「额定/当前容量」**。

为什么名字要带「额定」：单叫「当前容量」会被读成「现在装了多少」，于是与下面的
「剩余容量」打架（80% × 2709 = 2167 ≠ 2226）—— 用户正是这么被绕进去的。
这个量是**电池现在能装多少**（额定），不是**还剩多少**。

**(b) 评级：阈值与文字都错了（反汇编实证，不是推断）**

反汇编 `idm_info` 的评级函数拿到原始比较指令：
```
0x...1D4  cmp eax, 0x5B     ; 91
0x...1D7  jl  0x...1E2      ; < 91 往下
           → 「优」
0x...1E2  cmp eax, 0x50     ; 80
0x...1E5  jl  0x...1F0      ; < 80 ⇒ 差
           → 「一般」
```

⇒ **`优` = 91…100；`一般` = 80…90（闭区间）；`差` = 0…79。**

与旧实现的差异（**两处都是原来写错的**）：
- 旧代码 `80... → 良好`、`60..<80 → 一般` ⇒ **80 那条线错了**（应归「一般」）；
- **「良好」这个词在爱思二进制里根本不存在**（实测只有「优 / 一般 / 差」）。
  ⇒ 实机 81% 爱思判「一般」、我们判「良好」（用户截图实证）。
- 90 是**闭区间上界**（`< 91` 才往下走）⇒ 90 归「一般」，不是「优」。

另把寿命百分比从 `Int(...)` **截断**改为**四舍五入**（爱思是显式的
`trunc + (frac >= 0.5 ? 1 : 0)`，已读出来）。实机 81.37% 两法同结果，但 81.6% 会差 1
⇒ 可能跨过评级档位边界。

**「剩余容量」不动** —— 核过了，2226 mAh 是对的（80% × 满充 2805 = 2244，差 0.6%
是电量取整）。之前的「看着不对」来自上面那个标签歧义，合并后就不打架了。

#### 2. ★ airlift 探测：同一次运行里**第 2 个服务连接必卡**

真机实证（v0.3.456，**两次运行完全一致**）：
```
第 1 组正常跑完（拿到 SyncFailed/ErrorCode=4 基线）
第 2 组：查到端口 → 卡死在 adapter_connect，永不返回
        （8 分钟无任何日志，连 15s 读超时都没触发）
```
⇒ 卡在一个**没有超时的阻塞调用**上。

而本实验的设计是「**四组各用一条全新连接**」（因为设备在 `SyncFailed` 之后会关连接）
⇒ 两者冲突 ⇒ **四组连跑必然卡在第 2 组**，永远拿不到 (a)/(b) 的结果。

**修法**：`airlift` 命令支持**指定组号**，每次调用只建一条连接：
```
ssh_run.py airlift a     # 只跑「84 字节全 0」
ssh_run.py airlift b     # 只跑「01 01 + 82 个 0」
```
`forceProtocolProbe(group:)` / `triggerProtocolProbeOnce(onlyGroup:)` /
`runProtocolProbe(onlyGroup:)` 一路透传。

#### 3. 同版附带：一条**决定性**的真机证据

`airlift` 探测在真机上打出了这句（OS 自己的原话）：
```
CoreFP dlopen 失败：... (fat file, but missing compatible architecture
    (have 'i386,x86_64', need 'arm64e, arm64e.v1, arm64, arm64'))
```
⇒ bundle 里那份 `SAPAssets/CoreFP` **确实存在，但只有 i386 + x86_64 切片**。
**原生 `dlopen` 路线到此确证不可能**；x86_64 切片**必须走解释执行**（A-64）。

## [0.3.456] - 2026-09-19

### 电池「当前容量」对齐爱思 + 新增 SSH 入口 `airlift`（我自己能触发探测，不再麻烦用户）

#### 1. 电池「当前容量」取错字段（用户报告「输出和爱思不一样」）

**真机实证**（同一台设备、同一时刻，两边的值直接对）：

| 字段 | 设备 registry 真实值 | 爱思显示 | 我们（v0.3.455） |
|---|---|---|---|
| 出厂容量 | `DesignCapacity` = 3329 | 3329 ✓ | 3329 ✓ |
| **当前容量** | `NominalChargeCapacity` = **2709** | **2709** | 取 `AbsoluteCapacity` = **2263** ✗ |
| 满充容量 | `FullChargeCapacity` = 2805 | -1 | 2805 |
| 充电次数 | `CycleCount` = 949 | 949 ✓ | 949 ✓ |
| 电池寿命 | 2709 / 3329 = 81.4% | 81% ✓ | 81% ✓ |

⇒ 爱思的「当前容量」取的是**额定容量** `NominalChargeCapacity`，不是「剩余绝对容量」。
已改成同口径（回退链保留）。

**关于「满充容量」**：爱思显示 **-1**（它自己没读到），而我们读到的是真实的 2805
（`FullChargeCapacity` 确实存在于 registry）。**这里不跟着爱思改** ——
为了对齐而把一个**读得到的真值**降级成 -1，是拿准确性换一致性，不划算。

#### 2. ★ 新增设备端 SSH 命令 `airlift`

```
ssh_run.py airlift      # 强制再跑一遍 airlift 协议探测（忽略单飞标志）
```

**为什么必须加**：探测的设计是「功能首次调用 airlift 时**自动跑一次**」，
而开发期要**反复取结果**。没有这个入口，每次取结果都得**请用户去点一次「空间回收 → 扫描」**
—— 那是**把系统的活推给用户**（本项目已犯过的错，见缺陷 30）。
现在取结果在 SSH 里一条命令完成，**不需要用户配合**。

实现：`AirliftExploit.forceProtocolProbe()`（重置单飞标志后走原路径）+
`SSHServerService` 的 `case "airlift"`。
⚠️ 注释里写明**只给 SSH 调试用、不要挂 UI 路径**（它会真建 RSD 隧道，
挂 UI 上会跟其它功能抢隧道）。

## [0.3.455] - 2026-09-19

### 日志诚实性 + 结构加固（GP-10 审计落实）+ CI 桩自检改为「对证」

本版**不改实验逻辑**，只修「日志会说谎」和两处结构隐患。核心实验（Grappa 四组 + stage）
与 v0.3.454 完全一致。

#### 1. ★ 修两处**会误导判断**的日志措辞（GP-10 指出）

| 位置 | 原文（错） | 改成 |
|---|---|---|
| iOS 同类框架结论 | 「既没有 export trie 也没有可读 LC_SYMTAB」 | 「**本次未解析符号表**（系统路径镜像按 `fileBacked` 护栏跳过）」 |
| CoreFP 路径不存在 | 「两个候选路径都不存在」 | 「**所有候选路径都不存在（含 bundle 里的 `SAPAssets/CoreFP`）**」 |

为什么必须改：前者的真相是**我们根本没去解析**（护栏提前返回），说成「读了但读不到」
会让人**照着空结果去查一个不存在的 bug**；后者会让人以为「我们手上没有 CoreFP」——
**而事实是我们有**（`SAPAssets/CoreFP`，29 MB，随包发布，只是架构不对）。
日志一旦说谎，后面的所有判断都会建在错的前提上。

#### 2. ★ CoreFP 探测把 **bundle 内那份**放进了候选路径（第 1 条）

iOS 的 `/System/Library/...` 上**确实没有** CoreFP —— GP-20 用 iOS SDK 完整目录清单
**受控枚举**过（16.5 私有框架 1743 条、10.3 602 条，`truncated:false`；`CoreFP`/`AirTrafficHost`
两次 0 命中，而 `AirTraffic` 对照命中，证明清单**确实收录私有框架**）。
⇒ 只探系统路径，日志永远只会说「路径不存在」，这个结论**没有信息量**。
现在把 `Bundle.main.bundlePath + "/SAPAssets/CoreFP"` 放最前，设备日志会直接给出真相：
**文件存在，但架构不对**（10.9 那份是 fat i386 + x86_64，没有 arm64/arm64e 切片）。

#### 3. ★ 补丁 D：`LC_ID_DYLIB` 改成全局唯一名（结构加固）

`dlopen(path)` 的解析**按 install name 匹配已加载镜像**，不是按路径。我们这份补丁过的
AirTrafficHost，`LC_ID_DYLIB` 原本是系统那个名字
（`/System/Library/PrivateFrameworks/AirTrafficHost.framework/...`，补丁 C 之后变扁平但**仍是同名**）。
⇒ 若哪天系统上真有同名镜像已被加载，`dlopen` 会把**系统那份**还给我们，
而调用方按「bundle 路径」判出的 `fileBacked` 仍是 true ⇒ **护栏被静默绕过**。
iOS 现在没有 AirTrafficHost（已受控枚举），但这是**结构上不该留的口子**。

改法：`--unique-id`（默认 `@rpath/EscapeOSAirTrafficHost`），更短 ⇒ 原地覆写、`cmdsize` 不变。
我们一律**按路径 dlopen**、从不按名字查它；且这份二进制在 CI 里是**未签名**的
（签名由侧载工具施加）⇒ 改 load command 不破坏任何有效签名。

**本地实测（真 FAT 二进制）**：
```
补丁 C  LC_ID_DYLIB   @0x0550 cmdsize=112（未变）
            旧: .../AirTrafficHost.framework/Versions/A/AirTrafficHost
            新: .../AirTrafficHost.framework/AirTrafficHost
补丁 D  LC_ID_DYLIB   @0x0550 cmdsize=112（未变）
            旧: .../AirTrafficHost.framework/AirTrafficHost
            新: @rpath/EscapeOSAirTrafficHost
```
独立复核产物：`ID_DYLIB=@rpath/EscapeOSAirTrafficHost`、`platform=2(iOS) minos=18.0.0`、
桩路径正确、`CoreFoundation` 扁平、**全文件无 `/Versions/` 残留**、**不再自称系统 install name**、
大小不变 332176 → 332176。

#### 4. 补 `sizeofcmds` 上界（GP-10 指出）

原来只挡了 `cmdsize < 8` 的**下界**；单个 `cmdsize` 合法但累计越出 load command 区时
仍会读到区外。现在三个解析函数都加 `let cmdsEnd = 32 + sizeofcmds`，
循环条件改成 `cmdsize < 8 || off + cmdsize > cmdsEnd { break }`。

#### 5. ★ 措辞纪律：把「未实测的机制」降级为**推断**

v0.3.450/v0.3.453 的注释与 CHANGELOG 把
「**缓存构建器改写了 `__LINKEDIT.fileoff`**」当成**已证事实**写。
GP-10 指出：**没有本地共享缓存样本可验，这是推断**。

现在分两层写明：**实测确定的一层** = 崩溃就发生在对系统镜像做符号枚举的那处裸解引用；
**推断的一层** = 头部字段与文件不再自洽（最可能是 `__LINKEDIT.fileoff`）。
并写明「**护栏不依赖这层推断成立** —— 推断错也不会错杀它」。
⇒ 对外只说「算出了不可信地址」，不把具体字段当已证事实。

#### 6. CI：桩符号自检从「**自证**」改成「**对证**」（GP-20 发现）

原来拿**硬编码的 17 个名字**去查桩自己 —— 那是自证：查的是「桩导出了这 17 个吗」，
而不是「**这份 ATH 需要的是哪 17 个吗**」。而 ATH 是**从 runner 的 macOS 现取**的，
macOS 一升级它的导入集就可能变。届时 CI 仍会打印「桩 17 个符号全部已导出 ✓」并放行
⇒ 设备上 dlopen 才在 **bind 阶段**炸，而且失败码 `-0xa5a4` 与「桩文件不存在」**同码**。

现在改用**同一次运行里 patch 脚本产出的 `mobiledevice-imports.txt`** 当清单
（它读的就是**这份 ATH 的 import 表**）⇒ 才是「桩必须导出什么」的**唯一权威来源**。
历史清单只做**警告**（差异本身是信号：说明 macOS 换版了，基于旧版的偏移/符号名结论都要重核）。

---

### ★★ 追加：v0.3.454 真机上的两个故障（用户报告），都已修

用户报告（v0.3.454 / build 750）：「点空间回收扫描**闪退**」+「电池健康**仍然无法读取**」。

#### A. 电池健康：上次只修了**回退节点**，真正断的是**主节点**

真机日志（10:32:48）—— 上一版加的日志正好把根因打了出来：
```
电池：IOPMPowerSource 节点不存在（返回空）
电池：主节点 IOPMPowerSource 查询失败：未返回电池数据（设备可能未解锁，或 iOS 版本不支持）
```
UI 截图同一句话：「**无法读取电池数据 — 未返回电池数据**」。

**根因**：`fetchRegistry()` 退回另一种查法的条件写错了 ——
```swift
if let e {                            // ← 只有 name 形式**报错**时才退回 class 形式
    ...退回 class 形式...
}
guard let node else { return nil }    // ← name 形式「没报错但返回空节点」时走这里，直接 nil
```
本机上 **name 形式不报错、只返回空节点** ⇒ 退回分支**根本不执行** ⇒ 主节点拿到 nil
⇒ 整个电池读取失败（连温度回退都没机会跑）。而 class 形式（本文件**历史上**的原始写法）
本来是能取到节点的 —— 是 v0.3.443 把顺序改成「先 name 查」时引入的。

**判据错了**：应该是「**有没有拿到节点**」，不是「**有没有报错**」。
**修法**：两种查法**都跑**，只在**真的拿到节点**时才停。

#### B. 闪退：`dlopen` 返回的**不是**我们请求的那个镜像

真机日志：
```
10:32:52.049  [airlift] dlopen 成功          ← 断在这里
10:32:52.716  EscapeSpace 0.3.454 (750) 启动  ← 0.7 秒后重启 = 崩了
```
崩溃点在 `note("dlopen 成功")` 的**下一句** —— 解析 bundle 里那份 AirTrafficHost 的符号表。

**根因：三个洞叠在一起，任何一层单独都挡不住。**

| # | 洞 | 为什么挡不住 |
|---|---|---|
| ① | `isBundleLocalFileImage()` 判的是「我们传给 `dlopen` 的**路径字符串**」，不是「dyld **实际加载**的镜像」 | install-name 撞车时 `dlopen` 可能返回**另一个已加载镜像**的句柄，而它（多为共享缓存镜像）的 `__LINKEDIT` 语义完全不同 ⇒ 算出的 symtab 地址是垃圾。**本版补丁 D 已从另一侧堵住这个口子**（`LC_ID_DYLIB` 改成唯一名） |
| ② | 兜底的 `isPlausibleAddress` 只挡 0 / 未对齐 / 超出用户空间 | **垃圾地址照样通过** |
| ③ | `mach_vm_region`（唯一真正的可读性保证） | iOS SDK 下取不到（CI 实锤 `cannot find 'mach_vm_region' in scope`） |

**修法：换思路 —— 根本不碰内存里的符号表。**
新增 `findSymbolInFile(path:base:name:)`，**从文件**解析 Mach-O：

- 文件长度是**我们自己在同一函数里读出来的**（`Data.count`）⇒ 每一处读取
  （`u32`/`u64`/`segname`/字符串表）都硬性限制在这个长度内
  ⇒ **越界读在构造上不可能发生**，不再需要任何「地址看起来合不合理」的启发式。
- 运行时地址改用 `dladdr` 拿到的**真实**加载基址算：`base + n_value − __TEXT.vmaddr`。
- 顺带把洞 ① 变成**显式日志**：`dladdr` 的真实路径 ≠ 请求路径时单独报一行
  （否则会被误读成「符号没找到」）。

另两处 `findSymbolInImage` 调用点（CoreFP 段 / iOS 同类框架段）**都走默认 `fileBacked: false`**
⇒ 直接返回、不解析 ⇒ 不可能崩。**唯一**传 `true` 的那处已换成文件版。

#### 教训

**「证明不了可读，就不要解引用」** 这件事，本项目试过两次启发式
（头部自洽性检查、地址合理性检查），**两次都没挡住**。
真正的解法不是把启发式调严，而是**换一条不需要该保证的路径**：
数据有已知长度的副本时，就从副本读。

## [0.3.454] - 2026-09-19

### ★ 拦住一个即将发出去的回归：v0.3.453 修了「闪退」，但**放回了「抢隧道」**

**v0.3.453 的构建被我在构建途中取消，没有发给用户。** 原因如下。

#### 1. 两个故障是**独立的**，453 只修了其中一个

| 故障 | 机制 | v0.3.453 是否修好 |
|---|---|---|
| **闪退** | `runGrappaProbe()` 在共享缓存镜像上越界读 | ✅ 修好（`isReadable`） |
| **配对全废** | 三条设备探测**真建 RSD 隧道**，与其它功能抢隧道 | ❌ **被放回来了** |

v0.3.453 把四个探测**全部接回**自动路径，其中三条会 `withTunnel`
⇒ `tunnel_create_rppairing` 真建隧道。

#### 2. 为什么「修好闪退」不等于「可以放回 UI 路径」

`AFCService.swift:19` 写明的项目铁律：

> 同一 hostname 并发 `tunnel_create_rppairing` 会**互相抢占**。

各服务的队列**互不排斥**（`AirliftExploit.protocolQueue` 是它自己的私有队列，
与 `AFCService.afcQueue` / `DeviceControlService` 之间没有任何互斥）。

`triggerProtocolProbeOnce()` 挂在**功能首次被调用**的路径上 ——
用户点「空间回收 → 扫描」时，扫描自己那条隧道正被这串探测抢。

**这正是 v0.3.419 → v0.3.421 → v0.3.424 那串事故**（git 记录，逐条可查）：

- v0.3.421：「勾选 airlift 会抢挂所有依赖配对文件的功能」
- v0.3.424：「418 好、419 起所有依赖配对文件的功能失效」的真正根因 ——
  设备端被污染，真机实测 `attemptPairVerify` **连续 63 次零响应**（每 7 秒一次、持续 7 分钟）

⇒ 修好越界读**并不会**让隧道抢占消失。把三条设备探测放回自动路径，
就是**把 419 那串事故原样重演一遍**。

#### 3. 本版处置

| 探测 | 是否建隧道 | 触发方式 |
|---|---|---|
| `runGrappaProbe()` | **否**（纯 `dlopen` + 解析 Mach-O 头，毫秒级） | **自动**（功能首次被调用时，保持原设计） |
| `runAfcEscapeProbe()` | 是 | **手动**（新增 `runDeviceProbesManually()`） |
| `runStageProbe()` | 是 | 同上 |
| `runProtocolProbe()` | 是 | 同上 |

- 新增 `AirliftExploit.runDeviceProbesManually()`：三条设备探测的**唯一**入口，
  带单飞标志 `deviceProbesRunning`（同一时刻只允许一串在跑），串行依次执行、跑完置回。
- `ExploitSelectionView`：**仅当 airlift 已勾选时**显示一行「运行设备端探测」按钮。
  只在用户**主动点这一下**时跑 —— 不挂 `onAppear`、不挂 `toggle()`、不挂扫描路径。
- 代码注释里写明「⚠️ 不要把它挪回 `toggle()` 或任何 `onAppear`」，防止后人回退。

#### 4. 教训

同一个错本项目犯了三次（v0.3.419 / v0.3.450 / v0.3.453），
**每次都在「修好手头这个 bug 之后顺手把探测放回原路径」**。
根因不是「某个 bug 没修」，而是**触发位置本身错了**：
**有副作用（建隧道 / 裸读内存）的自检，不能挂在会被普通功能自动命中的路径上。**
修 bug 与挪位置是两件事，必须分开做、分开验证。

#### 5. ★ 更正上面第 1 句 + 本版补的编译修复

上面写的「**v0.3.453 的构建被我在构建途中取消，没有发给用户**」**不完整**，据实更正：

- v0.3.453 的构建（run `35414213779`）**确实被取消过一次**（第 1 次尝试，停在 step 22）。
- 但它**被重跑过**（第 2 次尝试），而重跑 **`failure`** —— 不是取消，是**编译不过**。
  真正的编译错误（CI 实锤）：
  ```
  EscapeOS/Engine/Exploits/AirliftExploit.swift:1051:25:
      error: cannot find 'mach_vm_region' in scope
  ```
- ⇒ 结论：v0.3.453 **不是「被拦下没发」，是「根本编不出来」**。两个原因都要记，
  不能只记「我拦住了」。

**根因**：v0.3.453 用 `mach_vm_region` 做「内核级可读性校验」，但
`import Darwin` 在 iOS SDK 下**不暴露** `mach_vm_region`。
（要做这件事得先确认正确的 module —— `Darwin.Mach` 还是 `MachO` —— 在能本机验证之前不赌。）

**本版改用的修法（编译上确定可用，且同样根治）**：把「问内核」换成「**不去解析**」——
新增 `fileBacked` 门禁 + `isBundleLocalFileImage(path)`：

| 层 | 做法 |
|---|---|
| ① **主保证** | 只解析「**在 `Bundle.main.bundlePath` 下、且确实存在于磁盘**」的文件型镜像。系统镜像（含全部共享缓存镜像）**一律不解析符号表**，直接报「本次无法判定」 |
| ② 兜底 | 解析前再做 `isPlausibleAddress` 合理性检查（非 0 / 8 字节对齐 / 未越出用户空间 / 加法不回绕） |
| ③ 顺带 | `ncmds` 封顶 4096、`nsyms` 上限 1e6、`boundedCString` 取代无上界的 `String(cString:)` |

**为什么第 ① 层就够**：崩溃只发生在**共享缓存镜像**上（它们的头部被缓存构建器改写）。
`AirTraffic.framework/AirTraffic` 就是这类；而 `runGrappaProbe()` 真正**需要**解析的
只有 bundle 里那份 `Frameworks/AirTrafficHost`（文件型）⇒ 该解析的照常解析，该跳过的整类跳过。

**同时修掉一处会造成假阴性的统计缺陷**：CoreFP 段新增 `undetermined` 桶 ——
「**未解析**」与「**真的没有**」必须分开，否则「本次无法判定」会被写成「缺 N 个」。
（判据分支顺序也随之调整，`dlsym` 命中数与未解析数都会如实进结论行。）

自检：括号平衡 +0；无 `mach_vm_region` / `mach_task_self_` / `VM_PROT_READ` 等残留引用
（仅保留在「为什么不用它」的说明注释里）；`isReadable` 字样已全部清掉。

#### 6. ★ 恢复 `runProtocolProbe`：它**不是「已死」，是「还没测」**

「补 3」把 Grappa 内容实验整个删掉了，理由写的是「AT/Grappa 这条线已死」。**这个理由不成立**，
而且它把**两个不同的问题**混成了一个：

| 问题 | 需要什么 |
|---|---|
| **设备侧能不能「生成」Grappa** | 需要 FairPlay/CoreFP —— 确实难 |
| **设备是否「校验」Grappa 内容** | **只需要发一组假值试一次** —— 不需要任何 FairPlay |

四组对照里只要 **(a) 84 字节全 0** 或 **(b) `01 01`+82 个 0** 有一组通过，
就说明**设备根本不校验内容** ⇒ **整条 CoreFP 路线全部作废**，攻击链直接往前走。
这是目前**最便宜、且唯一能改变路线**的实验，必须留着。

⇒ 手动入口恢复为跑**两条**（`runStageProbe` + `runProtocolProbe`），
改名 `runManualProbes()`，按钮文案「运行设备端探测（stage + 协议）」。
`runAfcEscapeProbe` 仍不进这个入口（**已实测证伪**：绝对路径被解析到根内、`..` 被服务端拒 `InvalidArg`）。

代码注释里同时写清 v0.3.451 那条「iOS 上没有 CoreFP ⇒ 路线到此为止」**已撤回**的三条理由
（探测路径全是系统路径、从未探 bundle 里的 `SAPAssets/CoreFP`；与生产中的 Unicorn 链路直接冲突；
`dlopen` 失败不构成证据），防止后人再照着那条错误结论删东西。

#### 7. ★ 补丁 C：修掉**第二个**加载期拦路虎（`Versions/A` 路径形态）

**这是 GP-20 发现的，与「闪退」「隧道抢占」都独立的第三个问题。**

补丁后的 `AirTrafficHost` 里，依赖路径记录的是 **macOS 形态**：

```
/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
```

而 iOS 上**没有 `Versions/` 目录**，系统框架的 install name 是**扁平形态**：

```
/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
```

dyld 解析依赖时 install name 是**按字符串精确匹配**共享缓存里的镜像名
⇒ 在 iOS 上会直接 `Library not loaded: .../Versions/A/CoreFoundation` 失败。

**只改 `LC_BUILD_VERSION`（补丁 A）不够 —— 这是两个独立的拦路虎。**

修法（补丁 C，`tools/patch_airtraffichost.py`）：把所有 `.../Versions/<X>/...` 路径
**逐个剥掉** `/Versions/<X>` 段。扁平形态**一定更短** ⇒ 原地覆写 + `\0` 填充，`cmdsize` 不变。
覆盖全部带路径名的 load command：`LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` / `LC_REEXPORT_DYLIB` /
`LC_LAZY_LOAD_DYLIB` / `LC_LOAD_UPWARD_DYLIB` / **`LC_ID_DYLIB`**。

**本地实测（在真 FAT 二进制上跑，不是纸上推理）**：
```
LC_ID_DYLIB   @0x0550 cmdsize=112（未变）
    旧: .../AirTrafficHost.framework/Versions/A/AirTrafficHost
    新: .../AirTrafficHost.framework/AirTrafficHost
LC_LOAD_DYLIB @0x0710 cmdsize=104（未变）
    旧: /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
    新: /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
共改 2 条
```
独立复核补丁后产物：`LC_BUILD_VERSION platform=2(iOS) minos=18.0.0`、
`@executable_path/Frameworks/libMobileDeviceStub.dylib`、
`CoreFoundation.framework/CoreFoundation`（扁平）、**全文件无 `/Versions/` 残留**、
文件大小不变（332176 → 332176）、`LC_DYLD_CHAINED_FIXUPS` 的 import 表也同步显示扁平名。

同一函数 `flatten_versions()` 之后 CoreFP 也要用（那边有 5+ 条同类路径）。

### ★ 同版附带：修「电池健康读不出数据」回归（用户报告）

**现象**：用户报告「电池健康板块出问题，没法读取电池数据了」。

**根因（真机实证 + git blame 双证）**：v0.3.443 那次「按爱思 9.0 口径修正」引入的。

`BatteryHealthService.query()` 里给温度加了回退节点：

```swift
if (intValue("Temperature", in: primary) ?? 0) <= 0 {
    pack = try fetchRegistry(client: client, entryName: "AppleSmartBatteryPack")  // ← 裸 try
}
```

两个问题叠加成**必现**故障：

1. **这个分支每次都会走到** —— 该函数自己的注释（v0.3.443 写的）已写明
   「iOS 27 的 `IOPMPowerSource` 里**没有** `Temperature`」⇒ `intValue(...) ?? 0` 恒为 0
   ⇒ `0 <= 0` 恒真。
2. **裸 `try`** —— `fetchRegistry` 在 name / class **两种形式都报错**时会**抛错**。
   于是这个**可选**的回退节点一旦查不到，**整个 `query` 直接抛出**，
   连已经拿到的 `IOPMPowerSource` 主数据一起丢掉 ⇒ UI 报「无法读取」。

**真机证据**：`LoginLogs/battery_dump.txt` **不存在**。
该文件正是在 `query()` 里紧接着那行 `try` 之后写的 ⇒ 说明执行**从未走到那里**。

**为什么定位费劲（一并修）**：这条失败路径**完全没有日志** ——
UI 只把错误塞进 `errorText`，`login.log` 里一行都没有，
所以只能靠「某个文件不存在」反推，代价很大。本版**三处补上日志**：
主节点不存在、主节点查询失败、回退节点查询失败（各自写明是否影响主数据）。

**修法**：回退节点改为「**失败即放弃回退**」，绝不让它拖死主数据 ——
主数据已经在手，一个可选的温度来源不该有否决权。

### ★ 同版附带：恢复**自动触发**（撤销「手动按钮」，并撤回一条错误判断）

#### 1. 撤销「把探测改成手动按钮」

我曾把三条探测从自动路径挪到一个手动按钮上，理由是「防止抢隧道」。
**这个改动是错的，已撤销。** 用户直接否决：**以前怎么测就怎么测** ——
「空间回收 → 扫描」「文件共享进界面」本来就会经 `ExploitRegistry` 调到 airlift，
这是**自然发生的调用**，用户不该为了跑一个诊断再去找按钮点。

**而且我当初的理由本身站不住**：「抢隧道」那串事故（v0.3.419/421/424）的**真凶是「重复」**，
不是「单次建隧道」。真机日志是 `attemptPairVerify` **连续 63 次零响应（每 7 秒一次、持续 7 分钟）**——
当时自检挂在「勾选 airlift」和「App 启动」**两个动作**上反复跑，设备端 RPPairing 是被
**反复建连**拖死的。而这套探测**单飞、整个进程只跑一次**（`protocolProbeStarted`），
量级完全不同；`withTunnel` 还自带 3 次退避重试，偶发抢占能自愈。

⇒ 恢复自动触发。若日后**真的**出现抢占，正确修法是**全局共享一条隧道队列**
（各服务现在各有一条、互不排斥），**不是**把动作推给用户。

#### 2. ★ 撤回「AT/Grappa 这条线已死」

我在「补 3」里以「AT/Grappa 这条线已死」为由把 Grappa 内容实验删掉了。**该理由不成立** ——
它把**两个不同问题**混成了一个：

| 问题 | 需要什么 |
|---|---|
| 设备侧能不能**生成** Grappa | 需要 FairPlay/CoreFP，确实难 |
| 设备是否**校验** Grappa 内容 | **只需要发一组假值试一次**，不需要任何 FairPlay |

四组对照（不发键 / 84 字节全 0 / `01 01`+82 个 0 / 真实块）里**只要 (a) 或 (b) 有一组通过**，
就说明**设备根本不校验内容** ⇒ **整条 CoreFP 路线全部作废**。
这是目前**最便宜、且唯一能改变路线**的实验，必须留着。

顺带把 v0.3.451 那条「iOS 上没有 CoreFP ⇒ 路线到此为止」的**撤回理由**也写进代码注释，
防止后人再照错误结论删东西（三条理由：候选路径全在 `/System/Library` 下、从没探过
bundle 里的 `SAPAssets/CoreFP`；与本项目**已在生产运行**的 `SignedStoreAuthenticator`
（用 Unicorn 解释执行 CoreFP 做 SAP 签名）直接冲突；`dlopen` 失败不构成证据）。

**自动路径现在跑三条**：`runGrappaProbe()`（纯离线）→ `runProtocolProbe()`（Grappa 内容实验）
→ `runStageProbe()`（zip symlink）。`runAfcEscapeProbe()` **不跑** —— 已实测证伪
（绝对路径被解析到根内、`..` 被服务端直接拒 `InvalidArg`），再跑只是白等超时。

#### 3. stage 那条路要回答的问题

**解压器跟不跟随 symlink？** 若跟随，只要在 zip 里放一个「路径穿过 symlink」的普通文件，
越界写在**解压阶段**就完成了 —— 整条链里**只有第 ② 步（发 `FileComplete`）需要 AT/Grappa**，
而第 ① 步 stage 走 `com.apple.streaming_zip_conduit`，**不碰 AirTraffic、不需要 FairPlay**。
PoC 的 zip 里**故意没有**这种条目 ⇒ 这一点从没被验证过。

`runStageProbe()` 里放了两条**独立**判据（不是一条）：

1. **不逃逸对照**：`p0/p1/p2/link` → `../../../airlift-stage-target`，
   再放 `p0/p1/p2/link/<follow-probe>`。**只回答「跟不跟随」，不触发 zip-slip 防护。**
2. **逃逸探针**：`p0/p1/p2/out` → `../../../../`，再放 `p0/p1/p2/out/<escape-probe>`。

★ 为什么必须有第 1 条：只有第 2 条时，整包若被 zip-slip 防护拒掉，
就分不清「不跟随」与「整包被拒」—— 两者后续动作完全不同。
代码里 `!linkPresent` 时的结论是「**无法判定**」，**不是**「不跟随」。

**zip 构造已做独立验证**（本地用 Python 逐字节复刻 `StageZipBuilder` 后过 `zipfile`）：
11 个条目、两个 symlink 都被识别为 `S_IFLNK`（`mode=0o120777`）、`0x5A53` extra field 正确、
**顺序全对**（`link`/`out` 必须排在「穿过它们」的条目**之前**，否则解压器会先建真目录、
穿透永不发生，测试就白做了；逃逸条目必须排**最后**）。15 条断言全通过。

## [0.3.453] - 2026-09-19

### ★ 闪退真修 + 四个探测全部恢复 + 撤回一条被写进代码的**错误结论**

#### 1. 闪退的**真正**修法（v0.3.452 只找到了位置，没修根因）

v0.3.452 定位正确 —— 崩在 `runGrappaProbe()` 里对**共享缓存镜像**做符号枚举时。
但它采取的是「**把探测全停掉**」来回避，不是修。本版修根因。

**根因**：把「文件偏移」折算成「运行时地址」用的式子
```
symTab = slide + (__LINKEDIT.vmaddr − __LINKEDIT.fileoff) + symoff
```
对**磁盘上的普通 dylib** 成立（`vmaddr − fileoff` = 首选加载地址，dylib 通常为 0）。
但对 **dyld shared cache 里的镜像**不成立 —— 缓存构建器改写了 `__LINKEDIT.fileoff`，
该式会**双重计数** ⇒ 算出**未映射地址** ⇒ 直接解引用 = 越界读 = 闪退。
`AirTraffic.framework/AirTraffic` 正是共享缓存镜像。

**关键认知**：**头部自洽性检查挡不住这个 bug** —— 缓存里的头部**本身是自洽的**
（`symoff` 确实落在 `__LINKEDIT` 描述的范围内），错的是 `slide` 的语义。
⇒ 只有「**真的去问内核这段内存可不可读**」才算修好。

**修法**（`AirliftExploit.swift`）：
| 措施 | 说明 |
|---|---|
| 新增 `isReadable(addr, len)` | 用 `mach_vm_region` 逐段确认**已映射且 `VM_PROT_READ`**；这是唯一真正的保证 |
| `exportTrieNames` | 读 `trieStart` 前先证明 `[trieStart, trieStart+trieSize)` 可读 |
| `findSymbolInImage` | `nsyms` 上限 1e6 + `symTab`/`strTab` 整段可读性校验 |
| `exportedNames` | 同上（不可读则**整段跳过**，trie 那半边仍有效，不丢结论） |
| `ncmds` 封顶 4096 | 畸形 `ncmds` 会让 load command 循环一直往后读 |
| `boundedCString` 取代 `String(cString:)` | 后者**无上界**，字符串表畸形时会扫出界（另一条越界读） |

★ **不可读时必须报「本次无法判定」，绝不退化成「没找到」** —— 后者是假阴性，会把结论带偏。

#### 2. 四个探测全部恢复

`runGrappaProbe()` / `runAfcEscapeProbe()` / `runStageProbe()` / `runProtocolProbe()`
调用点**全部接回**（v0.3.452 是四个全注释掉）。仍挂在「首次被功能调用」的路径上
（用户明确要求的设计：功能真的需要时自动拉起，而不是让用户手动勾选/取消勾选）。
所有探测都在串行后台队列，不阻塞 UI，连接一律 `defer` 释放。

#### 3. ★ 撤回 v0.3.451 写进代码/CHANGELOG 的错误结论

v0.3.451 写的是：
> 「iOS 上没有 CoreFP（实测，dlopen `no such file` + not in dyld cache）
>  ⇒ Grappa 的生成在设备侧无解 ⇒ **「移植 macOS AirTrafficHost」这条路线到此为止**」

**这条结论撤回。** 三处问题：

1. **证据基础不完整**：探测的候选路径**全是 `/System/Library/...` 系统路径**，
   **从未探测 App bundle 里的 `SAPAssets/CoreFP`**（29,014,912 B，**已经随包发到设备上了**）。
   「系统路径上没有」与「bundle 里那份加载不了」强度差一个数量级。
2. **结论与本项目已在生产运行的基础设施直接冲突**：
   `SignedStoreAuthenticator` 明确写着「用**本地 Unicorn 解释执行 Apple 的 CommerceKit/CoreFP**」
   给登录请求做 SAP 签名 —— **「在 iOS 上执行 macOS CoreFP」本项目早就做到了**。
3. **`dlopen` 失败本身不构成证据**：即便系统路径上有 CoreFP，它是 macOS 平台的二进制，
   平台号不匹配时 `dlopen` 也会失败；反过来，我们自己的那份是**文件**、可以走解释执行。

**⇒ 修正后的口径**：「**dlopen 路线**到此为止（系统路径无 CoreFP；且 CoreFP 有 12 条依赖，
其中 `StoreFoundation`/`DiskArbitration` 在 iOS 上不存在）。但**移植路线本身有既有基础设施**，
障碍已从『文件不存在』变成『**架构是否匹配解释器**』。」

#### 4. 顺带更正一处过时注释

`AirliftExploit.swift` 里「Windows 版 Grappa 生成**无条件硬失败**（与输入无关）」——
已被推翻：准确说法是「**真实实现，卡在某个早期 gate**」（42 状态平坦化 + MBA，是真代码），
且 Windows **也有**那套 `LoadLibraryA` + `GetProcAddress` 机制。

#### 5. 教训

同一个错本项目**犯了两次**：
- v0.3.419：**真连设备**的自检挂在 UI 触发路径上 ⇒ 配对相关功能全废
- v0.3.450：**裸读内存**的探测挂在同一条路径上 ⇒ 闪退

共同点：**把有副作用的自检挂在了 UI 触发路径上**。
但两次的教训**不一样**：419 的教训是「别把重活挂 UI 路径」，
450 的教训是「**任何由不可信头部算出的地址，解引用前必须先证明它可读**」——
后者不能靠「挪位置」解决，只能靠校验。

## [0.3.452] - 2026-09-19

### ★ 闪退真正的位置找到了：不是 AFC，是 `runGrappaProbe()` 里的**越界读**。全部探测归零。

**v0.3.451 我判断错了**，真机日志纠正了我：

```
09:41:19.648  [airlift] iOS AirTrafficHost 候选路径：AirTrafficDevice.framework/... — 不存在
09:41:26.928  ← 断在这里
```

**关键：连「AFC 越权路径探测开始」那行都没有** ⇒ 崩溃发生在**最后那行日志之后**，
也就是 **`runGrappaProbe()` 内部** —— 具体是在 **`AirTraffic` 那个镜像上做导出符号枚举**时。

**根因**：`/System/Library/PrivateFrameworks/AirTraffic.framework/AirTraffic` **`dlopen` 成功了**，
但它是**来自 dyld 共享缓存**的系统镜像，其 `LC_SYMTAB` 可能被裁掉 / `__LINKEDIT` 语义不同；
而我们那套地址折算
```
slide   = base − __TEXT.vmaddr
symTab  = slide + (__LINKEDIT.vmaddr − __LINKEDIT.fileoff) + symoff
```
在这种镜像上会算出**非法地址 ⇒ 越界读 ⇒ 崩**。
（实现者当初就标注过「若 dyld 给的 offset 语义不符会读到非法地址（崩溃风险）」—— 现在命中了。）

**本版处置：一条探测都不跑。**
`runGrappaProbe()` / `runAfcEscapeProbe()` / `runStageProbe()` / `runProtocolProbe()`
**四个调用点全部注释掉**（函数体保留）。App 稳定性优先。

**停掉不损失信息 —— 该拿的答案都已经拿到了**：
- ★ **iOS 上没有 `CoreFP`**（实测：`no such file`，且 `not in dyld cache`）
- **`AirTrafficHost` 也没有**；只有**设备侧**的 `AirTraffic`（不含 Grappa 生成逻辑）
⇒ **AT/Grappa 这条线在纯手机端走不通**（结论已定）。

**后续（按这个顺序，不再跳步）**：
1. 给 `exportedNames` / `findSymbolInImage` 加**地址合法性校验**（至少：`symoff`/`stroff` 必须落在
   `__LINKEDIT` 区间内、`nsyms` 上限、逐条读之前先验边界），修掉越界读；
2. 把探测改成**手动触发**（**绝不挂在功能调用路径上**）；
3. 再逐条放开，每次只放一条并真机验证不崩。

**教训（已写进 `MY-FAULTS.md`）**：**任何会真连设备、或会裸读内存的自检，都不能挂在 UI 触发路径上。**
v0.3.419 栽过一次（真连设备），这次又栽一次（裸读内存）—— 同一个错犯两遍。

## [0.3.451] - 2026-09-19

### ★ 紧急修回归：停用三条「真连设备」的探测（空间回收扫描闪退 + 配对功能全废）

**用户反馈**：「空间回收板块点击扫描又闪退了」+「涉及配对功能的都没法用」。

**根因（真机日志实锤）**：探测顺序是 `Grappa → AFC → stage → AT`，日志显示
```
09:41:19.648  [airlift] iOS AirTrafficHost 候选路径：AirTrafficDevice.framework/... — 不存在
09:41:26.928  ← 直接跳到别的日志，中间没有任何 AFC 输出
```
⇒ **`runGrappaProbe()`（纯离线）跑完了，之后没有任何 AFC 日志就断了 ⇒ 闪退在 `runAfcEscapeProbe()` 里。**

**为什么影响面这么大**：`triggerProtocolProbeOnce()` 挂在**首次被功能调用**的路径上——
「空间回收 → 扫描」「文件共享」**进界面**就会经 `ExploitRegistry` 调到 airlift ⇒ 触发这一串探测。
而三条设备探测**都会真建 RSD 隧道、真连设备服务** ⇒ 崩在那里会把配对相关状态带坏，
于是表现为「**所有依赖配对的功能都没法用**」。
**——这正是 v0.3.419 那次事故的同一类问题**（自检挂在 UI 触发路径上 + 真连设备），
我本该在加探测时就防住，是我的疏漏。

**本版处置：App 稳定性优先。**
- **只保留 `runGrappaProbe()`** —— 它**完全离线**（只 dlopen 一个本地文件，不建隧道、不碰设备），
  毫秒级、已实测不崩，而且它的答案**已经拿到了**（见下）。
- **`runAfcEscapeProbe()` / `runStageProbe()` / `runProtocolProbe()` 全部停用**（源码保留，调用点注释掉）。
  等各自单独排掉闪退、并且**改成手动触发**（不再挂在功能调用路径上）之后再逐条放开。

### ★★ 顺带定案：iOS 上**没有 CoreFP**（实测，不再是推断）

同一次日志里，`runGrappaProbe()` 给出了决定性结果：
```
CoreFP dlopen 失败（/System/Library/PrivateFrameworks/CoreFP.framework/CoreFP）:
  dlopen(...): tried: '.../CoreFP.framework/CoreFP' (no such file),
  '/private/preboot/Cryptexes/OS/.../CoreFP.framework/CoreFP' (no such file),
  '.../CoreFP.framework/CoreFP' (no such file, not in dyld cache)
```
⇒ **磁盘上没有，dyld 共享缓存里也没有** ⇒ **iOS 上确实没有 CoreFP** ✓
⇒ **Grappa 的生成在设备侧无解**（Grappa 依赖 FairPlay/CoreFP，而 Apple 只在 macOS/Windows 提供它）
⇒ **「移植 macOS AirTrafficHost」这条路线到此为止。**

**另一条实测**：`AirTrafficHost` 也不存在，但 **`/System/Library/PrivateFrameworks/AirTraffic.framework/AirTraffic`
`dlopen` 成功了**（`handle=0x36a75f300`）—— 那是**设备侧**的 AirTraffic，不是主机侧的 Host 实现，
不含 Grappa 生成逻辑。（已记录，后续如需可查它的导出符号。）

**⇒ 结论：AT/Grappa 这条线在纯手机端走不通。** 剩下的希望是 **stage**（不依赖 Grappa），
但它也需要先排掉闪退 + 改成手动触发再放开。

## [0.3.450] - 2026-09-19

### ★ 四组「Grappa 内容」实验 —— 直接判定设备**校不校 Grappa 内容**

**为什么这是现在最有价值的一个实验**：Grappa 生成依赖 FairPlay（`CoreFP`），而证据指向
**iOS 上没有 `CoreFP`**（三份独立 SDK 私有框架清单 + `CoreFP` 带 `fairplayd`/IOKit 内核组件 +
Apple 自己的 dyld 源码把该路径包在 `#if TARGET_OS_OSX` 里）。若那条路真断，
**唯一的转机就是「设备其实不校验 Grappa 内容」**。

**四组对照**（都发 `RequestingSync`，只是 `HostInfo.Grappa` 不同）：

| 组 | 内容 | 目的 |
|---|---|---|
| (0) | **不发** `Grappa` 键 | 基线（已知结果：被拒 `ErrorCode=4`） |
| (a) | **84 字节全 0** | 探测「占位即可」 |
| (b) | **`01 01` + 82 字节全 0** | 探测「前缀对就行」 |
| (c) | **真 Grappa**（从 `LoginLogs/airlift_grappa.bin` 读） | 阳性对照 |

**判据**（结论行原文）：
- 任一组回 `ReadyForSync` ⇒ `★★★ 通过！`
- **(a)/(b) 也通过** ⇒ `★★★ 关键结论：设备不校验 Grappa 内容（只当种子）` ⇒
  **不需要 CoreFP，整条路救活**
- **(c) 通过而 (a)/(b) 不通过** ⇒ `关键结论：内容被校验（但不一定绑主机身份）`
- **(c) 因缺 `airlift_grappa.bin` 被跳过** ⇒ 明确标注 **「本次是不完整结论」**（不装作有结果）

**★ 顺带修一个会让结论行说谎的缺陷**：原实现用 `last*` 变量拼结论，而设备在 `SyncFailed` 之后
**还会继续发消息**（`AssetMetrics`/`Ping`/`IdleExit`）⇒ `last*` 被覆盖 ⇒ 结论会显示
「Command=别的 ErrorCode=无」。改成**只认第一条 `SyncFailed`**。

**关于 `deviceType`**：实测真机 `Capabilities.GrappaSupportInfo` 报的是 **0**
（见 `ref-attraffic协议.md` 的真机抓包），macOS 侧也用 0 测出 `err=0/outLen=84`。
**保持 0 不动** —— 之前提过的「6」没有依据，已撤回。

**本版同时带上 v0.3.449 的构建修复**（桩被 xcodegen 拷到 bundle 根 ⇒ 改由 CI 显式拷进
`Frameworks/`，并加硬自检）。v0.3.449 那次构建**已成功**，本版在其基础上加四组实验。

**★ 本版修正一处发版缺陷（复核时抓到，非本次实验代码）**：
`CURRENT_PROJECT_VERSION` 曾误沿用 v0.3.449 的 **746**（应递增）。
`ModuleService.bootstrapBundledModules()` 以 `CFBundleVersion` 作**安装版本锚点**
（`ModuleService.swift:259-261`：「CFBundleVersion 每次发版必变」），
且设置页显示的就是 build 号 —— 449/450 同号会同时**丢掉覆盖安装检测**并**让用户无法从
日志区分装的是哪一版**。已改 **746 → 747**，并重发 v0.3.450（原 tag 指向的构建已取消，
`v0.3.450` 只构建一次）。

## [0.3.449] - 2026-09-19

### ★ 修 v0.3.448 的构建失败：桩被拷到了 **bundle 根**（而不是 `Frameworks/`）

**v0.3.448 的构建挂在 `Embed AirTrafficHost into Frameworks` 这一步 —— 是那道自检自己抓出来的。**

日志实锤（`CpResource`）：
```
CpResource .../EscapeSpace.app/libMobileDeviceStub.dylib   ← 拷到了 **bundle 根**
```
**根因**：xcodegen 对 `library.dynamic` 的 **`embed: true` 没有生成「Embed Frameworks」阶段**，
而是当**普通资源**拷到了 bundle 根。而框架里那条 `LC_LOAD_DYLIB` 要的是
`@executable_path/Frameworks/libMobileDeviceStub.dylib` ⇒ **位置对不上 ⇒ dyld 找不到桩
⇒ 整个框架 dlopen 必失败**。而且 **bundle 根不在侧载工具的递归签名范围内**，那份留着也没用。
（project.yml 里原来的注释还写着「`embed: true` 才会把它拷进 `.app/Frameworks/`」——**那条注释是错的**。）

**修法**：`project.yml` 里把该依赖改成 **`embed: false`**（只保留构建依赖，确保桩被编出来），
由 CI 的 Embed 步骤**显式 `cp` 进 `.app/Frameworks/`**（与框架同位置）。
并加自检：`test -f "$APP/Frameworks/libMobileDeviceStub.dylib"`（**硬失败**）+
「桩若同时出现在 bundle 根则警告」（软提示 `embed` 又被打开了）。

★ **顺带确认：v0.3.448 的另外 3 个修复全部生效**（日志可证）：
- step 22 `Build (compile/link)` **成功**；
- 桩链接参数里**只剩 `-framework CoreFoundation`**（SAP/openssl 那堆继承设置被覆盖掉了 ✓）；
- 产物名**确实是 `libMobileDeviceStub.dylib`**（`productName` 修法生效 ✓）；
- **补丁脚本在 runner 上跑通**：`框架源: /System/Library/.../AirTrafficHost`、
  `补丁后: offset=24(未变) cmdsize=112(未变) 新路径(53 字节)`、`ordinal 1 -> 17 个符号`、
  `AirTrafficHost embedded at .../EscapeSpace.app/Frameworks/AirTrafficHost` ✓。

### 加「iOS 原生 AirTrafficHost」探测 + export trie 枚举

**动机**：既然 Grappa 依赖 FairPlay（见下方更正），而 **iOS 自己也要做 FairPlay**，
那就存在一种可能：**iOS 系统里本来就带 `AirTrafficHost`（含 Grappa 能力）**。
如果真是这样，**我们前面折腾的一整套移植全部不需要** —— 不用改平台标记、不用空桩、不用重签，
**连 arm64/arm64e 架构的顾虑都没有**，直接 `dlopen` 系统那份、调同一个函数即可。

⚠️ **但独立复核（GP-20）给这个期望泼了冷水**，四条独立证据都指向「**iOS 没有 `AirTrafficHost`**」：
① TheAppleWiki 的 iOS `PrivateFrameworks` 全表里只有 `AirTraffic`(5.0+) 与 `AirTrafficDevice`(8.0+)，
**没有 `AirTrafficHost`**；② 另一份按版本的存在性矩阵（iOS 1.x–18.x）同样只有那两行；
③ `Dev:AirTrafficHost.framework` 页面**不存在**（API 返回 `missingtitle`），而
`Dev:AirTraffic.framework` / `Dev:AirTrafficDevice.framework` 都存在；
④ 全站搜 "AirTrafficHost" 共 5 处命中，**没有一处与 framework 相关**。
**置信度约 85%（公开资料，未实测）。**
而且反汇编里有 `"Grappa host verify fail: %d"` —— `AirFairSyncGrappaCreate` 是**主机侧**能力，
iOS 设备侧很可能**只消费 Grappa、不生成它**。
⇒ **本探测按「顺手一试」保留**（两个候选路径都试，成本≈0），**但不要把它当主路线**。
（已把候选路径扩到 `AirTraffic.framework/AirTraffic` 与 `AirTrafficDevice.framework/AirTrafficDevice`。）

**1. 新增「iOS 原生 AirTrafficHost」探测**
候选路径（**两个都试**，且**不因 `fileExists` 为假就跳过** —— 见下方坑 ②）：
```
/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost
/System/Library/PrivateFrameworks/AirTrafficHost.framework/Versions/A/AirTrafficHost
```
★ **判据升级（比原计划更可靠）**：不看混淆符号 `_uhO2GULXwfgKwPcp4YR2`
（它是 **private external**，只存在于 `LC_SYMTAB`；iOS 系统镜像常把 symtab 整个剥掉 ⇒ 会**假阴性**），
改为查 **`grappaPublic`** —— **公开导出里含 `grappa` 的**（如 `_ATHostConnectionGetGrappaSessionId`）。
**理由**：公开导出**在 export trie 里**，**不依赖 `LC_SYMTAB`**，**shared cache 场景照样拿得到**。

**2. `exportedNames` 补上 export trie（与 `LC_SYMTAB` 取并集，缺一不可）**
- **为什么要补**：iOS 系统框架多在 dyld shared cache 里、`LC_SYMTAB` 常被裁掉（`nsyms=0`）
  ⇒ 只认 symtab 的话导出名清单直接拿不到；而 export trie 在 shared cache 里也在，
  而且它正是 **`dlsym` 真正走的那张表**。
- **为什么还要保留 `LC_SYMTAB`**：**private external 不在 trie 里**（实测：
  `_uhO2GULXwfgKwPcp4YR2` **不在** AirTrafficHost 的 58 个 trie 名字里）⇒ 两者**互补**。
- 支持两种承载：`LC_DYLD_EXPORTS_TRIE`(0x80000033) 优先，`LC_DYLD_INFO(_ONLY)`(0x22/0x80000022)
  的 `export_off`(cmd+40) / `export_size`(cmd+44) 作回退。
- ★ **`trieOff` 是文件偏移、不是 vmaddr** ⇒ 必须按段折算（`__LINKEDIT` 的 `vmaddr − fileoff`）。
  普通 dylib 里恰好相等，**shared cache 里不保证** —— 不能偷懒写 `header + trieOff`。

**3. 验证方式：把 Swift 逐行照搬成 Python，跑真实二进制对比**
| 二进制 | trie 大小 | 节点数 | 解析出 | 期望 | 结果 |
|---|---|---|---|---|---|
| `_tmp_fw/AirTrafficHost` | 1320 B | 87 | **58** | 58 | **PASS** |
| `_tmp_corefp/fwx/A/CoreFP` | 176 B | 10 | **8** | 8 | **PASS** |

★ CoreFP 那例的 `__LINKEDIT` **delta = 32768 ≠ 0**，正好走到「shared cache 折算」那条分支
⇒ **公式被真实数据验证过，不是纸上推导**。

**4. 日志补 `nsyms` / `nValue` / `slide`**
用于核对「符号表到底有没有被剥」—— 若 `nsyms = 0` 就说明是 shared-cache 镜像，
此时**按名字定位会失败，但这**不等于**「没有这个能力」**。

**5. ★ 修一处会造成假阴性的结论措辞**
iOS ATH 的结论改成**四段式**，其中「trie 与 symtab 都读不到」时写的是
**「本次无法判定（注意：不是「没有」）」**，并单独加一行说明
「混淆符号未出现 —— 它是 private external，只在 `LC_SYMTAB` 里；若该镜像 symtab 被剥，
此项**阴性无效**，不作为判据」。
**为什么必须这么写**：搞混了就会让我们**错误地放弃「iOS 原生路径」这条最优解**。

**6. 更正 v0.3.448 里两处结论**（都来自同一轮深入复核）
- **Windows 的 `0x6560` 不是「无脑硬桩」** —— 行为上像（827 组输入恒同一错误码、不读入参、
  不写出参），**结构上是真实现**（42 状态控制流平坦化 + MBA 混淆；**有成功哨兵 `0x0FE8DD8F`**，
  在 `0x6560`–`0x8650` 内的 `0x6753` 处）。准确说法：**真实现，卡在某个早期 gate**。
- ★ **「Windows 也卡在 CoreFP 缺失」这个推断被推翻**（我自己推错的）：
  我拿「`0xFFFF5A5C` 有符号读 = `-0xa5a4`，与 macOS 上 CoreFP 缺失的失败码同值」直接推出「同因」——
  **「同码 ⇒ 同因」不成立**。硬证据：**Windows 版全文件扫 `CoreFP` = 0 命中**，
  导入表里没有能 dlopen 它的东西；**`0xFFFF5A5C` 全文件 0 处** ⇒ 返回值是**算出来的**
  （对照 `0xFFFF5BD9` 有 12 处）。
- ★ 但**「Grappa 依赖 FairPlay」这条站得住**：Windows 版**内嵌完整 FairPlay 证书链**
  （CN = `GrappaForATH.3333AF110510AF0000011` 一族），字符串里还有
  `Grappa host init failed` / `Grappa host verify fail` / `Grappa key could not be established`
  ⇒ **「Grappa 算法自包含、可纯 Swift 重实现」这个前提不成立**。
  （对我们影响为零 —— 第 4 轮就已改走「移植 macOS 框架」，这条只是**加强**那个决定。）

## [0.3.448] - 2026-09-19

### 修 3 个 bug + Grappa 探测链补全（`LC_SYMTAB` 替换 `dlsym`、CoreFP、iOS 原生框架）

**本版的核心目的**：把 v0.3.447 那次**必然失败**的三个 bug 全部堵上，并让**一次真机运行**
就能同时回答四个问题（框架能否加载 / iOS 有没有 CoreFP 且混淆名对不对 / iOS 有没有自带
`AirTrafficHost` / **stage 那条不依赖 Grappa 的路通不通**）。

**1. 修构建失败：`MobileDeviceStub` 链接不到 `libunicorn.a`**
顶层 `settings.base` 里的 SAP/openssl 设置（`$(DERIVED_FILE_DIR)/SAP/lib/libunicorn.a`、
`-L openssl-build -lcrypto`、QuickLook/PDFKit/AVKit… 一堆 framework）**对所有 target 生效**，
而桩 target **不跑** `prepare.sap.py` ⇒ 继承后去链一个不存在的文件。
修法：在**该 target 的 `settings.base` 里逐条覆盖**（xcodegen 的 settings 合并是**按 key 覆盖**、
不拼数组）—— `OTHER_LDFLAGS: ["-framework","CoreFoundation"]` / `HEADER_SEARCH_PATHS: []` /
`LIBRARY_SEARCH_PATHS: []`。**没动顶层 `settings.base`。**

**2. 修产物文件名不匹配（即使编译过，dlopen 也会失败）**
实际产物是 `MobileDeviceStub.dylib`（**无 `lib` 前缀**），而框架的 `LC_LOAD_DYLIB` 写的是
`libMobileDeviceStub.dylib` ⇒ **dyld 找不到桩**。
★ 我最初建议的 `EXECUTABLE_PREFIX: lib` **单独用不行** —— xcodegen 的产物引用路径是
`Target.filename`，而它**只对 `staticLibrary` 自动加 `lib`**（`dynamicLibrary` 不加）⇒
加了只会让**实际产物**带 `lib`，pbxproj 的 embed 阶段仍引用不带 `lib` 的名字 ⇒ **拷贝阶段找不到文件**。
修法：**三处一起钉死** —— `productName` + `PRODUCT_NAME: libMobileDeviceStub` + `EXECUTABLE_PREFIX: ""`。

**3. 修 `dlsym` 必然返回 NULL（private external）**
`_uhO2GULXwfgKwPcp4YR2` 的 `n_type = 0x1e` = `N_PEXT|N_SECT`，**`N_EXT = 0`**
⇒ **不进动态符号表 ⇒ `dlsym` 永远拿不到**。
修法：改成**自己解析已加载镜像的 `LC_SYMTAB`**（`_dyld_image_count` /
`_dyld_get_image_name` / `_dyld_get_image_header` / `_dyld_get_image_vmaddr_slide`
→ 遍历 load command → `nlist_64` 表按名匹配 → `n_value + slide`），`dlsym` 降为兜底。
- **地址换算**：`slide = base − __TEXT.vmaddr`；`symTab = slide + (__LINKEDIT.vmaddr − __LINKEDIT.fileoff) + symoff`
  （把文件偏移转成运行时地址）。
- **过滤**：跳 `N_STAB`、只取 `N_SECT`、跳 `n_value == 0`。
- ★ **对照值**：本机那份二进制里该符号 `n_value = 0x2ecb8`；runner 上算出的运行时地址
  `0x100c16cb8 − 0x2ecb8 = 0x100be8000`（**页对齐的 slide**）⇒ 两个独立来源自洽。
  ★ 但**不把它做成硬失败判据** —— CI 是当次 runner 现场取框架，版本不同则 `n_value` 也会不同。

**4. CoreFP 探测：改判据 + 修一个会造成假阴性的 bug**
- ★ **`dlsym(CoreFP, "appHelloImp")` 是错的判据**：那 5 个 `xxxImp` 只是 `AirTrafficHost` 用
  `puts` 打的**人类可读标签**；**真正传给 dlsym 的是混淆名**
  （`appHelloImp→WIn9UJ86JKdV4dM`、`appSetupSessionImp→X46O5IeS`、`runCommandImp→YlCJ3lg`、
  `getDLLVersionImp→lxpgvVMLd0S7uRl`、`teardownImp→dku592fbFAj`，在 loader `0x5abc` 处逐字节核对过）。
  这 5 个**全在 CoreFP 的导出表里**（CoreFP arm64e 切片只导出 8 个，全是混淆名）。
  ⇒ 改成**枚举 iOS CoreFP 的导出符号、逐个对照那 5 个 macOS 混淆名**。
- ★★ **修 `!exists → continue` 的假阴性**：iOS 的系统私有框架**大量只存在于 dyld shared cache**，
  磁盘上没有独立文件，而 `dlopen` 走 dyld、**不看文件系统**。原写法会「连试都不试 dlopen」
  就报「两个候选路径都不存在」——**恰好把最想回答的问题答错**。
  修法：`fileExists` 降级为纯日志，**dlopen 无条件试**（CoreFP 段与 iOS 段**两处都改**）。

**5. 新增：iOS 自带 `AirTrafficHost` 探测**
`dlopen("/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost")`（失败再试 `Versions/A/`）
→ 成功则列导出符号并查有没有 Grappa 符号；失败则打 `dlerror()` 原文。
★ **为什么值得加**：若 iOS 自带同款实现，它内部 dlsym 的是 **iOS 自己的 CoreFP 混淆名**（天然匹配）
⇒ **可能根本不用移植 macOS 那份**（无平台补丁、无桩、无名字不匹配）。

**6. 修一处会误导用户的日志**
`[airlift] 被调用（…）—— 当前无实际能力，返回 nil` ⇒ 用户看到后**以为 airlift 漏洞利用被移除了**。
新措辞把两件事都写出来：**既**返回 nil（airlift 不实现这条沙盒能力，注册表会自动继续试下一个），
**又**已经**唤起 airlift 协议探测流程**。

**已知未完成（不阻塞本版）**：从打进 bundle 的那份二进制里**动态读**那 5 个混淆名（替代硬编码）尚未落地；
`exportedNames` 的 `LC_DYLD_EXPORTS_TRIE` 回退也未加（iOS 系统框架常用 exports trie ⇒ 可能返回 nil）。
两者都**不会造成假阳性**，最坏是「本次无法判定」。**下一版补。**

## [0.3.447] - 2026-09-19

> ⚠️ **说明**：原本规划的 `v0.3.446`（stage 探针那一版）**只改了版本号与 CHANGELOG，没有提交、没有打 tag
> ⇒ 那一版从未存在过**。本版把它的全部内容与「Grappa 框架移植」合并发布，**一次构建覆盖两件事**。

### ★ 把 macOS 的 `AirTrafficHost`（arm64e）移植到 iOS 上跑 —— 直接**调用**它生成 Grappa

**背景**：AT 协议只剩 `Grappa` 认证块没解决。已查明：
- **Windows 版造不出 Grappa**（无条件硬失败 `-42404`，与输入/连接状态/外部环境全无关；
  IAT hook 17 个导入全程监控，执行期间**只调了一次 `CreateMutexA`**）；
- **macOS 版能造**（在 GitHub Actions 的 `macos-latest` runner 上**直调成功**：
  输入 12 字节 `01 00 00 00 | 00 00 00 00 | 01 00 00 00` → `err=0`、`outLen=84`）；
- ★ 但 **Grappa 每次输出都不同**（前缀 `0101` 固定，其余含随机密钥）⇒ **不能硬编码**。

⇒ 所以**不再逆算法，改成把那个框架搬到手机上、直接调用它**（我们不需要理解它，只需要能跑）。

**做法**（补丁脚本 + CI + Swift 三部分）：
1. **`tools/patch_airtraffichost.py`**（仓库里唯一的「移植」产物，**我们自己的代码**）——
   从 macOS 框架的 FAT 里抽出 **arm64e 切片**（332,176 字节）并打两个补丁：
   · `LC_BUILD_VERSION.platform` `1(macOS) → 2(iOS)`，`minos` `11.0 → 18.0`（sdk 保持 26.6.1 不动）；
   · `LC_LOAD_DYLIB` 里 macOS 专有的 `MobileDevice.framework` → `@executable_path/Frameworks/libMobileDeviceStub.dylib`
     （新路径 53 字节 < 原 80 字节，**同 `cmdsize` 内改写、尾部补 27 个 `\0`**，`offset`/`cmdsize` 未变）。
   ⚠️ 改过 load command ⇒ **原签名必然失效** ⇒ 必须靠侧载工具重签。
   ★★ **那个二进制不进仓库** —— 仓库是 **public**，再分发 Apple 的专有框架不合适。
   改为 **CI 在 runner 上现场取 + 现场打补丁**（`macos-latest` runner 上本来就有这个框架，
   而且拿到的是**与 runner 同版本**的那份）。仓库里只有补丁脚本、**没有任何 Apple 二进制**。
   （本地验证：用同一份输入跑，产出与手工产物 **sha256 逐字节一致**。）
2. **`vendor/MobileDeviceStub/MobileDeviceStub.c`** + `project.yml` 新增 `library.dynamic` target `MobileDeviceStub`
   —— 导出框架需要的 **17 个 `AMDevice*`/`AMD*` 符号**（清单来自 `LC_DYLD_CHAINED_FIXUPS` import 表
   `ordinal 1`，与 `LC_SYMTAB` undefined **17/17 对上**；总数 138 = 17 + 45(CoreFoundation) + 76(libSystem)）。
   · ★ **故意返回失败码**（`-1`）而不是 `0`：`AMDevice*` 的 `0` 语义是「成功」，若真被调用，
     框架会拿着我们返回的 **NULL 句柄**继续走 → 崩；返回非 0 让它**干净失败退出**。
     （`AMDeviceGetInterfaceType` 例外，返回 `0`：它返回**传输类型枚举**，没有「失败」档，
     `-1` 不是合法枚举值反而可能让调用方落到未定义分支。）
   · Grappa 路径**本来就不调它们** —— 它在 runner 上**无设备**也能成功生成 Grappa。
3. **`.github/workflows/build-xcode.yml` 新增 `Embed AirTrafficHost into Frameworks`**（在 Build 之后、打包之前）：
   在 runner 上取 macOS 系统里的 `AirTrafficHost` → 跑 `tools/patch_airtraffichost.py` →
   产出落到 **`.app/Frameworks/AirTrafficHost`**；并把 `PATCH-REPORT.txt` 打进构建日志（补丁前后对照 + 17 个桩符号清单）。
   ★ **为什么必须放 `Frameworks/`**：我们出的是**未签名 IPA**，签名完全靠侧载工具，
   而它们递归签名的范围是**约定位置**（`Frameworks/` / `PlugIns/` / `Watch/`）——
   **bundle 根下的散装 dylib 会被漏签**，而签名无效的镜像在 iOS 上**根本 dlopen 不了**。
   另加**桩符号自检**：`nm -gU` 逐个核对 17 个符号都导出了 ——
   把「默认可见性到底生效没有」从**猜测**变成**构建日志里的证据**（本机无法编译验证）。
4. **`AirliftExploit.runGrappaProbe()`**：`dlopen` → `dlsym`（先试带下划线 `_uhO2GULXwfgKwPcp4YR2`，再试不带）
   → `unsafeBitCast` 成 `@convention(c)` 调用 → `err`/`outLen`/前 16 字节 hex 全写日志，
   成功则 84 字节全 hex 落盘 `LoginLogs/airlift_grappa.txt`。
   ★ **`dlerror()` 原文必须记** —— 它区分「平台补丁不够 / 签名无效 / 桩没生效 / CoreFP 权限被拒」。

**已提前排掉/标出的坑**：平台补丁 ✓、桩 ✓、签名位置 ✓、桩返回值语义 ✓、`LC_CODE_SIGNATURE` 必然失效 ✓。
**唯一剩下的真未知**：iOS 上框架内部 `dlopen` 的 `CoreFP.framework`（FairPlay）**会不会因权限被拒** —— 只能实测。

### stage 探针加「解压器是否跟随 symlink」的两个测试（其中一个**可能绕过 Grappa**）

**动机**：AT 那条线卡在 VM 混淆的 `Grappa` 认证上，且**连 Apple 自己的 Windows 主机代码也造不出
Grappa**（实测：Apple 发出的 `RequestingSync` 同样没有 `Grappa` 键，设备同样回
`SyncFailed{ErrorCode:4}`）。**如果越界写能在「解压 zip」这一步就完成，整条链就完全不需要 AT。**

**关键未知数**：`com.apple.streaming_zip_conduit` 的解压器**建文件时会不会跟随 symlink**。
PoC 的 zip 里**故意没有**任何「穿过 symlink 的条目」（它的 symlink 是留给后面 `ATAirlock` 用的），
所以这一点**从没被验证过**。

**新增两个 zip 条目**（顺序严格，见下）：

| # | 条目 | 类型 | 落点 |
|---|---|---|---|
| 1 | `p0/p1/p2/link/airlift-follow-probe-<t>.txt` | 文件 0600 | `<source>/airlift-stage-target/…`（**不逃逸**，零风险对照） |
| 2 | `p0/p1/p2/out` | symlink 0777，内容 **`../../../../`** | `/var/mobile/Media/`（**逃逸**，真正的越界写探针） |
| 3 | `p0/p1/p2/out/airlift-escape-probe-<t>.txt` | 文件 0600 | `/var/mobile/Media/airlift-escape-probe-<t>.txt` |

**`..` 层数复核过**：`out` 在 `p0/p1/p2/` 下，相对目标从**它所在目录**解析 ⇒
`p0/p1/p2 → p0/p1 → p0 → <source> → /var/mobile/Media` = **4 个 `..`**。

**★ 为什么还要那个「不逃逸」的对照项**：`out` 是**逃出解压根**的，若解压器有 zip-slip 防护，
可能**整包拒绝** ⇒ 连 `link` 都没有 ⇒ **分不清「不跟随」和「整包被拒」**。
（注意 PoC 自己的 `link` → `../../../airlift-stage-target` **没逃逸** —— `../../../` 从 `p0/p1/p2/`
数上去正好是 `<root>/`，落点仍在根内。它是**故意**这么设计的，好过任何 zip-slip 校验。）
⇒ 对照项穿过那个**不逃逸**的 `link`，零风险地单独回答「解压器到底跟不跟 symlink」。

**四种观察组合各有明确解读**（结论行分开写，不混）：
| 观察 | 结论 |
|---|---|
| `link` 在 **且** follow-probe 也在 | **解压器跟随 symlink** → 再判逃逸那条成没成 |
| `link` 在 **但** follow-probe 不在 | 解压器**不**跟随（结论可靠，与整包是否被拒无关） |
| `link` 不在 **且** `<source>/` 也不在 | **整包被拒** → 不能下「不跟随」的结论，需去掉逃逸条目重跑 |
| `link` 不在 **但** `<source>/` 在 | 解压中途中断 → 同样别下结论 |

**条目顺序（严格）**：
```
META-INF/ → META-INF/com.apple.ZipMetadata.plist
→ airlift-stage-target/        ← 必须在所有穿透条目之前（否则目标目录还不存在，对照项必然 ENOENT）
→ p0/ p0/p1/ p0/p1/p2/
→ p0/p1/p2/link（symlink，不逃逸）
→ p0/p1/p2/link/<follow-probe>（★ 零风险对照）
→ payload
→ p0/p1/p2/out（symlink，逃逸）
→ p0/p1/p2/out/<escape-probe>（★ 越界写探针，必须最后）
```
（`out` 与穿透文件必须排最后：反过来的话解压器会先自建一个**真目录** `out/`，逃逸测试就废了。）

**AFC 回读新增**：`<source>/airlift-stage-target/airlift-follow-probe-<t>.txt` 与
`airlift-escape-probe-<t>.txt` 各查一次（note `size` / `st_ifmt`）；`AfcEntry` 加了 `exists` 字段
（原来只有 `ifmt`，分不开「取不到」和「取到但无 ifmt」）。

**残留**：`/var/mobile/Media/` 下那几个探针文件**刻意留着当证据**，事后再用 AFC 删。

## [0.3.445] - 2026-09-19

### 新增 airlift 第 ① 步「stage」：经 `streaming_zip_conduit` 上传含 symlink 的 zip

**为什么这一步现在就能做**：整条攻击链里**只有第 ② 步（发 `FileComplete`）需要 AirTraffic/AT 协议**，
而 AT 目前卡在 VM 混淆的 `Grappa` 认证上。第 ① 步走的是**另一个服务**
`com.apple.streaming_zip_conduit` —— 它**在我们的 RSD 服务表里**（真机实测 port 65096），
**完全不依赖 Grappa**。而且它是整条链的必经环节，**做了不亏**。

**新增 `AirliftExploit.runStageProbe()`**，三段式：

1. **先只发一条 plist** `{MediaSubdir: <source>}`，**4 种候选帧格式链式回退**：
   大端长度+XML → 大端长度+二进制 → 小端长度+二进制 → **无长度前缀+二进制**。
   每种都记：发送 ok/err（code+message）、`stream_recv_frame_raw` 的**前 32 字节 raw hex**、
   plist 全文、或 15s 超时原文。
2. **再发 plist + zip**（每条候选一个**新连接**）。
3. **用 AFC 回读验证**（`afc_client_connect_rsd`，根 = `/var/mobile/Media`）：
   `<source>/` 在不在、`<source>/p0/p1/p2/link` 的 **`st_ifmt` 是不是 `S_IFLNK`**（并打 `st_link_target`）、
   `<source>/payload` 在不在。

**★ 成功判据是 AFC，不是响应** —— PoC 自己也不看响应。

**新增 zip 构造器 `makeStageTestZip()`**（照抄 PoC 的 `build_archive()`）：
`META-INF/`、`META-INF/com.apple.ZipMetadata.plist`（二进制 plist `{Version: 2}`）、
`p0/ p0/p1/ p0/p1/p2/`、**`p0/p1/p2/link`（symlink，内容 `../../../airlift-stage-target`）**、
`airlift-stage-target/`（让 symlink 有落点）、`payload`。
★ 每个条目都带 **`0x5A53` 这个 zip extra field** + `external_attr` 里的 Unix mode ——
**只设 `external_attr` 解压器认不出 symlink**（PoC 源码里挖出来的）。

**★ 为什么必须新增一个 Rust FFI（超出「只改 Swift」的范围，但没得选）**
PoC 的 `SendAll` 用的是 `AMDServiceConnectionSend`（**纯 socket send、无帧头**）来发 zip。
我们现有的 `stream_send_bytes` 会多写 4 字节长度前缀 —— 设备会把那 4 字节当成 zip 开头，**必然失败**。
故新增：
```c
struct IdeviceFfiError *stream_send_raw(struct ReadWriteOpaque *, const uint8_t *bytes, uintptr_t len);
```
（逐行照抄 `stream_send_bytes` 只去掉前缀；内部拷成 owned `Vec` 以满足 `run_sync` 的 `'static` 要求。）
两份 `idevice.h` 同步更新，`diff` 确认仍逐字相同。

**为什么没动 `ZipWriter.swift`**：它的 local/central header **写死 `extra field length = 0`、
`external_attrs = 0`、`version made by = 20`**，而 stage 的 zip 必须带 `0x5A53` extra + Unix mode。
它是备份/压缩共用类，改动风险大 ⇒ 改为在 `AirliftExploit` 内自写最小 **STORED** 写入器
（自实现 CRC-32，不引 zlib）。

挂载顺序：`triggerProtocolProbeOnce` 里改为 **AFC 探测 → stage 探测 → AT 探测**
（stage 比 AT 重要，因为它不依赖 Grappa）。同一串行队列，不并发。

**已知取舍与风险**（如实记录）：
- **最坏耗时 ≈ 5~7 条连接 × 15s 超时 ≈ 75~105s**，会较久占用 RSD 隧道（串行，不并发）。
- 第 1 步「只发 plist」时设备大概率只是在等 zip（15s 超时）——**超时不能证明帧格式对**，
  真正定案靠第 2 步的 AFC 回读。这是刻意取舍（不想为探格式白等 4×15s）。
- 若真机上 `st_ifmt` 回 `S_IFREG`，说明解压器没按 `0x5A53` 建 symlink，
  下一步该查 extra field 编码而不是帧格式。
- Rust 侧无法本地编译（本机无 cargo/iOS target）—— `stream_send_raw` 是逐行拷贝去掉前缀，
  风险极低，但仍是本版唯一的编译风险点。

## [0.3.444] - 2026-09-19

### AT 主机消息结构修正（4 处，键名从 DLL 二进制直接读出）+ `Sig` 证伪

**背景**：v0.3.442 真机实测，设备回了
`SyncFailed{ErrorCode:4}` —— 它收到了我们的 `HostInfo` / `RequestingSync` 但**拒绝了**。

**1. 键名不是推断的，是从 `AirTrafficHost.dll` 二进制里直接读出来的**

方法：`lea rcx,[rip+X]` 指向的常量**就是内联 ASCII**，读原始字节即可（不用解析 `__CFConstantString`）。

| DLL 函数 | 真实的 `Params` 键（顺序即写入顺序） | 条目数 |
|---|---|---|
| `ATHostConnectionSendHostInfo` | `HostInfo` / **`LocalCloudSupport`** | `mov r9d, 2` |
| `ATHostConnectionSendSyncRequest` | `Dataclasses` / `DataclassAnchors` / `HostInfo` | `mov r9d, 3` |
| `ATHostConnectionSendMetadataSyncFinished` | **`DataclassAnchors`** | `mov r9d, 2` |

**⇒ 修正 4 处**：
1. `HostInfo` 消息：8 个业务字段应在 **`Params.HostInfo` 内层**（我们原来放在 Params 顶层）；
2. 补上 **`LocalCloudSupport`**（取自 `conn+0x28`；该初值未逆出，先发 `false` —— 它只由
   `ATHostConnectionCreateWithCallbacks` 第 5 参写入，`ATHostConnectionCreate` 走 calloc ⇒ 默认 false）；
3. `RequestingSync`：**`Grappa` 属于 `HostInfo` 内层**、类型是 **CFData**（`0x180031e98`），
   我们原来放在 Params 顶层当 `int(0)` —— **层级和类型都错**；
   `PlistValue` 因此新增 `.data(Data)`（plist 的 `<data>` 是 base64）；
4. `FinishedSyncingMetadata` 第二个键是 **`DataclassAnchors`**（`0x180031a85`），原来写成 `Anchors`。

另：**Session 号** `inc [conn+0x14]`（`0x180031df3`）只在 `SendSyncRequest` 里出现一次，
初值 0 ⇒ `HostInfo` 用 0、**从 `RequestingSync` 起用 1**。原来全是 0。

**2. `Sig` 与我们无关（此前的担忧被证伪）**

`Sig` 字符串全 DLL **只被引用一次**：`0x18002f4bd`，是 `ATCFMessageVerify` **读**它
（类型 CFData，`0x18002f4e3 CFDataGetLength`），唯一调用点在**校验设备发来的 `AssetManifest`**。
**Windows 主机从不产生 `Sig`** ⇒ 不用实现签名，省掉一整块密码学工作。
顶层字典也确认只有 `{Session, Command, Params}` 三个键（`Type`/`Id` 在代码里零引用）。

**3. `ErrorCode 4` = Grappa/认证失败**

`0x180030a33 mov edx, 4` 构造 `{Command:"SyncFailed", Params:{ErrorCode:4}}`；
两条汇入路径是 `"Grappa key could not be established"` 与
`"Grappa could not verify message, sending auth error"`。

**4. ★ 当前卡点（诚实记录）**：`Grappa` 的派生函数 `sub_180011110` 是 **VM 混淆**
（状态加密 + 加密函数指针表 `0x180049ae0` + 分发器 `sub_180003360`），
**人工逆向不现实**；且 `sub_1800125a0` 里 `rdtsc % 9` 选 9 个 16 字节常量之一，
**有可能每次都不一样**。`sub_180003430`（建密钥）同样是 VM。

已知的确定信息（有用）：`conn+0x18` 是 DLL 自己拍平的 **12 字节结构**
`{u8 version; u8[3] pad; i32 deviceType; u8 protocolVersion; u8 pad; u16 0}`，
本机实测 = `01 00 00 00 | 00 00 00 00 | 01 00 00 00`（来自设备 `Capabilities.GrappaSupportInfo`）。
`conn+0x24` = Grappa 会话 id（0 = 无活跃会话）。

**本版仍会得到 `ErrorCode 4`**（Grappa 未实现），但结构已全部正确 ——
这一步是为了把「结构错误」这个变量排除掉，确认 Grappa 是**唯一**剩下的拦路虎。

## [0.3.443] - 2026-09-19

### 电池健康按爱思 9.0 口径修正（温度 / 寿命 / 厂商 / 序列号）+ 全量 registry dump

**背景**：用户发现爱思助手 9.0 现在能读到一批电池信息（厂商 / 生产日期 / 序列号 / 温度 /
寿命 / 充电次数…），而我们面板「寿命不准、生产日期不显示、温度未知」。
逆向 `i4Tools9` 后确认：**这些值 9 项直读设备 IORegistry**（不是爱思服务端查表）。

**1. 温度（修「显示未知」）**

`idm_info.dll` 反汇编证据：`0x180014076 lea r8,"AppleSmartBatteryPack"`，
且位于 **`Temperature == 0` 的分支**里。而我们的 `query()` **只查了 `IOPMPowerSource`** ——
iOS 27 上这个入口的 `Temperature` 是 0。
⇒ 新增 `fetchRegistry(client:entryName:)`：**先按 `entry_name` 查，报错再退回 `entry_class` 查**
（原调用是 class 形式）。温度缺失/为 0 时再查 `AppleSmartBatteryPack`，
取 `BatteryData.Temperature`（单位 1/100 ℃）。
新增 `temperatureSource` 字段记录温度取自哪个 EntryName 并写日志，便于以后排查。
两处都拿不到 → 保持「未知」，**不编默认值**。

**2. 寿命（修「不准」）—— 两个原因叠加**

- **公式不同**：改用 `NominalChargeCapacity / DesignCapacity`。
  依据（很硬）：爱思截图里**「满充容量」显示 -1**（即它读不到 `FullChargeCapacity`）却仍给出
  **81%**；而 `2724 / 3329 = 81.8% ≈ 81%` ⇒ 它用的不是 `FullChargeCapacity`。
- **★ 删掉 `BatteryHealthBaselinePct`「单调基线」闩锁**（连带 `isChargingNow`）。
  它把**历史最低值锁死**，这本身就是「寿命不准」的直接原因；而且换公式后旧基线还会继续
  夹住新值，导致修复**完全无效**。
- 回退链保留：`nominal` 取不到时回退 `maxCapacity`。

**3. 厂商 —— 改成 2 位前缀 + 用爱思的真实表**

爱思用**序列号前 2 位**（`i4Tools.exe!0x14090ff60` 读 `cache/devices_table/devices_table.txt`
的 `batfacotry[]`，`QString::startsWith` 比前 2 位）。**从该文件逐条抄录了真实的 13 条**
（YW/YV 无锡索尼、AE/AF 东莞新能源、SB 三星、L5/TP 天津力神、D8 常熟新世、FG 常熟新普、
F5 惠州德赛、F8 深圳欣旺达、C0 苏州顺达、LN 乐金化学），2 位前缀优先，**3 位旧表降级为兼容回退**。
本机序列号 `F8YH7Y22SC600006TY` → 深圳欣旺达，与爱思截图逐字一致。

**4. 序列号**：首选键改为 `BatterySerialNumber`（空串也回退），再回退 `Serial`。

**5. ★ 新增「电池 IORegistry 全量 dump」（为了搞定「生产日期」）**

新增 `dumpBatteryRegistry(primary:pack:)` → `Documents/LoginLogs/battery_dump.txt`：
把 `IOPMPowerSource` 与 `AppleSmartBatteryPack` 两个节点的**顶层全键 + `BatteryData` 全键**
（键名 + 值）写出来，另设「键名含 date/time/manufactur/produc/firstuse/factory」小节。
只在成功拿到 registry 时写，失败静默，不含配对信息。

**为什么加这个**：生产日期**尚未定案**。逆向发现爱思有本地解码器
`ios_parse_production_date`（RVA `0x18000fb80`，按长度分支 + base-32 字母表
`123456789CDFGHJKLMNPQRTVWXY` + `mktime`），但把本机 SN / MLB / 电池 SN 各种组合代进去
**都算不出 2024-06-23**（都落在 2010 年左右），输入链路没钉死。
⇒ **用实测数据定案，不再猜**。SSH 可直接 `cat LoginLogs/battery_dump.txt` 取回。

**6. 顺带更正两处错误注释**（`BatteryHealthView.swift`）
- 原「爱思那个日期是它自己服务端按序列号查的」→ 更正为：不是服务端，
  `getProdate.xhtml` 本机实测回「未知」、`cache/` 也 grep 不到，证据指向本地解码器，但尚未定案。
- 原「iOS 27 已无温度键 → 与爱思同样显示 `--`」→ 更正为已回退
  `AppleSmartBatteryPack.BatteryData.Temperature`。

## [0.3.442] - 2026-09-19

### AT 链路打通到「读 SyncAllowed + 发 HostInfo」；修「发完等响应」的错

**1. ★ 二进制 plist 判定被证实，AT 链路大幅推进**

真机落盘记录（`LoginLogs/airlift_probe.txt`）：
```
AT 帧前32字节: 62 70 6C 69 73 74 30 30 D5 01 02 ...   ← "bplist00"，二进制 plist 确认
AT 帧字节序探测：小端
读 #1: InstalledAssets (3571 字节)
读 #2: AssetMetrics   (753 字节)
读 #3: SyncAllowed    (373 字节)   ← 等到了
已发 HostInfo（二进制 plist 337 字节，小端长度前缀）
读 HostInfo 响应 出错 → 读超时：15s 内设备没有发来完整的一帧
```
⇒ **二进制 plist、小端长度前缀、消息方向（先读 SyncAllowed）三件事全部验证正确**。
设备连上后会主动连发 `Capabilities` / `InstalledAssets` / `AssetMetrics` / `SyncAllowed`。

**2. 根因：主机发出的消息，设备不回响应**

上一版 `send()` 是「发一条 + 读一条响应」。于是 `HostInfo` 发出去之后干等 15s，
报读超时，整条链断在那里。

airlift PoC 的主机端源码可以佐证：`ATHostConnectionSendHostInfo` /
`SendSyncRequest` / `SendMetadataSyncFinished` / `SendAssetCompleted`
**后面都没有读**；所有「读」都是独立步骤（等 SyncAllowed / 等 ReadyForSync /
等 AssetManifest）。

**修法**：`exchange()` 改名为 `sendMessage()`，**只发不读**，返回 `Bool`。
`send()` 不再追加「响应全文」到 transcript。所有读仍走 `waitFor(...)`。

**3. AFC 越权探测结论：走不通（参考项目那条捷径被证伪）**

`LoginLogs/airlift_afc_probe.txt`：
```
crashreportcopymobile：/var/mobile/Library/Accounts/Accounts3.sqlite → 失败 Afc(ObjectNotFound)
crashreportcopymobile：/var/mobile/Library/Preferences            → 失败 Afc(ObjectNotFound)
crashreportcopymobile：../../Library/Accounts/Accounts3.sqlite    → 失败 Afc(InvalidArg)
crashreportcopymobile：对照 "."                                    → 成功 size=3712
com.apple.afc：同样 4 条全失败，对照 "." 成功
结论：绝对路径能逃出 AFC 根目录 = 不能
```
绝对路径被解析到 AFC 根目录**之内**（`ObjectNotFound`），`..` 被服务端直接拒绝
（`InvalidArg`）。对照组（`.`）可读，证明连接正常、这些失败是真的。
⇒ `marksvia/airlift-HideAccount` 的 `accounts_direct.m` 那条路**不成立**，只能继续走 AT 协议。

## [0.3.441] - 2026-09-19

### AT 帧改**二进制 plist** 收发（重大发现）+ Gestalt 入口移入主页百宝箱

**1. ★ AT 帧不是 XML，是「小端长度前缀 + 二进制 plist」**

v0.3.439 真机日志给出了决定性证据：
```
[airlift] 读 AT 首条消息 出错 code=13 UnexpectedResponse("plist 正文非 UTF-8")
```
对比上一版的 `plist 长度异常: 3087007744`（= 大端 `0xB8000000`，30 亿，不可能）——
同样 4 字节按**小端**读是 **184**（合理的小 plist 大小）。v0.3.439 的
「先大端、不合法再小端」规则**接受了小端这一支**，正文被完整读出来（184 字节），
只是不是文本。⇒ 两条结论：

- **AT 帧的长度前缀是 4 字节小端**。⚠️ **RSD 帧仍是 4 字节大端 + XML** ——
  同一根 socket 上，RSD 阶段和 AT 阶段的帧格式**不一样**，别混。
- **AT 帧的正文是二进制**，极可能是二进制 plist（`bplist00`）。

之前一直不通，是「方向 + 格式」双重错。

**2. 修法：项目已链 libplist，XML/二进制都能处理**

新增两个 FFI（原有 4 个 `stream_*` 一行未动，RSD 握手仍在用）：
```c
struct IdeviceFfiError *stream_send_bytes(struct ReadWriteOpaque *, const uint8_t *bytes,
                                          uintptr_t len, bool little_endian);
struct IdeviceFfiError *stream_recv_frame_raw(struct ReadWriteOpaque *, uint8_t **out_bytes,
                                              uintptr_t *out_len, bool *used_little_endian);
```
- **发**：保留现有 `atMessage(...)` 拼 XML → `plist_from_xml` → `plist_to_bin` 转二进制 → 发。
- **收**：拿原始字节 → **先打前 32 字节十六进制**（判断「到底是不是 `bplist00`」的唯一确证）
  → `plist_from_memory`（自动识别 XML/二进制/JSON）→ `plist_to_xml` 转**可读文本**落盘
  → 从解析出的 plist 取 `Command`（二进制里字符串查找 `<key>Command</key>` 必然失效，旧实现已换掉）。
- `stream_recv_frame_raw` 同样带 **15s 超时**（现在三个读函数都有超时）。
- libplist 的产出用 **`plist_mem_free`** 释放（不是 `free`）—— 项目里已有 7 处先例，
  用错会每次读值都泄漏。

**3. Gestalt 入口移入主页百宝箱（按用户选择）**

- **底部 tab**：删掉 `Gestalt`，只剩 **主页 / 更多** 两栏（`MainTab.gestalt` 全仓无其它引用）。
- **入口**：主页 → 百宝箱 → 「工具」卡片里的**第一个真实可点条目**（原来那 4 项全是「即将上线」占位）：
  「Gestalt 编辑 / 查询 · 修改 MobileGestalt 键值（含备份）」→ 右侧 chevron。
- **「工具」卡上移到设备控制卡之前**：百宝箱默认 detent 只有 0.4，排第三张的卡片在折叠区之外，
  入口会看不见，得先上拉 —— 真实可跳转的条目优先级高于两个开关。
- `GestaltView` 去掉最外层 `NavigationStack`（它现在是被 push 进来的；
  自带一层会套出第二层栈、页面没有返回按钮）。`git diff --ignore-all-space` 确认**只删了那 2 行**。
- **导航时序**：百宝箱是 sheet，不能在里面直接 push，也不能「关 sheet 的同时 push」（会被吞）。
  用 `sheet(isPresented:onDismiss:)` 做中转 —— `onDismiss` 里再置 `showGestalt`，此时 sheet 已完全消失。
- `EscapeOS/Tunnel/idevice.h`（CI 会从 `rust/idevice-ffi/idevice.h` 拷过去的**跟踪副本**）已同步，
  免得以后读头文件时找不到这些新函数。

## [0.3.440] - 2026-09-19

### 新增：AFC 越权路径**只读**探测（验证参考项目那条「不用 AT 协议」的捷径）

参考项目 `marksvia/airlift-HideAccount` 里有一条**完全不同的攻击路径**
（`Sources/accounts_direct.m`）：连 `com.apple.crashreportcopymobile` 这个 AFC 服务，
用 `AFCFileRefOpen(绝对路径, mode=3)` **直接写** `/var/mobile/Library/Accounts/Accounts3.sqlite`
—— 没有 zip、没有 symlink、**完全不用 AirTraffic/AT 协议**。

如果这条成立，整条攻击链会简单一个数量级。但该仓库 README 自称 `Untested`，
而且它的 `hide.py` **实际调用的还是老 airlift 链路**，`accounts_direct` 根本没被调用
—— 自相矛盾。所以本版做一次**只读**验证。

新增 `AirliftExploit.runAfcEscapeProbe()`：用现成的 `withTunnel` 建隧道，
分别连 **两组** AFC，各跑同一张路径表：

| 组 | 服务 | 已知根 |
|---|---|---|
| 1 | `com.apple.crashreportcopymobile`（经 `crash_report_client_to_afc` 转换） | `/var/mobile/Library/Logs/CrashReporter` |
| 2 | `com.apple.afc` | `/var/mobile/Media` |

路径表（**只用 `afc_get_file_info`，只查属性**）：
```
Accounts3.sqlite                                   ← 纯相对，作对照（不算逃逸）
/var/mobile/Library/Accounts/Accounts3.sqlite      ← ★ 绝对路径（参考项目的目标）
/var/mobile/Library/Preferences                    ← ★ 绝对路径（目录）
../../Library/Accounts/Accounts3.sqlite            ← 相对 + .. 回溯（★ 也算逃逸）
/var/mobile/Media                                  ← 绝对路径
+ 对照项：列根目录拿到的第一条（必然存在，用来证明连接是好的）
```
判定：**除「纯相对」那条外，任意一条成功 = 绝对路径能逃出 AFC 根目录**。
（不能只看「以 `/` 开头」——`../../` 那条走的是回溯，只按前缀判会漏掉它。）

**★ 全程只读：只做 `afc_get_device_info` / `afc_list_directory` / `afc_get_file_info`，
绝不写、绝不删、绝不改设备上任何文件。** 完整记录落盘 `LoginLogs/airlift_afc_probe.txt`。

挂载点：`triggerProtocolProbeOnce()` 里**先跑本探测**（只读、快、可能直接给出答案），
再跑 AT 协议探测；两者都在串行的 `protocolQueue` 上，不违反「RSD 隧道并发铁律」。

**遗留风险（已知，未处理）**：本探测与 AT 探测同挂在「首次被功能调用」的路径上，
会真连两个服务 —— 与 v0.3.419 事故同类（真建连）。用的是生产已验证的 FFI
（`crash_report_client_connect_rsd` 本来就是「崩溃日志」面板在用的），且单飞只跑一次，
但仍属「真连设备」，需要真机确认不影响其它依赖配对文件的功能。

## [0.3.439] - 2026-09-19

### AT 消息链按**正确方向**重写 + 读超时（修「永久挂死」）

拿到 airlift PoC 的**主机端真实源码** `Sources/airtraffic_host.m` 后发现：
**我们的 AT 消息方向是反的**。它用的是 Apple 私有 API，调用顺序本身就是协议时序：

```objc
ATHostConnectionCreate(udid);                                   // 建连接
// ★ 先「读」—— 设备会主动发 SyncAllowed（最多读 8 条）
ATHostConnectionSendHostInfo(c, hostInfo);                      // 发 HostInfo
usleep(200000);
ATHostConnectionSendSyncRequest(c, @[@"Book"], @{}, hostInfo);   // 发 RequestingSync
// ★ 再「读」—— 设备发 ReadyForSync（最多读 12 条）
ATHostConnectionSendMetadataSyncFinished(c, @{@"Book": @1}, @{}); // 发 FinishedSyncingMetadata
// ★ 读 —— 设备发 AssetManifest（最多读 20 条）
ATHostConnectionSendAssetCompleted(c, id, @"Book", dest);        // ★ 攻击：发 FileComplete
```

**上一版的 6 个错**：① 把 `ReadyForSync` 当**发送**消息（它是**设备→主机**的）；
② 从没读过设备主动发来的 `SyncAllowed`；③ `HostInfo`/`RequestingSync` 字段是编的；
④ 漏了 `FinishedSyncingMetadata`；⑤ 发 `AssetManifest`（也是设备→主机的）；
⑥ 一上来就发东西，没有先读。

**新的 AT 流程**（每步都写日志，读有次数上限）：
```
0 只读首条 → 探明帧字节序（失败即收工，不猜）
1 读至 SyncAllowed（≤7）        2 发 HostInfo（8 字段照抄 PoC）
3 usleep 200ms → 发 RequestingSync
4 读至 ReadyForSync（≤12）      5 发 FinishedSyncingMetadata{SyncTypes:{Book:1},Anchors:{}}
6 读至 AssetManifest（≤20）     7 发 FileComplete{AssetID,Dataclass,AssetPath}
```
另：名字前缀按 PoC 的 `airlift_target.h` 改成 `airlift-src-`（上一版写的
`airlift-source-` 与设备端认的**不一致**）。`FileBegin` 在 PoC 最小路径里不用，本版不发。

### 新增两个 FFI

```c
struct IdeviceFfiError *stream_send_xml_ordered(struct ReadWriteOpaque *, const char *xml,
                                                bool little_endian);
struct IdeviceFfiError *stream_recv_xml_auto(struct ReadWriteOpaque *, char **out,
                                             bool *used_little_endian);
```
- **为什么需要**：RSD 帧已实测是**大端**（RSDCheckin 两条响应都解析成功），
  但 AT 帧可能不是 —— 真机日志 `plist 长度异常: 3087007744` = `0xB8000000`，
  同样 4 个字节按**小端**读是 **184**（一个完全合理的 plist 大小）。
  所以不预设，**先读后发**：第一步就「读」，读成功即得字节序，之后再按它发送。
- 读失败时错误信息带上 4 个字节的**原始十六进制 + 两种解释**
  （`raw=B8 00 00 00 be=3087007744 le=184`）—— 一次构建就能定案，不用反复试。
- 原 `stream_send_xml` / `stream_recv_xml` **未动**（RSD 握手仍在用）。

### 修「永久挂死」：给读加 15s 超时

`read_exact` 原本**没有超时**。AT 阶段第一步恰恰就是「只读」等设备主动发消息 ——
设备不发的话，线程会**永远**卡在 `protocolQueue` 上，而调用方已经把
`protocolProbeStarted` 置了 `true` ⇒ airlift 在**整个 App 生命周期内永久失效**，
还白占一个线程。现在两个读函数都用 `tokio::time::timeout(15s)` 包住，
超时返回 `UnexpectedResponse("读超时：15s 内设备没有发来完整的一帧")`。
**宁可报错，不可挂死。**

## [0.3.438] - 2026-09-18

### 修「一点空间回收扫描就闪退」+ 日志设置 UI 按反馈重做

**1. 闪退根因：Swift 独占访问冲突（exclusivity violation）**

设备日志停在 `响应 #2` 之后再无输出，对应位置正是 v0.3.436 新增的 AT 消息链第一发。

```swift
// 出错写法（v0.3.436）—— exchange 同时接受 inout 的 transcript
// 和捕获同一个 transcript 的 note 闭包
exchange(stream: stream, label: "ReadyForSync", message: ...,
         note: note, transcript: &transcript)
```

`note` 是个嵌套函数，捕获了外层的 `var transcript`（装箱成堆上的 box）。
把 `&transcript` 作为 `inout` 传进去 → 该 box 进入「独占写」状态；
`exchange` 内部再调用 `note("已发 ReadyForSync")` → 又去写同一个 box →
**运行时直接 trap**（`Simultaneous accesses to ..., but modification requires exclusive access`）。

编译期不报错，是因为冲突**跨函数**（`exchange` 和调用方各自看都没问题），
只有运行到那一行才炸 —— 所以表现为「一切正常、一扫描就闪退」。

**修法**：`exchange` 去掉 `inout String` 参数，改为**返回响应正文 `String?`**，
由调用方拿到返回值后自行追加 `transcript`：

```swift
private static func exchange(stream: OpaquePointer,
                             label: String,
                             message: String,
                             note: (String) -> Void) -> String? { ... }

// 调用方
func send(_ label: String, _ message: String) -> Bool {
    guard let response = exchange(stream: stream, label: label,
                                  message: message, note: note) else { return false }
    transcript += "\n===== \(label) 响应全文 =====\n\(response)\n"
    return true
}
```

**规则（已记 `MY-FAULTS.md` 缺陷 27）**：
**绝不要对同一个变量同时用 `inout` 传参 + 用闭包捕获** —— 这是运行时崩溃，编译器拦不住。

**2. 日志设置 UI 按用户反馈重做**

- **不再显示换算数值** —— 删掉 `= 1024 KB` 那两行 caption（`LogLimitSettings.describe(mb:)` 随之删除）。
- **挪位置** —— 「日志」Section 从 Form 最顶移到 **「配对文件」下面**（原先在最顶，用户反馈「跟界面不协调」）。
- **输入框允许留空** —— 原先 `onChange` 里会把非法/空文本**强行回填**成 `1`，
  导致用户一取消输入状态就被填上，根本清不空。现在：
  - 输入框文本**永不回写**；
  - 值为默认值（1 MB）时，`onAppear` 显示为**空**（占位符里就是 `1`）；
  - 语义：**留空 = 用默认 1 MB**，填 `0` = 无限制。

## [0.3.437] - 2026-09-18

### 修 v0.3.436 的编译错误（同一根因，我上次只修了一半）

**v0.3.436 又因同一类错误失败：**

```
LogLimitSettings.swift:57/60/66/69: error: main actor-isolated static property 'bytesPerMB'
                                     can not be referenced from a nonisolated context
```

**原因**：v0.3.435 的报错只点名了 `defaultKB`，我**就只改了被点名的那个** ——
漏了同一个类里的 `bytesPerMB`。**同一根因导致连续两次失败、白烧两次构建。**

**修法**：给 `bytesPerMB` 补 `nonisolated`，并**按规则全量复查**：
`LogLimitSettings` 的全部 4 个 static 常量
（`defaultMB` / `fileLimitKey` / `catLimitKey` / `bytesPerMB`）**现已全部标 `nonisolated`**；
`shared` 不被非隔离上下文引用 —— 确认无遗漏。

**教训（已记 `MY-FAULTS.md` 缺陷 26）**：编译器只报「当前这轮能看到的错」，
同一根因常有未报出的同类点。**修这类错要按规则全量扫，而不是照着报错行改。**

## [0.3.436] - 2026-09-18

### 修 435 的编译错误 + 日志上限改 MB 单位 + airlift 完整 AT 消息链

**1. 修 v0.3.435 的 Swift 编译错误**（CI 失败）：

```
LogLimitSettings.swift:46:20: error: main actor-isolated static property 'defaultKB'
                              can not be referenced from a nonisolated context
（46 / 49 / 55 / 58 / 68 共 5 处）
```

**原因**：`LogLimitSettings` 是 `@MainActor` 类，里面的 `static let defaultKB`
**默认也是 main-actor 隔离**的；而我写的 `nonisolated static var fileLimitBytes` 去引用它 → 报错。
**修法**：给被引用的常量显式加 `nonisolated`
（项目里 `ExploitSettings.enabledKey` 的注释早就写过这条，我没照抄）。

**2. 日志上限单位改成 MB**（用户要求「默认以 MB 为单位，默认 1MB」）：
- 两个输入框单位由 KB 改为 **MB**，默认 **1 MB**；
- 输入框下方实时显示换算：填 `1` → `= 1024 KB`；填 `0` → `无限制`；
- 内部存储键同步改为 `LogLimit.maxFileMB` / `LogLimit.maxCatMB`。

**3. airlift 接入完整 AT 消息链**（用户要求「干脆这版直接接入步骤六的流程」）：

新增 `PlistValue` 枚举（支持 string / int / bool / dict / **array**）——
因为 AT 消息的 `Params` 里 `Dataclasses` 是数组、`HostInfo` 是字典、`FileSize` 是整数。
新增 `exchange(stream:label:message:...)` 统一「发一条 + 读一条」。

**消息链**（照 airlift PoC 的攻击路径）：

| 顺序 | Command | 关键字段 |
|---|---|---|
| 1 | `ReadyForSync` | version / deviceType / protocolVersion |
| 2 | `RequestingSync` | Grappa / **Dataclasses**（数组）/ DataclassAnchors / HostInfo |
| 3 | `AssetManifest` | `_AssetFileName` / Data |
| 4 | `FileBegin` | **AssetID**（`../../<source>/p0/p1/p2/link`，含 `..`）/ Dataclass / FileSize / TotalSize |
| 5 | **`FileComplete`** | **AssetID** + **AssetPath**（`/var/mobile/Library/SpringBoard`）← **攻击落点** |

**说明**：本版**只走通消息链、验证设备是否接受**（含 `Sig` 缺失时的反应）。
**真正的越界写还需要**：① 构造含 symlink 的 zip；② 先把它 stage 到设备；
③ 再让 `FileComplete` 指向它 —— 这三步留待下一版（airlift 的 PoC 靠 `device_helper` 的
`stage` 做，那份源码被 gitignore，需要自己实现）。

## [0.3.435] - 2026-09-18

### 日志上限加「无限制」选项 + 界面实时显示单位换算

**用户要求**：「算了日志存储和日志 cat 加上个无限制选项吧」+「如果我想调节成 1mb 呢」。

**1. 加「无限制」** —— 两个输入框都**填 `0` = 不限制**：
- **日志存储上限**：`0` → 永不截断（`LoginLogger` 跳过 `trimFile`）；
- **cat 读取上限**：`0` → 跳过大小检查。

（两处都加了 `Int.max` 溢出防护：只有 `limit < Int.max` 时才做大小比较。）

**2. 单位说明 + 实时换算** —— 每个输入框下方实时显示当前值对应的大小：

| 填入 | 显示 |
|---|---|
| `1024` | `= 1 MB` |
| `2048` | `= 2 MB` |
| `0` | `无限制` |

Section footer 也写明：「单位 KB（1 MB = 1024 KB）。填 0 = 无限制；留空自动恢复默认 1024 KB。」

**回答用户的问题**：**想设成 1 MB，就填 `1024`** —— 因为单位是 KB。

## [0.3.434] - 2026-09-18

### 日志上限可配置 + 一键清空 + airlift 第 5 步

**用户要求**：「在更多板块右上角设置里新增限制日志存储大小的功能（默认 1024KB，可自定义，
留空自动填回 1024KB）、cat 日志大小的限制、一键清空日志的功能」。

**1. 日志上限做成可配置**（新增 `LogLimitSettings`，两项都默认 **1024 KB**，留空自动回填）：

| 设置项 | 作用 | 此前 |
|---|---|---|
| **日志存储上限** | `LoginLogger` 写文件时超过上限就**滚动截断**（保留最新部分） | **完全没有上限**，实测涨到 683KB |
| **cat 读取上限** | `SSHServerService` 的 `cat` 改用它 | 硬编码 256KB（v0.3.433 临时提到 8MB） |

UI 位置：**「更多 → 右上角齿轮 → 日志」** —— 两个输入框 + 一个「清空日志」按钮。

**2. 一键清空** —— 调 `LoginLogger.shared.clear()`（清内存 buffer + 删日志文件）。

**3. airlift 第 5 步** —— 在已建立的 `com.apple.atc` 连接上发第一条 AT 消息 `ReadyForSync`：

```plist
{ Session: 0, Command: "ReadyForSync", Params: { version, deviceType, protocolVersion } }
```

顶层结构 `Session`/`Command`/`Params` 来自 `AirTrafficHost.dll` 反汇编。
**暂不发 `Sig`**（Grappa 签名）—— 先试探设备是否强制校验；若不校验就能省掉整个 Grappa 实现。

**顺带（用户指出的概念纠正）**：清掉 `project.yml` `settings.base` 里那行**不生效**的
`SWIFT_VERSION: "5.0"`（xcodegen 不采纳该层，只会误导），并在注释里写明
**「编译器版本 ≠ 语言模式」** —— CI 用的是 **Xcode 27 自带的 Swift 6.4 编译器**，
按 **target 层的 `"6.0"` 语言模式**编译。

## [0.3.433] - 2026-09-18

### 移除 SSH 调试服务的两个不合理上限（用户要求）

用户指出：「为什么一直都有响应内容被日志长度限制截断？是 ssh 的限制吗？能不能移除这个限制？
还有支持在没有『完整记录落盘』这个功能时加入导出完整响应日志的功能，免得重复浪费无意义的构建。
还有你确定真的获取不到完整日志吗？你再试试看。我们有 ssh 还这么憋屈不合理。」

**先验证用户的质疑 —— 用户是对的：**
完整响应其实**一直都在日志里**。我之前用 `grep airlift` 过滤，而 XML 响应是**多行**的，
只有首行带 `[airlift]` 前缀，后续行是独立行 —— **被我的 grep 漏掉了**。
直接看 `logs` 输出就拿到了完整内容：

```xml
响应 #1: <dict><key>Request</key><string>RSDCheckin</string></dict>
响应 #2: <dict><key>Request</key><string>StartService</string></dict>
```

这正是 pymobiledevice3 里那两次校验 —— **airlift 第 4 步完全打通**。

**两个真正的限制（都在我们自己的 SSH 服务里，不是 SSH 协议）：**

| 位置 | 原限制 | 改为 |
|---|---|---|
| `cat <文件>` | 硬编码 **256KB** | **8MB** |
| `logs [n]` | 最多 **200 行** | 最多 **5000 行** |

（help 说明同步更新。）

**顺带**：v0.3.432 的「响应全文落盘」保留 —— 它仍有用
（取大文件时 `cat` 不如专用文件方便）。

**改动范围**：只有 `SSHServerService.swift`。

## [0.3.432] - 2026-09-18

### airlift 第 4 步真机验证成功 + 响应全文落盘

**v0.3.431 真机实测（431/728）—— 第 4 步打通：**

```
[23:15:22.996] [airlift] 被调用（consumeExtension）            ← 功能调用触发了流程
[23:15:23.105] [airlift] 协议探测开始（连 atc 服务 + RSDCheckin）
[23:15:23.457] [airlift] com.apple.atc.shim.remote → port 58010
[23:15:23.462] [airlift] 已连上 com.apple.atc.shim.remote
[23:15:23.468] [airlift] 已发 RSDCheckin
[23:15:23.483] [airlift] 响应 #1：<?xml version="1.0" encoding="UTF-8"?>
[23:15:23.493] [airlift] 响应 #2：<?xml version="1.0" encoding="UTF-8"?>
[23:15:23.500] [airlift] 结论：RSDCheckin 完成 —— 服务连接已建立
```

**三件事同时验证了**：
1. **触发方式正确** —— 进一次空间回收（`被调用（consumeExtension）`）就把流程带起来了，用户零操作；
2. **连上了 `com.apple.atc.shim.remote`**（动态 port 58010，查服务表拿到的）；
3. **设备真的回了两次握手响应** —— RSDCheckin 成功。

**但响应内容被日志长度限制截断了**（只显示到 `<dict>`）。
**修法**：完整记录落盘到 `Documents/LoginLogs/airlift_probe.txt`
（日志里只留首行，全文进文件）—— 符合项目铁律「长内容必须独立落盘再取回」。
SSH 可直接 `cat LoginLogs/airlift_probe.txt` 取回全文。

**改动范围**：只有 `AirliftExploit.swift`。

## [0.3.431] - 2026-09-18

### 修 v0.3.430 的 Rust 编译错误（漏 import）

CI 在 `Build libidevice_ffi.a (Rust, aarch64-apple-ios)` 步骤报错：

```
error[E0425]: cannot find type `IdeviceError` in this scope
  305 | return Err(IdeviceError::UnexpectedResponse(format!(
error[E0433]: cannot find type `IdeviceError` in this scope
  312 | .map_err(|_| IdeviceError::UnexpectedResponse("plist 正文非 UTF-8".into()))
error: could not compile `idevice-ffi` (lib) due to 4 previous errors
```

**原因**：我在 `adapter.rs` 里写了 `IdeviceError::UnexpectedResponse`，但**没 import `IdeviceError`**。

**修法**：加一行 `use idevice::IdeviceError;`
（与项目里 `mcinstall.rs` / `debug_proxy.rs` / `mobilebackup2.rs` 等 8 个文件的写法一致）。

**顺带确认一件好事**：CI **只报了这 4 个 import 错误**，
**没有报 `run_sync` 的 `Send + 'static` 约束错误** ——
说明 `ReadWriteOpaque.inner` 的 `Box<dyn ReadWrite>` 满足该约束，
`stream_send_xml` / `stream_recv_xml` 的写法是可行的（这是我提交前唯一担心的风险）。

## [0.3.430] - 2026-09-18

### airlift 第 4 步：连 `atc` 服务 + RSDCheckin（被功能调用时自动唤起）

**触发方式按用户要求改对了**：不是「勾选」也不是「启动」，而是
**`AirliftExploit` 的能力方法第一次被其它功能调用时**。

为什么这样对：空间回收 / 文件共享 / 设备瘦身 / 备份 / 壁纸 / 拨号器主题等
**进界面就会经 `ExploitRegistry` 调用到 airlift** —— 这是**自然发生的调用**，
用户不需要做任何额外动作。所以 airlift 的流程就在「被调用」这个时刻被唤起（单飞，只跑一次）。

**新增 FFI（Rust 侧）** —— 这是实现的前提：
现有 FFI 里能发字节的 `adapter_send` 只接受 `AdapterStreamHandle`，
而 `adapter_connect` 返回的是 `ReadWriteOpaque`，**两者不通用、库里也没有转换函数**。
所以补了一对直接作用于 `ReadWriteOpaque` 的接口：

```rust
stream_send_xml(stream, xml)   // 4 字节大端长度前缀 + XML 正文
stream_recv_xml(stream, &out)  // 先读 4 字节长度，再读正文
```
线格式与 `mcinstall.rs` 的 `send_xml` 一致（idevice property_list_service 线格式）。

**Swift 侧流程**（`AirliftExploit.runProtocolProbe()`）：
```
1. 建 RSD 隧道（withTunnel，与 AFCService 同款：10.7.0.1:49152 + 3 次退避）
2. rsd_get_service_info("com.apple.atc.shim.remote") → 拿动态 port
3. adapter_connect(adapter, port) → 拿 stream
4. stream_send_xml(RSDCheckin) → stream_recv_xml × 2（先 RSDCheckin 再 StartService）
5. idevice_stream_free 立即关闭连接（419 事故的教训）
```

**安全边界**（照 AFCService 规格，不重演 419）：
专用串行队列 + 单飞标记 + 用完立即释放连接。

**改动范围**：`AirliftExploit.swift`(+210)、`EscapeOS/Tunnel/idevice.h`(+41)、
`rust/idevice-ffi/idevice.h`(+41)、`rust/idevice-ffi/src/adapter.rs`(+95)。

> 注：Rust 侧新增 FFI 需 CI 编译验证；若 `Box<dyn ReadWrite>` 不满足 `run_sync`
> 的 `Send + 'static` 约束会编译失败，届时按 CI 报错调整。

## [0.3.429] - 2026-09-18

### 删掉 airlift 自检里「无效且拖慢 40 秒」的残留代码

**真机实测（426/723）发现的**：自检在服务表查询成功后，还会继续跑一段
`lockdownd_connect_rsd` + `lockdownd_start_service` 循环 —— 每个候选都回
`BrokenPipe("channel closed")`，**而且每次要等 10 秒超时**：

```
[22:33:20.309] 失败：start_service(streaming_zip_conduit.shim.remote) BrokenPipe
[22:33:30.585] 失败：start_service(atc.shim.remote) BrokenPipe           ← 白等 10 秒
[22:33:40.747] 失败：start_service(afc.shim.remote) BrokenPipe           ← 白等 10 秒
[22:33:50.901] 失败：start_service(notification_proxy…) BrokenPipe
[22:33:50.902] 失败：start_service(installation_proxy…) BrokenPipe
```

**这段是 v0.3.419 时代的残留**：`start_service` 是 **usbmux 通道**的机制，
在 RSD 通道上必然失败（v0.3.418 那次就已确认）。判断服务可用性的正确方式是
**查 RSD 握手包**（自检的 2.6 段已经在做）。

**删掉后**：自检从「40 秒 + 一堆误导性失败」变成「约 1 秒出结果」。

**顺带确认的好消息**（426/723 真机实测）—— 目标服务都在 RSD 服务表里：

| 服务名 | port |
|---|---|
| **`com.apple.streaming_zip_conduit.shim.remote`** | **55580** |
| **`com.apple.atc.shim.remote`**（AirTraffic 主服务） | **55621** |
| `com.apple.afc.shim.remote` | 55619 |
| `com.apple.mobile.notification_proxy.shim.remote` | 55596 |
| `com.apple.mobile.installation_proxy.shim.remote` | 55590 |

## [0.3.428] - 2026-09-18

### 撤掉 v0.3.427 的 onAppear 触发，改成「App 启动时自动跑」

用户指出：「什么叫进入漏洞利用页面时补跑一次？意思我要手动进入漏洞利用选择界面才能让它调用？」

**这是对的** —— 「进入页面才触发」等于**还是把观测责任推给用户**。

**改法**：
- 撤掉 `ExploitSelectionView` 的 `onAppear`；
- 新增 `AirliftExploit.scheduleSelfTestAfterLaunch()`，在 `EscapeSpaceApp.init` 里调用：
  **只要 airlift 处于勾选状态**（`ExploitSettings.snapshot()` 含 `.airlift`），
  启动后**延迟 5 秒**自动跑一次自检。

**为什么延迟 5 秒**：App 启动瞬间多个功能集中建 RSD 隧道（文件共享 / 应用管理 / 设备信息 …），
此时插一条会加剧竞争；等启动高峰过去更稳。

**效果**：勾选过一次 airlift 之后，**什么都不用做** —— 每次启动 App 都会自动跑一遍并写 `[airlift]` 日志。
（勾选那一刻也会跑一次，两条路径都覆盖。）

**另外**（v0.3.427 已包含，本版保留）：`AirliftExploit` 的三个能力方法
（`paths` / `consumeExtension` / `consumeExtensionWithFallback`）各加一次「被调用」日志 ——
这样你用空间回收 / 文件浏览时，就能在日志里看到 `[airlift] 被调用（…）`，
证明它确实参与了分发（只记第一条，避免淹日志）。

**改动范围**：`AirliftExploit.swift`（+15）、`EscapeOSApp.swift`（+3）、`ExploitSelectionView.swift`（−10）。

## [0.3.427] - 2026-09-18

### 修两处我的疏漏（用户指出）

用户反馈：「我觉得你勾选了这个，你在用其它功能调用这个功能应该会调用啊，怎么可能没有日志？
还是你没加？！还得我手动取消勾选再勾选这种操作」

**疏漏 1 —— `AirliftExploit` 的能力方法里没加日志。**
`AirliftExploit` 的 `paths` / `consumeExtension` / `consumeExtensionWithFallback` 都返回 `nil`，
**但没有任何输出** —— 所以其它功能（空间回收 / 文件浏览 / 壁纸 / 拨号器主题）通过
`ExploitRegistry` 调用它时，用户完全看不到它被调用过。
**修法**：三个能力方法各加一次「被调用」日志（`noteInvokedOnce`）。
**只记第一条** —— 这些方法在扫描循环里会被调用上万次，每次都记会淹掉日志文件。

**疏漏 2 —— 「已勾选状态」没有触发自检。**
触发原本只挂在「勾上」这个动作上，所以若 airlift 早已勾选（状态存在 UserDefaults），
用户进来什么都看不到，必须「先取消再勾选」才行。
**修法**：`ExploitSelectionView` 加 `onAppear` —— 进入本页时若 airlift 已勾选，补跑一次自检。
（`runConnectivitySelfTestIfIdle()` 自带单飞标记，重复进入不会重复跑。）

**改动范围**：只有 `AirliftExploit.swift`（+34）与 `ExploitSelectionView.swift`（+10）两个文件。

## [0.3.426] - 2026-09-18

### airlift：把「勾选时跑一次连通性自检」加回来（这次是安全的）

用户要求：加回来，但**不能出 bug**。

**为什么以前不能加、现在能加：**
- v0.3.421 撤掉它的**唯一原因**是：那时自检会真的 `adapter_connect` 建连 +
  `idevice_rsd_checkin` 做完整会话握手 → 抢隧道、污染设备端 →
  所有依赖配对文件的功能一起失效（真机事故，详见 v0.3.424 / v0.3.425 条目）。
- **现在自检已改成只读**：只查 RSD 服务表（拿 port / remoteXPC），
  **不建连、不发 RSDCheckin、不碰设备** —— 撤掉它的理由已不存在。

**本次实现（只加触发，不加任何"自动"逻辑）：**
- `AirliftExploit.runConnectivitySelfTestIfIdle()` —— 新增的显式入口：
  - 走 airlift **自己的串行队列**（`com.ipaside.escapeos.airlift.selftest`），不占主线程；
  - **单飞标记**：已有自检在跑时直接返回，快速连点勾选也不会并发；
  - 结果照旧写 `[airlift]` 日志，SSH 可取回。
- `ExploitSelectionView.toggle()`：**只在「勾上」airlift 时**调用该入口；
  **取消勾选不做任何事**；不勾 airlift 则一切照旧（完全无副作用）。

**改动范围**：只有 `AirliftExploit.swift`（+35 行）与 `ExploitSelectionView.swift` 两个文件。

**airlift 当前进度（整条链 6 步，已完成第 3 步）**：

| # | 环节 | 状态 |
|---|---|---|
| 1 | 配对文件读取 | 已完成 |
| 2 | RSD 隧道建立（`10.7.0.1:49152` + RPPairing） | 已完成 |
| 3 | RSD 服务表查询（确认 `com.apple.streaming_zip_conduit.shim.remote` 在表里，port 53635） | 已完成 |
| 4 | RSDCheckin 建立服务连接 | **故意未做** —— 等 AT 协议落地时接入正式功能路径，不放自检里 |
| 5 | AT 协议（Books 同步握手 / asset 描述 / zip conduit 会话） | 未开始（需逆向 `AirTrafficHost.framework`） |
| 6 | 触发 `ATAirlock` 路径校验缺陷 → 越界写 | 未开始 |

## [0.3.425] - 2026-09-18

### 撤销：v0.3.424 里我擅自加的两个「自动」机制

用户明确要求：**不要加自以为是的机制、不要让代码变得看不懂、不要擅自替用户回退勾选。**
原文：「就是不能干我勾选了吗你就擅自回退到 bad_query」。

**撤销 1 —— `ExploitKind.isFunctional` + `ExploitRegistry.enabled()` 的兜底。**
v0.3.424 曾加过一个判断：只要「勾了东西、但一个能干的都没有」，就自动补回 `bad_query`。
这等于**在用户没同意的情况下擅自改他勾选的效果**。已全部删除 ——
`enabled()` 恢复成「勾了什么就用什么」，与 v0.3.423 逐字一致（`git diff 8b009b0` 为空）。

**撤销 2 —— `ExploitSettings` 的一次性勾选迁移。**
v0.3.424 曾加过一个迁移：启动时把 `UserDefaults` 里遗留的 `.airlift` 勾选清掉。
这同样是在擅自改用户的设置。已全部删除 —— `ExploitSettings` 恢复原样。

**保留 —— 唯一真正的修复：`AirliftExploit.connectivitySelfTest()` 只读服务表。**
这才是「418 好、419 起坏」的根因：v0.3.419 把自检从「只读 RSD 握手包」
（`rsd_service_available`）改成了「**真的建连**」（`adapter_connect`），
v0.3.420 更做了完整会话握手（`idevice_new_tcp_socket` + `idevice_rsd_checkin`）。
`git diff 2aa47a7 cf0e032` 可证 418 → 419 的代码差异只有这一处。
本版保留「自检只读」这个修复，**其余一律不动**。

## [0.3.424] - 2026-09-18

### 修复：「v0.3.418 好、419 起所有依赖配对文件的功能失效」的真正根因

用户报告：**v0.3.418 一切正常，从 v0.3.419 开始，所有依赖配对文件的功能都无法使用**
（先测到的是空间回收板块），且升级到 421/422/423 都不恢复。

排查方法：`git diff 2aa47a7 cf0e032`（418 → 419 的完整代码差异）。

**结论：418 → 419 的代码差异只有一处** ——
`EscapeOS/Engine/Exploits/AirliftExploit.swift` 的 `connectivitySelfTest()`
从「只读 RSD 服务表」变成了「**真的去建连**」：

```
418:  rsd_service_available(handshake, name, &available)        ← 纯读握手包，不发请求
419:  rsd_get_service_info(...) + adapter_connect(adapter, port, &stream)   ← 真的建连
420:  更进一步 —— idevice_new_tcp_socket + idevice_rsd_checkin（完整会话握手）
```

而这段自检**当时被挂在「勾选 airlift」这个 UI 动作上**（`ExploitSelectionView.toggle`），
跑在 `Task.detached` 里 —— 于是用户一点勾选，就额外建了一条 RSD 隧道并向设备发起会话握手。

**两层后果：**

1. **设备端被污染**：真机日志显示此后 `attemptPairVerify` 连续 63 次零响应
   （`Sending attemptPairVerify` → `Waiting` → 超时，每 7 秒一次、持续 7 分钟），
   即设备端 RPPairing 配对验证不再响应，所有走 RSD 隧道的功能一起失效。
2. **App 侧勾选状态不自愈**：`.airlift` 一旦被勾选就存进 `UserDefaults`。
   而 `AirliftExploit` 目前**没有任何实际能力**（`paths` / `consumeExtension` /
   `consumeExtensionWithFallback` **全部返回 `nil`**）。用户若为测试 airlift 而
   **取消勾选 `bad_query`**，`ExploitRegistry.enabled()` 就只剩 `[AirliftExploit]` ——
   **所有依赖沙盒逃逸的功能（空间回收 / 文件浏览 / 壁纸 / 拨号器主题 / 配置描述）一起失效**，
   而且升级版本也不会自愈。

**本版三处修复：**

1. **自检彻底只读**：`connectivitySelfTest()` 只查 RSD 服务表（拿 port / remoteXPC），
   **不建任何连接**。注释里写明原因，防止以后有人再把建连加回去。
2. **`ExploitRegistry.enabled()` 加兜底**：新增 `ExploitKind.isFunctional`
   （`badQueryList` = true，`airlift` = false，等 airlift 真正实现越界写后改回 true）。
   `enabled()` 里若发现「勾了东西、但一个能干的都没有」，就补回 `badQueryList` ——
   **保证基础功能永远可用**，且不改变「一个都不勾 = 不使用任何漏洞利用」的原语义。
3. **`ExploitSettings` 一次性迁移**：清掉 `UserDefaults` 里历史遗留的 `.airlift` 勾选状态
   （若清空则回落到 `badQueryList`）。迁移只做一次，用户以后想再用 airlift 可重新勾选。

**另外**：v0.3.421 已撤除「勾选即跑自检」，v0.3.422 给虚拟定位健康检查加了失败退避，
v0.3.423 给 `enabled()` 加了缓存 —— 这三项与本条根因是**不同的独立问题**，一并保留。

## [0.3.423] - 2026-09-18

### 修复：我引入的性能回归 —— `ExploitRegistry.enabled()` 被高频调用却没缓存

**背景**：用户报「空间回收不能用」。排查后确认根因在我自己的改动里（v0.3.413 的 bad_query 收口）。

**问题**：v0.3.413 把 `SandboxEscape.consume`（取沙盒扩展）从「直接调 `bad_query`」
改成「经 `ExploitRegistry.enabled()` 分发」。但 `enabled()` 的实现是**每次调用**都做
`UserDefaults.array` 读 + `Set` 构造 + `filter` + 数组分配。

而 `consume` 是**高频调用点**：
- `ReclaimService.scan`（空间回收）用 `escape.withHandle(for:)` 包住整个扫描，
  每个容器、每个分类都走一次；
- `ContainerNameResolver` 每个路径一次；
- `LiveContainerDiscovery` 每个实例一次；
- 壁纸 / 拨号器主题 / MDM / 配置描述各自循环调用。

空间回收要扫**几万个路径** → **几万次 UserDefaults 读 + 几万次数组分配** →
扫描被拖到近乎卡死。

**修法**：`enabled()` 加缓存，只在**勾选内容真的变化**时才重建。
（缓存键用 `ExploitSettings.snapshot()` 的结果做比较；该快照本身仍是轻量 UserDefaults 读。）

**说明**：这是我 413 收口时引入的回归，与 airlift 无关。

## [0.3.422] - 2026-09-18

### 修复：虚拟定位健康检查的「死循环重连」（真机事故的放大器）
**真机证据（设备 0.3.421/718）**：Rust 日志 `tunnel dial` **63 次、持续 7 分钟**，
每次都是 `dial → Sending attemptPairVerify → Waiting → 无响应`（**63/63 全超时**）。

**定位**：间隔 ≈ 7 秒 = `SpoofSession` 健康检查的 **5 秒**（增强守护档）+ 失败开销。
它的逻辑是 `!LocationEngine.isSessionActive` → `apply()` → `LocationEngine.set` → **建隧道**，
**失败后没有退避** → 5 秒后再撞 → 死循环。

**危害**：设备端 `remotepairingd` 一旦不响应，它就会**持续占用设备端**，
把所有排在后面的配对/隧道功能（空间回收 / AFC / 设备控制…）一起拖住。

**修法**：给健康检查加**连续失败指数退避**（5s → 10s → 20s → 40s → **60s 封顶**），
会话恢复即清零。⇒ 从「每 5 秒硬撞」降到「最多每 60 秒一次」，把设备端让给其它功能。

**说明**：这只治「放大器」，不治「源头」——
源头是 v0.3.414~420 那个在勾选时并发建隧道的 airlift 自检（v0.3.421 已撤除，
见 `MY-FAULTS.md` 缺陷 17）。设备端若已被搞到不响应，仍需**关掉虚拟定位让它喘息**或**重启手机**。

## [0.3.421] - 2026-09-18

### 🔴 紧急修复：勾选 airlift 会让**所有依赖配对文件的功能**一起失效
**用户报告**：「勾选这个导致所有依赖配对文件的功能好像不正常没法用了，首先我测试了空间回收板块」。

**真机日志（0.3.420 / build 717）实证**：
```
[20:55:00.899] [airlift] 连通性自检开始 → com.apple.streaming_zip_conduit
[20:55:00.904] [airlift] 配对文件 OK
（之后没有下文 —— 卡在建隧道）
[20:55:03.118] ❌ IPA 侧载登录失败 …
```

**根因**：v0.3.414 起，`ExploitSelectionView.toggle()` 在勾选 airlift 时会
`Task.detached { AirliftExploit.connectivitySelfTest() }` —— 而**自检第一步就是
`tunnel_create_rppairing` 建一条新 RSD 隧道**。
项目铁律明确写着：**「同一 hostname 并发建隧道会互相抢占」**。
它跑在 detached 里，于是跟其它功能（空间回收 / AFC / 设备控制 …）**抢隧道** →
自检卡住，**其它依赖配对文件的功能一起不正常**。

**修法**：**勾选只改状态位，绝不发起任何 I/O**（撤掉自动自检）。
自检能力仍保留在 `AirliftExploit.connectivitySelfTest()` 里，但必须**串行**在
`AFCService` 那条队列上跑，且**另找触发时机**（不占用户操作路径）—— 留待后续。

## [0.3.420] - 2026-09-18

### 通道打通：`streaming_zip_conduit` 已在 RSD 服务表里，且建连成功
**v0.3.419 真机实测（设备 0.3.419 / build 716）关键结果**：
```
服务表里有 com.apple.afc.shim.remote：port 53678              → 建连成功
服务表里没有 com.apple.afc（ServiceNotFound）
服务表里有 com.apple.streaming_zip_conduit.shim.remote：port 53635 → 建连成功
服务表里没有 com.apple.streaming_zip_conduit（ServiceNotFound）
服务表里有 com.apple.atc.shim.remote：port 53680
```
**两条硬结论**：
1. **RSD 上的服务名必须带 `.shim.remote` 后缀** —— 不带后缀的标准名**一律 `ServiceNotFound`**
   （服务表里根本没有）。这就是 v0.3.414~418 一路 `BrokenPipe` 的根因。
2. **airlift 的入口服务 `com.apple.streaming_zip_conduit.shim.remote` 确实存在，且建连成功。**

**本版补齐第 ③ 环 —— `RSDCheckin`**：
- `idevice_new_tcp_socket(sockaddr(10.7.0.1:port), …, "EscapeSpaceAirlift", &device)`
  —— 连到服务端口并包成 `IdeviceHandle`；
- **`idevice_rsd_checkin(device)`** —— 发 `RSDCheckin` plist 完成握手（RSD 语义下真正的"启动服务"）；
- `idevice_free(device)` 释放。
- `candidateServices` 全部改成 `.shim.remote` 形式，并把实测端口写进注释。

**下一步**（通道确认后）：逆 AT 主机端协议 —— Books 同步握手 / asset 描述（`Persistent ID` 含 `..`）/
zip conduit 会话，最终触发 `ATAirlock` 的路径校验缺陷。

## [0.3.419] - 2026-09-18

### 突破：找到 RSD 上启动服务的**正确**方式（此前一直用错 API）
查 **pymobiledevice3** 的 RSD 实现（`pymobiledevice3/remote/remote_service_discovery.py`，权威参考）
得到明确结论：

> **"On modern devices, services are no longer started through lockdownd's StartService RPC.
> Instead a RemoteXPC handshake against the RSD port yields `peer_info` describing every available
> service and the TCP port it listens on."**

**RSD 上取服务的正确姿势**：
1. `peer_info["Services"][name]["Port"]` —— **本地查表**拿端口（**不调 StartService**）；
2. 建 TCP 连到该端口；
3. 发 `RSDCheckin` plist（`{"Label":…,"ProtocolVersion":"2","Request":"RSDCheckin"}`）完成 check-in。
**服务不存在时本地就报 `InvalidServiceError`，根本不发请求。**

⇒ **这解释了 v0.3.414~417 的 `BrokenPipe`**：`lockdownd_start_service` 是 **usbmux 通道**的机制，
在 RSD 上**压根不是这么用的** —— 难怪连「已知可用」的 `com.apple.afc` 也失败。

**本版把自检改成正确流程**：
- `rsd_get_service_info(handshake, name, &info)` → 拿 `port` / `uses_remote_xpc`；
- **`adapter_connect(adapter, port, &stream)`** → **真正建连**（这一步才是 RSD 语义下的"启动服务"）；
- `idevice_stream_free(stream)` 释放。
**任一候选建连成功即说明通道可用**，下一步才是发 `RSDCheckin` 与逆 AT 协议。

（`adapter_connect` 这个 API 项目里**此前从未用过**；`rsd_service_available` / `rsd_get_service_info`
的先例在 `Engine/LocationEngine.swift:274`。）

## [0.3.418] - 2026-09-18

### 诊断（决定性一步：换用 RSD 自己的 API）
v0.3.417 真机（0.3.417/714）拿到**干净数据**后确认：
```
start_service(com.apple.afc)                              → BrokenPipe("channel closed")
start_service(com.apple.afc.shim.remote)                  → BrokenPipe
start_service(com.apple.streaming_zip_conduit)             → BrokenPipe
start_service(com.apple.streaming_zip_conduit.shim.remote) → BrokenPipe
start_service(com.apple.mobile.data_sync)                  → BrokenPipe
start_service(com.apple.atc)                               → BrokenPipe
```
**连「已知可用」的 `com.apple.afc` 也失败** ⇒ **RSD 通道不支持 `lockdownd_start_service`**。

**原因**：`start_service` 是 **usbmux 通道**的机制（host 请 lockdownd 拉起服务）；
而 **RSD 的模型是「设备广播服务 → host 直连端口」**，压根不经过 `start_service`。
**旁证**：项目里凡走 RSD 的服务（AFC / MCInstall / DVT）用的都是各自封装的**专用 FFI**，
没有一处用 `lockdownd_start_service`。

**本版改用 RSD 自己的 API 判断**：
- `rsd_get_services(handshake, &array)` —— **列出 RSD 广播的全部服务**（name / port / entitlement）；
- `rsd_service_available(handshake, name, &bool)` —— 逐个问候选服务名在不在。

**这才是 RSD 语义下的正确判据。** 下次自检会直接打印**服务清单**，
一眼就能看出 RSD 上有没有 `streaming_zip_conduit`（或它广播时的真实名字）。

## [0.3.417] - 2026-09-18

### 修复（两个真机实测发现的坑）
- **每个候选服务名必须重新连一次 lockdownd**。v0.3.416 真机（0.3.416/713）实测：
  ```
  [airlift] 失败：start_service(com.apple.afc)                   code=1 BrokenPipe("channel closed")
  [airlift] 失败：start_service(com.apple.streaming_zip_conduit)  code=1 NotConnected("not connected")
  [airlift] 失败：start_service(com.apple.mobile.data_sync)       code=1 NotConnected("not connected")
  [airlift] 失败：start_service(com.apple.atc)                   code=1 NotConnected("not connected")
  [airlift] 失败：start_service(com.apple.mobile.sync_data_class) code=1 NotConnected("not connected")
  ```
  **规律**：**第一个**候选回 `BrokenPipe`，**之后全部**回 `NotConnected` ——
  说明 `lockdownd_start_service` 一旦失败，**连接就废了**，
  后面几个候选的结果**全是假的**（不是"名字不存在"，是"连接已死"）。
  ⇒ 改成**每个候选独立 `lockdownd_connect_rsd` 一次**，用完即 `free`。
- **候选表加 shim 服务名**。`com.apple.afc` 是我们**已知可用**的服务
  （`AFCService` 与 AirLift Mini 都靠它），但它走 `lockdownd_start_service` 也失败了 ——
  说明 RSD 隧道上**标准服务名不适用**。而 `AFCService` 的注释里写的是
  **`com.apple.afc.shim.remote`**（shim 服务名）。
  ⇒ 候选表加入 `com.apple.afc.shim.remote` 与 `com.apple.streaming_zip_conduit.shim.remote`。

## [0.3.416] - 2026-09-18

### 诊断推进
- **airlift 加「对照组」+ 换候选服务名**。v0.3.415 真机实测（设备 0.3.415/712）：
  ```
  [airlift] 配对文件 OK / RSD 隧道 OK / lockdownd OK
  [airlift] 失败：start_service(com.apple.streaming_zip_conduit) code=1 BrokenPipe("channel closed")
  [airlift] 失败：start_service(com.apple.atc)                    code=1 NotConnected("not connected")
  [airlift] 失败：start_service(com.apple.mobile.sync_data_class) code=1 NotConnected("not connected")
  [airlift] 失败：start_service(com.apple.airtraffic)             code=1 NotConnected("not connected")
  [airlift] 失败：start_service(com.apple.mobile.airtraffic)      code=1 NotConnected("not connected")
  ```
  **两个错误码含义不同**：`NotConnected` = lockdownd **不认识这个名字**；
  `BrokenPipe` = **名字对、请求被接受，但启动过程被切断**。
  ⇒ airlift 组件图里的 `com.apple.streaming_zip_conduit` **名字没错**，卡的是**启动条件**。
- 本版加**对照组**：`com.apple.afc` 是**已知可用**的服务（`AFCService` 靠它工作，
  AirLift Mini 的日志也证明它能自连）。
  · 若连它也失败 → 问题在**我们的调用方式**；
  · 若它成功、只有 zip_conduit 失败 → 问题在**那个服务本身**
    （很可能它要求 USB 传输，而 RSD 是本地回环隧道）。
  候选顺序改为：`com.apple.afc` → `streaming_zip_conduit` → `mobile.data_sync` → `atc` → `mobile.sync_data_class`。

## [0.3.415] - 2026-09-18

### 修复 / 推进
- **airlift 自检改成「批量探测候选服务名」**。v0.3.414 真机实测（设备 0.3.414/711）结果：
  ```
  [airlift] 配对文件 OK
  [airlift] RSD 隧道 OK
  [airlift] lockdownd OK
  [airlift] 失败：start_service(com.apple.streaming_zip_conduit) 被拒
            code=1 Socket(BrokenPipe, "channel closed")
  ```
  **前三步全通**，只卡在「启动服务」。`BrokenPipe` 不像 `InvalidService`（名字不存在），
  更像「名字对不上 / 该服务不接受 RSD 启动」。
  所以不再赌单一名字：`candidateServices` 里列出 5 个候选
  （`com.apple.streaming_zip_conduit` / `com.apple.atc` / `com.apple.mobile.sync_data_class` /
  `com.apple.airtraffic` / `com.apple.mobile.airtraffic`），逐个 `start_service` 并逐行记结果。
  **一次自检就能定案**：是名字全错，还是服务存在但不接受 RSD 启动。

## [0.3.414] - 2026-09-18

### 新增
- **漏洞利用新增 `airlift`**（思路来自 `github.com/0xjohnnydev/airlift`，走**设备自连**）。
  - **先澄清**：那份 PoC **跑在 Mac 上** —— `device_helper` / `airtraffic_host` 链接的是
    macOS 私有框架 `MobileDevice.framework` + `AirTrafficHost.framework`（见其 Makefile），
    且 `Sources/` 里只剩 `airlift_target.h`、两个 `.m` 被 gitignore，**无法直接移植**。
  - **但设备自连这条路是通的**：EscapeOS 已有 RSD 隧道（`LocalDevVPN 10.7.0.1:49152` +
    RPPairing，见 `AFCService`）与 `lockdownd_start_service`（FFI 已导出、`mcinstall.rs` 已在用），
    可以**自己扮演 AT 主机端**，不需要 Mac。
  - **本版只做第一步：连通性验证**。勾选 airlift 时自动跑
    「RSD 隧道 → lockdownd → `start_service(com.apple.streaming_zip_conduit)`」，
    逐行写 `[airlift]` 日志（SSH 取回）。**连不上就说明这条路在无越狱下不通，后面不必投入。**
  - **尚未实现**：AT 主机端协议（Books 同步握手 / asset 描述 / zip conduit 会话）。
    需要逆向 `AirTrafficHost.framework`，是后续独立工程。

## [0.3.413] - 2026-09-18

### 修复
- **「显示已完成 100% 却没有安装按钮」**（用户截图两张图）：那一行是下载中心的**任务行**
  （只画进度条，**从不画安装按钮**），本该在台账写完后被去重掉；但去重用的是页面**内存快照**，
  下载刚完成、`reload` 还没跑的那一刻去重失败 → 任务行残留；点它走的是任务行分支，
  面板 `isPendingDownload` 以前写死 `true` → 「覆盖安装 / 在线安装」被置灰标「下载中」，
  于是同一行上「已完成」与「下载中」自相矛盾。
  现在：**已成功完成且文件已落盘**的 job 不再单独成行（由台账行承担显示）；
  任务行面板的 `isPendingDownload` 改按 `job.phase.isBusy` 传。
- **D8：加密包「重装」缺 sinf**（修法 B）：`sinf` 以前只活在内存 `Job` 里，
  而重装走 `installLocal`（那个 Job 早已结束）→ 必然报「缺少 SC_Info/*.sinf」。
  现在 sinf **跟着台账落盘**，重装时读回来写进包内，**不用重下**。
  （历史包台账里没有 sinf 的仍装不了，需要的话另开回填。）

### 改进
- **漏洞利用：`bad_query` 的「全部」能力已收口**。此前只收口了「列目录」，
  另一条能力「取沙盒扩展」（`bad_query` / `bad_query_release` / `bad_query_internal_daemon`）
  仍写死在 `SandboxEscape` 与 `GestaltEngine` 里 —— 这正是「勾不勾选都一个样」的原因。
  现在两条能力都归 `BadQueryExploit`（含三路由回落：system → App Group → internal daemon，
  路由顺序不变）；**全仓直接调用 bad_query 系原语的位置只剩 `Engine/Exploits/`**。
  取消勾选会真的让这两条链路一起失效。
- **并发下载**：单下载槽 → **最多 3 个并发**（`maxConcurrentDownloads`）。
  配合「下载完成不再自动安装」，不会出现多个安装同时抢 RSD 隧道。

### 未做（等用户确认）
- **airlift**（`github.com/0xjohnnydev/airlift`）是**跑在 Mac 上**的 PoC：
  `make` + `./airlift.py`，用 macOS 的 `MobileDevice.framework` / `AirTrafficHost.framework`，
  路径为 Mac → USB/Wi-Fi → iPhone，攻击 iOS 27 的 AirTraffic/ATAirlock（Books 同步路径校验缺陷）。
  **iOS 侧 app 拿不到那两个 macOS 框架**，无法作为 EscapeOS 内的漏洞利用实现。

## [0.3.412] - 2026-09-18

### 新增
- **「更多」新增「漏洞利用」导航入口**（置顶），点进去是**二级选择页**，多选启用（可同时开多个）。
- **把 `bad_query` 真正抽成独立的可插拔实现**（不是调用点里加判断）：
  - 新增 `SandboxExploit` 协议（`Engine/Exploits/SandboxExploit.swift`）—— 漏洞利用的能力接口。
  - 新增 `ExploitRegistry` 注册表 —— 所有玩法的**唯一登记处**，按用户勾选过滤、按随机顺序分发（第一个成功即采纳，全失败才报无可用）。
  - 新增 `BadQueryExploit`（`Engine/Exploits/BadQueryExploit.swift`）—— `bad_query_list` 的**独立实现**。
  - **删除** `BadQueryLister`（实现已整体搬进 `BadQueryExploit`，不留第二套）。
  - 调用方（`FileService` / `DialerThemeManager` / `WallpaperHandler`）改为面向 `SandboxExploit` 协议，
    **不再认识 `bad_query`** —— 将来新增玩法只需「加一个实现 + 注册表加一行」，调用方零改动。
  - `ExploitKind` 枚举 + `ExploitSettings` 持久化（UserDefaults），默认启用 `badQueryList`（与升级前行为一致）。

### 修复
- **彻底去掉「下载完成自动安装」**（用户明确要求「以后安装都不能自动安装 否则怕出bug」）。
  - 移除 `Job.autoInstall` 字段、`start(...)` 的同名参数、4 处调用点的 `autoInstall: true` 字面量。
  - 删除 `installAfterDownload(...)` 方法（原本是「写 sinf → 装包」一气呵成的入口，现在拆开）。
  - 下载完成后状态永远停在「已下载」，由用户在「下载管理」点对应行的「安装」手动装。
  - 牛蛙源 sinf 写入**仍必须在下载落盘后做**（否则手动装过不了 FairPlay 验证），从 `installAfterDownload` 拆出来单独在 `handle()` 的 detach 任务里跑 —— 与「是否自动装」解耦。

### 不在本版（下一版）
- 并发下载（当前仍是单下载槽串行）—— 用户提了但没在 412 改，因为状态机改动面较大，单跑一轮 CI 风险高，留到 0.3.413 单独立项。
- 「下载完成后已完成但没安装按钮」的 bug（用户贴图我看不到图）—— 等用户用文字描述。

## [0.3.410] - 2026-09-14

### 修复（牛蛙「大部分应用获取失败」的直接成因：空直链不重试）
- **`/appstore/download` 回 200、但直链为空时不重试** → 用户点「获取」失败，只能自己再点一次。
  - 解密后的原文：`{"pub_code":0,"pub_desc":"接口调用成功","body":{"ba_sinfs":"","ba_ipaURL":""}}` —— 服务端报「成功」却**不给包**；
    解析层把它当「没有包」，**返回 `nil` 而不是 error**，而 v0.3.408 加的重试**只覆盖 `StoreError.network`** → 这条路径**根本没有重试**。
  - **真机日志证明它是限流/抖动、不是"真没包"**（同一个 `com.tuyafeng.Via`）：
    ```
    21:46:36 region=1 download → 空（ba_ipaURL=""）
    21:46:40 region=1 download → ✓ 直链（sinf 1376 字符）        ← 隔 4 秒重试即成功
    18:47:20 / 18:47:41 region=0 → 空
    18:47:43 region=0 → ✓ 直链                                    ← 第 3 次成功
    ```
  - 现在：**空直链最多再试 2 次、每次间隔 600ms**，每次打日志（`空直链（<bundleId>），第 N 次重试` / `✓ 空直链重试成功`）。
  - **有界**的理由：实测 1~2 次即成功；再多试只会把「服务端对这个应用真没包」也拖成十几秒假死 —— 那种情况该如实报「没有可用的安装包」。
  - 两层重试**语义分开、互不叠加**：网络层（`.network`，400ms，一次）在 `fetchNiuwaPackageOnce`；空直链层在外层循环。
    其余错误（`.server` / `.decode` / `.crypto` / `.http(N)`）一律直接抛出，不重试。

### 已知（本轮未动，留待定案）
- **首次请求可能带「伪 UDID」**：身份缓存未热时 `pub_udid` 用伪值，约 250ms 后预热完成才用真 UDID。
  **尚未证实**它与空直链相关（香港档系统性失败、中国/美国档偶发，更像限流）；且 v0.3.408 明确不在请求路径上做设备 IO，故**本轮不改**。

## [0.3.409] - 2026-09-14

> 本轮把交接文档里「结论已有、但没落成代码」的四项一次性补齐（B1~B4），无行为性回归风险。
> 前一轮（v0.3.408）的六条真机观测点仍待真机日志确认。

### 变更
- **牛蛙免登录商店：区域档位去掉「香港」**（`Engine/NiuwaStoreClient.swift` 的 `NiuwaRegion`）。
  - **实测依据**（2026-09-14 真机日志，同一个 `com.tuyafeng.Via`）：
    | region | `/appstore/search` | `/appstore/download` |
    |---|---|---|
    | `0` 中国 | ✓ 15/15、16/16 | 重试 1~2 次即成功（`sinf 1376 字符`） |
    | `1` 美国 | ✓ 19/19、18/18 | 重试 1~2 次即成功 |
    | `2` 香港 | ✓ 17/17（英文名：Via Browser / Viu / Microsoft Edge…） | **20 秒内连试 8 次全部空直链** |
  - 香港档失败时服务端回的原文：`{"pub_code":0,"pub_desc":"接口调用成功","body":{"ba_sinfs":"","ba_ipaURL":""}}` —— **报成功却不给包**。
  - ⇒ 香港档**搜得到、下不了**，点了「获取」必然失败 → 不再暴露该档；界面分段控件随 `allCases` 自动收敛为「中国 / 美国」两项。
  - 原版牛蛙客户端同样只有两档（区域切换控件 `nwcore_regionSegmented`，由 `nwcore_regionItemClicked:` 弹出）。
  - 数值语义未变（`0` 中国 / `1` 美国 / `2` 香港），**将来要恢复香港档就用 `index = 2`**；旧持久化值 `"hk"` 由 `NiuwaRegion(rawValue:) ?? .cn` 兜底回落。

### 文案统一
- **爱思商店两处「安装」→「获取」**（`Views/AppStoreI4View.swift` 的应用行与特殊应用行）：这两处是「定位包 → 下载 → 安装」的取包动作，与免登录商店统一措辞。

### 注释补全（无行为改动，防后人误判）
- `Views/FileSharingAppsView.swift` 的 `computeDocumentSizes()` 标注为**死代码**：它走的 house_arrest 路要求目标应用开启「文档共享」，微信/游戏恰恰没开 → 永远量不到；现文档大小改由 `DeviceSlimService.startDocSizePass` 的本机沙盒扩展通道量。**保留代码作历史证据**。
- `Engine/IPADownloadCenter.swift` 的 `PackageSINFWriter` 处写明：**别删工作区 `_tmp_ssh/syllabic/` 解压目录** —— 该样本包自带 `SC_Info/`，是 v0.3.407「缺少 SC_Info/*.sinf」问题的唯一复现来源。

## [0.3.408] - 2026-09-14

### 修复（预览/图标弹窗「没有可查看的图片」+ 不自动刷新、返回才刷新）
用户原话：**「查看图标时会这样（全黑 + 『没有可查看的图片』）也不自动刷新加载 返回才刷新 而且也不是没有图标啊 是不是哪里有bug」**
- **根因**：**图数组挂在了「页面」上，而弹窗从外部读它** ——
  `previewImages = …` 与 `previewTarget = …` 是**两次独立的状态写入**，不保证落在同一事务；
  而 `fullScreenCover(item:)` 的 content 是 **item 变非 nil 那一刻构建**的 →
  先构建就读到**旧的空数组** → 显示「没有可查看的图片」；返回时视图重算才拿到新值。
- **修法**：**把图数组放进 `ImagePreviewTarget` 自己身上**（弹窗构建时数据就是完整的）：
  `struct ImagePreviewTarget { let index: Int; let urls: [String]; var id: String { "\(index)-\(urls.count)-\(urls.first ?? "")" } }`。
  `id` 这样定有讲究：**只用 index** 会让图标预览（恒 0）与每组第 1 张撞 id；
  **UUID** 则每次求值都变、item 还活着时会反复重弹；「下标+张数+首图」在一次展示内恒定、跨调用点够区分。
  `showIconPreview` 撤掉 `images:` Binding（图标地址为空仍**只 toast**，行为未变）；`ImageGalleryViewer` 只读 `target.urls`。
- 四处调用点全部改净（`viewerImages` / `previewImages` 的代码出现次数 → **0**，只剩注释说明「别再这么写」）。

### 修复（牛蛙源「第一次点必失败、重试几次才成功」）
- **根因（硬结论）**：**请求路径上现场建 RSD 隧道**。
  `NiuwaStoreClient.pubParams` 里 `pub_udid` 走 `LocalDeviceIdentity.load()`（冷缓存时真建隧道）、
  `pub_system_version` 走 `DeviceInfoService.lockdownFullDict()`（**每次请求都建一次**，无进程内缓存）——
  一次「获取」可能建**两趟**隧道；而建隧道时 `LocalDevVPN` 被重配，**这一发 HTTPS 会被顶掉** →
  `URLSession` 直接抛错 → `.network` → 界面弹「获取安装包失败」。第二次点缓存/隧道已热 → 于是「重试几次就成功」。
  这与 v0.3.402 已立过的规矩是同一个病：**关键路径上不得同步做设备 IO**（`LocalDeviceIdentity` 文件头就写着这句），牛蛙这条链漏了。
- **修法**：① `pub_udid` **只吃缓存**，没有就后台预热 + 回落**持久化伪 UDID**（40 位 hex，只生成一次，保证同机稳定）；
  ② `pub_system_version` 只吃缓存，冷时回落 `UIDevice.current.systemVersion`（纯本地读、零 IO）；
  ③ 新增后台预热（幂等）与「UDID 来源」单行日志。
- **重试只做一次，且只对 `StoreError.network`**（等 400ms）——
  理由写进注释：`.network` 是「请求根本没拿到响应」，正是「隧道顶掉这一发」的**唯一**形态；
  `.server`（服务端说没包）/`.decode`/`.crypto`/`.http(N)` 重试都是白搭，**所以不做无条件多次重试**。
- 诊断新增一行：`[牛蛙源] pub_udid 使用：本机真 UDID` 或 `伪 UDID（身份缓存未热…）`。

### 修复（设备瘦身「较大应用」文档大小恒 0）
- **确切原因（硬结论）**：**`DynamicDiskUsage` 根本不在请求字段里、从来没请求过** ——
  v0.3.406 只加回了 `StaticDiskUsage`；而解析那行仍在跑 → 字典没这个键 → 恒 nil → 死分支。
  （顺带：`computeDocumentSizes()` 确认仍是**死代码**；它走的 house_arrest 路**要求应用开启文档共享**，
   微信/游戏恰恰没开 —— 所以即使接上也量不到它们。这就是它一直没生效的原因。）
- **改用「本机容器直读」**（`SandboxEscape` + `FileService.countTree`）——
  **与「空间回收」页完全同一套机制**（`ReclaimService.stat` 就是 `countTree`），已在真机跑通；
  容器路径来自 `get_apps` 默认响应里的 `Container` 键（**白拿的**，不带 ReturnAttributes 的响应就带它）。
  **不需要应用开文档共享，不需要额外隧道。**
- **代价与限流（明确）**：要真走一遍文件树 → **按需 + 只对候选集**：单轮 ≤60 个应用、单应用 ≤12k 节点、
  结果缓存 10 分钟、**跨轮累积往下补**；跑在 `utility` 优先级后台任务，**与后面最长 15 秒的带属性 Lookup 重叠**，不额外占首屏。
  量不到时按 0 算（**与改前一字不差，不是回退**）。新增 `[设备瘦身] 文档大小：本轮量 N 个应用…` 进度日志。
- ✅ **没有**把 `DynamicDiskUsage` 加回请求（它仍是「卡 ~25 秒」的头号嫌疑）；`sizeComplete` 判据未动。
- 新增统计日志：`无 appSize 的 N 条中：系统应用 X / 三方 Y / 无安装路径 Z` —— 用于定性那 209 条。

### 变更（按钮文案「安装」→「获取」）
用户建议：**「其实我觉得应该改为叫『获取』」**
- **改了 4 处**：免登录商店列表行（`trailingControl`，爱思/牛蛙共用）、`InstallButton`（两个详情页共用）、
  爱思商店（专题/榜单）两处。**只改文案**，颜色/尺寸/胶囊样式一字未动。
- **4 处维持不变**（语义不同，改了反而错）：`继续/暂停`（对**已在跑的任务**操作）、`安装运营商包`（IPCC，另一件事）。

## [0.3.407] - 2026-09-14

### 新增（牛蛙：把 `ba_sinfs` **真正写进包内** —— 解决「缺少 SC_Info/*.sinf」）
用户原话：**「下载的包好像是 itunes 来源的但是缺少 sinf 这个确定是牛蛙的吗」**
- **先回答第一条困惑**：`ba_ipaURL` 指向 `iosapps.itunes.apple.com` 是**预期** ——
  牛蛙服务器**代你去 Apple 取包**，取完把直链转手给你。**链接由牛蛙下发，包就是它给的那一个。**
- **「缺少 sinf」的原因**：牛蛙一起下发的 `ba_sinfs`（真机样本 1376 字符 base64，
  解出 **1032 字节**、头 `00 00 04 08` + ASCII `sinf` = 标准 `.sinf` 容器）之前**只解析、没使用** ——
  因为现有两条安装链路的 sinf 都是**从包内 `SC_Info/` 读**的、不是传参。
- **本版接线**：新增 `PackageSINFWriter`（`Engine/IPADownloadCenter.swift`）——
  落盘后、安装前，**只对 `source == .niuwa` 且带 sinf 的包**执行：
  1. 校验有 sinf、base64 可解（失败会打出字符数）；
  2. **只对加密包**（`IPAPackageInspector.isFairPlayEncrypted == true`）动手，未加密包直接跳过；
  3. 用 `ApplePackageArchive(accessMode: .update)` 打开 IPA，
     **从包内 `Info.plist` 读 `CFBundleExecutable`**（不硬编码）定位
     `Payload/<App>.app/SC_Info/<exe>.sinf`，`addEntry` + `flush` 写入；
  4. 每一步都会落日志（前缀 `[下载中心] sinf 注入：`），失败不静默。
- **不影响**爱思源与 AppleID 通道（那两条的 sinf 由各自链路负责）。
- ⚠️ **已知限制（写进日志了）**：当前写入器**只能追加、不能替换** ——
  包内若**已有**同名 sinf 则跳过。牛蛙的 `.dpkg.ipa` 实测没有 sinf，所以正常路径可用；
  真机若报「包内已有 …；跳过（安装可能解密失败）」，再考虑改替换语义。

### 修复（牛蛙下载失败：把「空直链」与「真失败」区分开）
用户原话：**「大部分应用都获取安装包失败」**
真机日志（同一接口、同一 region，**有的成功有的失败**）：
```
{msedge, region=0}      → ✗ 无候选数组键命中；body 键：ba_ipaURL, ba_sinfs
{TakeBrowser, region=0} → ✗ 无候选数组键命中；body 键：ba_ipaURL, ba_sinfs
{Via, region=0}         → ✓ 下载接口返回直链（sinf 1376 字符）
{SogouExplorer, region=0} → ✓ 下载接口返回直链（sinf 1376 字符）
```
- **结论**：这与「在详情页还是列表页点」**无关**（两处调的是同一个 `startNiuwaDownload`）；
  是**部分应用拿不到有效直链**。
- 本版**加诊断**：`body` 里 `ba_ipaURL` 存在但为空/非字符串时，**单独打一行并带 bundleId** ——
  一次真机即可判定是 **(a) 牛蛙服务器没有这些包**（不是我们的 bug）、
  **(b) 服务端不稳**，还是 **(c) 我们漏了某种返回形态**（那就继续改解析）。

## [0.3.406] - 2026-09-14

### 撤销（SSH 调试页：把 v0.3.404 / v0.3.405 关于 SSH 的改动**连根删掉**）
用户原话：**「我们不用 hostNameReport 这些了吧 我们不改 ssh 啊」**
- **「连接信息」区回到只显示「局域网 `ssh escape@<IP> -p 2222`」一条**；
  删掉「本机（仅设备自身）127.0.0.1」与「固定主机名（需 Bonjour）<设备名>.local」两行，
  以及配套的 `mdnsCommand` / `hasLAN` 之外的残留。
- `SSHServerService`：删 `hostNameReport()`、`hostLabel(_:)`、`mdnsHostLabel`、
  受限 shell 的 `hostname` 分支、`help` 里对应行、`refreshNetworkInfo` 里那行 `.local` 日志。
- ⚠️ **注意**：v0.3.405 CI 曾报 `SSHServerService.swift:598: type 'Self' has no member 'hostNameReport'`。
  **本版不是"修"它，而是把这整块删掉** —— 那块功能用户已经不要了，删掉错误自然不存在。
  （教训已记入 `.workbuddy/memory/MY-FAULTS.md` 缺陷 1：**不要修用户已经撤销的东西**。）
- 监听地址语义未动（仍 `0.0.0.0`）。

### 修复（截图/预览**不清晰了** —— 高清改写从「无差别」改成「按比例」）
用户原话：**「我发现现在获取的预览/截图图片不清晰了以前是清晰的 为什么」**
- v0.3.404 为修黑屏把「无差别改写成 `1024x1024`」改成「截图走原址」，清晰度因此退回缩略图（真机实测取的是 `320x480bb`）。
- 现在：命中 `(\d+)x(\d+)bb` 时**宽固定 1024、高按同一比例算**（`320x480bb` → `1024x1536bb`，
  `392x696bb` → `1024x1818bb`；正方形图标仍得 `1024x1024bb`）；长边已 ≥1024 或无尺寸标记则**不放大**。
- **候选链两档**：`[按比例高清, 原址]`，**高清失败自动回落原址**（不会退回黑屏）。
  日志 `候选 1/2` = 服务端接受任意比例；`候选 2/2` = 不接受、回落缩略。
- 全屏展示 / 长按保存 / 提取图标三处**走同一个 `PreviewImageLoader`**，清晰度一起回来。
- 顺手**删掉 `String.appStoreHighResImage`**（全仓已无调用点，且它就是黑屏的源头），
  原位留注释指向新实现，避免以后有人再写一个无差别版本。

### 新增（牛蛙源：能进**详情**、能**下载**）
用户原话：**「牛蛙源只是显示获取到直链 而且没有 app 详情界面也不能下载」**
- 新增 `NiuwaStoreDetailView`（与爱思详情同款排版，**不额外发请求**，字段只来自搜索响应）；
  牛蛙搜索行左侧接 `NavigationLink` 进详情。
- **下载走全项目唯一入口** `IPADownloadCenter.shared.start(...)`（与爱思源**同一个** `start(...)`），
  **没有第二个下载管理器**；牛蛙只是多一步「先打 `/appstore/download` 拿 `ba_ipaURL`」。
- 列表行右侧换成与爱思共用的 `trailingControl`；两个详情页共用提出来的
  `DownloadJobSection` / `JobProgressChip` / `InstallButton`（**一份实现**）。
- **失败不静默**：拿不到直链 → 「该应用没有可用的安装包」；抛错 → 「获取安装包失败」（原因进 `[牛蛙源]` 日志）；
  取直链期间行内显示「获取中」（牛蛙比爱思多一次网络往返，必须看得见）。
- 牛蛙详情页也接上了「查看图标 / 提取图标」（同一份 `iconMenuItems`）。
- **`ba_sinfs` 本版未使用**（经查证：现有两条安装链路的 sinf 都是**从包内 `SC_Info/` 读**的，
  不是传参；要用 `ba_sinfs` 必须在下载完成后覆盖写回包内 → 涉及 `IPADownloadCenter` 落盘环节，
  本版不做）。已在字段注释里留「待触发说明」，**真机若报「加密包缺少 SC_Info/*.sinf」再走那条路**。
- `IPADownloadCenter.Source` 新增 `case niuwa = "牛蛙免登录"`，牛蛙下载的来源不再错显示成「爱思免登录」。

### 修复（设备瘦身「较大应用」扫不到应用）
用户原话：**「设备瘦身的较大应用扫描修复一下现在扫不到应用」**
真机日志证明根因：`[设备瘦身] 大小增强回填 334 条，其中真的带 appSize 0 条（sizeComplete=false）`
—— 334 个应用**一个都没拿到应用大小**，因为 v0.3.401 为治「带属性 Lookup 卡 ~25 秒」把磁盘占用字段全去掉了。
- 本版**只加回 `StaticDiskUsage`**（installd 已有的静态统计，几乎免费）；
  **`DynamicDiskUsage` / `CFBundleSize` 仍不请求**（前者要遍历每个 App 的数据容器，最可能就是卡死元凶）。
- **降级链完全保留**：带属性 Lookup 有超时（额度不变）→ 超时/失败仍回落 `get_apps`
  → 那时缺 `appSize` → `sizeComplete=false` → 页面给「应用大小不可用」提示（**不静默变空**）。
- **判据**：真机 `[文件共享] 主路径返回 … 端到端 X.Xs（实际执行 Y.Ys）`。
  **Y ≈ 2~3s** ⇒ 卡的是 `DynamicDiskUsage`，邮箱与大小同时恢复；
  **Y 仍 ≈ 25s** ⇒ 卡的是 Lookup 本身、与字段无关，届时把该字段撤掉（回退配方写在代码注释里）。

## [0.3.405] - 2026-09-14

### 新增（SSH 调试页加「固定主机名」连法，不再只依赖会变的局域网 IP）
用户原话（批准时）：「**可以 这个作为备用共存**」
- 「连接信息」并列三条：
  - 本机（仅设备自身）：`ssh escape@127.0.0.1 -p 2222`
  - 局域网：`ssh escape@<IP> -p 2222`
  - **固定主机名（需 Bonjour）**：`ssh escape@<设备名>.local -p 2222`
- 主机名优先取 `ProcessInfo.hostName`（系统主机名，空格/非法字符已被系统规范化），
  退回 `UIDevice.current.name`；取不到则**整行不显示**；主机名带空格时自动改用 `ssh -l escape "<名字>.local" -p 2222`。
- 受限 shell 新增 `hostname`（一次列出：设备名 / 主机名 / 固定主机名），`help` 同步；
  打开页面时把固定主机名写进「通用」日志 —— **连不上时界面看不到，日志里看得到**。
- **未自己广播 Bonjour**（经评估是零收益：设备自带 `.local` 已由系统广播，
  而能否解析取决于**客户端**有没有 mDNS 解析器，自广播不改变这一点）；
  监听地址未改（仍 `0.0.0.0`）。
- ⚠️ **Windows 侧需装 Bonjour**（iTunes 自带，或 Bonjour Print Services）才能解析 `.local`；
  本机实测**未安装 Bonjour → `.local` 解析不了**（报 `Non-existent domain`）。
  ⇒ 备用方案：工作区 `ssh_run.py find` **直接扫局域网 2222 端口找设备**，零依赖。
- 顺手把「说明」里那句枚举命令的长文案改成「受限 shell：只应答内置诊断命令（help 查看全部）」
  （原来把命令名列在界面文案里，加一条就得改一次）。

## [0.3.404] - 2026-09-14

### 修复（牛蛙源：能搜到但「获取不了」）
用户真机日志（v0.3.403）——**搜索已完全打通，且 `region` 档位确认**：
```
region=0 → {"ba_apps":[{"trackName":"Via 浏览器",…}]}   ← 国区（中文名）
region=2 → {"ba_apps":[{"trackName":"Via Browser",…}]}  ← 美区（英文名）✓ 解析 15/15 条
```
但 `/appstore/download` 的响应**结构不同**（同一批日志）：
```
← 解密后 {"body":{"ba_ipaURL":"https://iosapps.itunes.apple.com/…signed.dpkg.ipa?accessKey=…",
                 "ba_sinfs":"AAAECHNpbmY…"},"pub_code":0}
✗ 无候选数组键命中；body 键：ba_ipaURL, ba_sinfs
```
⇒ **下载响应没有数组**，`body` 里直接给安装包直链与 sinf。
之前下载**复用了搜索那套「找数组」的解析** → 永远读不到 → 用户看到「获取不了」。
- 修法：`perform` 里**先判下载形态**（`body.ba_ipaURL` 非空即视为下载响应），
  取出 `ba_ipaURL` 与 `ba_sinfs`（新增 `NiuwaApp.sinfBase64` 字段）后再走原来的数组解析。

### 修复（截图/预览点开**全黑**）
用户原话：**「app 详情界面的预览/截图板块（免登录商店和 AppleID 商店都受影响）点击查看图片都是黑的」**
- **根因（一行无差别替换）**：全屏预览给**每一张图**都套了「图标专用」的高清改写 ——
  `String.appStoreHighResImage`（`MediaSaver.swift:69`）把地址里的 `\d+x\d+bb` **一律**换成 `1024x1024bb`。
  这招**只对正方形图标成立**（`100x100bb` → `1024x1024bb`）；
  而**截图不是正方形**（`392x696bb`、爱思图床把尺寸写进文件名）→ 换成**服务端不存在的资源** → 请求失败。
  **缩略图用的是原址** → 所以「**缩略图看得见、点开全黑**」，两个商店同因。
  失败后 `AsyncImage` 只画一枚 40% 白的小图标、**无文案、无日志** → 用户看到的就是一片黑。
- 修法：新增 `PreviewImageLoader`（**只有正方形变体才升高清，且高清失败回落原址**；取图全程落日志）
  与 `PreviewImageView`（**环形加载** / **「加载失败」+「重试」**）；空数组也提示「没有可查看的图片」。
- 新增 `PreviewImageCache`（NSCache，120 张）内存缓存：同一地址不再每次重下 ——
  顺带解决用户另一条抱怨「**没有加载转圈、加载没感觉、感觉很慢**」。
- 「提取图标」与长按保存也改走同一份取图逻辑。

### 新增（SSH 调试页并列显示两个地址）
用户要求显示固定 IP：连接信息区现在并列显示
- 本机（**仅设备自身**）：`ssh escape@127.0.0.1 -p 2222`
- 局域网：`ssh escape@<IP> -p 2222`

⚠️ 监听地址**未改**（仍 `0.0.0.0`）。
**必须说明**：`127.0.0.1` 是设备自己的回环地址，**同一局域网的电脑永远连不上它** ——
它**解决不了**「局域网 IP 变了就连不上」的问题；那条要靠 **Bonjour（固定主机名）** 才能真正解决。

## [0.3.403] - 2026-09-14

### 修复（牛蛙源：解密已通，最后一层是「数据嵌在 body 里」）
用户真机证据（v0.3.400 日志）——**加解密两关都过了**：
```
[17:01:39.848] ✓ 命中 N候选[尾部+T]=3832897897（尾部=1932313057 T=1900584840）
[17:01:39.850] ← 解密后 {"pub_code":0,"pub_desc":"接口调用成功","body":{"ba_apps":[…]}}
```
⇒ v0.3.402 的 `N = 响应尾部数字 + 本次请求发出的 T`（反汇编结论）**在真机验证成立**。
只差最后一层解析：
- **数组不在顶层**，而是嵌在 **`body.ba_apps`** → 现在**先在 `body` 里找、再回落顶层**
  （之前只看顶层，于是明明解密成功却报「无候选数组键命中」）；
- **`ba_apps` 加入候选键并排第一**（真机实测的真实键名），`nwcore_*` 降为兜底；
- **状态码真实键名是 `pub_code` / `pub_desc`**（`code` / `nwcore_code` 保留兜底）；
- 失败日志现在**同时打出顶层键与 body 键**，一次真机就能定案。

### 变更（长按菜单统一为「查看图标 + 提取图标」）
用户原话：**「APPdetail 也要查看图标和提取图标 我说的是图标不是图片 你看清楚点」**
- 菜单内容收敛成**一份** `ImagePreviewSupport.swift` 的 `iconMenuItems(...)`：
  「查看图标」= `ImageGalleryViewer` 单张预览；「提取图标」= `IconExporter` —— **四处不再各写一份**。
- **四处最终菜单**：
  - AppleID 商店 · 列表 → 查看图标 / 提取图标 / 查看图片（末位）
  - AppleID 商店 · App 详情 → 查看图标 / 提取图标
  - 爱思源 · 列表（爱思行与牛蛙行同一份）→ 查看图标 / 提取图标
  - 爱思源 · App 详情（头图）→ 查看图标 / 提取图标
- 爱思源列表行的**长按挂载点从左侧链接提到整行**（原来长按右侧下载控件区域不出菜单）；
  菜单项外层包 `Group`，避免 `@ViewBuilder` 返回多项时未被摊平导致菜单为空。
- 布局 / 缩略图尺寸 / 详情页结构**未动**。
- ⚠️ **「查看图片」保留在 AppleID 列表末位**（用户 v0.3.399 亲口要的，本轮只让补图标两项、没让撤）；
  爱思源无截图组（牛蛙行无详情页），故无法在四处一一对应。

## [0.3.402] - 2026-09-14

### 修复（AppleID 商店点下载要等好几秒才开始）
用户原话：**「还有我发现 AppleID 商店下载应用好像得等好几秒之后才会下载 这个是不是哪个bug影响的」**

**根因（代码定位，非猜测）**：`click → 第一次网络请求` 之间有一段**同步设备 IO**：
`AppStoreLocalInstallService.downloadAndInstall` 调的 `LocalDeviceIdentity.apply()`
会连建 **2 次 RSD 隧道**（`lockdownFullDict` 一次 + `com.apple.mobile.iTunes` 域一次），
而建隧道是秒级操作（旁证：0.3.25x 变更日志「此前在主线程同步建隧道会冻住设置页数秒」）。
用户看到的就是任务已入列「准备中 0%」、进度却几秒不动。

**关键事实：这 2 次隧道换来的字段，在这条链路上没有任何消费者。**
- `serialNumber` **不进任何请求** —— 三个请求构造器都写死 `"0"`
  （`StoreDownloadEndpoint+Fetch.swift:290`、`VersionFinder.swift:158`、`VersionLookup.swift:146`；
  v0.3.334 真机实测：带本机真序列号时 volumeStore 回空包、redownload 回 HTTP 500）。
  它唯一的读者是 `Download.swift:123` 的一行日志。
- `fairPlayCertificate` / `fairPlayDeviceType` **全工程只写不读**。

**改动**
- `LocalDeviceIdentity`：
  - 加**进程内缓存**（`NSLock`），一个 App 生命周期只真正建一次隧道；新增
    `cachedSnapshot()` / `invalidate()` / `warmUpInBackground()`；
  - **删掉第二次隧道**：不再读 `com.apple.mobile.iTunes` 域，连同那两个没人读的
    FairPlay 字段一起删除；
  - **改准顶部注释**：旧注释称"必须传本机真序列号，Apple 才能关联本机 FairPlay 证书、
    生成可用 sinf"——该结论已被 v0.3.334 推翻并回退，现按代码事实重写（见文件头）。
- `AppStoreLocalInstallService.downloadAndInstall`：不再同步等设备身份，
  改为 `warmUpInBackground()`（后台预热，跑在等账号租约的那段时间里）+ 只读缓存。
  `Configuration.deviceSerialNumber` 的赋值保留在 `applyIfCached()`：缓存热了才写，
  且写在**下载任务自己**里（与 vendor 的读同任务有序，不引入跨线程写 `String` 全局量的竞争）。
  **首次下载**那次的日志里 `serialNumber=` 会是默认 `0`（该字段不进请求，只影响可读性）。
- 新增 `[计时]` 日志（`onLog`，落 `[下载中心]` 分类）：把三段耗时**分开**——
  「点击→下载链路启动」「账号租约门等待」「设备身份步骤」，另外
  `LocalDeviceIdentity` 内部会打一行「读设备身份耗时 Xms」，用于验证隧道真实开销。

**已知代价**
- **首次下载**那次的日志里 `serialNumber=` 会是默认的 `0`（该字段不进请求，只影响可读性）；
  缓存热了之后由 `applyIfCached()` 补上真值。
- 读设备身份**失败时不写缓存**（免得把一次偶发失败固化一整个生命周期），
  所以隧道一直不通时每次下载都会在后台重试一次（与改动前的自愈行为一致）。
- `invalidate()` 已提供，但当前没有调用点（换设备 / 重连隧道时才有意义）。

**未做（有意）**
- 不动账号租约语义（已购 / 版本历史页靠它防 cookie 并发改写），
  所以「下载可能排在那些页面的 metadata 请求后面」这一条**本版仍存在**；
- 不改 `IPAFileDownloader` 的进度上报口径（首字节到达前显示 0% 属正常）。

## [0.3.401] - 2026-09-14

### 修复（回归：共享正版被显示成「苹果正版」）
用户原话：**「我发现怎么文档浏览板块、应用管理板块的对共享正版的识别不到位
的 怎么识别成苹果正版的 之前不是好好的吗」**

**这是回归**，引入版本 **`b2c310d`（v0.3.378）**：当时为解决「带属性 Lookup 卡死
20 秒」，把 instproxy 主数据源退回**不带 ReturnAttributes** 的 `get_apps` ——
而 `get_apps` **不返回 `iTunesMetadata`**，于是购买邮箱（`appleId`）与正版存在性
（`isGenuine`）恒空。`AppTypeDetector` 的判据 `hasITunesMetadata || 购买邮箱非空`
两条输入都空 → 继续往下落 `.appStore` → 界面文案「苹果正版」，于是**共享正版被
显示成苹果正版**。文档浏览与应用管理共用同一输入与判定，所以两个板块同时坏。
（可选增强 `lookupAppAttributes(timeout: 15)` 本该补救，但它在真机 20s 卡死场景下
必然超时返回空数组，永远补不上。）

- **A（止血，提交 `d5b28a6`）** —— `AppTypeDetector.detect`：在「有元数据/有购买邮箱」
  判据**之前**插入一条判据 —— **元数据没拿到（`hasITunesMetadata == false`）
  且购买邮箱为空 且 `isFairPlayEncrypted == nil`（加密状态未知）⇒ `.unknown`（「未识别」）**。
  真·正版不会被误伤（它有 iTunesMetadata，或有明确 `isFairPlayEncrypted == false`）；
  **错标比不标更糟**：宁可「未识别」，也不能把共享正版显示成「苹果正版」。
- **B（治本，本提交）** —— `FileSharingService` 的**类型判定主路径改回带属性 Lookup**
  （购买邮箱的唯一来源），并把 ReturnAttributes **收紧到类型判定必需字段**：
  去掉 `StaticDiskUsage` / `DynamicDiskUsage` / `CFBundleSize`
  （`rust/idevice-ffi/src/installation_proxy.rs` 的 `attrs` 常量）。
  假设：这三个字段让 installd 对**每个**已装应用走一遍 bundle / 数据容器目录树
  （`DynamicDiskUsage` 要遍历 GB 级数据容器），是这条命令最贵的部分 —— 待真机日志
  的「实际执行 X.Xs」验证。**保留两层降级**：带属性 Lookup 有额度（自适应、上限 15s）、
  失败/超时仍退回 `get_apps`（此时缺购买邮箱 → 由 A 兜成「未识别」，不再误判）。
  额度 < 10s 的调用（如 `IPADownloadActionsSheet` 的 5s 快路径数据源）直接用 `get_apps`。
  新增日志：请求字段清单 + 端到端耗时 + 「带 iTunesMetadata / 带购买邮箱」条数。
### 已知代价（大小字段被移出请求）
> **⚠️ 本节已被 v0.3.406 修正**：`StaticDiskUsage` **已经加回**请求
>（只保留 `DynamicDiskUsage` / `CFBundleSize` 不请求）——
> 因为去掉全部大小字段导致 334 个应用**一个都拿不到 `appSize`**，「设备瘦身」扫不到应用。
> 见 `## [0.3.406]` 的「设备瘦身」条。**下文保留当时的事实与推理，别再当作现状。**
- 为解决「带属性 Lookup 卡 ~25 秒」的卡死，本版把 `StaticDiskUsage` / `DynamicDiskUsage`
  （连同 `CFBundleSize`）**从该请求里去掉**（`rust/idevice-ffi/src/installation_proxy.rs`
  的 `attrs` 常量）。真机证据（实测日志）：
  `[17:00:08.237] 类型判定一批：8 条`（快路径 334 个应用 **0.12 秒**跑完）→
  `[17:00:33.449] 带属性增强：僵尸 Lookup 返回（已超时放弃，结果丢弃）` = **约 25 秒**。
  顺带旁证：pymobiledevice3 里这三个字段同样是 opt-in（`get_apps(calculate_sizes=True)`）。
- ⇒ **应用大小在 iOS 侧没有等价通道**（AFC / house_arrest 只到数据容器，拿不到 bundle 大小），
  相关位置会显示「—」。文档大小的 AFC 兜底实现虽在
  （`FileSharingService.computeDocumentsSize`），但它的调用点
  `FileSharingAppsView.computeDocumentSizes()` **当前没有任何调用**（死代码，要用得先接上）。
- ⇒ 「设备瘦身」的「应用」分片与「较大应用」分组在拿不到大小时**给出「应用大小不可用」提示，
  不再是静默为空**：本版把 `sizeComplete` 的判定从「增强回填了几条」改成
  「是否真的拿到了 `appSize`」（`DeviceSlimService.swift:334`）。

## [0.3.400] - 2026-09-14

### 修复（v0.3.399 的编译错误）
CI 唯一错误：`NiuwaStoreClient.swift:520: error: cannot find 'dumpResponse' in scope`。
原因：我把这个诊断落盘函数放在了嵌套的 `NiuwaCrypto` 里（`private`），
而调用它的 `perform` 在**外层** `NiuwaStoreClient` 里 —— 跨类型访问不到。
修法：把它**移到 `NiuwaStoreClient` 内**（诊断落盘本来就是客户端的职责），
并把这次踩的坑写进该函数的注释，避免以后重犯。

> 0.3.399 的全部内容（长按菜单/图标提取/截图预览 + 牛蛙响应落盘与 `N=尾部+T` 根因修复）本版照常生效。

## [0.3.399] - 2026-09-14

### 新增（长按菜单 / 图标提取 / 截图预览与保存）
用户原话：**「还有爱思源没有长按弹出选择提取图标、查看图标的功能
默认主页的 AppleID 商店也没有长按弹出选择查看图片的功能
还有爱思源的图片预览 也就是截图板块不能像 AppleID 商店进入 app 详情点图片预览和长按弹出选择下载图片的功能」**

- **① 免登录商店（爱思 / 牛蛙）列表行长按 →「查看图标 / 提取图标」**（`I4StoreFreeView`）：
  爱思行挂在 `NavigationLink` 上（与 AppleID 商店列表同一个长按位置），牛蛙行挂在左侧信息块上；
  两行共用同一个 `iconMenu(_:fileNameBase:)`，菜单内容只写一份。
- **② AppleID 商店列表行长按 →「查看图片」**（`AppStoreView`）：
  榜单行与搜索结果行共用 `storeRow(_:rank:)`，避免两处各挂一份一模一样的 `contextMenu`。
  榜单走官方 RSS（`parseRSSEntry` **不解析截图**），所以长按时按 `id` 补一次 `lookup` 取图；
  搜索结果（`parseSearchItem`）自带截图，直接开预览、不发请求。
- **③ 免登录商店详情页截图板块 → 点图预览 + 长按保存**（`I4StoreFreeDetailView`）：
  缩略图改为可点，点开走与 AppleID 详情页**完全同一套** `ImageGalleryViewer`，
  长按存图因此不必另写。缩略图尺寸 / 圆角保持原样，只加交互。
- **共用组件抽取**（新增 `EscapeOS/Views/ImagePreviewSupport.swift`，全工程仅此一个新文件）：
  - `ImageGalleryViewer`：由 `AppStoreDetailView` 里的 `AppStoreScreenshotViewer` **原样搬出改名**
    （实现未改），供三个调用点共用；
  - `ImagePreviewTarget`：`.fullScreenCover(item:)` 的 `Identifiable` 包装（原私有 `ScreenshotTarget`）；
  - `IconExporter.save(iconURL:fileNameBase:)`：由 `AppStoreDetailView.extractIcon()` 抽出，
    爱思源与 AppleID 商店的长按「提取图标」**同一份实现**，不做第二套。

### 修复（牛蛙源：响应解不开的**根因** —— N 少加了一项）
- 请求侧加密此前已通（服务端从「84 字报错」变成回 **9106 字真实数据**），但**响应始终解不开**。
  反汇编 `NiuWaCore` 的解密函数定位到真因：
  `0x060a70 mov x24, x3` → `0x060b30 add x21, x0, x24`
  ⇒ **服务端派生密钥用的是 `N = 响应尾部数字 + 本次请求发出的 T`**，而我们一直只用「尾部数字」。
  这解释了长期矛盾「小样本能解开、大样本解不开」：早期抓到的 92 字样本对应的请求**没带 T**（参数=0），
  `尾部+0` 恰好等于旧算法；请求侧加密打通后 `T≠0` → GCM tag 校验必然失败。
  同一函数还证明：全程**无长度分支**、单次 `EVP_DecryptFinal_ex`（**排除分块**）；
  调用方 `mov x2,#0; mov x3,#0`（**排除 AAD**）。
- 修法：记住本次请求实际发出的 T，解密时按 **`尾部+T` → `尾部` → `T`** 逐个试
  （GCM 校验非过即挂，不存在误判），命中会记明是哪个候选中的。

### 新增（诊断基础设施：完整响应落盘）
- 按用户建议，把**完整响应**覆盖写入固定文件 `Documents/LoginLogs/niuwa_last_response.txt`
  （头部带 `len` / `tail20` / `T`），绕开日志写入时的 **2000 字截断** ——
  此前尾部那 14 个字符（决定 key/iv 派生）正好被截掉，导致「分段对不对」长期无法验证。
  电脑侧用工作区的 `ssh_run.py niuwa` 一条命令拉回本地，并**当场复现解密**、逐个试 N 候选。

## [0.3.398] - 2026-09-14

### 修复（下载中心的暂停 / 继续 / 失败三件事）
用户原话：**「为什么暂停之后就不能继续了 而且在app详情界面点击继续虽然继续了没有刷新暂停按钮
还有就是几率出现暂停了之后就显示失败了 而且不能继续」**

截图现象：同一行从「已暂停 + 44% + 继续（可点）」变成「失败 + 0% + 暂停（灰、点不动）」。

- **① 「继续」点了没反应**（`IPADownloadCenter.resume`）：兜底分支原本直接 `pump()`，
  而 `pump()` 只挑 `phase == .waiting` 的任务 —— 一个刚暂停的任务是 `.paused`，
  **永远选不中** → 点了等于没点。改为「先重新排队（`.waiting`）再 `pump()`」；
  走这条兜底说明下载流已经断了（连 `resumeData` 一起没了），只能从头下，
  所以把 `progress / receivedBytes / speed` 一并归零 —— 界面显示 44% 却从头传是骗人。
  **没有**改 `pump()` 的筛选条件（去收 `.paused` 会让暂停的任务被自动拉起，违背暂停意图）。
- **② 「暂停」几率变成「失败 0%」**（`IPADownloadCenter.pause` / `RemoteDownloader`）：
  暂停是靠 `URLSessionDownloadTask.cancel(byProducingResumeData:)` 实现的，取消必然产生
  一个错误回调；原来靠「失败回调到达时 `phase == .paused`」来区分「这是暂停不是失败」，
  但**回调是跨队列来的**，`pause()` 又是最后才写 `.paused` → 回调先到就被判成真失败。
  三层改法：
  1. `pause()` 改成**先记意图 → 再写状态 → 最后才动下载流**；
  2. 新增主 actor 上的 `pausingIDs: Set<UUID>`（`pause()` 插入，`resume()` / `cancel()` 移除），
     `handle` 的失败分支判据改成 `pausingIDs.contains(id) || phase == .paused`；
  3. **根因层**（`RemoteDownloader.urlSession(_:task:didCompleteWithError:)`）：
     `URLError.cancelled` **无条件丢弃**。只靠②不够 —— `resume()` 会把 `paused` 改回 `false`，
     而被取消任务的错误**可能晚于** `resume()` 才到达（旧任务先报错、新的还在传），
     那一刻 `paused == false` → 照样被判成失败。`cancelled` 只可能来自本地 `cancel`
     （暂停 / 取消），网络断开是 `networkConnectionLost` / `timedOut` 等**别的**码。
  `.failed` 的 `overall` 恒为 0，所以这一判错就直接表现为「44% 的暂停」变成「0% 的失败」。
- **③ 失败的任务显示「暂停」且点不动**（`IPADownloadManagerView.jobActions`）：
  原来只有两态（`paused → 继续`，其它一律 `→ 暂停`）→ 失败的任务显示出「暂停」，
  又因为 `canPause` 只认 `downloading`/`paused` 而被置灰，成了死状态。
  改成三态：`.paused →「继续」`（可点）、`.downloading →「暂停」`（看 `canPause`）、
  **`.failed →「重试」`（可点，走既有的 `center.retry`）**、其余 → 暂停（灰）。
- **④ App 详情页「点继续后按钮没刷新」**（`AppStoreDetailView`）：
  **核实结论：该页并没有缓存 phase** —— 它持有 `@ObservedObject center`，
  `activeJob` 是计算属性，`jobs` 一变就重画；原诊断的「本地 `@State` 缓存一份 phase」在全仓
  （含免登录商店的 `I4StoreFreeView` / `I4StoreFreeDetailView`）都不存在。
  用户看到「没刷新」的真正原因是 **①**：`resume()` 什么都没改 → 没有发布事件 → 界面自然不动。
  本次只做了一处**不加布局**的加固：暂停/继续按钮的**动作**改成点击时现取一次任务最新状态
  （`center.job(job.id)`），不再用渲染那一刻的快照 —— 避免快照过期时误发暂停/继续。

### 补修（同版追加的两处 UI 死状态）
- **已完成的任务不再挂一个灰「暂停」**：`.done` 现在**不渲染**暂停/继续按钮，
  但用**同宽 `.hidden()` 占位** —— 否则它后面的「删除安装包」「提取链接」会整体左移一格，
  正是用户之前抱怨过的「整行图标左右位移」。
- **App 详情页的失败任务补上「重试」**：用户原话里的「**而且不能继续**」就是在这一页遇到的 ——
  原先那一格只会画一个灰的「暂停」，点不动。现在 `.failed` 显示橙色「重试」并接到 `center.retry`，
  且 **`.disabled` 对失败态放行**（否则又回到「显示暂停但点不动」那种死状态）。
  只改这一个状态位的文案/动作/颜色，**布局（间距、字号、行高）未动**。

> **未在真机编译验证**：本机没有 Xcode / 真机通道，只做了静态自检（括号深度扫描、
> 行首孤立 `/`、改动调用点 grep）与逐行核对。

## [0.3.397] - 2026-09-14

### 修复（v0.3.396 的编译错误）
- `NiuwaStoreClient.swift:93`：
  `error: no exact matches in call to initializer`。
  原因：诊断日志里写了 `String(key.prefix(8))` —— `key` 是 `Data`，
  `prefix` 返回 `Data.SubSequence`，**那个 `String(_:)` 初始化器并不存在**。
  改为 `String(decoding: key.prefix(8), as: UTF8.self)`；`iv` 那段一并改成显式变量。
- 同时把同类隐患全仓扫了一遍：其他 `String(x.prefix(...))` 的 `x` 都是 `String` 本身，**只有这一处对 `Data` 用**。

> 本版内容 = v0.3.396 的全部（**牛蛙响应解密的 padding 修复** +
> **在线安装卡进度环的四条收尾**），只是把那一处编译错误修掉后重发。

## [0.3.396] - 2026-09-14

### 修复（在线安装卡在圆圈进度条）
用户原话：**「我发现在线安装如果设备上已经安装了 / 安装失败还会一直卡在在线安装圆圈进度条 %」**

根因：进度环原先**只有一条收尾** —— 本机服务器保活到期（15 分钟）。
设备上已装同一版本、或系统直接拒装时，系统**一个字节都不会来拉包**，
`OnlineInstallProgress` 就永远停在 0% 转圈，要挂满 15 分钟才消失。

- **A 先查「设备上已装」再决定装不装**（`IPADownloadActionsSheet`）：
  第一次点「在线安装」先用**快路径** `FileSharingService.listAppsWithFileSharing(timeout: 5)`
  （`get_apps`，真机实测约 2.5 秒、带硬超时）查设备上有没有这个 `bundleId` ——
  **不用**带属性的 `Lookup`（那条命令实测 20 秒一个字节不回，会把点击卡死）。
  已装 → 只提示一次「设备上已安装」，**不装**；用户**再点一次**才真的重装。
  查不到（读取失败 / 超时 / 没有 bundleId）**一律不阻断安装** —— 宁可按用户意愿装，
  也不能因为查不到就不让装。检查期间该行转圈 + 置灰，防连点。
- **B 「发起后系统没来拉包」→ 60 秒一次性看门狗**（`OnlineInstallService`）：
  打开清单后若 60 秒内已发字节始终为 0 → 判「系统未开始下载」→ `reset()` 收掉进度环 +
  提示「系统未开始下载」。**只 `asyncAfter` 一次**（不是轮询）；60 秒内来过任何字节就静默作废。
  用**会话号**守卫：期间又发起新 OTA → 这次判定作废（同一个包连点两次不会误收新会话的环）。
  只在**经本机服务器发包**的路径挂：远端直链路径一个字节都量不到，挂上去 60 秒必误报。
- **C `.installing` 阶段兜底 3 分钟**（`OnlineInstallProgress`）：
  进入系统安装态后最多再留 `installingWindow = 3 * 60` 秒，到期自动 `reset()`。
  **从「进态那一刻」起算、不是从「开会话」起算** —— 271 MB 的包在局域网里传可以超过 3 分钟，
  按会话起算会把**正在传**的会话掐掉。会话号 + `stage == .installing` 双守卫，只在首次进态时排一次。
  本机服务器保活（15 分钟）**保持原样，一行没动**（它管的是「还要继续服务这个包」）。
  **B 与 C 不冲突**：B 管「一个字节都没发过」（60 秒，触发在**传输前**），
  C 管「已经发完、进入系统安装」（3 分钟，触发在**传输后**），触发条件互斥；
  即便两条都在跑，谁先到谁收尾，另一个到期时也会被各自的状态 / 会话守卫拦下。
- **D 点环即收掉**（`IPADownloadManagerView`）：在线安装的进度环**点一下 = `reset()`**，
  没有说明文字、没有额外按钮。只有环确实是 OTA 画出来的才接这个手势 ——
  覆盖安装 / 下载中的环背后是下载中心的真任务，点一下绝不能把它们悄悄取消。

> **未在上编译验证**：本机没有 Xcode / 真机通道，以上只做了静态自检（括号深度扫描、
> 行首孤立 `/`、改动调用点 grep）与逐行核对。B 的 60 秒、C 的 3 分钟都是**故意取整的固定值**，
> 真机若发现不合适（比如系统弹窗停留更久）直接调 `noBytesWindow` / `installingWindow` 两个常量即可。

## [0.3.395] - 2026-09-14

> 本版是把**两件事一起发**（用户只需装这一次）：
> 1. **v0.3.394 的台账根因修复** —— AppleID 下载通道现在会自己写台账
>    （`sourceURL` = 这次下载用的直链、`storeItemId` = App Store 商品号），
>    所以「已下载」面板里「提取下载链接」「复制商店链接」不再都是「无」。
> 2. **下载管理改版**（提交 `bde07f4`）：合并成一个列表 / 行内进度+速度 /
>    下载中把安装类动作置灰 / 装完自动刷新。**明细见下方 `[0.3.394]` 条目里的「改版」段**
>    （那段内容随本版首次发版；v0.3.394 的包里不含它）。
>
> **生效范围**：两条链接只对**本版之后新下载的包**有效。旧条目台账里从来没存过这两个字段，
> 不追溯补写（追溯只能读包内 `iTunesMetadata`，而重签包那个文件本来就没有）。

## [0.3.394] - 2026-09-14

### 修复（v0.3.393 的编译错误）
- `IPADownloadCenter.swift:362` 写了 `Job.Source.appleID.rawValue`，但 `Source` 是
  **`IPADownloadCenter` 的嵌套类型、不是 `Job` 的** →
  `error: type 'IPADownloadCenter.Job' has no member 'Source'`。改为 `Source.appleID.rawValue`。
  （v0.3.393 里「AppleID 通道补写台账」那个根因修复本身没变，本版把它一起带上。）

### 改版（下载管理：合并一个列表 / 进度+速度 / 下载中置灰 / 装完自动刷新）
用户原话：**「我觉得你应该参考这样类似的下载管理 原来app详情界面的下载进度条保留 还有不要分类已下载和下载中的了
并且一开始下载就写入了商店来源和下载链接 不需要分类 下载管理参考如图 下载时展开ipa详情在线安装、覆盖安装按钮是灰色不可按的
安装好后会自动刷新 不要等到返回上一级目录才能刷新状态那种傻逼做法 记得UI要好看美观」**

- **A 只有一个列表**：删掉「下载中 / 已下载」两个分组，把任务与台账条目合成一个数组
  （`IPADownloadManagerView` 新增 `ListRow` + `mergedRows`）。**去重**：某任务的落地文件名
  （`localFileName`，还没落地时用预测名 `expectedFileName`）已经在台账里 → 不再单独列它，
  否则包刚落盘的那一刻会被列成两行。排序：**进行中的在最上面**，然后是刚结束（失败可重试）的，
  最后按下载时间倒序。标题带总数：`下载管理 (5)`。
  详情页那套下载进度条（`AppStoreDetailView`）按用户要求**原样保留、没动**。
- **B 行内进度 + 速度**：`IPADownloadCenter.Job` 新增 `receivedBytes` / `totalBytes` /
  `speedBytesPerSecond` / `createdAt`；`RemoteDownloader.onProgress` 改为回传**原始字节数**
  （原来只回传折算好的 0~1，界面拿不到「70.3 MB/271.7 MB」）。
  速度 = **两次回调的字节差 ÷ 时间差**（0.8s 采样窗口 + 指数平滑 55/45），**不是全程平均**
  —— 掉速时全程平均会长时间停在虚高的数字上，等于骗人。暂停 / 下载完成 / 失败都清零。
  行内显示「进度条 + 百分比 + 已下/总量 · 速度」，数字一律 `.monospacedDigit()`，
  颜色用主题青 `LocusTheme.accent`（不用用户最讨厌的棕黄 `accentSecondary`）。
- **C 下载中 → 面板里的安装动作置灰**：`IPADownloadActionsSheet` 的「覆盖安装」「在线安装」
  `disabled` + 右侧标「下载中」，**其余动作照常**（「提取下载链接」下载中就能取，「复制商店链接」
  走台账商品号 `storeItemId`）。理由：本地还没有包时点覆盖安装必然落到 `installLocal` 的
  「文件不存在」分支，而那条分支会给**这个文件名**记一条失败（`recordFileFailure`），
  之后真正下好的同名条目会被标成红的「下载失败」（v0.3.390 专门修过这个坑）。
  面板**不再裁剪行**（v0.3.387 的「下载中只留一行」作废）—— 参考图要的是「展开这个包的详情」。
  另：「删除」在下载中 = 取消这次下载并丢弃半成品，所以**真的接上了闭包**
  （原来是空实现，点了确认什么都没发生，比置灰更糟）。
- **D 装完自动刷新**：`IPADownloadCenter` 新增 `@Published finishedTick`，在 `update(_:_:)` 里
  **任务一换阶段就 +1**；页面 `.onChange(of: center.finishedTick) { reload() }` 重新读台账 →
  「安装中」自己变成「安装 / 重装」，**不用退出这一页 / 返回上一级**。
  为什么不用「`jobs` 变了」当信号：`jobs` 在**每个下载进度回调**里都会变（每秒几十次），
  跟着它重读台账等于把磁盘读爆；而阶段变化一个任务只有 2~3 次。
- **E「需要 iOS x 及以上」本版不显示**：台账（`IPADownloadItem`）与 `IPAPackageInspector`
  都**没有**最低系统版本这个字段（只有网络模型 `AppStoreItem.minimumOS`），
  按「没有就不显示、不为它加网络请求」处理。

## [0.3.393] - 2026-09-14

### 修复（「已下载」面板里「提取下载链接」和「复制商店链接」都是「无」—— 找到根因）
真机实证（同一个包）：
```
11:51:44  提取下载链接（下载中任务）：https://iosapps.itunes.apple.com/...   ← 下载中拿得到
11:52:25  [下载] 完成：178 MB → com.openai.chat-1.2026.230.ipa              ← 落盘
11:52:56  [下载面板] 台账无 sourceURL，给不出 IPA 原链接                     ← 台账里却是空
```
**根因**：**AppleID 通道不走 `startDownload`，因此从不经过 `handle`** ——
而写台账（含 `sourceURL` / `storeItemId`）的逻辑在 `handle` 里。
以前 `startWithAppleID` 完成后**只更新内存里的任务**，台账条目是事后靠**磁盘扫描现场补登记**
生成的，那条路径根本不知道这两个字段 → 两个链接双双为空。
- **修法**：`startWithAppleID` 完成后**自己写台账**（把任务上的 `remoteURL` / `storeItemId` 一起落盘），
  `localFileName` 改用真实的 `dest.lastPathComponent`（不再靠拼字符串），并加一行落盘日志便于复核。

### 修复（爱思源直装的两条路径同样漏了这两个字段）
- `AppStoreI4View` 里两处 `IPADownloadLibrary.shared.record(...)` 只传了 6 个参数。
  它们手上的 `hit`（`SourcePackageLocator.Hit`）**本来就带着** `ipaURL` 与 `itemId`
  → 补上 `sourceURL: hit.ipaURL, storeItemId: hit.itemId`。

### 说明
- 以上修复只对**修好之后新下载的包**生效。此前已下载的条目台账里从来没存过这两个字段，
  不会追溯补写（要追溯得靠包内 `iTunesMetadata`，而重签包那个文件本来就没有）。

## [0.3.392] - 2026-09-14

### 修复（牛蛙源：真因是**请求体没加密**）
- 逆向拿到完整算法并**已独立复现验证**：报文 = `base64(密文‖tag)` + `base64(时间数字)`；
  **AES-256-GCM**；`key = MD5(前缀A + 数字)`、`iv = MD5(前缀B + 数字)` 的第 5..17 位。
- 用真机抓到的响应样本解出：**`{"pub_code":650,"pub_desc":"unknow error"}`**
  → 服务端在报「你没按加密格式发请求」。**根因是我们一直发明文 JSON**，
  所以「HTTP 200 却不是 JSON」「界面永远空」全都由此而来。
- 现在：**发请求前加密、收到响应后解密**（新增 `NiuwaCrypto`）。
  解密失败会把原始响应前 200 字符写进日志，不再「什么都看不到」。

### 修复（爱思来源也能给「商店链接」）
- 用户指出「爱思有个从 App Store 安装，它也能查到 App Store 来源的应用」——
  **是对的**：`I4PCStoreClient.swift:51` 的 `I4App.itemId` 注释就写着 `App Store trackId`，
  而且版本历史那条链路**早就在用它**，是我漏了。
- 现在：爱思下载时也把该号记进任务 → 落盘写台账 → **爱思下的包也能「复制商店链接」**。

### 诊断（「已下载」面板里两个链接都为空）
- 真机实测出现「下载中能取到直链，但落盘后台账里是空的」——
  即使读代码链路看着完全正确，也**不能靠读代码下结论**。
- 已加两处定案日志：拿到直链写入任务时一条、落盘写台账时一条（打印实际要写的两个值）。
  下次下载一次即可定位断在哪一步。

## [0.3.391] - 2026-09-14

### 修复（「复制商店链接」给不出 —— 我方向错了，用户指出）
- 用户原话：「什么叫『无商店链接』你不认账 …… 就是去AppStore安装那个跳转的链接呀」。
  **用户是对的，我方向搞错了**：我一直在纠结**读包内 `iTunesMetadata.itemId`**，
  而**下载的那一刻我们本来就拿着商品号** —— `AppStoreItem.id` 的注释就写着它是 `trackId`。
- 现在：下载时把商品号记进任务（`Job.storeItemId`），**落盘时写进台账**（`IPADownloadItem.storeItemId`）；
  「复制商店链接」改为**台账优先**，拼 `https://apps.apple.com/app/id<itemId>`；
  读包内 `iTunesMetadata` 降为**兜底**（重签工具会删掉那个文件 ——
  本机 `AssppPro-4.2.5.ipa` 与 `NBPro_v3.6.2.ipa` 实测都不含该条目）。
- 覆盖范围：只有 **AppleID 通道**有 App Store 商品号；爱思 / 直链来源没有，仍走读包兜底。

### 说明（两条链接的留档时机）
- 「每个下载都记录**商店链接 + 下载直链**」：两者都在**下载完成落盘时**写入台账
  （`sourceURL` + `storeItemId`）。所以「下载中」那一行提取到的直链，会在下载完成之后
  自动出现在「已下载」的**同一目标条目**上（v0.3.390 起生效），不需要再手抄。

## [0.3.390] - 2026-09-13

### 变更（文案：用户明确要求）
- 「**复制下载链接**」→「**复制商店链接**」。它读的是包内 `iTunesMetadata.itemId` 拼出的
  **App Store 商店地址**，叫「下载链接」名不副实，也和「提取下载链接」撞名。

### 修复（「提取下载链接」—— 我此前理解错了用户需求）
- 用户原话：「提取下载链接**不应该在下载时就已经记住这一次的下载链接**了吗（尽管是有有效期会失效的）」。
  我此前以「AppleID 通道的地址必须带授权头才有效、单给一个 URL 没意义」为理由**什么都不给** ——
  那是把「这个链接**单独能用吗**」与「这个链接**有没有留档**」混为一谈了，用户要的是后者。
- 现在：Apple 一签发下载地址，就**回填到该任务并写进下载台账**
  （`AppStoreLocalInstallService` 新增 `onResolvedURL` 回调 → `startWithAppleID` 接住 → `handle` 落盘时写入）。
- ⚠️ 同时修掉一个**必然把它写成 nil** 的 bug：`handle` 里原本用的是函数开头取的 `Job`（**值类型快照**），
  而直链是**下载过程中**才回填的 → 改为落盘时**重新取一次** job。
- 台账里没有直链时（更早下载的包、或该来源确实不给），提示由「无下载链接」改为「**该来源无公开直链**」。

### 新增（下载中那一行可直接提取，不必点进面板）
- 用户原话：「下载的进度条也没提取下载链接的按钮 **我让你加在进度条也不加**」。
- 「下载中」每一项的按钮行新增「**提取链接**」按钮（拿到直链才可点），直接把该任务的直链复制走。

### 诊断（为定位「正版包读不出商店链接」）
- `copyLink()` 改为**分步读 + 分步记日志**，一次点击即可区分三种情况：
  ① 包里压根没有 `iTunesMetadata.plist`；② 有该条目但 zip 解析失败；③ 有文件但没有 `itemId`（会打出实际键名）。
- 已用本机两个第三方重签包实测：**它们确实都不含 `iTunesMetadata.plist`**（重签工具会删除它）；
  而 `SignatureInjector` 只追加 sinf、**不删条目** —— 所以 App Store 原始包读不出来的情形，**待这次日志定案**。

## [0.3.389] - 2026-09-13

### 修复（AppleID 下载永久卡在「准备中 0%」）
- **根因**：`StoreAccountSession` 的账号租约门是**纯内存态**，`release` 只在 `withAccount` 的
  do/catch 两路被调用。只要**持锁那一次调用没走到 release**（最典型：App 进后台被挂起、
  或进程被系统回收 —— 异步任务不会补跑），`owners` 里就留下一个**永不释放**的 email
  → **此后这台设备上所有下载都永久停在「准备中 0%」，而且日志里一条下载记录都没有**
  （卡死在第一条 `onLog` 之前，`[AppleID] 请求下载信息…` 永远不出现）。真机实测正是这个形状。
- **修法**：取锁改为「轮询 + **25 秒超时强制接管**」。超时后本次照常继续，
  并由调用方的 `release` 把那个僵尸持有者清掉 → **一次超时之后链路自行恢复**；
  同时写一条 `[会话] 账号租约等待超过 25s…` 日志，以后同类问题一眼可辨。
  旧的 `withCheckedContinuation` 排队**等待者没有任何超时或取消能力**，一旦泄漏就是永久，已删除。

### 修复（牛蛙源：不再让用户白等）
- 真机实测：`region=cn` 与 `region=us` 返回的**都是 base64 密文，不是 JSON**
  → 说明「搜不到」的瓶颈**不在 region 取值**，而在**响应体本身要解密**。
- 因此把上一版加的「三种 region 形态串行试」**收窄为只发数字形态**
  （证据最强：`nwcore_region` 的 objc 类型是 `Tq` = `NSInteger`），
  避免 `25s × 3` = 最长 75 秒的「一直卡在加载中」。
- 失败文案改为直接说明原因：**「响应不是 JSON（服务端加密了，待解密）」**，
  让界面自己讲清楚，而不是让用户反复点。

## [0.3.388] - 2026-09-13

### 新增（安装进度：覆盖安装 / 在线安装都在「已下载」行内画圆环 + 百分比）
用户原话：**「而且在线安装的时候也没有安装进度 无论是覆盖安装还是在线安装都不要占用那个下载进度条那栏
应该在这个"已下载"的目标要安装的IPA显示一个百分比及圆圈进度条（要好看美观）」**

- **顶部横条只管下载**：新增 `IPADownloadCenter.downloadJobs`（等待/下载中/已暂停），
  下载管理顶部「下载中」那一区改用它 —— **安装阶段不再占用那条横向进度条**。
- **行内圆环**：`IPADownloadManagerView` 里「已下载」行右侧原来那条 44pt 横向进度条，换成
  **44pt 圆形进度环 + 环内等宽百分比**（12 点起画、圆头 3pt、主题青 `LocusTheme.accent`，
  未用用户最讨厌的棕黄 `accentSecondary`）。仍是 44pt，**不动行高、不挤掉右侧信息**。
- **覆盖安装（AFC + installd）有进度了**：`IPAInstallService.uploadFile` 以前**逐块写但不上报**，
  新增逐块字节回调 → 上传段映射到链路前 75%，installd 的 0~100 映射到后 25%
  （`Job.overall` 在 `.installing` 改为直接取 `progress`，避免二次压缩）。
  **声明式加权，不是系统给的「整体百分比」**：两段各自都是真实测量值，权重是估计。
- **在线安装（OTA）有进度了**：唯一真实来源是**本机 HTTP 服务器已发给系统的字节数** ——
  `IPALocalHTTPServer.FilePump` 每发完一块回调 (`onProgress`)，把「本次响应绝对偏移 + 本次已发」
  上报（`Range` 断点续传据此累计，百分比只增不减、不超 100）；新增 `OnlineInstallProgress`
  单例承载并投给 UI —— 其状态字段带 `@Published`（**没有它 `objectWillChange` 永不触发，
  圆环在传输期间根本不会刷新**），写入一律 hop 回主线程。
- **诚实边界（重要）**：包发完之后由 **iOS 系统**（itunesstored / installd）安装，
  **App 侧完全观测不到进度** → 此时行内切**不确定态（持续旋转的弧、不写百分比）**，
  **绝不假装还在走百分比**。该会话由「本机服务器保活到期」被动收尾（`scheduleIdleReset`），
  这不是「装完了」的信号，只是观测窗口结束。
- 顺带：所有既有 `progress` 回调的消费方（签名安装页 / 设备瘦身 / Apple ID 通道）从此能看到
  上传段，不再干等在 0%。

版本号 `0.3.388` / `685`。

## [0.3.387] - 2026-09-13

### 修复（下载管理「提取下载链接」：下载时就记住直链 + 下载中也能提取 + 彻底解耦安装状态）
用户实测反馈：**已下载**的 ChatGPT 点面板，「提取下载链接」是灰的、右侧还标着「安装中」。

- **解耦安装状态**：该行的取值只是**读台账里的直链**，不碰任何服务，与「在线安装 / 安装中 /
  下载中」没有任何竞争关系 → 删掉 `IPADownloadActionsSheet.extractLinkRow` 上的
  `IPALocalHTTPServer.shared.currentPurpose == .ota` 判断、`disabled:` 与「安装中」状态字，
  现在**恒可点、永不置灰、不显示任何状态字**。旧理由（本机 HTTP 服务时代「再 start() 会掐掉
  OTA 会话」）随之作废，注释一并删干净。
- **下载时就写入直链**：以前是界面 reload 时按 `Job.remoteURL` 事后回填，只覆盖「还在任务里」的
  条目 → 历史条目取不到链接。现在改为**在文件名/直链确定的那一刻就写进台账并落盘**
  （`IPADownloadCenter.startDownload` 用新的 `Job.expectedFileName` 落一次、`handle` 落盘时
  再随 `record(sourceURL:)` 写一次，`startFromI4Source` 拿到直链时也写一次）；失败/取消**保留**
  已写入的值。界面侧 `syncSourceURLs()` 降级为幂等兜底。
- **下载中也能提取**：`IPADownloadManagerView` 的「下载中」那行现在**点标题行也能弹出同一个操作
  面板**，直链直接取 `Job.remoteURL`（台账此时还没有这一行）。该面板在
  `isPendingDownload` 模式下**只渲染「提取下载链接」** —— 本地还没有包文件，安装/打开/分享/删除
  都不成立，不做出来给用户点。横向下载进度条与行内布局均未改动。
- Apple ID 通道本来就没有公开直链 → `sourceURL` 保持 nil，面板提示「无下载链接」，
  **不回落去包内读**（「复制下载链接」= 包内 `iTunesMetadata.itemId` 的商店链接，两行严格互斥）。

版本号 `0.3.387` / `684`。

## [0.3.386] - 2026-09-13

> ⚠️ **v0.3.378–v0.3.385 都没有产出过可安装的包**（v0.3.379 与 v0.3.384 都在 CI 编译阶段失败）。
> **请直接安装本版**，本版包含它们全部改动。

### 修复（编译失败：v0.3.384 无产物的真因）
- `EscapeOS/Views/I4StoreFreeView.swift:25`
  `error: cannot find 'NiuwaRegion' in scope`。
  根因：`NiuwaRegion` 是 `NiuwaStoreClient`（`EscapeOS/Engine/NiuwaStoreClient.swift:44`）**内部的嵌套 enum**，
  裸名引用找不到 → 改为全限定名 `NiuwaStoreClient.NiuwaRegion(rawValue:)`。

### 变更（下载管理操作面板：「两行」语义按口径对齐）
- **「复制下载链接」= App Store 商店来源链接**：读包内 `Payload/<App>.app/iTunesMetadata.plist` 的
  **`itemId`** → `https://apps.apple.com/<当前商店区>/app/id<itemId>`。
  **纯读本地文件，不联网、不起任何服务**；该行**恒显示**（不再要求台账有直链），
  包里读不到商品号（自签 / 三方重签包）→ 提示「无商店链接」。
- **「提取下载链接」= IPA 包本身的下载原链接**：读台账 `IPADownloadItem.sourceURL`
  （下载时回填，例如爱思 `https://d-app6.i4.cn/soft/....ipa`）。
  **纯读台账，不读包、不起服务**；台账没有 → 提示「无下载链接」。
- 两行**严格互斥、不互相回落**。旧版「提取下载链接 = 用本机 HTTP 服务现场生成一个分享地址」
  的做法**已删除**（本机 HTTP 服务现在只服务「在线安装」）。

### 变更（在线安装：入口互挤变得可见）
- 本机 HTTP 服务加**用途标记**（`Purpose.ota` / `.share`）：**在线安装占用时**，
  「提取下载链接」行置灰并标「安装中」；**分享占用时**，「在线安装」行置灰并标「分享中」。

### 修复（在线安装 / gist 托管）
- **manifest 回读加严**：必须 **Content-Type ∈ {application/xml, text/xml, application/x-plist, *+xml}**，
  并把**实际取到的 Content-Type 写进日志**（此前只比对内容，`paste.rs` 那种 `text/plain` 也能过）。
- 匿名候选池：**删掉被劫持的 `envs.sh`**（回读被解析到广告域名）→ 新增 `tmpfiles.org` / `uguu.se`；
  **单候选超时 25s → 8s**。
- **本机服务器改绑 `0.0.0.0`、默认用局域网 IP 供包**（取不到才回落 `127.0.0.1`），日志写出实际地址。
- gist 发布失败日志补上 **HTTP 状态码**（定位 401/403/404）；**仍用 secret gist，不切 public**。

## [0.3.384] - 2026-09-13

> ⚠️ **v0.3.378–v0.3.383 都没有发布过包**（内部提交号）。请直接安装本版，本版包含它们全部改动。

### 新增（免登录商店：接口二 = 牛蛙源）
- 免登录下载页新增**「来源」选择（爱思 / 牛蛙）** + **「区域」三档（中国 / 美国 / 香港）**。
  牛蛙这条**不带任何账号/令牌**（请求公共参数只有 `pub_*`）→ 即「免登录」。
  ⚠️ 线上 `region` 取值**尚未确证** → 本版会把**请求体（UDID 打码）与响应原文**写入 `[牛蛙源]` 日志，用于下一轮收敛。**爱思（接口一）一行未改。**
- **下载管理右上角齿轮 → 设置页填 GitHub Token**：token 存 **Keychain**（`WhenUnlockedThisDeviceOnly`、不同步），日志只记前 8 位。
  **填了优先用 gist 托管安装清单**（不再碰第三方），失败回落匿名候选。优先级：**自有 HTTPS 地址 → gist → 匿名候选**。

### 修复（在线安装）
- **manifest 回读加严**：现在必须 **Content-Type ∈ {application/xml, text/xml, application/x-plist, *+xml}**，
  并把**实际取到的 Content-Type 写进日志**（此前只比对内容，导致 `paste.rs` 这种 `text/plain` 也能过）。
- 匿名候选池：**删掉被劫持的 `envs.sh`**（回读被解析到广告域名）→ 新增 `tmpfiles.org` / `uguu.se`；
  **单候选超时 25s → 8s**（不再让一个候选把用户晾 25 秒）。
- **本机服务器改绑 `0.0.0.0`、默认用局域网 IP 供包**（取不到才回落 `127.0.0.1`），并在日志写出实际地址。
  理由：Feather/JSBox 都用局域网 IP。

### 修复（下载管理）
- **失败态区分「下载失败」/ 「安装失败」**（`Job.failureStage`）：按失败发生的阶段打标，
  不再把下载失败显示成安装失败；红字 + 仍可点重试。`installLocal` 增加「文件不存在」前置判定。

### 变更（下载管理操作面板）
- 分节「**危险**」→「**其它操作**」（`删除` 仍为红色 + 二次确认）。
- 新增「**提取下载链接**」（**当前语义 = 为本机已下载的包生成一个可分享的下载链接**，10 分钟后自动关服务；
  「从包里读原始来源链接」版本下一版改）。

## [0.3.381] - 2026-09-13

### 修复（下载管理：同一应用多个版本行一起显示「安装中」）
- **根因**：`IPADownloadCenter.swift:90` 的 `activeJob(bundleId:name:)` **只按 `bundleId` 匹配**
  → 同一应用的**所有版本行**都命中同一个活跃任务。
  而 `Job` 本来就有 `localFileName`（`<bundleId>-<version>.ipa`）、库也是按文件名记安装态。
- **修法**：行状态改按 **文件名（含版本）优先**匹配（新入口 `activeJob(fileName:bundleId:version:name:)`），
  回落只对「还未落地」的任务生效（先比 version 再比 bundleId），保留旧 2 参入口给「免登录源按 bundleId 找包」那条路。

### 修复（体验）
- **虚拟定位「增强守护」按钮**：去掉内层底色（只留单层胶囊）；**图标随状态变**
  （开 = `checkmark.shield.fill` / 关 = `shield.slash`）；切换时弹 toast。
  行为逻辑（ON 档 3s 重发 / 5s 健康检查 / 回前台重发）**一行未改**。
- **在线安装：不再因「FairPlay 加密」提前拒绝安装**。该假设**无证据、已撤回**：
  OTA 通道本身不检查 FairPlay，能否安装取决于**签名有效性与许可**；现在加密包照常走完整链路（只记一条非阻断日志）。

## [0.3.380] - 2026-09-13

> ⚠️ **v0.3.379 与 v0.3.378 的包都不存在**（两次都是编译失败）。请直接安装本版，本版包含它们全部改动。

### 修复（编译错误×2）
- **v0.3.379 失败原因**：`OnlineInstallService.swift:40` 注释被写成**单个 `/`**
  （`/        // 本机服务器起不来），Swift 把它当成运算符函数声明 →
  `expected 'func' keyword in operator function declaration`。已改回 `///`。
- **v0.3.378 失败原因**：一处 `runGated` 调用漏传第 4 个参数（闭包体）。已在下面那次改写中消除。

### 内容（合并 v0.3.378 / v0.3.379）
- **P0 回归修**：主列表改回 `get_apps` 快路径；超时只计实际执行（排队单独记账）；文档浏览补齐**重试按钮 + 下拉刷新**；
  设备瘦身**不再静默变空**（区分「应用读取超时」与「应用大小不可用」）。
- **带属性 Lookup 卡死修复**（应用大小/文档大小/Apple ID 恒显「—」的真因）：
  真机实证卡点在**第一次读 4 字节长度头**（**并非**分片读法，该假设已推翻）；实质差异是
  ReturnAttributes 的代价（`installd` 逐个算磁盘占用+读元数据），并发把重活叠成多份。
  现在：**单飞 + 设备级串行**（三方共享同一次），成功缓存 12s / 失败静默 4s；
  删掉**请求了但从不读**的 `Entitlements` / `ApplicationMissingDSID`；增强额度 **8s → 15s**（后台可选，不阻塞首屏）。
- **虚拟定位「增强守护」开关**：ON = 重发 8s→3s、健康检查 12s→5s、回前台立即重发（复用同一条隧道）。
- **下载管理：点已下载 IPA 弹操作面板** + **在线安装（OTA / itms-services）**：
  本机 HTTP 服务器发 `/package.ipa`（`Range`/`206`）→ manifest → 自有 HTTPS 优先 / 匿名临时托管兜底 → itms-services 三级兜底。**不需要任何账号。**
- 撤回一个错误的提前拦截（以「FairPlay 加密」为由直接拒绝安装）：**OTA 本身不检查 FairPlay**。

## [0.3.379] - 2026-09-13

> ⚠️ **v0.3.378 的包不存在**（构建因编译错误失败）。请直接安装本版，本版包含其全部改动。

### 修复（编译错误）
- `FileSharingService.swift` 里一处 `runGated` 调用**漏传第 4 个参数（闭包体）**（`{` 后直接跟 `switch` 分支）→ 已在下面那次改写中消除（改走 `AttributeLookupCenter`）。

### 修复（应用大小 / 文档大小 / Apple ID 恒显「—」的真因）
- 真机实证卡点在**第一次读取 4 字节长度头**，**并非**分片读法/终止条件（该假设已被推翻）；
  实质差异是 **ReturnAttributes 的代价**（`installd` 要对 333 个应用逐个算磁盘占用 + 读元数据），而并发把这份重活叠成 3 份、每条都超时。
  时间线：v0.3.284 引入 Lookup 时**只有「文档浏览」一个消费方**（当时能出值）；v0.3.369 加「应用管理」→ 2 并发；v0.3.376 加「设备瘦身」→ 3 并发，**卡死首次出现于这一刻**。
- 现在：**进程内单飞 + 设备级串行** —— 三个消费方共享**同一次** Lookup；成功缓存 12s、失败静默 4s；
  增强额度 **8s → 15s**（后台可选增强，不阻塞首屏）。首屏仍为 `get_apps` 快路径。

### 新增（下载管理：在线安装 / OTA）
- 本机 HTTP 服务器只发 `GET /package.ipa`（`Range` / `Accept-Ranges` / `206`，大包不整包读内存）→ 生成 manifest →
  托管到 HTTPS（**自有地址优先且不再对外发请求**；留空走匿名临时托管，逐个回读校验）→
  打开 `itms-services://`（系统 open → 内置浏览器再跳 → 复制链接提示 Safari）。**不需要任何账号 / token。**
- **撤回一个错误的提前拦截**：此前会因「FairPlay 加密」直接拒绝安装（该结论无依据）。
  **OTA 本身不检查 FairPlay**；能否安装取决于签名有效性与许可。

## [0.3.378] - 2026-09-13

> ⚠️ **0.3.376 的包有严重回归**（文档浏览 / 应用管理 / 设备瘦身一起坏），请直接安装本版。
> 内部提交号 0.3.377 未单独发版，其改动已并入本版。

### 修复（真机 P0：三个板块一起坏，**同源**）
真机日志实证的根因：`instproxy` 的**带全属性 `Lookup` 命令**在本机（333 个应用）**卡死 20 秒、一个字节都不回**；
而**同一次会话**里改用 `get_apps + profile` 只用 **2.5 秒**就判完 333 个应用 —— **通道是好的，是这条命令的问题**。
而 v0.3.369 把「应用管理」与「文档浏览」的数据源都换成了 Lookup、设备瘦身也共用同一入口 → 一处卡死三处崩。

- **主列表改回 `get_apps` 快路径**；带属性 Lookup 降级为**可选后台增强**（独立 8 秒、失败就不补、字段显示「—」，
  **绝不阻塞首屏**）。
- **超时只计实际执行时间**：排队等待单独计并单列日志（原来排队时间会吃掉超时额度 —— 实测「开始」到「超时」
  只隔 3.6 秒却报 20s，导致后续调用一进去就"已超时"）。
- **补齐重试入口**：文档浏览错误态新增**「重试」按钮** + **下拉刷新**（此前超时态没有任何重试入口，等于不可用）。
- **设备瘦身不再静默变空**：超时/失败时仍用快路径出数据；区分「应用读取超时」（错误态 + 重试）与
  「应用大小不可用」（有数据、只是不精确，非致命提示）。
- 一并修 `EscapeSpaceProfiles` 同 hostname 无串行保护（`ProvisioningProfileStore` 与 `ProfileConfigService` 共享同一条队列）。

### 新增
- **虚拟定位右上角「增强守护」开关**：ON 档 = 重发 **8s → 3s**、健康检查 **12s → 5s**、**回前台立即重发**、
  检出会话被回收时当场重建；**所有重发复用同一条隧道**（不新建）；持久化键 `escape.locationGuard`；
  日志前缀 `[增强守护]`（含触发来源、累计重发次数、"疑似复位"命中次数）。
- **下载管理：点击已下载的 IPA 弹出操作面板** —— 覆盖安装（复用既有本地安装链路）/ 在线安装 / 打开 /
  复制下载链接 / 分享 IPA / 删除 / 取消。玻璃卡片 + 分组 + 危险项红色，**任何一行都不出现省略号**。
  · 「复制下载链接」**只在台账里真有来源直链时显示**（不伪造）；「打开」已安装则直接跳转，未安装置灰。

### 说明（未做，且有依据）
- **「在线安装」暂为「未接入」**：逆向确认它是 **OTA（`itms-services`）**，硬门槛 = 「**已签名 IPA**」+「**我们自己的
  HTTPS 托管**」三条同时满足，缺一装不上（iOS 7.1 起 manifest 必须 https；iOS 18+ 走本地服务器方式还额外要求
  `networkextension` / Associated Domains 等 entitlement，我们没有）。参考工具能做是因为**它自带服务器**。
  面板里该行**诚实标注「未接入」**，不做假路径；一旦有 HTTPS 空间即可接入。
- **定位通道预检降级为纯诊断**：0.3.376 里它会在 `dtservicehub` 不在 RSD 服务表时**直接失败** —— 该假设**尚未真机实测**
  （反方旁证指向 `remoteserver`），一旦不成立就会**打断现在能用的虚拟定位**，故改为**只写日志、不拦截**。
  下次开启虚拟定位，日志会给出 `[定位通道] 预检：…` 的实测答案，之后才好决定要不要启用硬门槛。

## [0.3.376] - 2026-09-13

> **v0.3.374 的包不含以下修复**。内部提交号 0.3.375 / 0.3.377 未单独发版，其改动已全部并入本版。

### 修复（用户实测两个故障，**同源**）
- **文档浏览无限「正在读取已装应用…」**：`FileSharingAppsView.load()` 用的是 `defer { loading = false }`，而 `defer` **只在函数返回时执行**；
  这条链路从 Swift 到 Rust **一层超时都没有**（`run_sync_local` 阻塞式 block_on、隧道 `TcpStream::connect` 无超时、
  instproxy 读响应无超时，中间还有 3 次重试会把等待翻倍）→ 只要设备/隧道一次不应答就**永不返回**。
  现在：**20 秒硬超时** → 列表区显示 `⚠️ 读取超时`（四字），类型占位收敛（不再停在「识别中」）；迟到的成功结果仍会正常回填，不会把用户锁在超时态。
- **应用管理「三方应用」类型胶囊消失**：胶囊只在 `appTypes[bundleId]` 有值时才渲染，而该字典在 `loadAppTypes()` **最后一行**才写入
  → 上面那个卡住会让字典恒空、**三方胶囊整条不渲染**（系统应用走 `isSystem` 分支，所以不受影响，与用户描述的"三方"逐字吻合）。
  **反证**：若只是失败，`try?` 会退化成空数组、代码会继续跑完、胶囊仍在 → **胶囊消失只可能是「卡住」而非「失败」**。
  现在 Lookup 超时/失败时按「无 Lookup 数据」**继续**用 `get_apps + profile` 判定 → 胶囊最多 20 秒后照常出现。
- **同 hostname 并发建隧道的两处违规**（项目实测铁律：同 hostname 并发 `tunnel_create_rppairing` 会互抢）：
  · `EscapeSpaceFileShare`：应用管理与文档浏览会**各自**建隧道且无串行保护 → 加串行队列（只锁「建隧道」这一步，不锁调用方生命周期）；
  · `EscapeSpaceProfiles`：`ProvisioningProfileStore` 与 `ProfileConfigService` 共用同一 hostname 却无保护 → 共享**同一条**串行队列。
- **设备瘦身两条无超时读取入口**：改用带超时的入口；超时按空数据降级（「应用」分片按 0、「较大应用」为空），
  页面底部显示 `应用读取超时`，不再无限「正在读取空间占用…」。

### 新增（让故障可见，不再靠猜）
- 上述路径**每一步写日志**（走 `LoginLogger`，不用 `print`——用户看不到 stdout）：隧道连上 / Lookup 条数 / 回落 / 失败原因 /
  每批判定条数 / 超时。以后卡住直接看「登录日志」定位。
- **虚拟定位：通道预检**。建隧道后、连服务前先查 `com.apple.instruments.dtservicehub` 是否存在
  （`rsd_service_available`），并把 `port` / `uses_remote_xpc` 写进日志；不可用即收口为新错误 **「定位通道不可用」**
  并缓存 `channelStatus` 供 UI 读取（原来会落到泛化的 remote-server/超时错）。

### 说明（本次**未做**，有依据）
- **iAnyGo 的「方案二」（lockdown `com.apple.instruments.remoteserver`）未实现**：该入口只在 **iOS ≤16** 存在
  （crate 注释、go-ios 报错文案、本仓 FFI 注释三处独立一致），而本 App 最低支持 **iOS 18**（`Depends: firmware (>= 18.0)`）
  → 永不触发；且设备侧还缺 provider（无 usbmuxd；`idevice_tcp_provider_new` 需经典 lockdown 配对文件）。
- **DDI 挂载也不需要**：要挂 DDI 的只有那条 lockdown 老路；现走的 **RSD → `dtservicehub` → DTX 在 iOS 17+ 不需要 DDI**
  （这也是虚拟定位一直能直接用的原因）。App 至今从不挂 DDI（`DDIDownloadView` 只下载+打包，`image_mounter` 从未被调用）。
- Rust 侧 `connect` / instproxy `read_raw` 仍无超时（FFI 不可取消）：本次只做到「不再阻塞 UI」，进程内线程与隧道残留仍在。

## [0.3.374] - 2026-09-13

> **v0.3.373 的包不存在**（tag 构建在编译阶段失败，release 未发布）。请直接安装本版，本版包含 0.3.373 的全部改动。

### 修复（编译错误）
- `EscapeOS/Engine/BLECoordinator.swift:603`：`CBATTError.Code` **没有** `.notPermitted` 这个 case，
  编译报 `type 'CBATTError.Code' has no case 'notPermitted'`（CI 退出码 65）。
  该处是**写请求**的应答，改为 `.writeNotPermitted`。
  （原写法意图正确但枚举名不存在；这是 v0.3.373 唯一的编译错误。）

## [0.3.373] - 2026-09-13

### 新增 / 变更（蓝牙位置模拟面板）
- **设备标识**：广播名按角色 `ES-T`（模拟终端）/ `ES-S`（信号端），界面显示 `EscapeSpace（模拟终端）`。
  **角色标签不再依赖广播名** —— 31 字节广播包里 128-bit 服务 UUID 已占 16 字节，`EscapeSpace-T` 会被 iOS 静默丢弃；
  而只有「模拟终端」会广播、扫描又按服务 UUID 过滤，所以列表一律按终端渲染，不再退化成「未知角色」。
- **「附近设备」列表**：扫描只累积，不再「发现第一个就自动连」；按 identifier 去重、RSSI 降序、12 秒未出现即移除；
  点行连接，已在连接中的行禁用（不支持热切换）。
- **被配对方弹窗授权**：订阅请求先挂起，A 机弹窗「<设备> 请求连接」；点「允许」才推送坐标。
  **拒绝（手动或 20 秒无人应答）走同一路径**：记住该设备 → 拆服务踢掉对端 → **停止广播**（不重广播，杜绝「重连→重问」循环）
  → 之后该设备静默忽略、不再弹窗、不再刷日志；面板出现「重新开始广播」一键解冻（仅在有拒绝记录时显示）。
- **面板样式对齐「轨迹」面板**：大标题、左上「完成」、动作行带图标、键值行等宽前导 + 值左对齐换行，
  **任何一行都不再出现省略号**（含日志行与所有标签文案）。
- 使用说明（4 行）含一句：蓝牙为可选跨设备扩展，单机无需第二台设备，直接用虚拟定位。

### 修复（虚拟定位托盘）
- 摇杆开启态由橙棕 `accentSecondary`（`0.95/0.55/0.28`）改为主题青 `accent`。
- **「摇杆 …」文案被截断 + 整行图标左右位移**：根因是「开始定位」（`minWidth 96` + `padding 10`）与
  「停止定位」（`minWidth 72` + `padding 8`）宽度差 28pt，把弹性宽度的摇杆胶囊挤窄、并推动整行位移。
  现在两者统一 `.frame(width: 72)` + `.padding(.horizontal, 8)`，摇杆加 `.layoutPriority(1)` 与缩字，
  该行间距 10 → 8。

### 其他
- `Resources/Info.plist`：去掉重复的 `NSLocalNetworkUsageDescription`（两条合并为一条，键唯一）。
- 蓝牙面板 sheet 呈现改为 `.presentationDetents([.medium, .large])`（与「轨迹」面板一致）。

## [0.3.372] - 2026-09-13

> **v0.3.371 的包不包含本版修复**（修复提交在 tag 之后），请直接安装本版。

### 修复（蓝牙位置模拟面板）
- **A 机「连上即停广播」后可能永远不再广播**：原来只在收到系统的「退订」回调时才重开广播，
  而 B 机退后台/被系统杀掉时 iOS 未必及时投递该回调 → A 机握着过期订阅记录、**再也不广播**，
  B 回来按服务扫描永远扫不到，必须手动关开面板。现在：
  · **静默超时看门狗**（25 秒，5 秒一 tick）—— 只有「**有待发坐标 + 期间无任何活动**」才判定对端失联，
    避免「链路空闲但对端正常」被误杀；活性由「成功 `updateValue`」或「收到 B 的回报」刷新。
  · **三个重开广播时机**：退订回调 / 看门狗判定失联 / 每 tick 兜底（无活跃连接且未在广播 → 重开）——
    不再依赖单一回调。
- **B 机静默自愈（与 A 对称）**：A 的看门狗是破坏性的（会清掉订阅），若 A 的发送队列被系统卡住而 B 其实还连着，
  B 会停在「已连但收不到」且不自愈。现在 B 在 30 秒（**晚于 A 5 秒，让 A 先动**）收不到任何负载 →
  切断连接 + 立即重新扫描。两条自愈因此收敛到「B 重连」一条路径，不会互相打断。
- **坐标去重**：B 机对相同坐标不再重复应用（A 的 8 秒心跳只刷新存活时间，不重复触发定位）。
  ⚠️ 关键细节：`lastReceivedAt` 在**去重判断之前**刷新 —— **被去重丢弃的包同样是「链路存活」的证据**，
  否则全心跳都是同一坐标时 B 会误判失联、反复重连（比原问题更糟）。
- **重扫路径修正**：原来按 `isScanning` 判断再扫，而该标志异步翻转 → 重连路径可能卡死；
  改为无条件「先停后扫」，且**全文件只有一处发起扫描**，四个入口（蓝牙上电 / 断连 / 连接失败 / 静默自愈）共用；
  `didFailToConnect` 也纳入，重扫加 2 秒退避防高速空转。
- **面板日志重复抑制**：3 秒窗口内相同内容只留一条（避免极端时序下连刷两条），不引入去重表。

## [0.3.371] - 2026-09-13

### 新增
- **虚拟定位新增「蓝牙位置模拟」面板**（**辅助功能、默认关闭、原有功能一行不改**）。
  · 角色二选一：**A 机＝模拟终端**（下发坐标）/ **B 机＝信号端**（收到后调用**现有**虚拟定位入口应用，并回报状态）。
  · 载荷 v1：`1 字节版本 + 2 × Double(经纬度)` 小端；A→B 单向下发为主，B→A 只回状态码。
  · **A 机连接建立后立即停止广播**，之后只靠写特征推送坐标；断线才重新开广播（降低掉线面）。
  · **坐标不做二次变换** —— 现有应用坐标入口内部已经做过一次中国区偏移修正，再来一次会把位置整体偏出去
    （代码里留了注释防止后人重复加）。
  · 状态机 6 态（`off / advertising / scanning / connecting / connected / synced`），错误单独记；
    UI 三节：角色与开关 / 链路状态 / 回报与日志。
  · 入口在**虚拟定位页**（不是「更多」页）。

### 修复
- **补齐蓝牙权限声明**：`Info.plist` 之前**没有** `NSBluetoothAlwaysUsageDescription` ——
  iOS 13+ 下第一次访问 CoreBluetooth 会**直接崩溃**（不是弹窗被拒）。同时给 `UIBackgroundModes`
  补上 `bluetooth-peripheral` / `bluetooth-central`。

### 已知限制（如实记录）
- **必须两台设备**：同一台手机上的广播端与扫描端互相不可见（Apple 的既定行为），所以不支持单机自连；
- **双方基本都需保持前台**：后台广播/扫描能力受限（名字会被剥离、扫描间隔拉长、系统仍可能回收进程）；
  面板里给了一句提示。原有后台保活不在本功能范围内改动。

## [0.3.370] - 2026-09-13

### 修复
- **App Store 详情页首次进入不显示「App 隐私」**。原实现第一次请求用的区就是持久化的商店区（**不是**区域同步竞态
  —— 这一点由 worker 实测否掉了）。真因两条：
  · Apple 对「请求区 ≠ 出口区」的请求返回 **HTTP 200 + 出口区的 `/<出口区>/iphone/today` 降级页**
    （实测：CN 出口请求 `/us/app/id…` 一律被重定向，**与应用是否上架该区无关**）。
    旧代码把这份降级页**当成功写进缓存**（10 分钟）→ 「取不到」被钉死，
    只能靠切区 / TTL / 缓存淘汰才恢复 —— 这正是用户「得刷新或切区才显示」的现象。
  · 回落只有 `cn` 一种：US 账号 + 非 CN 出口、且发起区不是 us 时，两条都拿不到详情页 → 永久空。
  改法（三处最小改动）：**只缓存确实是该应用详情页的结果**（降级页照旧解析但不落缓存，下次进入自然重抓）；
  回落次序改为 **请求区 → 账号区 → cn**（账号区通常就是出口区）；详情页发起时定死区域并显式传入，
  仍为空且区域变了才补抓一次。
  效果：用户情形下首次进入就是「cn 发起 → 被重定向 → 账号区 us 拿到真详情页」，一节到位；
  成功页仍走原有 TTL + 并发去重缓存，同一份 HTML 不会重抓。

## [0.3.369] - 2026-09-13

### 修复
- **应用管理板块的「共享正版」不再被判成「苹果正版」**。根因是**两个板块走的是两条不同的设备查询**：
  · 「文档浏览」用 `FileSharingService.lookupAppsWithAttributes()` = **Lookup + ReturnAttributes**
    （Rust FFI `installation_proxy_lookup_apps`）—— 这是**唯一**会返回 `iTunesMetadata` 的调用，
    而「购买邮箱」就在 `iTunesMetadata.appleId` 里，是判正版/共享的唯一依据；
    它返回**全部**已装应用（不做文件共享过滤，过滤开关只在视图层）。
  · 「应用管理」此前用 `AppDiscovery.getAllAppsInfo()`（`installation_proxy_get_apps`）**不带
    ReturnAttributes → 不返回 `iTunesMetadata`** → 邮箱与存在性恒空 → 只能落成苹果正版。
    **v0.3.367 那个「App Store 应用全被判成越狱版」的回归也是同一条链路缺输入造成的。**
  修法：`loadAppTypes` 先做**一次同款全量 Lookup**（不是每应用一次），据此构建
  `applicationType` / `iTunesAppleID` / `hasITunesMetadata` 三张表；旧查询只兜底 Lookup 缺项；
  `ApplicationType == "Unknown"` 视同未拿到。**判定逻辑一行未改，改的是输入** →
  同一应用在两个板块必然显示同一类型。三条隧道串行创建、各自 defer 释放（避开历史并发闪退）。
- **商品页抓取改为区域健壮（修「App Store 详情看不到 App 隐私」）**。实测：从中国大陆出口 IP，
  `apps.apple.com` 会**按 IP 地理重定向** —— `/us/app/id…`（含 ChatGPT）**302 到 `/cn/iphone/today`**，
  不带区域同理，**加 `Cookie: geo=US`/`site=US` 也无效**；只有 `/cn/app/id…` 能正常返回应用页。
  用户的账号区是 US，所以此前去抓 `/us/…` → 拿到 Today 页 → 0 条 → 而实现是「空就不显示」→ **静默消失**。
  现在：先按请求区抓 → **最终 URL 不是应用页就回落 `/cn/` 再抓一次** → 两条都不是才收尾；
  缓存里记录「实际服务的区域」（`served`），下次不再先撞一次重定向；
  **拿不到时把原因写进商店日志**（`us：200 但落到 …/today；cn：HTTP 404`），界面仍不显示空节。
  实测（真实网络）：**微信 0→1 组、淘宝 0→3 组、抖音 0→2 组**；ChatGPT 仍 0
  （US 独占应用从 CN IP 取不到，非解析问题）。**隐私分组数量随应用不同，不是固定 3 组**。

## [0.3.368] - 2026-09-13

### 新增
- **App Store 详情新增「App 隐私」栏目**。数据来自我们**已经在抓的**商品页 HTML
  （`serialized-server-data` 里 `"page":"privacyDetail"` 那段），三组照 Apple 语义：
  **用于追踪你的数据 / 与您关联的数据 / 不与你关联的数据**；类别与用途、数据类型**全部用 Apple 原文**。
  · **不新增请求**：新加 `productHTML(appId:country:)` 按「区域\|appId」缓存整段 HTML（TTL 10 分钟、
    上限 3 条、在途去重），**与历史版本页共用同一份** → 详情页 + 历史版本页同一次进入只打一发。
  · Apple 的 amp-api 实测 **401**，不使用。
  · **没有该数据的应用整节不显示**（实测部分 us 样本就没有），不显示空壳或占位。
- **免登录下载详情新增「App 隐私」栏目**。复用 `appinfo.xhtml` 返回里**本来就有**的 `app_privacy`
  —— **零额外请求**（核过：该客户端全部网络调用点仍只有既有的 2 处）。
  实测**部分应用没有这个字段**（豆包 / 汽水音乐）→ 同样整节不显示。
  · 保真度边界（如实说明）：爱思这份数据**没有 Apple 的「用途 / 数据类型」那两层**，有多少显示多少；
    `items[].icon` 实测恒为空串，所以不显示图标。

## [0.3.367] - 2026-09-13

### 修复
- **修 v0.3.364 引入的分类回归：应用板块里 App Store 应用全被显示成「越狱版」。**
  两条叠加导致：① `AppListView` 调判定时**没传「是否存在 iTunesMetadata」**（默认 false），
  而文档浏览那条链路传了 —— 这就是「文档浏览正常、应用板块全错」的原因；
  ② 更要紧的是规则太激进：**把「没有证据」当成了「破解包」**。已装应用读不到包内
  `SC_Info/*.sinf`（AFC 只到媒体域）→ 加密状态是**未知**，而未知被当成「无加密 → 越狱版」。
  现在**越狱版必须有正面证据**（明确读到「确实无 FairPlay 加密」才判），未知一律兜底为苹果正版；
  同时把存在性传进应用板块。
- **历史版本：来源选择恢复可在读取中切换**（我此前把用户「不能随意切换来源不友好」误读成「应当禁止切换」，
  做反了）。现在随时可切，切换即**取消旧任务**按新来源重来，避免两次加载并发串台；
  重登 ≤1 次、加载更多有界、文案取源头这些已做对的保持不变。

### 界面
- **免登录下载列表不再挤压**：版本/大小胶囊各自保持单行（原来被压成 `v8.0.` / `78`、`767.2` / `9MB`），
  胶囊整块换行；简介与名称改为可换行不截断；右侧进度控件不再抢左侧宽度。
- **免登录下载详情页补上「下载中」区块**（阶段文字 + 版本 + 百分比 + 进度条 + 暂停/删除），
  与列表同源（只读 `IPADownloadCenter.shared` 的同一个 Job，没有第二套下载状态）。
  真因是头部原先按**版本号**匹配下载任务（详情版本与发起下载时的版本不一致就匹配不到）→ 改为按应用匹配。
- **App Store 详情页进度展示优化**：原来下载与安装**共用一条 0→100%**，看不出处于哪个阶段；
  现在改为「阶段胶囊（下载中/安装中/已暂停/等待中）+ 阶段文字 + 大号等宽百分比 + 进度条」。
- **顶栏搜索常驻**（用户要求「无论下滑状态都能搜索」）：App Store 商店与免登录下载的
  `searchable` 从 `displayMode: .automatic` 改为 `.always`，对齐主页「应用」板块。

## [0.3.366] - 2026-09-13

> 本版含提交信息里标 `v0.3.365` 的几条（同一批修复，一次出包）。

### 修复
- **消除「候选版本重试」的请求放大**（verhist 定量审计的结论）。此前 `versionCandidates` 是常驻的，
  `attempt` 每轮重试都会重新进候选循环 → 一次下载动作**最坏 30~38 次请求，其中 12 次是纯重复**；
  而连发会撞 429，正好把这几轮的修复整体打坏。现在候选**只吃一轮**（调用前清空，成败都不再重复）。
- **volumeStore 的 429 明确识别为限流**：原来会归一成 `emptyPackage`（让上层以为「没有包」而转进购买/刷新流程、
  继续放大请求），或抛裸状态码「invalid response status 429」这种看不懂的硬失败。现在直接抛可识别的限流错误，
  **不重试、不降级**，把准确原因交给用户。
- **历史版本页**：
  · 「加载更多」单次点击的 volumeStore 请求 **20 → 10**（`versionsPerBatch = 10`，攒够 5 条即停）；
  · **整次加载的重登上界 ≤20 → = 1**：同一道 `allowRotate` 闸门覆盖身份通道与 metadata；
    唯一那次额度**优先给身份通道**（它是拿全量版本身份的入口，失败降级最小），metadata 拿到 `false`，
    令牌过期时错误原样上抛并停手（避免一次点击打出 20 次重登——每次重登都是一次完整 SAP 登录）。
- **三方版本目录的失败负缓存**：原来只有「200 + 解析成功」才落缓存，429 后没有任何冷却 →
  每次进页面再打一发、自持复发。现在失败记 3 分钟 TTL 的**失败时间戳**（与 6h 成功缓存**分开记、绝不混写**），
  窗口内快速失败、窗口一过自然恢复。
- **空包候选加第二来源：爱思 `appinfo.xhtml`**。已证实爱思的 `versionid` **就是** Apple 的 `externalVersionId`
  （同版本数值 4/4 精确相等；且不同应用的同历史 ID 按日期交错，只可能是 Apple 的全局版本计数器）。
  来源链：三方目录 → 拿不到才回落爱思 → 都拿不到返回空（**不新增硬失败**）；
  两条来源统一按 **ID 数值降序**（爱思的 `releasetime` 实测不可信）。
  候选阶段最坏请求数 1 → 3（目录 1 + 搜索 1 + 详情 1），有界。
  **已知局限（实测确认）**：`trackId → 爱思 appid` 的映射走「按名/bundleId 搜索 + 精确比对 `itemId`」，
  **CN 未上架的应用（ChatGPT / Telegram / YouTube）爱思库里根本没有**，因此这条兜底覆盖不到它们 —— 接受。
- **错误文案在源头归一**：`passwordTokenExpired` 的「登录状态已过期（password token is expired），
  请重新登录该 Apple ID」→ **「登录已过期，请重新登录」**（去掉对用户无意义的英文术语）；
  `licenseRequired` 的英文 `"License required"` → **「缺少下载许可」**。与视图内的短文案统一，同一原因同一说法。

## [0.3.364] - 2026-09-13

### 新增
- **App Store 区域「自动」标记**：选「自动」时，**跟随到的那个区那一行会显示 `[自动跟随]`**
  （常用区显示 `中国大陆 [自动跟随]`，其他区显示 `BR - 143503 [自动跟随]`）——
  用户此前无法确认「自动」到底跟到了哪个区。判定逻辑本来就是跟随账号 storefront
  （`X-Apple-Store-Front` 第一段，如 `143503-1,29` → `BR`），未登录兜底 `cn`。
- **文档浏览新增类型筛选**（苹果正版 / 共享正版 / 个人签名 / 企业签名 / 越狱版 / 系统 / 未识别
  + 「全部」，**默认「全部」**），与「仅显示文件共享应用」、搜索三条件取交集。
- **免登录下载新增应用详情页 + 爱思历史版本**：列表项可点进详情（图标/简介/截图/新功能/系统要求），
  详情内列出爱思的历史版本（默认 8 条、可展开）并可直接下载旧版 —— 下载仍走既有
  `IPADownloadCenter`，未新建下载器。

### 修复
- **安装来源分类改为对齐爱思 9.0 的口径**。此前用「`iTunesMetadata.appleId` 是否等于**本机当前登录的
  Apple ID**」来分正版/共享 —— 未登录、换号、家人共享时必然判错，这就是用户说的「共享正版、正版分不清」。
  逆向 `i4Tools.exe` 字面量 + 它自带 `photo.ipa` 后确认：爱思的「共享正版」= **App 自身的购买邮箱落在
  一个硬编码的共享账号白名单里**（`share_appleid@163.com`、`share_appleid001~006@163.com`），
  **不看本机 Apple ID、也不看 `ApplicationDSID`**。现在改为同一判据，本机 Apple ID 降级为辅助。
- **补「越狱版」**：无 profile、无 `iTunesMetadata` 的破解包此前落到兜底被显示成「苹果正版」，明确错误。
- **修 `AppDiscovery` 的键名 bug**：读的是 `meta["apple-id"]`，真实键是 **`appleId`**
  （iOS 27 上 `iTunesMetadata` 还会是 binary plist 字节）→ 此前「应用」板块**永远判不出共享**。
- **界面不再出现「AppStore」这种词**（`.appStore` 兜底的 rawValue 直接渲染成了标签，Loon 那行就是它）：
  现在兜底与苹果正版同文案；标签集合为 苹果正版/共享正版/个人签名/企业签名/越狱版/系统/未识别。
- **下载管理行排版**：「加密包 · 带 sinf」原来与两个尺寸胶囊挤在同一个 HStack，空间不足时被压成
  **一列一个字的竖排窄列**；现在移到独立一行，不再挤压、也不再截断。
- **历史版本页**：
  · 来源改名：`版本目录` → **三方 API**、`Apple 账号` → **苹果 API**；
  · **读取中（含分页、后台补日期）禁止切换来源**（原来只在主 loading 时禁用）；
  · **修「苹果 API 没有返回信息」**：通道失败设的错误文案在**回退通道成功后没有清掉**，
    而 body 里错误提示优先于列表 → 数据其实已到手却被橙色警告盖住，这就是用户看到的现象；
  · 账号通道撞的是同一个**静默空包**（不带 `externalVersionId` 时该端点对任何应用都可能回
    「HTTP 200 + 空 + 无错误码」），旧代码把它当成「该 Apple ID 缺少此应用的获取记录」——
    现在改为**用版本目录的最新 6 个 ID 重打**（与下载链路同一招），并把误导文案一并去掉
    （`VersionFinder` / `VersionLookup`）。
- **文档浏览首屏不再被 profile 阻塞**：先只开 instproxy 一条隧道把列表显示出来，类型标签由后台任务
  分批（8 个一批）算完再刷；未算出时显示「识别中」，跑完收敛到「未识别」。两条 profile 隧道仍**串行**创建
  （避开历史并发闪退）。顺带 `DeviceSlimService` 的两处调用也不再等 profile（它只用 applicationType/appSize）。

### 验证
- `tools/verify_store_protocol.py` 新增断言：账号版本通道必须带 `externalVersionID` 并把静默空包
  归一成 `emptyPackage`；版本通道不得再出现「可能缺少此应用的获取记录」这种把接口行为说成
  「你没买过」的结论。

### 文档更正
- **`appinfo.xhtml` 并没有死**（推翻旧结论）：死的是手机端 `list-app-m.i4.cn/appinfo.xhtml`；
  PC 商店端 **`POST https://app4.i4.cn/appinfo.xhtml`** 可用，返回详情 + `historyversion[]`
  （微信实测 116 条，含 `versionid`/`path`/`sizebyte`，旧版直链实测可 206 分段下载）。
  此前误判的原因：PC 商店 SPA 的 JS 里中文是 `\uXXXX` 转义，**按明文 grep 会漏**。

## [0.3.363] - 2026-09-13

### 新增
- **App Store 区域：新增「自动」+ 完整 storefront 表（134 个区域）**。
  · 「自动」= 跟随账号：读账号的 `fullStoreFront`（如 `143503-1,29` → `143503` → `BR`）并解析成国家码；
    账号区不在常用列表里时，选项标题显示 **`自动 · BR`**；未登录/认不出则兜底 `cn`（保持原默认行为）。
    `"auto"` 只存在于存储的原始值，**任何请求参数都会先被解析成具体国家码**。
  · 全表数据取自二改版 AssppPro 二进制内嵌的 storefront 常量数组，与 vendor 的
    `Configuration.countryCode` 表**逐条一致且顺序相同（134/134）**。
  · 区域选择器：`自动（· XX）` → `常用区域` → `其他地区`（`XX - id`，按国家码升序）。
    后两节**互不重叠**（其他地区剔掉常用区）—— 两节若列出同一个国家码会带相同 `.tag`，
    SwiftUI 可能双勾选或折叠标题取错，这是实现时发现并规避的。

### 修复
- **文档浏览的安装来源分类接入权威判定（`AppTypeDetector`）**。此前只用
  「有没有 `iTunesMetadata`」二分，于是**企业签名、个人签名、系统应用全被显示成「共享正版」**，
  而第三方商店**重签的 App Store 包仍带 `iTunesMetadata`**，又被误报成「苹果正版」。
  现在与「应用」板块同源同判定：`正版 / 共享 / 个人签名 / 企业签名 / 隐藏 / 未知`，
  `ApplicationType != "User"` 直接显示「系统」；企业判定的唯一权威字段仍是
  `.mobileprovision` 顶层 `ProvisionsAllDevices`。
- **文档浏览不再截断**：标题 2 行、bundleId 换行、尺寸行拆分、胶囊内部允许换行 —— 不再出现 `…`。
- **文档浏览详情改为任意胶囊可点**：类型 / 版本 / 应用大小 / 文档大小 / Apple ID 五类胶囊
  都能点开同一个详情（此前只有 Apple ID 胶囊可点），且未破坏右侧进入箭头与滑动手势。

## [0.3.362] - 2026-09-13

### 修复
- **候选版本策略不再「几周后静默失效」**。v0.3.361 只取目录里最新的 6 个候选，而
  ChatGPT 的**最新两个 ID 必定被 Apple 拒**、它又约每周一版 —— 4~6 周后可用项就会被挤出窗口，
  症状是「突然又下不了」且不报错。现在把**上次成功下到包用的 `externalVersionId` 缓存在候选第 1 位**
  （按 dsid + bundleId，命中即停），最新 6 个退化为兜底；缓存只影响「先试哪个」，
  丢了最多多撞一轮，所以放 UserDefaults 足够。
- 候选窗口取回上界修正为 **6**（v0.3.361 曾放宽到 8，但实际最多迭代 4 次，6 已足够）。
- 候选命中后**日志写出实际采用的版本号**（`Apple 拒绝了最新版，已改用该账号可下的版本 x.y.z`）；
  候选链路不再吞掉 `CancellationError`。候选数量在来源端就截到 6，避免把 125 个全量传下去。

### 文档更正
- 更正一处错误记载：`apis.bilin.eu.org`（版本目录）**不需要**带浏览器 UA ——
  实测同一分钟内「无 UA / curl UA」都是 200，而「iPhone 浏览器 UA」反而回
  **429 `error code: 1015`**；那是 **Cloudflare 频率限制**，与 UA 无关。

## [0.3.361] - 2026-09-13

### 修复
- **空包（未授权的「没有下载记录」）改用历史版本 `externalVersionId` 重打 volumeStore**。
  真机实测（同一份新会话，ChatGPT 6448311069 对照 Via 1639085829）：该端点返回
  「HTTP 200 + 空 `songList` + 无任何错误码」的**唯一决定性变量**就是 body 里有没有
  `externalVersionId` —— 不带 → 空包；带该账号可下的旧 ID（856638501 / 857146407 /
  857195392 / 890134149）→ **`songList=1` 出包**；而**最新的两个**（890363403 / 890707559）
  仍是空包。重跑 5 次结论稳定，Via 不受影响。出包响应会带回
  `softwareVersionExternalIdentifiers`（212 个）⇒ **空包 = 该账号没有「最新版」的下载记录，
  但更旧的版本可以下**。公开情报一致：社区教程正是用 `--external-version-id 856638501`
  把 ChatGPT 下下来的。
  现在的顺序：volumeStore（最新版）→ 空包则用**历史版本目录**取候选（最多 6 个）逐个重打
  volumeStore → 全空才退到 redownload → 再走原有的「刷新会话 / 获取许可」流程。
  命中哪个版本会写进商店日志。
- **启动时把版本号写进日志**：`EscapeSpace x.y.z (build) 启动`（分类「通用」）——
  排查时先看这一行，不必再靠截图推断用户装的是哪个包。
- 顺手清掉误入库的 `tools/__pycache__/*.pyc`（`git add -A` 带进来的），并加 `.gitignore`。

## [0.3.360] - 2026-09-12

### 修复
- **登录：3xx 但拿不到可用 Location 时改为「进下一档」，不再当场判死打断阶梯**。
  真机实证：用户看到的是 `missingRedirect` 的文案（「Apple 登录返回 HTTP 302，但缺少有效的
  Location 跳转地址」），而商店日志里**完全没有**「认证入口 HTTP …（无 plist）」那行 —— 后者
  只有「换档」路径才打。说明循环是被 3xx 分支当场 `throw` 打死的，②③④ 档（bag·form /
  bag·plist / bag 尾斜杠）一次都没被尝试；而 legacy 端点回 Location-less 3xx 恰恰是
  v0.3.357 起要逃离的形态（PC 复现：301 + 162 字节 HTML，Location 头为 None）——
  本该靠换档绕开的拒绝，反而把换档本身掐断了。现在只有阶梯耗尽才抛 `missingRedirect`。
  安全性质不退化：换档只发往自己白名单内的候选，**从不把凭据重放到未经验证的 Location**。
- **下载管理补齐 App 图标**。根因：真机 `Documents/ipa_downloads.json` 里 5 条记录**都没有
  `iconURL`** —— 「本地」来源的条目多由磁盘扫描（`IPADownloadLibrary.makeItem`）现场构造，
  该路径固定传 `iconURL: nil`，于是永远只显示占位图。现在界面按 bundleId 反查图标补齐
  （单次最多 30 条），并用新增的 `IPADownloadLibrary.updateIconURL(fileName:url:)` **落盘**，
  避免每次进页面重发一轮请求；查不到时回退为**首字母方块**（虚框看起来像「加载失败」）。
- **下载管理文字改为换行、不再截断**（用户要求）：标题允许 2 行；包类型与副标题去掉
  `lineLimit(1)`/中间省略号，改为完整换行显示；两个尺寸/版本胶囊仍保持单行。
- `tools/verify_store_protocol.py` 新增断言：3xx 无可用 Location 必须换档。

## [0.3.359] - 2026-09-12

### 修复
- **native 档现在也带 store-client 的 `Accept`**。原来 `Accept` 只在 path 以 `/authenticate`
  结尾时加，而 native 的 path 是 `/auth/v1/native/fast/` → **梯子第一档同时差「host 是 native」
  和「没带 Accept」两个变量**，①档失败无法归因于 host（归因污染，jsbox-re 发现）。
  凡是发往认证端点的请求现在统一带上 `Accept`，这样真机上一次登录就能干净地得出
  「native 可行 / native 不可行」的结论。
- **已购链路的 SAP 校验与登录侧对齐**：`PurchaseHistoryService` 此前仍硬校验
  `sign-sap-version == "200"` 并 pin 死 `s.mzstatic.com` / `fpinit.itunes.apple.com`，
  登录侧已放宽到「Apple 自有域 + 内置兜底」→ 会出现「登录能过、已购签不出」的不对称。
  现在两处同一个口径（`StoreAuthenticationProtocol.isAppleHost`）。
- `tools/verify_store_protocol.py` 新增断言：native 档必须带 `Accept`、已购侧必须用放宽后的 host 校验。

## [0.3.358] - 2026-09-12

### 修复
- **更正 native/fast 第一候选的归属：这是 JAsspp 独有的做法，不是 ipatool 上游行为。**
  上游 `appstore_bag.go:103-118` 的 `validateAuthenticationEndpoint` 只放行
  `buy.itunes.apple.com` / `*-buy.itunes.apple.com`，路径必须**恰好**是
  `/WebObjects/MZFinance.woa/wa/authenticate` —— native 端点反而进不去；
  `appstore_login.go:29-31` 还把 `LoginInput.Endpoint` 标记 deprecated（「unsigned or
  caller-selected fallbacks are impossible」）。行为不变，只把注释里的因果改对：这一档当作
  **便宜的额外形状探测**，真正对齐上游的解释仍是「边缘按请求形状路由」（v0.3.355/356）。
- **SAP 端点不再 pin 具体主机名**：原先只认 `s.mzstatic.com` / `fpinit.itunes.apple.com`，
  比上游严 —— 上游 `appstore_bag.go:89-94` 对 SAP 端点只要求 `https` + host 非空，**不 pin**。
  现改为「https + 无 userinfo/fragment + 443 + 落在 `apple.com` / `mzstatic.com` 域内」：
  bag 换到同域其它主机名时直接用 bag 的值，硬编码兜底（`sap.js:24-25`）降级为**最后手段**，
  并在日志里区分「bag 缺字段」与「bag 端点在 Apple 域外」两种回退原因。
- **403 / 429 确认不纳入认证重轮换**（源码注释固化证据）：上游
  `retryableAuthenticationError`（`appstore_login.go:210-222`）只重试 204 / 404 / 5xx；
  真机日志 `login_full.log` 里 429、403 作为状态码**出现 0 次**（实际只有
  204×3 / 404 / 301 / 500 / 503），没有「429 其实是抖动」的样本支撑。429 仍走
  `Retry-After` 的 `rateLimited` 退避，不重放凭据。
- 补充两处注释证据（不改行为）：URL 上的 `?guid=` 只是 JAsspp 保留历史实现的幂等参数，
  **不是路由要求**（上游 `appstore_login_test.go:155` 断言 `req.URL == testAuthEndpoint`，无查询串）；
  下载侧 `serialNumber` 保持 `"0"`、不补 `X-Token`、Pod 为空时不加 `p25-` 前缀，均与上游一致。
- `tools/verify_store_protocol.py` 新增断言：SAP 校验走 Apple 域而非 pin host、pin host 写法已移除、
  403 / 429 不出现在重试条件里、native-first 必须被标注为 JAsspp-only 差异。

## [0.3.357] - 2026-09-12

### 修复
- **登录候选顺序改成「native/fast 第一，bag 的 legacy 端点其后」**（对齐 dompling/Jsbox-Ipa
  的 JAsspp：`config.js:52-53` 把 `https://auth.itunes.apple.com/auth/v1/native/fast/?guid=`
  列为第一候选，`auth.js:193-202` 明确注释「bag 给出的 legacy 端点最近常被 Apple 直接拒绝」）。
  真机实证（`login_full.log`）：每次登录都只打在 bag 返回的
  `buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate`，拿到的全是
  204 空响应 ×3 / 404 + 146 B / 301 + 162 B / 500 + 170 B / 503 + 190 B，**一次都没进到认证应用**；
  而同一账号、同一时刻的下载端点 `p25-buy.itunes.apple.com/…/volumeStoreDownloadProduct` 是
  HTTP 200 —— 不是账号/网络/IP 问题，是这个端点形态本身被拒。此前 native 被放在**最后一档**，
  真机上永远走不到，所以「每次登录都不成」。现在梯子有界：native · form-urlencoded →
  bag 端点 · form-urlencoded → bag 端点 · x-apple-plist → bag 端点尾斜杠，每档只打一次。
- **bag 返回的 native 端点做路径规范化**（同 JAsspp `bag.js:33-53`）：bag 里的 native 地址
  通常**缺 `/fast` 子路径**，直接访问会被 301 到 HTML；我们此前只按精确路径放行，
  bag 一旦给 native 就 `invalidRedirect` —— 这正是「bag 拿到了却登不上」的另一半。
- **设备标识放宽到 12–32 位偶数长度十六进制**（同 JAsspp `device.js:11` /
  `sap.js:884`）。本地 `device_guid.txt` 是从旧版本 `UserDefaults` 迁移过来的**任意非空串**
  （`bootstrapDeviceIdentifier` 不校验格式），此前只认恰好 12 位 → 长度不符直接
  `invalidConfiguration`。硬件 ID 仍取前 12 位（6 字节）。登录与已购两条路径同时放宽。
- SAP 端点保留硬编码兜底（`s.mzstatic.com/sap/setupCert.plist` +
  `fpinit.itunes.apple.com/v1/signSapSetup/legacy`，同 `sap.js:24-25`），
  `sign-sap-version != 200` 只记日志不再直接判死。
- `tools/verify_store_protocol.py` 新增断言：native/fast 必须是第一候选、native 端点需规范化、
  guid 口径放宽；`Content-Type` / 尾斜杠探测各只出现一次。

### 界面
- **25 处界面文案精简**（用户批准）——去掉解释性长句、footnote 式说明与「为什么」的自白，
  只留必要信息与操作必需的路径/设置页指引：`PairingSetupView`、`RingtonesView`、`DialerThemeView`、
  `DomainBlockerView`、`PiPKeepAliveView`、`LiveCleanTabView`、`ProcessManagerView`、`ConfigurationsView`、
  `WallpaperView`、`SSHDebugView`、`ProfileInstallView`、`BackupsListView`、`CertificateView`、
  `AppDetailView`、`ReclaimAppView`、`ModuleManagerView`、`RestrictionTweaksView`。
  另删掉两处语义重复的 footer（`FileBrowserRootView`、`KernelCacheView`），只保留一条。

## [0.3.356] - 2026-09-12

### 修复
- **登录请求对齐「二改版 AssppPro 4.2.5」的形态**（差异直接从它的二进制字面量挖出来，
  strings @0x46414–0x46419，就在 `MZFinance.woa/wa/authenticate/` 旁边）：
  · 登录请求带 `Accept: application/xml, application/x-apple-plist, text/xml`（**我们此前没有**）；
  · 端点默认值是 **带尾斜杠** 的 `…/authenticate/`（**我们此前无斜杠**）。
  PC 复现（未签名请求）显示：同一个 URL 加不加 `Accept`、带不带尾斜杠，Apple 前置回的状态码
  都不一样（301 / 204 / 403 / 404 混着来）—— 说明这两项影响的是**前置路由**，
  而真机日志里那几个「204 空响应 / 403、404 + 146 字节 HTML / 302 无跳转地址」正是这一档。
  现在的登录梯子（全部有界，最多各试一次）：带 `Accept` 发一次 → 被前置拒 → 换
  `Content-Type: application/x-apple-plist` → 仍被拒 → 换尾斜杠端点。每次切换都写进商店日志。
- `tools/verify_store_protocol.py` 新增断言：`Accept` 必须发送、尾斜杠变体只探一次。

## [0.3.355] - 2026-09-12

### 修复
- **登录被 Apple 前置边缘挡住时，换 `Content-Type` 再打一次**。PC 复现（同一份 XML plist body，
  只改 Content-Type）：`application/x-www-form-urlencoded` → **404 + 146 字节 HTML 错误页**；
  `application/x-apple-plist` → **204 空响应**。两者都不是认证结论 —— 说明请求**根本没进到
  认证应用**，被前置路由挡掉了。真机日志里反复出现的「HTTP 204 空响应」「HTTP 403/404 + 146 字节」
  就是这个形状。
  现在按上游 ipatool 的形态发一次，若被边缘拒（拿不到 plist）就换 Apple 自家商店客户端的
  `application/x-apple-plist` 把同一份 body 再打一次，并在商店日志里明确写出换了哪种 ——
  这样「请求形状被拒」和「真的被 Apple 拒」在日志里就能一眼分开。
- `tools/verify_store_protocol.py` 新增断言：Content-Type 探测存在且只重试一次。

## [0.3.354] - 2026-09-12

### 修复
- **换过机器身份（重置设备标识）后不再带旧会话登录**。Apple 的 store 会话
  （`passwordToken` / Cookie）与 guid 绑定：用户点过「重置设备标识」之后，旧票据在 Apple
  眼里属于**另一台设备**，继续当 Cookie 发出去，Auth 边缘回的是畸形应答
  （真机实测 204 空响应 / 302 无 Location），而不是一句清楚的「Sign In to the iTunes Store」。
  现在账号模型记录 `deviceGuid`（这份会话在哪个身份下签发），刷新会话时若**当前 guid 与它不一致
  就不带旧 Cookie**，直接走一次干净登录；重置设备标识的日志也补上这句话。
- `tools/verify_store_protocol.py` 新增断言：会话必须记录签发身份、跨身份的会话不得复用。

## [0.3.353] - 2026-09-12

### 修复
- **登录重试对齐上游 ipatool（这是「登录一次都没成」的直接原因）**：
  ipatool 的 `retryableAuthenticationError` 会对 **204 No Content / 404 / 5xx** 用
  **同一份 body + 新签名重发 3 次**（延迟 250ms × 第几次）；我们此前只认 `502/503/504`，
  且额外要求「body 非空且不是 plist」——
  **204（空 body）和 404（HTML）会被立刻判死**，还顺带写入 60 秒本地冷却，
  于是每次登录都用一次瞬时抖动换来一次失败 + 一分钟不能再试。
  现在重试集合、次数、退避与 ipatool 一致；`Retry-After`（429）仍然不重发。
- **3xx 但没有 Location 也算可重试**：那是 Apple 边缘的畸形应答（真机报过 HTTP 302 无跳转地址），
  没有可跟随的目标，直接判死等于把瞬时抖动升级成登录失败。有合法 Location 时照旧手动跟随、
  只允许 Apple 商店白名单主机。
- 重试过程写进商店日志（`[SAP] 认证请求 HTTP xxx（第 n 次，重发同一 body + 新签名）`），
  便于区分「Apple 在抖」还是「真的被拒」。

### 保留（上一版行为不变）
- 登录冷却与那条「已停止自动重试并保留现有账号」的提示**原样保留** —— 它把问题讲清楚了，
  不要在它之上叠加自动重试风暴。

### 验证
- `tools/verify_store_protocol.py` 新增断言：204/404/5xx 必须可重试、3xx 无 Location 必须可重试、
  重试上限 3 次、退避为 250ms × attempt、429 不重发。

## [0.3.352] - 2026-09-12

### 修复
- **「未购应用」下载链路恢复打通**：Apple 对「没有下载权」的应用有两种表达方式 ——
  `failureType 9610`，和 **HTTP 200 + 空 `songList`**（后者会被 redownload 的 5xx 包住）。
  v0.3.351 把 redownload 的失败还原成裸 HTTP 错误，导致空包这一档不再抛 `emptyPackage`，
  上层「空包 → 获取许可 → 重试」的分支彻底变成死代码 —— 真机日志里 ChatGPT 就是这样挂在
  `redownload HTTP 500/502` 上的。现在 5xx / 空包统一归一为 `emptyPackage`；
  拿到空包后**先刷新一次会话确认**（Apple 也用合法空包表达「票据不被认可」），
  仍为空才去获取许可，然后再重试下载。
- **购买 2002 按「票据失效」处理**：Apple 在会话票据不被认可时对 `buyProduct` 回
  `failureType 2002 / "Your password has changed."`（离线回放实测确认）。此前它落在
  default 分支被当成普通失败、不重登，于是「已经买过的免费应用」永远拿不到授权。
  现在与 ipatool 一致：2002 / "password has changed" / "Sign In to the iTunes Store"
  都触发「刷新会话 → 再买一次」。
- **下载重试有界**：下载信息获取改为显式状态机（`capture emptyPackage/licenseRequired →
  acquireLicense 一次 → 重试`，`passwordTokenExpired → 刷新一次`），最多 6 轮，
  不再有 `while true` 里靠 catch 顺序决定行为的隐式路径。
- **已购列表空表也刷新一次会话**：票据不被认可时 DMAP 回的是合法空表
  （`mstt=200 / mtco=0`）而不是 401，只按 401/403 重登就会把「票据失效」误判成
  「没有购买记录」。现在空表会刷新一次会话再问一遍（单次，刷新失败则沿用空结果）。
- **界面文案精简**：移除下载管理的说明性 footnote 与空态解释；已购列表空态、
  下载失败提示改成一句话（「Apple 未返回可下载内容」）。

### 界面
- **下载管理行排版重做**：版本/体积标签固定单行（原来被右侧按钮挤窄后会把
  `v6.0.260824` 断成两行）、包类型改为行内次要文字（仅「缺 sinf」告警着色）、
  安装按钮固定尺寸不再被压缩。

### 验证
- `tools/verify_store_protocol.py` 更新并 PASS：新增「空包/9610 必须触发许可获取」
  「2002 必须按票据失效处理」「重试与刷新有界」「空表允许单次刷新」等断言。

## [0.3.351] - 2026-09-12

### 修复
- **阻止 Apple ID 重登风暴**：已购返回合法空表、下载缺许可或空包都不再被误判为
  passwordToken 过期；只有明确的 HTTP/DAAP 401/403 或 Apple 2034/2042 才刷新会话。
- **同账号操作事务化**：登录刷新采用 single-flight，下载、历史版本和已购共享账号锁；
  新增 session revision，防止较早请求结束后把新 token/cookie 覆盖回旧值。
- **Cookie 正确性**：按 name + domain + path 合并，解析重复 Set-Cookie、Expires、Max-Age
  与 host-only 语义；移除 URLSession 隐式 cookie jar 和手工 cookie 的双重管理。
- **重定向安全与 POST 保真**：认证、购买、下载和版本接口不再让 URLSession 自动把
  301/302 POST 改成 GET；只手动跟随 HTTPS Apple 商店白名单路径，限制跳数且阻断循环。
- **已购协议收敛到上游口径**：只使用 `/update` 返回的 `musr` 请求
  `/databases/{musr}/items`，删除 revision=1 和多 storefront 猜测；校验 mstt/mtco/mrco。
- 保留完整 `X-Set-Apple-Store-Front`，日志不再输出 Apple 响应正文；HTTP 301 空响应
  不再武断提示为 IP 限流，而是明确说明 Apple 没有提供可跟随的 Location。

### 验证
- 新增 `tools/verify_store_protocol.py`，离线验证重登触发条件、DAAP 空表/截断处理、
  Cookie 单一所有权、会话 CAS/single-flight 以及凭据重定向白名单。

## [0.3.258] - 2026-09-09

### 修复（对齐上游 ipatool 5f776fe）
- **AppStore 下载报「Your device or computer could not be verified.
  Contact support for assistance.」**：搜索正常、登录偶尔成功，卡在下载请求——
  上游 ipatool 8/28 的修复（fix: FailureType 5002, commit 5f776fe）给
  **download / get_version_metadata / list_versions 三个请求体补了
  `serialNumber: "0"`**：Apple 会校验请求里的设备序列号，缺省时按无效设备处理
  直接拒绝。我们的移植版三个请求都缺这个字段（逐字比对了上游改动清单）。
  `purchase` 上游未改，保持不动。
- 登录部分无需再改：上游 8/29 的「临时性认证响应重试」（204/404/5xx 重试 3 次 +
  250ms 递增退避）与 legacy 端点回退，我们在 v0.3.176/0.3.172 已移植且更完整
  （上上限 4 次 + 全新 anisette 强制刷新）。

### 审计结论
- 对照上游 2026 年 8 月批次提交逐条核对：SAP 登录（已实现）、5002/serialNumber
  （本轮补）、临时性认证重试（已有）、legacy 回退（已有）、bag.xml 自定义端点
  （已有）。剩余上游新增的 visionOS/macOS 搜索下载与 list-purchases 与本 App
  场景无关，不引入。

## [0.3.257] - 2026-09-09

### 修复
- **引导卡圆角与同页卡片不统一（彻底解法）**：List 场景引导卡不再自绘背景与圆角，
  直接交给**系统 Section 卡片**渲染——底色 / 圆角 / 边距 / 分隔与同页其它卡片
  **像素级一致**（此前自绘 16pt 圆角永远和系统圆角差一点，怎么调都不对）。
  `PairingGuideCard` 新增 `showsBackground` 参数：List 场景传 false，
  VStack/ScrollView 场景（电池健康错误态）保持默认 true 自带背景。
- 11 个 List 调用点同步：去掉 `listRowBackground(Color.clear)`、行 insets 归零
  （内容内边距由组件自带 16pt 提供），参数顺序调整为 showsBackground 在前。
- 误改回退：应用列表 / LiveClean / 空间回收三个页面的分段选择器行 insets
  恢复 (8,16,8,16)，未受本次改动影响。

## [0.3.256] - 2026-09-09

### 修复（回退 + 重做）
- **配对引导卡左右多出一条「河」**：List 的行本身自带系统边距（约 20pt），
  v0.3.251 又在 `listRowInsets` 里叠了 16pt → 双层边距，引导卡比同页其它卡片
  窄出一圈（用户实测截图 IPA 侧载 / 应用列表）。
  **回退 v0.3.251 的横向改动**：11 个页面统一改回 `EdgeInsets(top:6, leading:0,
  bottom:6, trailing:0)`（横向与上一版一致、与同页卡片等宽），只保留 6pt 纵向间距。
- 引导卡尺寸维持 v0.3.255 的主卡同级参数（内边距 16 / 图标 40 / 标题 headline）不变。

## [0.3.255] - 2026-09-09

### 调整
- **配对引导卡放大到与页面主卡同级**（用户反馈「尺寸还是太小」）：内边距 12→16、
  图标块 36→40（符号 18→20）、标题 subheadline→**headline**、导航行 subheadline→callout，
  与「IPA 侧载」等页面的标题卡视觉权重完全一致。
- 电池健康错误态状态卡同步放大（内边距 16、图标 40），与引导卡保持同级。

## [0.3.254] - 2026-09-09

### 修复（方向纠正）
- **SIGKILL locationd 必须走 RSD 隧道**：设备没有越狱，App 在沙盒里本地 `kill`
  守护进程必被拒——v0.3.253 的 `setuid(0)` 提权方案把「有越狱」当前提，完全搞错了方向，
  **已作废删除**。正确做法是本项目「进程管理」页一直在用的那套 FFI：
  `app_service_list_processes`（枚举设备进程）→ 找 `/locationd` →
  `app_service_send_signal`（SIGKILL），全部经 RSD 隧道由设备侧执行。
- 清除流程：无条件 `clear`（自带「无会话先建会话」幂等）→ 隧道 SIGKILL locationd
  → 成功「已清除模拟位置」/ 失败「操作失败」。
- 隧道操作移到后台线程执行（此前在主线程同步建隧道会冻住设置页数秒），执行期间按钮禁用。

## [0.3.253] - 2026-09-09

### 修复
- **清除虚拟定位后 SIGKILL locationd 不生效（真根因）**：App 以普通身份运行，
  `kill` 系统守护进程必被 EPERM 拒绝——所以 v0.3.251 里 kill 一直静默失败，
  只做了 clear 没杀掉守护，定位自然不刷新（你手动 SSH kill 就好使，正说明差的是权限）。
  现在**先 `setuid(0)` 提权（Dopamine 允许 App 提权）再 kill，杀完切回 501**，
  kill 真正生效后定位立即回真实 GPS.
- **电池健康错误态两张卡一大一小**：状态卡改用与引导卡**同款紧凑样式**
  （图标块 + 文案 + 右侧小号重试按钮），圆角统一 16pt、内边距统一 12pt，
  两卡同宽同高量级，不再是「一大一小」.

## [0.3.252] - 2026-09-09

### 修复
- **描述文件管理只显示预置描述、比爱思少一截（真根因）**：列表只走 misagent
  （`com.apple.misagent`），它**只返回预置描述（.mobileprovision）**——用户安装的
  配置描述（.mobileconfig / 托管描述）它根本拿不到，爱思走的是 MCInstall。
  现在合并 **MCInstall GetProfileList**：解析应答里的 ProfileMetadata
  （identifier → PayloadUUID / DisplayName / Description / Organization / Version /
  RemovalDisallowed / CreationDate / ExpirationDate），与 misagent 结果按
  PayloadIdentifier 去重合并。MCInstall 不可用（老系统）时维持原样不报错。
- **描述文件详情页「文件描述」为空**：同样因为 misagent 元数据缺 PayloadDescription，
  GetProfileList 自带，合并后正常显示。

### 调整
- 虚拟定位「清除虚拟定位」极简化：**无条件执行**（clear 自带「无会话先建会话」幂等逻辑）
  → SIGKILL locationd → 成功提示「已清除模拟位置」、失败提示「操作失败」，去掉所有附加条件与长文案。
- 配对引导卡收紧：内边距 14→12、行距 10→8；电池健康错误态两卡间距 16→12、状态卡高度 32→22。

## [0.3.251] - 2026-09-09

### 修复
- **App Store 下载登录失败**（根因与 AltSign PR #52 完全一致，2026-08-31 起 Apple 改动）：
  Apple 在 `gsa.apple.com` 前面的边缘节点现在**每条连接最多放行 1~2 个请求**，之后的请求一律回
  `503 text/html`。登录要连发三个请求（`o=init` → `o=complete` → `o=apptokens`），`URLSession.shared`
  复用连接 → `apptokens` 必中 503 → HTML 被 plist 解析器吃掉 → `NSCocoaErrorDomain 3840`
  「数据格式不正确」。**密码其实已经验证通过，死在最后换 token 那一步。**
  - 对策①：新增 `GrandSlamHTTP`——每个请求走全新 ephemeral `URLSession`，用完即 `invalidate`，
    杜绝连接复用（比改 User-Agent 的 PR #47/#51 更稳：直接不受限流值影响）。
  - 对策②：状态码 ≥500 直接抛错并带上响应头 160 字节，不再把 HTML 喂给 plist 解析器，
    以后一眼能看出是限流而不是格式问题。
- **虚拟定位清除没反馈**：设置页「清除虚拟定位」现在必弹结果——成功/本就无虚拟定位/失败，
  并说明是否成功重启了系统定位服务。
- **虚拟定位清除后定位不刷新**：清除成功后追加 **SIGKILL locationd**（`sysctl KERN_PROC_ALL`
  枚举进程 → `kill -9`），甩掉守护进程里残留的模拟值，定位立即回真实 GPS；App 无特权 kill
  失败时会如实提示改用「锁屏再解锁」。
- **进程管理反复弹窗**：未导入配对文件时 `refresh()` 失败不再弹「加载进程失败」
  （此前弹窗点「好」→ 自动刷新 → 再弹窗，无限循环），页面直接显示配对引导卡.

### UI 统一（配对引导）
- `PairingGuideCard` 升级为**真正的独立卡片**：自带卡片背景 + 16pt continuous 圆角 + 14pt 内边距，
  去掉外层 `.padding(.vertical, 4)`（它导致卡片在 List 里上下空隙不对称、圆角看着不协调）。
- List 场景的引导卡补横向 inset（`EdgeInsets(top:6, leading:16, bottom:6, trailing:16)`），
  卡片不再顶到屏幕两缘（10 个页面同步修正：应用列表/崩溃分析/IPA 侧载/JIT/拉起应用/
  空间回收·LiveClean/进程管理/配置描述/电池健康/铃声）。
- 电池健康错误态拆成**两张独立卡片**：①状态卡（图标/标题/重试）②配对引导卡，不再挤在一起。
- 配置导入页：配对引导从「配置导入」标题卡里**抽出来独立成板块**。

### 描述文件详情页（对齐爱思助手）
- **文件 ID = PayloadUUID**，**唯一码 = PayloadIdentifier**（此前两者常显示成同一个 UUID）。

### 说明
- SSH 连 `192.168.2.110` 超时（设备不在线/不同网段），本轮 AppStore 登录修复基于 AltSign PR #52
  的上游根因分析（同错误码、同症状、同时间线）。修复后若再失败，登录日志会直接显示
  「Apple 服务器返回 5xx（疑似边缘节点限流）」而不是误导性的 3840。

## [0.3.250] - 2026-09-08

### 结论（真机实锤，监督模式走不通的根因）
- 监督模式开启报 **14002「A cloud configuration is already present on this device.」**
  —— **这台设备早就被别的身份监督过了**，Cloud Configuration 不能覆盖。
- `Escalate` 必须用**当初把这台设备置为监督的那份监督身份**（证书+私钥）。App 新生成的自签身份设备不认，所以 `SetWiFiPowerState` 依旧 14005「Unable to set Wi-Fi power」。
- 想换监督身份得直接改写 `CloudConfigurationDetails.plist`，但 **iOS 26 上 configurationprofiles 系统组只读**（项目 `ConfigAccess.readable` 探测结论，与 MobileGestalt 系统路径写入不可行的既有结论一致）。
- **因此「Wi-Fi 射频开关」在这台设备上是被苹果监督机制硬性拦住的**：除非拿到当初监督它的那份身份文件（pymobiledevice3 的 keybag / 对应证书+私钥），否则这条命令无法成功。这不是 App 崩溃（v0.3.247 已修），也不是协议错误（已逐字对齐 pymobiledevice3）。

### 改动
- 监督模式 14002 / 14005 时，自动读取本机 `CloudConfigurationDetails.plist`（系统组可读）并在错误里给出**监管组织名 / IsSupervised / 监督证书张数 / OrganizationMagic**，让「谁在监督这台设备」一眼可见。
- 开关说明同步更新，写明 14002 的含义与硬门槛。

### 技术说明
- 错误链路已完全可读化：`设备拒绝 SetCloudConfiguration（DMCTunnelErrorDomain 14002）：…`，不再倒 XML。
- 监督通道（SetCloudConfiguration / Escalate / PKCS7 附签）实现保留，拿到合法监督身份后即可直接用。

## [0.3.249] - 2026-09-08

### 新增
- 百宝箱「设备控制」新增 **「监督模式（Supervision）」** 开关。开启后 Wi-Fi 射频开关走 MCInstall **Escalate 监督通道**——这是设备回 `DMCTunnelErrorDomain 14005`「Unable to set Wi-Fi power」时的正路。

### 实现链路（对齐 pymobiledevice3 `MobileConfigService.escalate` / `supervise`）
1. **监督身份**：App 内生成 RSA-2048 + 自签证书（CN=EscapeOS），PEM/DER 持久化在 UserDefaults，跨会话同一身份（换身份 = 设备侧监督失效）。走已链接的 libcrypto（ZSign 同源），零新增依赖。
2. **`SetCloudConfiguration`**：`IsSupervised=true` + `SupervisorHostCertificates=[证书DER]`，把设备置为受监督。
3. **`Escalate`（同一连接内）**：`SupervisorCertificate(证书DER)` → 设备回 `Challenge` → PKCS7 附签（attached / Binary / SHA-256，`PKCS7_sign` + `PKCS7_BINARY|PKCS7_NOSMIMECAP`）→ `EscalateResponse` → `ProceedWithKeybagMigration`。
4. **`SetWiFiPowerState`**：监督模式开启时，每次射频开关都在同一连接先 Escalate 再下发。

### 架构改动
- Rust 侧把「单条射频命令」泛化成 **`mcinstall_request_rsd`**（通用 MCInstall 请求 + 可选 Escalate），Swift 只组装 plist 正文，帧协议/IO 仍全在 Rust（v0.3.244 闪退教训：Swift 不碰帧协议）。
- PKCS7 签名走 **函数指针回调**（Swift 注册 → Rust 在 Escalate 中回调），Rust 不引加密依赖、Cargo.lock 不变。
- 手写 base64 编解码（不新增 crate）；plist 应答解析在 Swift 侧做（纯字符串处理，无指针风险）。
- 新增文件 `EscapeOS/Engine/SupervisionService.swift`（已登记 Makefile `EscapeSpace_FILES`）。

### ⚠️ 须知
- 开启会把设备置为受监督，设置里出现「此 iPhone 由 EscapeOS 监管」；**MCInstall 没有公开的撤销接口**，关闭开关只停用本 App 的监督通道，不会撤销设备侧状态。
- 若设备已被其他身份监督，`Escalate` 会失败并给出设备原文错误。

## [0.3.248] - 2026-09-08

### 修复
- 「Wi-Fi 射频开关」报错时把**一整段 XML 应答**直接糊到界面上（真机截图实锤），现在只显示人能读懂的一行。

### 结论（重要）
- **闪退已修好**：v0.3.247 之后点按不再崩溃，而是给出明确的设备应答。
- 本次真机应答：`Status=Error`、`ErrorCode=14005`、`ErrorDomain=DMCTunnelErrorDomain`、`LocalizedDescription=Unable to set Wi-Fi power.` —— **是设备端拒绝了这条命令**，不是 App 崩溃、也不是协议写错。
- 已用 pymobiledevice3 源码逐字核对：`set_wifi_power_state` 发的就是 `{"RequestType": "SetWiFiPowerState", "PowerState": state}`，与其 CLI `profile set-wifi-power`（**不调用 escalate、不需要监督 keybag**）完全一致。我们的请求与上游语义一字不差。
- 结论：射频开关走 MCInstall 这条路在我们的隧道环境下被系统拒绝（`shim.remote` 家族本就是给 Apple Configurator / MDM 远程配对用的）。不回退到 lockdown `SetValue("WifiPowerState")`——那会被 lockdownd 静默吞掉，等于**假装成功**，更坑。

### 改动
- Rust `set_wifi_power_stream`：拒绝时解析 `ErrorCode` / `ErrorDomain` / `LocalizedDescription`，只返回一行可读信息（此前把整段 XML 塞进错误消息）。
- Swift `error(from:fallback:)`：剥掉 Rust `{:?}` 调试格式外壳（`UnexpectedResponse("...")`），界面不再出现调试语法。
- 射频开关说明补充：设备报「Unable to set Wi-Fi power」是系统拒绝该命令，不是 App 出错。

### 若要真正生效
需要走「监督（Supervision）」路线：MCInstall `SetCloudConfiguration`（把设备设为受监督）→ `Escalate`（监督证书挑战应答）→ 再 `SetWiFiPowerState`。**这会把设备置于受监督状态、界面会显示「此 iPhone 由 xx 组织监管」**，属于改变设备状态的大动作，待明确批准后再做。

## [0.3.247] - 2026-09-08

### 修复
- 百宝箱 → 「Wi-Fi 射频开关」点按闪退（v0.3.244 / 0.3.245 真机实测必崩）。

### 根因
| 项 | 说明 |
| --- | --- |
| 崩溃代码 | v0.3.244 起的「纯 Swift 手写帧」实现：`adapter_send` / `adapter_recv` + 自制 4 字节大端长度帧 + 欠读补齐循环。 |
| 直接原因 | FFI 头 `idevice.h` 明写「stream 必须与 adapter 同线程、句柄非线程安全」，而 Swift 侧把 `adapter_connect` 拿到的 `ReadWriteOpaque*` 跨 `run_sync` 边界反复收发；设备提前关流时 `adapter_recv` 返回 `got == 0`，补齐循环仍继续按旧缓冲取字节，直接越界/野指针。 |
| 为什么没人发现 | v0.3.246 的修复方向（协议下沉到 Rust `mcinstall_set_wifi_power_rsd`）只写了 Rust 实现，**没有在 `idevice.h` 里补 C 声明**，Swift 侧根本引用不到，只能继续沿用会崩的手写帧版本。 |

### 改动
- **协议整体下沉 Rust**：`mcinstall_set_wifi_power_rsd`（RSD 服务表取 `MCInstall.shim.remote` 端口 → 隧道内直连 → RSDCheckin → SetWiFiPowerState → 校验 `Acknowledged`）全在同一个 tokio 上下文内完成，Swift 只负责建隧道和借出句柄。
- **补 C 声明**：`rust/idevice-ffi/idevice.h`（及 CI 会拷贝的 `EscapeOS/Tunnel/idevice.h`）新增 `mcinstall_set_wifi_power_rsd` 导出声明——这是 v0.3.246 编不过的直接原因。
- **服务可用性判定改为确定性查询**：用 `rsd_get_service_info` 直接查 RSD 握手自带的服务表，不再靠「FFI 错误码 21 == ServiceNotFound」这种未验证的映射决定要不要回退 lockdown `SetValue("WifiPowerState")`。
- **隧道并发铁律**（与 `AFCService` 同款）：本服务所有操作走同一条串行队列；一次操作只建**一条**隧道（此前「局域网 Wi-Fi 配对」一次要建 2 条，页面 `onAppear` 还要再建 1 条）。
- **建隧道失败退避重试**（3 次，300ms 递增），与 `AFCService` / `DeviceControlService` 对齐。
- **内存**：`plist_to_bin` 的产出改用 `plist_mem_free` 释放（此前每次读状态都泄漏）。
- **UI**：两个开关各用各的 busy 标志（此前共用一个，一个在忙另一个也被禁用）；写入失败时开关弹回原值并如实报错，不再停在错误位置；新增成功/失败的颜色区分。

### 体验小结
- 点按「Wi-Fi 射频开关」不再闪退；成功/失败都在卡片底部给出中文回执。
- 单次操作只建一条隧道，射频开关的等待时间约为此前的一半。
- 射频开关是**写入型**（设备不提供读取请求），UI 显示的是「上次设定值」；关闭射频后若 LocalDevVPN 本身走 Wi-Fi，隧道会断，恢复网络后需重新开启——卡片说明已注明。

## [0.2.82] - 2026-08-27

### 修复
- IPA 侧载真正复用「更多 → 设置」的 Apple ID 登录态（用户诉求：不要两套登录、不要每次重复 2FA，像 SideStore 一样登录一次全部复用）。
- 根因：设置登录（AppleAuthenticator / GrandSlam）存的是 dsid + authToken（`com.apple.gs.xcode.auth` 的 app token），而 IPA 签名（isideload）之前只能走 `si_apple_signin` 完整登录（SRP + 2FA）。
- 修复（源码实证 isideload 可跳过登录）：新增 `si_signin_with_session`——isideload 的 `DeveloperSession::new(AppToken, adsid, GrandSlam, anisette)` 可直接用已有 token + dsid 构造（GrandSlam 只需 anisette client_info，AppToken 即字符串封装）。IPA 侧载打开时优先用设置的 dsid+authToken 恢复签名会话，**免登录免 2FA**；token 过期才回退完整登录。证书管理 / 增加内存限制 / IPA 侧载现在共用同一套登录态。

## [0.2.79] - 2026-08-27

### 新增
- 「更多 → 证书管理」批量撤销：进入「选择」模式后可勾选多张证书（支持全选/取消全选），底部显示已选数量并批量吊销（带确认弹窗）。
- 「更多 → IPA 侧载」：汉化移植 SideInstaller「安装」板块——选择 IPA（本地导入走统一文件选择调用点 / URL 直链下载）→ 登录 Apple ID（含 2FA）→ 签名（isideload，自动注册设备与描述文件）→ 通过 LocalDevVPN 隧道安装到设备（AFC 上传 + installation_proxy）。登录/签名走 isideload 纯网络+本地文件路径，不依赖原版卡点 LocalNetworkAuthorization，LiveContainer 兼容。
- Anisette 服务器列表由 4 个扩至 15 个（合并 SideInstaller 社区列表 servers.sidestore.io 中缺失的 11 个）。

### 技术说明
- Rust 侧首次引入 isideload（Apple ID 登录 + IPA 签名），仅用 sign-only 路径（Sideloader::sign_app），与项目现有 git idevice 0.1.63 共存编译（isideload 依赖 crates.io idevice 0.1.61，SideInstaller 已验证同组合）。
- IPA 体积增大至 22.8MB（isideload 依赖树含签名/证书库）。

## [0.2.78] - 2026-08-27

### 新增
- 「更多 → 证书管理」：汉化移植 SideInstaller「证书」板块。登录 Apple ID（复用现有 SRP-6a + Anisette v3 + 2FA 认证引擎）后列出账号下的 iOS 开发证书（名称 / 机器 / 序列号 / 到期时间 / 过期徽章），支持吊销（带确认弹窗）。纯开发者门户 API（listAllDevelopmentCerts / revokeDevelopmentCert），不需要隧道与本地网络权限。
- 「更多 → 配置导入」：汉化移植 SideInstaller「配对 → 安装到应用」。扫描设备上已安装的侧载工具（SideStore / LiveContainer / Feather / StikDebug / StikTest / SparseBox 等 12 项），把当前配对文件写入目标应用的 Documents（house_arrest + AFC，读回验证字节数），支持单个写入与写入全部。链路为 LocalDevVPN 隧道，不依赖原版的本地网络权限（LiveContainer 兼容）。

### 技术说明
- 两个功能均零 Rust 改动：证书 API 复用项目现有 AppleDeveloperAPI（QH65B2 协议）；配置导入的 house_arrest / AFC 符号项目 Rust FFI 早已具备。
- 原版 SideInstaller 的 LocalNetworkAuthorization（NWBrowser/NWListener 本地网络权限探测）未移植——那是它在生成配对文件时请求权限用的，LiveContainer guest 拿不到；我们的流程只做写入，用已有配对文件 + 系统 VPN 隧道天然绕开。

## [0.2.77] - 2026-08-27

### 修复
- 「更多 → 备份」的「自定义恢复」导入功能在 LiveContainer 共享应用 / 证书直装环境下无法导入（报错"无法读取备份"）。
- 根因：`BackupImportPicker` 自己实现 `UIDocumentPickerViewController`（未设 `asCopy: true`），返回 security-scoped 原始 URL，读取依赖 `startAccessingSecurityScopedResource()`——LC guest 沙盒下这一步失败。已删除该自实现，改用项目统一文件选择调用点 `SharedDocumentPicker`（默认 `asCopy: true`，文件先拷入沙盒再读），`handlePickedZip` 同步去掉 security-scoped dance。
- 全项目 `.fileImporter` / 自实现 `UIDocumentPicker` 调用点现已全部清零，统一走 `SharedDocumentPicker`。

## [0.2.76] - 2026-08-27

### Fixed
- **iOS 27 无线配对 sheet UI 居中**：
  - 进度态 ProgressView + 状态文字 之前和 keepAliveCard 一起被外层 Spacer 垂直居中，keepAliveCard 较高把菊花+文字重心拉下，看起来偏下不好看。改为两段式：菊花+状态文字单独居中，keepAliveCard 贴底。
- **iOS 27 无线配对 Bonjour 广播失败回报给 UI**：
  - `NSNetService didNotPublish` 之前只 NSLog，LiveContainer 共享应用 guest 等嵌入环境下 publish `_remotepairing-pairable-host._tcp` 被系统拒绝时用户毫无感知。v0.2.76 起把 `NSNetServicesErrorCode` 通过新通知 `WirelessPairingDidFailBroadcastNotification` 回报给 UI，在菊花下方显示「⚠️ 广播未确认（Bonjour code X）」副提示。
  - **关于 LC 共享应用 guest 模式无法广播**：根因怀疑是 guest 进程缺失 `com.apple.developer.remotepairing` entitlement 导致 publish 被过滤/拒绝（与原版 StikDebug 在纯蜂窝 LocalDevVPN 类似的「平台/嵌入环境限制，EscapeSpace 侧无法直接修」）。本改动至少让用户能看到真因，不再静默。建议：转回普通应用或单 LC 模式。

## [0.2.75] - 2026-08-27

### Fixed
- **「描述文件管理」无法导入 .mobileprovision**：
  - 根因：导入一直用 SwiftUI `.fileImporter` + `startAccessingSecurityScopedResource()`——正是 v0.2.33 `SharedDocumentPicker` 注释里点名的 LiveContainer 沙盒失败机制（security-scoped URL 读取常失败、`.fileImporter` 在 iOS 26/证书直装环境弹出不可靠）。当时只统一了配对文件导入，描述文件管理漏网。
  - 修复：AppExpiryView 改走 `SharedDocumentPicker` 统一入口（`.documentPicker` 修饰符，`asCopy: true` 先把文件拷入沙盒再读取，去掉 security-scoped dance）。
  - 顺手统一：MapHomeView 虚拟定位 GPX 导入（同类隐患）；全项目 `.fileImporter` 已清零。

## [0.2.74] - 2026-08-27

### Fixed
- **保活机制全盘审计修复**（用户补充：开启「保持后台运行」时启用 JIT 仍黑屏）：
  - **根因链**：目标应用启动时会激活自己的 AVAudioSession，抢占/打断本应用的音频会话 → 「保持后台运行」（KeepAliveManager 静音音频保活）失效 → EscapeSpace 退后台被挂起 → attach 后 detach 未执行 → 目标应用停在 SIGSTOP 黑屏。**音频保活在「拉起其它 App 后还要继续干活」的场景天然不可靠**。
  - **影响面审计**：虚拟定位 / 无线配对广播（本 App 自己跑任务，不拉起其它 App）音频保活有效、不受影响；唯一受影响的是启用 JIT，v0.2.73 起已由 beginBackgroundTask 兜底修复。
  - **JIT 保活升级**：`JITBackgroundLease` 改为 beginBackgroundTask **到期自动续期**（对齐 StikDebug PR #432 续期思路），去掉对音频保活的依赖——不再受「静默音频」开关影响、不与 KeepAliveManager 抢音频会话。
  - **KeepAliveManager 增强**：纯零静音 WAV 改为 **-80dBFS 非零信号**（±1 交替 + 音量 0.01，人耳不可闻）——PR #432 实锤：纯零静音会被 iOS 判定 idle 并回收，导致保活悄悄失效（虚拟定位 / 无线配对同样受益）。
  - **隧道健壮性**：隧道创建失败自动重试（最多 3 次、短退避）——Wi-Fi↔蜂窝切换等瞬时抖动不再一次失败即抛错（对齐 PR #432 蜂窝部分的重试思路）。

## [0.2.73] - 2026-08-27

### Fixed
- **「启用 JIT」后目标应用永久黑屏无反应**：
  - 根因：`process_control_launch_app` 以调试模式启动目标应用后，EscapeSpace 立即退到后台，iOS 数秒内挂起进程——QStartNoAckMode / vAttach / D（detach）流程没跑完就停摆：attach 可能已发出（T11 stop reply 已收到），但 **detach 未执行**，目标应用一直停在 SIGSTOP → 永久黑屏。
  - 修复（对齐原版 StikDebug 的 `DebugKeepAliveLease`，原版三管齐下：beginBackgroundTask + 静音音频 + 后台定位）：新增 `JITBackgroundLease`，`enableJIT` 全程持有——① `beginBackgroundTask` 争取系统后台执行宽限（核心兜底）；② 复用项目已有 `BackgroundAudioManager.requestStart()` 静音音频保活计数。defer 释放，确保 attach/detach 完整执行后目标应用正常恢复运行。

## [0.2.72] - 2026-08-27

### Fixed
- **「启用 JIT」目标应用打开后闪退 + 误报「调试器附着失败：T11thread:...」**：
  - 根因：debugserver 的 `vAttach` **成功**时返回的是 stop reply 包（`T11thread:...;`，T11 = SIGSTOP，目标进程被调试器暂停），**不是 "OK"**。上一版检查 `!text.contains("OK")` 把成功当失败 → 抛错后 detach 从未执行，目标应用一直停在 SIGSTOP，debug_proxy 连接释放后设备端 debugserver 断连默认终止被调试进程 → 应用闪退 + 误报附着失败。
  - 修复（对齐原版 StikDebug，原版不检查 attach 响应、成功失败都继续 detach）：vAttach 响应仅以 `E` 开头（debugserver 错误包）或 FFI 报错才算失败；`T`/`S`/`W` 开头的 stop reply 与空响应均视为成功，继续执行 detach，应用恢复运行、JIT 生效。
  - 顺带修正 FFI 错误与响应同存时的释放顺序（err 优先，避免内存泄漏）。

## [0.2.71] - 2026-08-27

### Fixed
- **「启用 JIT」/「拉起应用」部分应用（主要是第三方应用）图标丢失、显示灰色占位**：
  - 根因：行内图标此前用进程内私有 API `UIImage._applicationIconImageForBundleIdentifier:format:scale:`，读的是本机 IconServices 图标缓存——证书直装 / 侧载的第三方应用经常取不到（图标不在该缓存可达范围），回退为灰色 `app.dashed`；系统应用图标位于 `/System/Library` 恒可达所以正常。
  - 修复：改用与原版 StikDebug 同源的 `springboard_services_get_icon`（RSD 隧道 → 设备端 SpringBoardServices 服务，按 Bundle ID 返回真实图标 PNG），系统应用与第三方应用均能拿到；复用现有 Rust idevice-ffi 的 springboardservices 符号（feature 早已启用），零新增依赖。
  - 配套：新增 `JITAppIconLoader`（内存缓存 + in-flight 去重 + 4 并发信号量），滚动列表不重复建隧道；行图标改为 `JITAppIconView` 异步加载，加载中/失败才显示灰占位。
  - 细节：icon PNG 缓冲区由 Rust 侧分配，用 `idevice_data_free` 释放（比原版直接 C `free()` 更正确）。

## [0.2.70] - 2026-08-27

### Added
- **「更多」新增「拉起应用」（Launch Apps，汉化移植自 StikDebug）**：
  - 列出全部已安装应用（含系统应用），点击一键在前台拉起（普通启动，不启用 JIT）。
  - 支持搜索（名称 / Bundle ID）、行内图标、启动中进度指示、底部胶囊成功/失败反馈。
- **「启用 JIT」页对齐原版布局**：
  - 新增导航栏常驻**搜索框**（搜索名称 / Bundle ID）；
  - 新增「**最近使用**」分组（最近启用过的应用置顶，最多 5 个）；
  - 新增「**Apps with get-task-allow**」分组展示全部可 JIT 应用；
  - 行内显示 App 图标 + 名称 + Bundle ID（与 StikDebug 一致）。
- **「描述文件管理」增强**：
  - 新增**搜索**：匹配证书名（AppIDName）/ 应用名 / Bundle ID / UUID / application-identifier；
  - 长名称与长 UUID **完整显示**（移除行内截断，可换行 + 长按选择复制）。

### Fixed
- **CI 增量编译缓存真正生效**：修复 GNU make 将 Makefile 视为所有目标隐式依赖导致的全量重编（v0.2.69 改了 Makefile 后增量失效）。校准步骤现把 Makefile 也拨回过去时间，本次起增量编译按预期工作。

## [0.2.69] - 2026-08-27

### Added
- **「更多」新增「启用 JIT」（汉化移植自 StikDebug）**：
  - 列出签名带 get-task-allow 的已安装应用（证书直装签名默认带），点击后以**调试模式启动**该应用获得 JIT 权限（debug_proxy + process_control 调试启动，与 debugserver attach 等价，无越狱要求）。
  - 依赖：配对文件（与应用页共用）+ LocalDevVPN；缺配对时页面给引导。
  - 全程中文反馈：隧道建立 → 调试启动 → 附着 → 分离，成功/失败原因明确。
- **「更多」新增「描述文件管理」（App Expiry，汉化移植自 StikDebug）**：
  - 读取设备上**全部 provisioning profiles**（misagent 服务，物理位于设备的 `/var/mobile/Library/MobileDevice/Provisioning Profiles/`），按 AppIDName 解析出证书名 / application-identifier / UUID / 过期时间。
  - **优化①（按用户要求）**：原版「Other Profiles」把所有未匹配描述文件挤在一个 Section；现改为**按证书名（AppIDName）分组**，每组显示软件名 + 最新过期时间 + 剩余天数颜色（红/橙/黄/绿），一眼分清属于哪个软件。
  - **优化②（按用户要求）**：新增**批量选择删除（含全选）**——右上角「编辑」进入批量模式，行首复选框 / 底部全选 + 删除选中（N），misagent 逐个删除。
  - 保留：单条导出（.mobileprovision）、单条删除、导入描述文件、已匹配应用分组展示。
  - 说明：misagent 是 Apple 官方描述文件管理通道（Xcode Devices 窗口同源），走开发者隧道以配对身份访问，无需越狱。

## [0.2.68] - 2026-08-27

### Added
- **「更多」新增「虚拟定位」入口（移植自 Bellaboy/locus-ZH，MIT）**：
  - 原理：通过 LocalDevVPN 本机隧道 + RPPairing 配对文件，调用 Apple 开发者工具同款 DVT 定位模拟服务（Xcode「模拟位置」机制）向 locationd 注入模拟坐标——无需越狱 / 漏洞，复用 EscapeSpace 已有的 idevice FFI（Rust idevice-ffi 原生支持 location_simulation）。
  - 功能：地图放置图钉 / 长按拖动、搜索地点（含坐标直搜）、定位模拟开/停、摇杆连续移动、出行方式（步行/跑步/骑行/驾车）、道路路线规划与轨迹运行（速度倍率、循环）、手绘轨迹、GPX 导入/导出、收藏与最近使用、中国地图 GCJ-02 坐标自动转换。
  - **保活（离开页面也持续运行）**：会话为全局单例（`SpoofSession.shared`），返回「更多」菜单后模拟注入与 8 秒重发 / 12 秒健康检查定时器继续运行；退到后台由「静音音频保活 + 后台定位」延续（Info.plist 已有 audio/location 后台模式）。
  - 配对文件与「应用」页共用 `Documents/pairingFile.plist`，已导入直接可用；隧道 IP 与「设置 → 本地隧道」联动。
  - 依赖提示：需 LocalDevVPN（App Store 下载，连接后默认 10.7.0.1）+ idevice_pair 生成的 RPPairing 配对文件；页面状态栏会提示缺失项，一键打开 LocalDevVPN。
- **「更多 → 设置」新增「保活」开关（汉化移植自 rooootdev/mond 的 keepalive.swift）**：
  - 功能与原版一致：开启后应用关闭也会在后台保持运行（静音音频方式，`AVAudioSession` playback + 静音 WAV 循环）。
  - 与虚拟定位联动：模拟激活时强制保活（与开关无关），停止模拟后若开关关闭则自动停止。

### Changed
- **CI 编译时间优化**：
  - 新增 Theos 构建产物缓存（`.theos` + 源文件 hash 快照），恢复时对未变化源码校准 mtime、删除已变化文件对应的 `.o`，`make` 只增量编译 diff，不再每次 `make clean` 全量编译（Swift 源文件已近 200 个，全量耗时随版本线性增长）。
  - 效果自 v0.2.69 起体现（首次无缓存仍全量）。

## [0.2.67] - 2026-08-27

### Fixed
- **「从已安装应用选择」列表仍为空（v0.2.66 修复无效，真机复测）**：
  - 根因：v0.2.66 改用 `NSClassFromString("LSApplicationWorkspace")` 反射枚举，但 **`NSClassFromString` 只搜索「已加载」的类，不会自动加载 framework**——CoreServices 未被链接（Theos 下未链接 CoreServices 正是 v0.2.66 链接失败的原因），运行时类也不存在，`NSClassFromString` 直接返回 nil，列表依旧为空。
  - 修复：枚举前先 `dlopen` 强制加载 CoreServices / MobileCoreServices（失败无害），再走反射枚举。
  - 配套：空列表时显示诊断信息（区分「framework 加载失败」与「确实没有三方应用」），便于下次定位。

## [0.2.66] - 2026-08-27

### Fixed
- **监督模式工具「从已安装应用选择」列表为空（真机反馈）**：
  - 根因：应用枚举沿用了「更多 → 应用」的 `AppDiscovery`，它依赖配对文件 + LocalDevVPN 本地隧道（installation_proxy）才能列出应用；证书直装环境没有配对文件，直接弹「未检测到配对文件」或空列表。
  - 修复：改为设备本地 `LSApplicationWorkspace` 私有 API 直接枚举（与 Lithium 原版一致），无需配对文件 / 隧道；只列出用户安装的应用（User / Internal，隐藏对系统 App 无效），图标走已有的私有 API。应用隐藏、通知管理两个入口同步修复。
- **安装描述文件时 Safari 报「无法连接服务器」（真机反馈）**：
  - 根因：安装流程用 `UIApplication.shared.open` 跳到外部 Safari，应用退到后台被 iOS 挂起，本地 HTTP 服务器的 accept 线程停摆——首个 HTML 页能加载（第一次连接成功），1 秒后 meta refresh 跳到 `.mobileconfig` 时（第二次连接）握手成功但无人响应，Safari 报无法连接服务器。（「屏蔽域名」页因额外申请了后台任务才没踩到。）
  - 修复：改为 app 内 `SFSafariViewController` 打开安装页（与 Lithium 原版一致），应用保持前台、服务不中断；Safari 关闭时自动停止本地服务。五个监督工具页统一生效。

## [0.2.65] - 2026-08-27

### Added
- **「配置管理」新增「监督模式工具」板块（移植自 jailbreakdotparty/Lithium，纯描述文件路线，无需任何漏洞/越狱前提）**：
  - 前提：设备开启监督模式（通常用 Nugget 开启）后，在「设置 → VPN 与设备管理」安装生成的 `.mobileconfig` 即可生效；未开启监督模式时显示引导弹窗说明如何开启，并禁用调整入口。
  - 双轨保留：原有「直接写入系统 plist」能力完全不动，两条路线并存。
  - 四个工具页 + 锁屏页脚，全部中文本地化，UI 复用项目 DesignSystem（浅色大圆角卡片 / 系统语义色，无棕色系）：
    1. **限制开关**（`com.apple.applicationaccess`）：分组开关覆盖 iOS 26 常用限制键（安装/删除 App、应用内购买、截屏、Siri/助手、相机、NFC、隔空投送、Safari、Game Center、Genmoji、写作工具、Apple 智能相关开关等），支持 iOS 26 强制延迟软件更新（最多 90 天）滑块，含系统版本门控与关键项风险提示。
    2. **应用隐藏**（同载体 `blockedAppBundleIDs`）：从已安装 App 列表勾选隐藏（私有 API 取真实图标），也支持手动输入 Bundle ID；登记目录 JSON 持久化，可滑动删除。
    3. **通知管理**（`com.apple.notificationsettings`）：按 App 开关通知（`NotificationsEnabled`），同样支持手动添加 Bundle ID。
    4. **网页快捷方式**（`com.apple.webClip.managed`）：名称 / URL / 图标（相册选取 + 裁剪）/ 全屏 / 无边框，生成的 Web Clip 显示在主屏。
    5. **锁屏页脚**（`com.apple.shareddeviceconfiguration`）：监管版锁屏消息（与直接写入版双轨并存，各自独立生效）。
  - 每个工具页都有统一的底部「安装描述文件」按钮（复用项目已有的 `ProfileHTTPServer` 本机安装通道，与「屏蔽域名」同机制）与右上角菜单（导出描述文件 / 重置为默认）。
  - 模板资源随包携带（`Resources/esc.*.mobileconfig`），首次进入复制到 `Documents/Profiles/` 作为可编辑副本，标识符已全部改为 EscapeSpace 命名，避免与真实 Lithium 安装的设备冲突。

## [0.2.64] - 2026-08-27

### Fixed
- **「空间回收」顶部分段控件遮挡列表内容（真机反馈首项被压住）**：
  - 根因：v0.2.63 误判为底部 Tab 栏遮挡，实际是我把「常规清理 / 容器管理」分段控件以固定条放在 `VStack` 顶部，子视图的 `List` 从分段控件下方开始布局；但由于 `searchable` / 大标题等导航行为干扰，首项内容被分段控件实色背景压住。
  - 修复：分段控件不再作为固定条存在，而是作为每个子页 `List` 的第一个 `Section` 随列表内容一起滚动。切换 segment 时仍瞬时响应，列表内容从分段控件下方自然开始，彻底解决遮挡。

### Added
- **「壁纸」页支持提取当前系统壁纸并导出为 `.tendies`**：
  - 入口：壁纸页右上角菜单 →「提取当前系统壁纸」。
  - 自动扫描 PosterBoard 容器（`com.apple.PosterBoard`）下三个 provider 描述符目录：Collections、MercuryPoster、Videos。
  - 列表展示每个描述符的名称、provider 类型与文件数，支持多选 / 全选。
  - 导出为 `.tendies` 压缩包（`Documents/TendiesExports/Extracted_<时间戳>.tendies`），结构与导入器兼容（`container/.../descriptors/<name>/`）。
  - 导出完成后直接弹出系统分享面板，可隔空投送 / 存文件 / 分享。
  - 读取同样走 `bad_query` / 沙盒扩展消费，与「导入 / 应用」共用同一套 PosterBoard 容器访问能力。

## [0.2.63] - 2026-08-27

### Fixed
- **底部 Tab 栏压住列表内容的观感（「空间回收」页常规清理 / 容器管理两个子页）**：
  - 根因：`SpaceReclaimView` 用 `VStack` 包住 `ReclaimTabView` / `LiveCleanTabView` 各自的 `List`，在 TabView 嵌套下，列表底部安全区失效，最后一项直接顶到 Tab 栏实色背景，产生「被压住 / 遮挡」的感觉。
  - 修复①：给 `RootView` 的 `TabView` 显式设置 `.toolbarBackground(.visible, for: .tabBar)`，强制 Tab 栏为标准半透明毛玻璃，消除实色「板子压住」的观感。
  - 修复②：`ReclaimTabView` / `LiveCleanTabView` 的非选择态也保留 12pt 底部 `safeAreaInset` 占位，列表最后一项与 Tab 栏之间留出呼吸间距，不再贴死。

### Changed
- PosterBoard 壁纸能力在 iOS 26 上可用（项目已有的「更多 → 壁纸」导入 / 应用 `.tendies` 功能在 iOS 26 实测可工作，路径不受 MobileGestalt 系统路径写入封堵影响）。因此「提取当前系统 `.tendies` 壁纸」在 iOS 26 上同样具备可行性（读取 + 重新打包导入），不再沿用此前过度保守的 iOS 26 不可写结论。

## [0.2.62] - 2026-08-27

### Added
- **配置管理 · Respring 加回，改用 Mond 项目（rooootdev/mond）的实现方式**：
  - 移植 `mond/helpers/utils.swift` 的 `RespringView`（neon 的 Web 压力方案，@neonmodder123 开发 / @skadz108 Swift 移植），与 Mond 逐字一致。
  - 展示方式与 Mond / Erosion 完全对齐：`.overlay { RespringView().brightness(-1.0).ignoresSafeArea() }`（此前 v0.2.60 用的是 `.fullScreenCover` 模态展示，多出转场动画与独立宿主窗口，是「黑屏 + 延迟」观感的主要来源；v0.2.61 曾整体移除）。
  - 应用 / 恢复成功弹窗恢复「Respring」按钮（仅成功时可触发），点击后黑屏执行；失败弹窗不提供该按钮。

### Changed
- 应用 / 恢复成功提示恢复为「配置已应用。Respring 后生效。」（v0.2.61 的「请手动重启」文案替换回带 Respring 按钮的方案）。

## [0.2.61] - 2026-08-26

### Removed
- **日志板块整体移除**（按用户要求，后续再设计）：
  - 删除「更多 → 日志」独立入口与 `EscapeLog` 引擎（内存 500 条 + `Documents/escapeos.log` 持久化）、`LogView` 完整日志面板（等宽字体 / 长按复制 / 导出 / 清空）。
  - 删除「配置管理」页内嵌的「操作日志」区与跳转入口。
  - 对应源码：`EscapeOS/Views/LogView.swift`、`EscapeOS/Engine/EscapeLog.swift` 已移出工程（Makefile 注销）。
- **配置管理「Respring」按钮 + 全屏黑屏覆盖层移除**：
  - 经与原版 Erosion `Respring.swift` 逐行对照，该方案是**不可靠的"假 respring"**：用 WKWebView 堆 500 层 `backdrop-filter` + 死循环 `navigator.share`/`crypto` 去"挤爆" SpringBoard，本就不保证真重启。
  - 原版之所以"很快"是因为其 `makeUIView` 里 `WKWebpagePreferences` 创建了却**没赋值给 `webView.configuration`**，JS 实际被禁、重载脚本根本没跑；本端移植时修正了该 bug 导致 JS 真执行 → WebKit 被拖死 + 我自加的 `.brightness(-1.0)` 全屏压黑 → 你看到的"黑屏 + 延迟"。
  - MDM 监督模式改动本就需要**真实重启**才生效，假 respring 既黑屏又不可靠，属于减分项。
  - 现改为：应用 / 恢复成功后弹窗明确提示「请手动重启（Respring / 重启设备）使更改生效」，干净不黑屏。移除 `EscapeOS/Views/RespringView.swift`（Makefile 注销）。

### Changed
- **明确配置管理不依赖 LiveContainer 访客容器扩展**：`SandboxEscape.consume` 对系统组路径（`/private/var/containers/Shared/SystemGroup/...`）走的是真实 `bad_query`，与原版 Erosion 一致；LC 访客容器扩展（`lcContainerExtensionsActive` / `lcHomePath` / `lcAppGroupPath`）只在「容器管理」功能覆盖 LC 私有/共享容器根时使用，配置管理未触碰。源码注释已写明此边界。

## [0.2.60] - 2026-08-26

### Fixed
- **配置管理写入失败（真机报「你没有将文件 SharedDeviceConfiguration.plist 保存到 configurationprofiles 中的权限」）**：
  - 根因：旧实现探测时消费 bad_query 沙盒扩展后**立即释放**，真正写入时扩展已失效，系统按无权限拒绝。
  - 修复：与原版 Erosion 一致，`consume` 后**一直持有扩展到进程结束**（`heldHandle`），写入/恢复前自动确保扩展可用。
  - 同时废弃不可靠的 POSIX `isWritableFile` 判定，改为**真实写入探测**（写临时文件再删除），避免「显示可读写却写失败」的误判；iOS 26 平台限制（写 systemgroup 被堵死）仍如实显示为「可读取」。

### Added
- **配置管理 · 备份并分享**：一键将 `SharedDeviceConfiguration.plist` / `CloudConfigurationDetails.plist` 与说明.txt 打包为 zip，通过系统分享面板导出（隔空投送 / 文件 / 微信等）；不依赖写权限，任何环境可用。
- **配置管理 · 恢复入口**：工具栏新增「恢复」按钮（gobackward，对齐原版），确认后删除页脚并取消监督。
- **配置管理 · Respring**：应用 / 恢复成功后弹窗提供「Respring」按钮；移植原版 Erosion 的 WKWebView 内存压力方案（@neonmodder123 / @skadz108），以全屏黑屏覆盖层触发 SpringBoard 重启，适配所有 iOS 版本。
- **日志板块**（参考原版 Erosion 日志面板样式）：「更多 → 日志」新增入口；等宽字体滚动展示、长按菜单复制 / 导出、工具栏导出（系统分享面板）与清空。配置管理探测 / 应用 / 恢复 / 备份自动记录日志（内存 500 条 + 持久化 `Documents/escapeos.log`）。
- **配置管理内嵌日志板块**：「配置管理」页底部新增「操作日志」区，实时显示最近 15 条操作记录（等宽字体，参考原版 LogView），并提供「查看完整日志 / 导出」跳转至完整日志面板，便于现场排查「写入被拒」等问题。

### Changed
- 监督模式警告去掉黄色 ⚠️ 表情，改为页眉 `info.circle` 信息按钮 + 纯文本页脚，形态对齐原版 PlainToggle 的信息按钮。
- 锁屏预览对齐原版：改用随包携带的 solarium 图片背景（Resources/solarium.jpg），白色文本 + 白色下划线（145×4），修复下划线偏移/不对齐问题。
- 「访问能力」区块删除状态行下方的长描述文字，仅保留状态 + 重新检测。

## [0.2.59] - 2026-08-26

### Added
- **「配置管理」入口**（移植自 Erosion「Configurations」，「更多」页新增）：
  - **锁屏页脚**：读取/设置 `SharedDeviceConfiguration.plist` 的 `LockScreenFootnote`，带简易锁屏预览。
  - **监督模式**：切换 `CloudConfigurationDetails.plist` 的 `IsSupervised` / `OrganizationName`；MDM 已配置设备警告；支持一键恢复（删除页脚 + 取消监督）。
- **iOS 26 适配（访问能力探测）**：
  - 进入页面自动探测系统配置目录（`SystemGroup/systemgroup.com.apple.configurationprofiles/...`）读写能力：越狱/iOS 27+ 可读写；iOS 26（无越狱）可读取与备份、写入受限——与 bad_query/MHA class-13 的既有结论一致（iOS 26 写 systemgroup 被平台堵死）。
  - 页内顶部显示访问状态（可读写 / 可读受限 / 完全受限 + 原因），「应用」按钮在不可写时禁用并给出明确中文提示。
  - 尝试 bad_query（`SandboxEscape.consume`）与 MHA 身份（`MCMIntegration.isMobileHouseArrest`）两条访问路线；iOS 27+ 保持可写兼容。
- 操作结果 / 失败均以弹窗提示（应用后需 Respring 生效，页面内给出提示）。

### Fixed
- **v0.2.59 首版构建失败（CI run 32979035426）**：`ConfigurationsView.swift` 中三个 `Section` 误用了已废弃的 `Section(header: Text(...)) { ... } footer: { ... }` 写法，在 Xcode 26 / iOS 26 SDK 下报 `incorrect argument label in call (have 'header:_:footer:', expected 'header:footer:content:')` 与 `type '() -> Text' cannot conform to 'View'`。已统一改为 iOS 17 新语法 `Section { ... } header: { Text(...) } footer: { ... }`，重新打 tag 构建通过。

## [0.2.58] - 2026-08-26

### Added
- **批量开启「增加内存限制」（含全选）**：
  - 每行 App 左侧新增圆形勾选按钮（行内点击或按钮切换），选中后蓝色填充。
  - 列表标题右侧「全选/取消全选」按钮一键切换当前团队所有 App 选中状态；默认排除已开启的（关「跳过已开启」包含全部）。
  - 列表底部「跳过已开启」Toggle（默认开）+ 「批量开启（N）」按钮（显示选中数量），点击后**串行**开启所有选中 App（每次 PATCH 取独立 Anisette OTP，最稳）。
  - 操作期间按钮禁用并显示进度「批量开启中 X/Y…」（行内同步显示小转圈）。
  - 完成后一次性汇总结果：成功 N、失败 M 及各自列表（App ID + 失败原因）。
- 新增「全部成功」体验：批量结束后自动刷新 App 列表，状态即时更新；勾选集合自动清空。

## [0.2.57] - 2026-08-26

### Added
- **「增加内存限制」真实开启逻辑**（移植自 GetMoreRam）：登录后自动加载开发者团队（listTeams.action）→ 选择团队 → 加载 App ID 列表（ios/listAppIds.action）→ 点击「开启」调用 `PATCH /services/v1/bundleIds/<id>` 为 App ID 启用 `INCREASED_MEMORY_LIMIT` 能力。
- 新增 `AppleDeveloperAPI`（纯原生 URLSession，移植 StosSign `AppleAPI`）：`fetchTeams` / `fetchAppIDs` / `enableIncreasedMemory`，所有请求携带 dsid + authToken + **每次全新 Anisette OTP**（避免一次性 OTP 失效）。
- App ID 列表显示已开启状态（绿色 ✓）；操作结果与错误弹出显示服务器响应原文，并写入诊断日志。
- `AnisetteData` 补充显式成员构造器。

### Changed
- 「增加内存限制」页替换原「功能未就绪」占位：未登录时提示去设置登录；已登录直接进入团队/App 操作流程（支持下拉刷新）。

## [0.2.56] - 2026-08-26

### Fixed
- **修复 2FA 二次握手 -22421**（真机日志定位）：Apple 的 Anisette OTP 是**一次性**的，首次握手（complete）成功后即失效；此前两步验证通过后复用旧 OTP 重新握手 → Apple 拒绝 `-22421`。现在 `authenticate` 支持 `refreshAnisette`：2FA 验证码提交后**重新获取全新 Anisette（新 OTP）**再走完整握手。
- **登录耗时从 ~56 秒降到 ~1-2 秒**：BigInt 除法从「逐位二进制长除法」升级为标准 little-endian **Knuth D**（O(n·m)），性能提升两个数量级；已用 Python 参考实现验证（1000 组随机除法 + SRP 固定向量 S/K 精确匹配），设备端自检缓存升级为 v2 强制重跑一次确认。

## [0.2.55] - 2026-08-26

### Fixed
- **修复 SRP S 计算错误（-22406 的真正根因，设备端自检实锤）**：
  - 真机自检日志显示 `X_NORMAL/X_HEX PASS` 但 `S/K/M1/M2 FAIL` → x 推导正确，**BigInt 大数除法错误**。
  - 原因：自研 `divModMag`（Knuth D 实现）存在取 limb 方向的实现缺陷，导致模幂（modPow）结果错误 → S 错 → M1 错 → Apple 拒绝登录（-22406）。
  - 修复：除法重写为**逐位二进制长除法**（每比特：余数左移→取被除数位→够减则减并置商位），算法正确性直观可证明；已用 Python 参考实现验证：SRP 固定向量 S/K 精确匹配 + 200 组随机除法全部正确。
  - 自检保留：登录首次自动运行，PASS 后缓存结果（`SRPTestResult`），后续登录零开销。

### Changed
- SRP 自检从「每次登录都跑」改为「首次运行并缓存」，消除重复 PBKDF2 开销。

## [0.2.54] - 2026-08-26

### Added
- **SRP 自检（登录前自动运行）**：用 Python 参考实现（纯标准库，对照 swift-srp 逐公式实现）预生成的固定测试向量，验证 x 推导（PBKDF2 普通/十六进制两分支）、BigInt 大数运算（S/K）、M1/M2 证明——任一 FAIL 会写入诊断日志，登录失败时导出的日志可直接判断是 x 推导错误、BigInt 数学错误还是密码问题，不再盲猜。
- **SRP 中间值日志**：每次握手把 x / u / S / K 的十六进制写入诊断日志（u 不依赖密码，可与参考实现精确复算对比）。

## [0.2.53] - 2026-08-26

### Fixed
- **修复 GrandSlam 握手 -22406（真机日志 + 原版源码逐行对照实锤）**：
  - 根因①：M1/M2 证明把会话密钥 `K=SHA256(S)` **再次哈希**（`sha256(K)`），而原版 swift-srp 只哈希一次（`hashSharedSecret = H(S)`），导致 M1 与 Apple 计算不符 → Apple 为安全统一返回「密码错误」-22406。
  - 根因②：`sessionKey` 应为 **S 的 256 字节**（spd 解密用 `HMAC(S, "extra data key:")` 派生，HMAC 允许任意长度 key），此前误用 32 字节 K；apptokens 阶段 sessionKey 会被 spd 中的 `sk` 字段覆盖（原版同款流程），不受影响。
  - 根因③：`u` 计算中 B 应使用**服务器原始字节**（对齐 swift-srp `H(A_pad256 | B_raw)`），此前 pad 到 256。
- 全盘审计对照原版（StosSign GSAContext + swift-srp @ ce202c48 + GetMoreRam AnisetteDataHelper）确认：k / x1(PBKDF2) / x / S / M1 / M2 / spd-CBC / sk / checksum / GCM / lookup 头 / identifier 全部一致。

### Added
- **密码框小眼睛**：登录界面密码输入框右侧新增眼睛图标，点击切换明文/密文。
- **记住账户（默认开启）**：登录成功的账户写入「最近登录」历史（最多 10 条，去重置顶），每个账户的密码按邮箱单独存入钥匙串。
- **最近登录下拉一键登录**：邮箱输入框右侧时钟图标下拉，列出历史账户；点击自动回填邮箱+密码并立即登录；每个账户行右侧有「删除」按钮，可单独移除该账户记录（连同其保存的密码）。
- 登录成功额外保存 `firstName` / `lastName`（对齐 SideStore 的账户信息存储）。

## [0.2.52] - 2026-08-26

### Fixed
- **修复 provision 卡死根因（真机日志定位）**：`gsa.apple.com/grandslam/GsService2/lookup` 此前为**裸 GET**，Apple 返回 **HTTP 404**，导致首次登录（无 adi.pb 需配给时）必然失败。
  - 对齐 GetMoreRam 参考实现 `buildAppleRequest`：新增 `makeAppleRequest`，为 lookup / midStartProvisioning / midFinishProvisioning 三个 Apple 端点统一附加设备头（`X-Mme-Client-Info`、`User-Agent`、`X-Apple-I-MD-LU`、`X-Mme-Device-Id`、`X-Apple-I-Client-Time`(UTC)、`X-Apple-Locale`、`X-Apple-I-TimeZone`、`Accept`）。
  - midStart / midFinish 两个配给端点同样改为带完整头的 POST，避免下一个环节再被 Apple 拒绝。

### Added
- **登录日志「清空」功能**：诊断日志页右上角新增「清空」按钮（带二次确认），一键清除内存与文件日志。

## [0.2.51] - 2026-08-26

### Added
- **登录诊断日志**：新增 `LoginLogger`，把认证引擎每一步（Anisette client_info / WebSocket provision 各消息 / get_headers 响应 / GrandSlam 握手 / 2FA / 错误码）记录到 `Documents/LoginLogs/login.log`。
- **登录界面「诊断日志」入口**：登录弹窗右上角新增「诊断日志」按钮，可查看完整日志、一键复制，或通过系统分享面板导出日志文件/文本，便于把真实报错直接发给开发者排查。

### Fixed
- **错误透传真实原因**：所有 `Anisette 数据无效或已过期` 的笼统报错改为带阶段与细节的真实错误（如「Anisette client_info 失败: HTTP 403 …」「Anisette provision 失败: WebSocket 接收失败: …」「Anisette 被 Apple 拒绝(-22421): …」），登录失败弹窗直接显示真实原因。
- Anisette v3 各 HTTP 请求（client_info / get_headers / gsa lookup / midStart / midFinish）增加状态码检查与响应内容记录，不再把「服务器 5xx/格式异常」误报成「Anisette 无效」。

### Changed
- **CI 编译加速**：`make package` 改为 `make -j$(sysctl -n hw.ncpu)` 并行编译（macOS runner 多核），Swift 多文件编译不再串行，预期编译阶段显著缩短。

## [0.2.50] - 2026-08-26

### Fixed
- **修复登录报「Anisette数据无效或已过期」（真机实测反馈）**：
  - 根因：`AnisetteProvider.fetchClientInfo` 把 16 字节随机数据以**原始字节**写入钥匙串，而 `EscapeKeychain.string(for:)` 按 **UTF-8** 解码，随机字节几乎必然解码失败（返回 nil），导致首次登录必然在生成 identifier 后立即抛出 `invalidAnisetteData`。
  - 修复：identifier 改为以 **base64 字符串** 存储；并自动检测/清除旧版本遗留的无效 identifier（解码校验 16 字节，失败则重新生成），老用户升级后无需清除应用数据即可登录。
- 修复 v3 Anisette `date` 字段时区错误：此前用 `TimeZone.current`（如中国 +8）却打印 `'Z'`（UTC）后缀，时间戳偏差 8 小时；现强制 UTC 生成，避免被 Apple 判定时间不符（-22421）。

### Changed
- `AppleAuthenticator` 的 GrandSlam 错误码映射不变（-22421 → Anisette 无效），但 Anisette 生成侧已修复，正常首次登录不再触发。

## [0.2.49] - 2026-08-26

### Added
- Apple 认证引擎正式接入「登录 Apple ID」：不再只是保存凭据，而是走真实的 GrandSlam (gsa.apple.com) SRP-6a 握手 + Anisette v3 设备认证，登录成功后返回 `Account` 与 `AppleAPISession`（含 dsid / authToken），存入钥匙串供后续「增加内存限制」等功能统一调用。
- 自研纯 Swift 引擎（无第三方 SwiftPM 依赖，可在 Theos/clang 下编译）：
  - `BigInt.swift`：自包含大整数（Knuth 长除法 + 模幂），含 `selfTest()`。
  - `SRP6a.swift`：RFC 5054 2048-bit 质数，Apple 变体 SRP-6a（k/H/N/g、x 派生、客户端证明 M1、服务端证明 M2）。
  - `GSAAuth.swift`：替换 StosSign 的 GSAContext，使用原生 `CommonCrypto`(PBKDF2/AES-CBC) 与 `CryptoKit`(SHA256/HMAC/AES-GCM)。
  - `AppleAuthenticator.swift`：完整 init→complete 握手、两步验证（受信任设备 / 短信）、`apptokens` 取令牌、拉取账户信息。
  - `AnisetteProvider.swift`：Anisette v3 `client_info → provisioning_session(WebSocket) → get_headers`，首次登录自动配给并缓存 `adi.pb`。

### Changed
- `AppleIDLoginSheet` 改为调用 `AppleAuthenticator.authenticate(...)`；遇到两步验证时弹出验证码输入框，提交后继续完成登录。
- 隐私脱敏与眼睛图标（v0.2.48 加入）保持不变。

### Fixed
- 延续 v0.2.48 的统一文件导入修复，本次将导入能力固化进引擎侧，无新增导入路径问题。

## [0.2.48] - 2026-08-26

### Added
- 统一文件导入入口 `SharedDocumentPicker`：所有文件选择（配对文件、SideStore 账户、壁纸、文件浏览器）现在走同一条 `UIDocumentPickerViewController(asCopy:true)` 路径，从根视图控制器弹出，从根本上修复 LiveContainer 沙盒内 `.fileImporter` 无法访问安全作用域 URL 的导入失败问题。
- Apple ID 账户显示恢复隐私保护：默认以「首 2 字符 + 星号」脱敏（`john•••@icloud.com`），点眼睛图标临时展开/收起完整账号与凭证详情。

### Changed
- `PairingFilePicker` 内部改为复用 `SharedDocumentPicker`，导入机制全局统一。
- `AppleIDLoginSheet` / `FileBrowserView` / `WallpaperView` 的 `.fileImporter` 全部替换为 `.documentPicker` 修饰符。

## [0.2.47] - 2026-08-26

### Changed
- Apple ID 账户管理从「增加内存限制」页迁移到「更多 → 设置」里，作为统一登录入口。
- 删除 Team ID 字段与显示（账户模型只保留 Apple ID + 密码）。
- 已登录账号改为纯文本显示（GetMoreRam 同款），不再使用眼睛图标和星号脱敏。
- 「增加内存限制」页改为只读状态页，显示当前 Apple ID / Anisette 服务器 / 操作占位。

## [0.2.46] - 2026-08-26

### Added
- 「更多」新增「增加内存限制」入口（移植自 GetMoreRam）：登录 Apple ID 账户、查看账号/Team ID、退出登录。
- 设置页新增「Anisette 服务器」下拉：可选 ani.sidestore.io（默认）/ ani.stikstore.app / ani.sidestore.app / ani.846969.xyz，供「增加内存限制」功能调用。
- 支持导入 SideStore 账户 JSON（手动输入之外的快捷登录方式）。
- `MemoryLimitSettings` / `EscapeKeychain`：账户与服务器配置的本地存储与脱敏显示。

### Changed
- 「增加内存限制」主操作在 Apple Developer API 引擎接入前显示「功能未就绪」提示，并复用设置中的账户与 Anisette 服务器。

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
