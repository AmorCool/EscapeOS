# -*- coding: utf-8 -*-
"""视图层「下载状态文案」推导检查 —— 防复发机制（① 静态检查）。

背景（用户原话）：
    「抽共享的『下载状态行』组件（6 个页面各自渲染同一状态 —— 这就是『拆东补西』的根源，
      那怎么根源解决）」
根因：`IPADownloadCenter.Job` 的 `phase`（枚举）与 `stageText`（自由字符串）是两个**独立字段**，
      视图层**各自推导**显示文案 ⇒ 6 处各补一次补丁 ⇒ 修一个漏一个。
收口方案：`Job.displayStage` 是**唯一真源**，视图层只读它；`stageText` 关成 `private(set)`。
本脚本就是「以后不会再有人犯同样的错」的**守门人**：在提交前拦住「又有人自己推导」。

检查范围：仓库里 `EscapeOS/Views/**` 下的所有 .swift（视图层）。

检查规则：
  R1 [ERROR] 视图层读取 `.stageText`        —— 视图不得读它，应读 `.displayStage`
  R2 [ERROR] `phase … ? "<状态文案>"` 之类**状态文案三元推导**（含 `phase == .paused ? …`）
  R3 [WARN ] 直接调用 `phase.title`          —— 状态文案的**平行来源**（合法用法见豁免表）
  R4 [ERROR] 硬编码状态文案字面量            —— 排除注释 / 多行串，合法用法见豁免表
  R5 [ERROR] 用 `isBusy` / `isPendingDownload` 推导**状态文案**（形如 `isBusy ? "…"`
             / `isBusy ? .text("…")`）—— 该布尔只表示「占用中」，`.paused` 亦为 true，
             拿它当文案来源必错（暂停会被标成「下载中」）。
             ⚠️ 该布尔用于**可点性 / 排序 / 筛选 / 去重**是合法的，本规则只认「`?` 后紧跟
             **状态字面量**」的形状 ⇒ 变量（如 `isBusy ? pendingStageText`）、非状态文案
             （如 Toast 的 `isBusy ? "安装包尚未下载完成"`）一律不报。

> 历史：R4 原为 WARN，被审计指出「漏点只报噪音、CI 拦不住」⇒ 升为 ERROR；R5 为审计
>   指出的缺口（`IPADownloadActionsSheet` 曾由 `job.phase.isBusy` 硬编码「下载中」而脚本
>   主动豁免）⇒ 本轮新增。豁免表亦经逐条复核（详见 README / 修复简报）。

误报处理（三层，务必读）：
  1) **逐字符状态机**（复用 P4_全能签逆向/_impl/_scan_punct.py 的思路）把源码切成
     code / string / 多行串 / 行注释 / 块注释（块注释支持嵌套）。R1~R3、R5 只在 **code**
     命中（R5 的 `"…"` 字面量借 noc_mask 看见）；R4 只在 **单行字符串** 命中。
     ⇒ 注释里的 `stageText`（如 I4StoreFreeView.swift:816）与多行文档串里的「下载中」
     **不会**误报。
  2) **内置豁免表** ALLOW：按 (文件 glob, 行正则, 理由) 精确豁免**已知合法**的用法
     （Section 标题、其它业务域自己的状态、阶段胶囊 helper …）。豁免会被统计并打印。
     ⚠️ 每条豁免都必须复核「理由是否成立」；不成立 / 已失效的条目要删。
  3) **行内抑制**：某行**本身或上一行**含 `// state-guard: allow` 即整行跳过。
     （本轮不改 P1 的 Swift 文件，故此机制为将来预留；现在靠 ALLOW 表。）

用法：
    python swift_view_state_derivation.py [仓库根，默认 .] [--strict]
    仓库根 = 含 EscapeOS/Views 的那一层（即 P1_EscapeOS_宿主仓库）
退出码：0 = 无 ERROR；1 = 有 ERROR（R1/R2/R4/R5 任一即致命；--strict 时 R3 的 WARN 也算）。
"""
import os
import re
import sys
import fnmatch

# ── 视图层根目录（相对仓库根）─────────────────────────────────────────────
VIEWS_SUBDIR = os.path.join("EscapeOS", "Views")

# ── R4：认定为「下载状态文案」的字面量集合（精确整串匹配，非子串）──────────
STATUS_LITERALS = {
    "等待中", "下载中", "已暂停", "安装中", "已完成", "失败", "已下载", "准备中", "排队中",
}

