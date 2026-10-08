# 防复发检查 · 约定与用法

本目录的脚本是「**以后不会再有人犯同样的错**」的机制化守门人。目前两项检查，
统一入口：`swift_precommit_check.py`。

> **⚠️ 仓库内 / 仓库外两份**
> 本文件在**仓库内** `Resources/Scripts/`，是 **CI 实际运行的版本（单一真源，改动请改这里）**。
> 工作区另有一份在**仓库外** `P0_分析脚本库/`（人工/本地分析用，不随仓库走）。
> 两份会各自演进、**内容不完全一致** —— 例如仓库内这份多两条「收窄豁免」让它在当前代码上
> EXIT 0（见 §3.2.1）。**以仓库内这份为准。**

> **给后来者的一句话约定（最重要）**
> **视图层（`EscapeOS/Views/**`）不得自行推导「下载状态文案」；一律读 `Job.displayStage`。**
> `Job` 的 `phase`（枚举）与 `stageText`（自由字符串）是两个独立字段，视图各自推导
> 就会「修一个漏一个」——这正是用户说的「拆东补西」的根源。`displayStage` 是**唯一真源**。

---

## 1. 怎么跑

```bash
# 仓库根 = 含 EscapeOS/ 的那一层（P1_EscapeOS_宿主仓库）
python3 Resources/Scripts/swift_precommit_check.py .          # 在仓库根直接跑
python3 Resources/Scripts/swift_precommit_check.py <仓库根> [--strict]
```

| 退出码 | 含义 |
|---|---|
| 0 | 全部通过 |
| 1 | 有任一检查失败（`--strict` 时 WARN 也算失败） |
| 2 | 参数 / 路径错误 |

单独跑某一项：

```bash
python3 Resources/Scripts/swift_top_level_type_collision.py <仓库根>          # 顶层类型重名普查
python3 Resources/Scripts/swift_view_state_derivation.py <仓库根> [--strict]  # 视图层状态文案推导
```

Python 解释器（本机）：`C:\Users\xcrad\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe`

> **依赖：纯标准库**（`os` / `re` / `sys` / `fnmatch` / `subprocess` / `collections`）。
> **无任何第三方包** ⇒ CI 里 `python3` 直接能跑，无需 `pip install`。

---

## 2. CI 里在哪一步跑

`Resources/Scripts/swift_precommit_check.py .` 在 `.github/workflows/build-xcode.yml` 的
**`guard` job** 里跑，步骤名「Guard — 视图层状态文案推导 + 顶层类型重名（防复发）」。

- **独立轻量 job**（秒级跑完），与 8~11 分钟的 `xcode-build` 分开 —— 不拖慢编译，失败信号独立。
- **触发条件**：与其它 job 一致 —— `v*` tag 触发（`push`）+ `workflow_dispatch` 手动触发。
- **它失败会阻止发版**：`promote` 与 `xcode-build` 都门控在 `guard` 成功上
  （`promote: needs: [guard]`；`xcode-build: if: ... needs.guard.result == 'success' ...`）。
  ⇒ 两条 Release 发布路径（promote 复用产物 / xcode-build 末尾的 Publish Release）**都被拦住**。

---

## 3. 两项检查分别管什么

### 3.1 `swift_top_level_type_collision.py` —— 顶层类型重名
Swift 同一 module 内顶层类型**不许重名**（`swiftc -parse` 单文件解析查不出来）⇒ 只有
CI 全量编译才发现。本项目已因此炸过一次 CI（`AppIconView` 被两个文件同时声明）。
只看**行首无缩进**的顶层声明，缩进的嵌套类型（如 `enum CodingKeys`）不误报。

### 3.2 `swift_view_state_derivation.py` —— 视图层状态文案推导
扫描 `EscapeOS/Views/**`：

| 规则 | 级别 | 拦什么 |
|---|---|---|
| R1 | ERROR | 视图层读取 `.stageText`（应读 `.displayStage`） |
| R2 | ERROR | `phase … ? "<状态文案>"` 之类**状态文案三元推导**（含 `phase == .paused ? …`） |
| R3 | WARN | 直接调用 `phase.title`（状态文案的平行来源） |
| R4 | ERROR | 硬编码状态文案字面量（`"下载中"` / `"安装中"` / `"已暂停"` …） |
| R5 | ERROR | 用 `isBusy` / `isPendingDownload` 推导**状态文案**（`isBusy ? "…"` / `isBusy ? .text("…")`） |

> **R4 为什么是 ERROR**：原为 WARN，审计指出「硬编码状态字只报噪音、CI 拦不住」⇒ 升为 ERROR。
> **R5 是什么**：`isBusy` 只表示「占用中」（`.paused` 亦为 true），拿它推状态文案必然把暂停
> 显示成「下载中」。**它只用于可点性 / 排序 / 筛选 / 去重是合法的** ⇒ R5 只认「`?` 后紧跟
> **状态字面量**」的形状；`isBusy ? 变量`、`isBusy ? "安装包尚未下载完成"`（非状态文案）都不报。
> **R3 为什么只是 WARN**：`phase.title` 有合法用法（阶段胶囊 helper、去重比较）⇒ 不致命，只提示。