# ── 内置豁免表：(文件 glob, 命中行正则, 理由)──────────────────────────────
# 只豁免「已知合法」的用法；新增豁免必须写清理由。glob 用 fnmatch，对相对仓库根路径匹配。
#
# 【复核记录 · 本轮】逐条核对了每个条目的理由是否成立：
#   · 已删除 `IPADownloadActionsSheet.swift` 的 `"下载中"` 豁免 —— 其理由「不读 Job 状态」
#     本身就是错的（该处正由 `job.phase.isBusy` 驱动，见审计报告 §7.3）；且代码已修
#     （改用 `pendingStageText = Job.displayStage`），正则不再命中 ⇒ 条目已失效。
#   · 其余 5 条复核通过（Section 标题 / 工具栏按钮 / 另一业务域状态 / 胶囊 helper），保留。
#   · 【本轮新增】`IPADownloadManagerView.swift` 的 `failureStage == .download ? "下载失败" : "安装失败"`
#     —— 这是「失败**阶段**徽标」而非「状态行文案」：`displayStage` 对 `.failed` 只透出 `stageText`
#     （「失败 / 文件不存在 / 未找到安装包 / 删除失败」），**给不出**「下载阶段失败 vs 安装阶段失败」。
#     换成 `displayStage` 会丢信息（错标比不标更糟）⇒ 有意保留。当前 R1~R5 均不命中该形状
#     （`failureStage` 不是 `phase`/`isBusy`，字面量也不在 STATUS_LITERALS），本条为**前置声明**：
#     若将来按复核建议把 `failureStage` 纳入规则 / 把「下载失败/安装失败」加入 STATUS_LITERALS，
#     本条会立即生效、避免误报。代码侧同时在该行上方加了 `// state-guard: allow`（双保险）。
#   · 【入库接 CI 轮新增 2 条】让脚本在**当前干净代码**上 EXIT 0（此前 1 ERROR + 1 WARN）：
#     a) `AppStoreDetailView.swift` 的 `job.displayStage != job.phase.title`（R3 命中）——
#        这是**去重比较**，不是渲染 `phase.title`；换成 `displayStage` 会让条件恒 false ⇒
#        额外一行永不渲染（审计明确「勿替换」）⇒ 合法用法，豁免。
#     b) `IPADownloadManagerView.swift` 的 `case .installing: return (nil, "安装中")`（R4 命中）——
#        这是 **OTA 在线安装**进度环的文案，来源是 `otaProgress.stage`
#        （`OnlineInstallProgress.Stage`，**另一套状态机**），与 `IPADownloadCenter.Job` 无关 ⇒
#        `displayStage` 不是它的源（脚本默认提示「应来自 .displayStage」对它是**错的**）。
#        两条正则都**收窄到该具体形状**（不是整文件放行），避免成为定时雷。
ALLOW = [
    ("**/I4StoreFreeDetailView.swift", r'Section\("下载中"\)',
     "Section 区块标题，非状态行文案"),
    ("**/NBStoreDetailView.swift", r'Section\("下载中"\)',
     "Section 区块标题，非状态行文案"),
    ("**/KernelCacheView.swift", r'Label\("已下载"',
     "工具栏按钮 Label，非 Job 状态行"),
    ("**/ModuleManagerView.swift", r'return "安装中"',
     "模块管理域自己的状态，与 Job 无关"),
    ("**/AppStoreDetailView.swift", r'Text\(phase\.title\)',
     "阶段胶囊 helper：phase.title 的渲染点（审计列为「平行来源·可疑 S3」，本轮不改 P1，保留并登记）"),
    ("**/IPADownloadManagerView.swift", r'failureStage == \.download',
     "失败**阶段**徽标（下载失败 / 安装失败），非状态行文案 —— displayStage 给不出该区分，有意保留"),
    ("**/AppStoreDetailView.swift", r'displayStage\s*!=\s*job\.phase\.title',
     "去重**比较**（非渲染 phase.title）：判断「黑字」与「阶段胶囊」文案是否相同来决定是否多画一行；"
     "换成 displayStage 会让条件恒 false ⇒ 额外一行永不渲染（审计明确『勿替换』）"),
    ("**/IPADownloadManagerView.swift", r'case\s+\.installing:\s*return\s*\(nil,\s*"安装中"\)',
     "OTA **在线安装**进度环文案：来源是 otaProgress.stage（OnlineInstallProgress.Stage，另一套状态机），"
     "与 IPADownloadCenter.Job 无关 ⇒ displayStage 不是它的源（脚本默认提示『应来自 displayStage』对它是错的）"),
]

SUPPRESS_RE = re.compile(r'//\s*state-guard:\s*allow')

# R1：code 模式下读取 `.stageText`
RE_STAGE_TEXT = re.compile(r'\.stageText\b')
# R2：`phase … ? "<状态文案>"`（状态文案三元推导）。用「条件里含 phase、`?` 后紧跟字面量」
#     的宽形状；是否成立再看字面量是否属于 STATUS_LITERALS（排除 `? "继续" : "暂停"` 之类动作动词）。
RE_TERNARY_PHASE = re.compile(r'\bphase\b[^?"\n]{0,40}?\?\s*(?:\.\w+\s*\(\s*)?"([^"]{1,20})"')
# R5：`isBusy ? "…"` / `isPendingDownload ? .text("…")`（用占用中布尔推导状态文案）。
#     同样只认「`?` 后紧跟字面量」⇒ `isBusy ? pendingStageText`（变量）与
#     `isBusy ? "安装包尚未下载完成"`（非状态文案）都不会命中。
RE_TERNARY_BUSY = re.compile(r'\b(?:isBusy|isPendingDownload)\b[^?"\n]{0,40}?\?\s*(?:\.\w+\s*\(\s*)?"([^"]{1,20})"')
# R3：code 模式下 `phase.title`
RE_PHASE_TITLE = re.compile(r'phase\.title\b')
# R4：单行字符串字面量（用状态机拿到的 span 判定，这里只做备用）


def classify(src):
    """逐字符状态机。返回 (code_mask, noc_mask, string_spans)。

    code_mask    : 与 src 等长；**只有 code 字符保留**，注释 / 字符串 / 多行串
                   一律替换为空格（换行保留，保证行号不错位）。→ 给 R1/R3 用。
    noc_mask     : 与 src 等长；保留 code **与字符串**，只有注释替换为空格。
                   → 给 R2 用（它要看见 `? "已暂停"` 里的字面量）。
    string_spans : [(start, end, multiline)]，**字符串字面量**的区间（不含注释）。
    """
    n = len(src)
    keep = [' '] * n        # code_mask
    keep2 = [' '] * n       # noc_mask
    spans = []
    modes = []            # 每个字符的模式，仅供 span 判定用
    i = 0
    mode_stack = ['code']
    interp_depth = []
    block_depth = 0
    str_start = None
    str_ml = False

    while i < n:
        ch = src[i]
        mode = mode_stack[-1]
        modes.append(mode)

        if mode == 'lineComment':
            if ch == '\n':
                keep[i] = '\n'
                keep2[i] = '\n'
                mode_stack.pop()
            i += 1
            continue

        if mode == 'blockComment':
            if ch == '/' and i + 1 < n and src[i + 1] == '*':
                block_depth += 1
                i += 1
                continue
            if ch == '*' and i + 1 < n and src[i + 1] == '/':
                block_depth -= 1
                i += 1
                if block_depth == 0:
                    mode_stack.pop()
                continue
            if ch == '\n':
                keep[i] = '\n'
                keep2[i] = '\n'
            i += 1
            continue

        if mode == 'code':
            if ch == '/' and i + 1 < n and src[i + 1] == '/':
                mode_stack.append('lineComment')
                i += 1
                continue
            if ch == '/' and i + 1 < n and src[i + 1] == '*':
                block_depth = 1
                mode_stack.append('blockComment')
                i += 1
                continue
            if ch == '"':
                if src[i:i + 3] == '"""':
                    str_start = i
                    str_ml = True
                    mode_stack.append('multiline')
                    i += 3
                    continue
                str_start = i
                str_ml = False
                keep2[i] = ch          # 单行串开引号保留在 noc_mask（R2 要用）
                mode_stack.append('string')
                i += 1
                continue
            # 普通 code 字符：保留
            keep[i] = ch
            keep2[i] = ch
            if ch == '(' and interp_depth:
                interp_depth[-1] += 1
            elif ch == ')' and interp_depth:
                interp_depth[-1] -= 1
                if interp_depth[-1] == 0:
                    interp_depth.pop()
                    mode_stack.pop()
            i += 1
            continue

        if mode == 'string':
            if ch == '\\':
                keep2[i] = ch
                if i + 1 < n and src[i + 1] == '(':
                    # 进入插值：按 code 处理（插值里的代码要能判）
                    i += 2
                    interp_depth.append(1)
                    mode_stack.append('code')
                    continue
                i += 2
                continue
            if ch == '"':
                keep2[i] = ch
                spans.append((str_start, i + 1, False))
                mode_stack.pop()
                i += 1
                continue
            keep2[i] = ch
            i += 1
            continue

        if mode == 'multiline':
            if ch == '\\':
                i += 2
                continue
            if src[i:i + 3] == '"""':
                spans.append((str_start, i + 3, True))
                mode_stack.pop()
                i += 3
                continue
            if ch == '\n':
                keep[i] = '\n'
            i += 1
            continue

    return ''.join(keep), ''.join(keep2), spans


def line_of(src, pos):
    return src.count('\n', 0, pos) + 1


def line_text(src, ln):
    lines = src.split('\n')
    return lines[ln - 1] if 0 <= ln - 1 < len(lines) else ''