**误报处理**（三层）：
1. **逐字符状态机**（思路同 `P4_全能签逆向/_impl/_scan_punct.py`）：把源码切成
   code / string / 多行串 / 行注释 / 块注释（块注释支持嵌套）。R1~R3、R5 只在 **code** 命中；
   R4 只在 **单行字符串** 命中 ⇒ 注释里的 `stageText`、文档串里的「下载中」都不误报。
   同一 `(行, 字面量)` 只报一条（R5 优先于 R2，二者都优先于 R4），不叠噪音。
2. **内置豁免表 `ALLOW`**（脚本内）：按 `(文件 glob, 行正则, 理由)` 精确豁免**已知合法**用法。
   **每条豁免都须复核「理由是否成立」**；不成立 / 已失效的条目必须删。正则务必**收窄到具体
   形状**，别写成整文件放行（否则会变成「定时雷」——将来该文件里的真违规被静默放行）。
3. **行内抑制**：某行本身或上一行含 `// state-guard: allow` 即整行跳过（**新增合法用法时优先用这个**，
   比改脚本的 `ALLOW` 表更局部）。

#### 3.2.1 豁免表（逐条 · 当前仓库内版本共 8 条）

| # | 文件 | 命中正则 | 理由 | 是否成立 |
|---|---|---|---|---|
| 1 | `I4StoreFreeDetailView.swift` | `Section\("下载中"\)` | Section 区块标题，非状态行文案 | ✅ |
| 2 | `NBStoreDetailView.swift` | `Section\("下载中"\)` | Section 区块标题，非状态行文案 | ✅ |
| 3 | `KernelCacheView.swift` | `Label\("已下载"` | Section 头里的按钮 Label，非 Job 状态行 | ✅ |
| 4 | `ModuleManagerView.swift` | `return "安装中"` | 模块管理域自己的状态，与 Job 无关 | ✅ |
| 5 | `AppStoreDetailView.swift` | `Text\(phase\.title\)` | 阶段胶囊 helper：`phase.title` 的**渲染**点（审计登记为「平行来源·可疑 S3」） | ⚠️ 存疑·登记 |
| 6 | `IPADownloadManagerView.swift` | `failureStage == \.download` | 失败**阶段**徽标（下载失败 / 安装失败），非状态行文案 —— `displayStage` 给不出该区分 | ✅ |
| 7 | `AppStoreDetailView.swift` | `displayStage\s*!=\s*job\.phase\.title` | **去重比较**（非渲染）：判断「黑字」与「胶囊」文案是否相同来决定是否多画一行；换成 `displayStage` 会让条件恒 false ⇒ 额外一行永不渲染（审计明确「勿替换」） | ✅ |
| 8 | `IPADownloadManagerView.swift` | `case\s+\.installing:\s*return\s*\(nil,\s*"安装中"\)` | **OTA 在线安装**进度环文案：来源是 `otaProgress.stage`（`OnlineInstallProgress.Stage`，**另一套状态机**），与 `IPADownloadCenter.Job` 无关 ⇒ `displayStage` 不是它的源 | ✅ |

- **已删除的条目**：`IPADownloadActionsSheet.swift` 的 `"下载中"` —— 其理由「不读 Job 状态」**是错的**
  （该处正由 `job.phase.isBusy` 驱动），且代码已改成读 `displayStage`、正则不再命中 ⇒ 既错又失效，删除。
- **#7 / #8 是「入库接 CI」轮新增**：为让脚本在**当前干净代码**上 EXIT 0。两条正则都收窄到该具体形状
  （反控实测：同文件里 `Text(job.phase.title)` 仍报 R3、`Text("安装中")` 仍报 R4 ⇒ 未过度放行）。

---

## 4. 当检查报红时怎么办（按优先级）

1. **正解**：把视图里那处推导改成读 `job.displayStage`（一处语义、一处维护）。
2. **确实是合法用法**（例如另一个业务域的同名文案、去重比较、另一套状态机）：在该行加
   `// state-guard: allow` 并写明原因；若是**跨文件、稳定**的合法用法，加进脚本的 `ALLOW` 表。
3. **绝不**为了过检查去改脚本把规则关掉。

> **⚠️ 豁免理由必须诚实**（血泪）：写清「**为什么不违规**」，不是「为什么我想让它过」。
> 上一轮就有一条豁免理由是**错的**（写「不读 Job 状态」，实际在读），它比**没有豁免更糟** ——
> 因为它把一处**真违规**静默放行了。**不成立 / 已失效的条目必须删。**

---

## 5. 为什么是「一个入口」而不是「一个脚本」

两项检查的输入、口径、退出码都独立，各自的报告与豁免表各管一摊。把逻辑塞进一个文件只会互相牵制。
`swift_precommit_check.py` 只做**编排**（依次 subprocess 调用），将来加检查 = 往 `CHECKS` 加一行。