def is_allowed(relpath, line, rule):
    for glob, rx, reason in ALLOW:
        if fnmatch.fnmatch(relpath, glob) and re.search(rx, line):
            return reason
    return None


def check_file(relpath, src):
    """返回 (findings, allowed_count)。finding = (line, rule, snippet, reason_or_None)。"""
    findings = []
    allowed = 0
    code, noc, spans = classify(src)
    lines = src.split('\n')

    def suppressed(ln):
        cur = lines[ln - 1] if ln - 1 < len(lines) else ''
        prev = lines[ln - 2] if ln - 2 >= 0 else ''
        return bool(SUPPRESS_RE.search(cur) or SUPPRESS_RE.search(prev))

    def add(ln, rule, msg):
        nonlocal allowed
        line = lines[ln - 1] if ln - 1 < len(lines) else ''
        if suppressed(ln):
            allowed += 1
            return
        reason = is_allowed(relpath, line, rule)
        if reason is not None:
            allowed += 1
            return
        findings.append((ln, rule, msg, line.strip()))

    # R1：.stageText 读取（code 模式）
    for m in RE_STAGE_TEXT.finditer(code):
        add(line_of(src, m.start()), "R1", "读取 .stageText —— 视图层应读 .displayStage")

    # R2 / R5：状态文案三元推导（code+字符串 mask，需看见 `? "…"`）
    #   同一行可能同时含 `phase` 与 `isBusy`（如 `job.phase.isBusy ? "下载中"`）⇒ 用
    #   (行, 字面量) 去重，优先归到更具体的 R5（isBusy 作文案来源），避免同一处被报两遍。
    #   同一 (行, 字面量) 也不再由 R4 重复报（见下）——三条规则各司其职、不叠噪音。
    ternary_keys = set()
    busy_hits = set()
    for m in RE_TERNARY_BUSY.finditer(noc):
        lit = m.group(1)
        if lit in STATUS_LITERALS:
            ln = line_of(src, m.start())
            busy_hits.add((ln, lit))
            ternary_keys.add((ln, lit))
            add(ln, "R5",
                "用 isBusy/isPendingDownload 推导状态文案（%r）—— 该布尔含 .paused，"
                "应读 .displayStage" % lit)
    for m in RE_TERNARY_PHASE.finditer(noc):
        lit = m.group(1)
        if lit in STATUS_LITERALS:
            ln = line_of(src, m.start())
            if (ln, lit) in busy_hits:
                continue
            ternary_keys.add((ln, lit))
            add(ln, "R2",
                "在 phase 上三元推导状态文案（%r）—— 应读 .displayStage" % lit)

    # R3：phase.title（code 模式）
    for m in RE_PHASE_TITLE.finditer(code):
        add(line_of(src, m.start()), "R3",
            "直接调用 phase.title —— 状态文案的平行来源，确认应否改读 .displayStage")

    # R4：硬编码状态文案字面量（仅单行字符串 span）。已被 R2/R5 就同一 (行, 字面量)
    #     报过的，不再重复（避免一行报三条）。
    for (start, end, ml) in spans:
        if ml:
            continue
        content = src[start + 1:end - 1]
        if content in STATUS_LITERALS:
            ln = line_of(src, start)
            if (ln, content) in ternary_keys:
                continue
            add(ln, "R4",
                "硬编码状态文案 %r —— 应来自 .displayStage" % content)

    return findings, allowed


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv[1:]
    root = args[0] if args else "."

    views = os.path.join(root, VIEWS_SUBDIR)
    if not os.path.isdir(views):
        print("找不到视图层目录: %s" % views)
        print("用法: python swift_view_state_derivation.py [仓库根] [--strict]")
        return 2

    files = []
    for dirpath, _dirs, names in os.walk(views):
        for f in sorted(names):
            if f.endswith(".swift"):
                files.append(os.path.join(dirpath, f))

    total = 0
    allowed_total = 0
    err = 0
    warn = 0
    for path in sorted(files):
        try:
            src = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        rel = os.path.relpath(path, root).replace("\\", "/")
        findings, allowed = check_file(rel, src)
        allowed_total += allowed
        if not findings:
            continue
        for (ln, rule, msg, snippet) in findings:
            total += 1
            if rule in ("R1", "R2", "R4", "R5"):
                err += 1
                tag = "ERROR"
            else:
                warn += 1
                tag = "WARN "
            print("%s %s:%d  [%s] %s" % (tag, rel, ln, rule, msg))
            if snippet:
                print("        | %s" % snippet)

    print("-" * 72)
    print("扫描视图层文件: %d" % len(files))
    print("命中: %d（ERROR %d / WARN %d）　已豁免: %d 处" % (total, err, warn, allowed_total))
    if total == 0:
        print("✓ 视图层无「自行推导下载状态文案」——合规")
    failed = err > 0 or (strict and warn > 0)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
