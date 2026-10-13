#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「用 AppleID 已购列表下载下架应用」防复发检查.

背景（用户原话）：
    「我们现有的AppStore商店的默认AppleID商店则不支持搜索下架应用及下载下架应用 你需要移植过来」

机制（定案，见 `P4_全能签逆向/_简报/研究_IPARanger与下架应用下载.md`）：
    · **能搜到** = 已购列表 / 官方 lookup 有记录；
    · **能下载** = Apple 已购许可（`volumeStoreDownloadProduct` 对已购 App 即使下架仍发直链 + sinf）；
    · **二者缺一不可** —— 必须是「你买过 / 下过」的 App。
    上游 ipatool 的做法（`cmd/download.go:79`）：lookup 回 `ErrAppNotFound` **不中止**，
    只要 appID 有效就继续下；重试只认 `ErrPasswordTokenExpired`（重登）与 `ErrLicenseRequired`（购买）。

本脚本把这次移植的六条不变量机械守住（判据只认结构/符号，不绑行号、不绑文案）：

  D1  `PurchaseHistoryService.query` 必须同时带三种 media kind
      （131072 移动 / 262144 Arcade / 67108864 Mac）—— 只带一种会漏 Mac 端与部分 Arcade 已购。
  D2  `PurchaseHistoryService.storefronts` 必须同时含 `"34"` 与 `"13"`，
      且 `list(account:)` 里真的用到它（逐 store 轮询）。
  D3  `list(account:)` 必须按 id 合并（`merged`）并以 `requestStoreFront` 切出前缀
      —— 防退回「只取一个 storefront 的结果」。
  D4  `PurchaseHistoryView` 必须接 `startWithAppleID` —— 已购条目 → 下载入口。
  D5  `AppStoreView.runSearch` 搜不到时必须回落查已购（`fallbackOwnedMatches`）。
  D6  `AppStoreLocalInstallService.downloadInformation` 必须处理 `catalogUnavailable`
      （目录查不到 = 多为已下架）—— 对齐 ipatool「不中止」。
  D7  `PurchaseHistoryView` 必须能标出「已下架」（`delistedIds` + 文案「已下架」）
      —— 判据「已购里有、lookup 查不到 ⇒ 下架」，且仍保留下载入口。
  D8  `AppStoreView.runSearch` 必须**无条件**并入已购匹配：`ownedMatches` 那行必须来自
      `fallbackOwnedMatches` 且**不得**再用 `searchResults.isEmpty` 把回落门控起来
      —— 否则同名的在架应用一命中，下架那条永远搜不到。
  D9  `PurchaseHistoryService.parseItems` 不得对「Apple 只回部分记录」硬失败
      （DAAP 已购库无服务端分页，对齐 ipatool 不校验 mtco/mrco）——
      否则一个被截断的响应会让整个已购列表打不开。
  D10 `PurchaseHistoryView` 的已购行必须能点进详情（`NavigationLink` → `AppStoreDetailView`）
      —— 下架条目也要能进（详情页会走 NB 下架库补全，见 D13）。
  D11 `PurchaseHistoryView` 必须带「上架 / 下架」分段筛选（`Picker` + `.segmented` +
      两个分类字面量），否则用户没法只看下架应用。
  D12 `PurchaseHistoryService.offSaleIcons` 必须存在，且用 NB 下架库
      （`NBStoreClient.searchOffSaleApp` + `displayIcon`）给下架条目补图标
      —— 公开 lookup 对下架应用天然回空，图标只能来自下架库收录的 `iconPath`。
  D13 `AppStoreDetailView` 必须带 `delisted` 开关：下架态吃 NB 下架库内嵌的 `lookupDetail`
      补详情（不白屏），且不给「去 App Store 安装」（系统安装页对下架应用只会报找不到）。
  D14 `AppStoreVersionHistoryView` 必须带 `accountFirst` 开关，并在 `load()` 里真的用它
      —— 下架已购应用的「可下载版本」只有账号通道（App Store 下载协议）给得出。

用法：python3 swift_delisted_download_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import sys

BS = chr(92)   # 反斜杠
Q = chr(34)    # 双引号


def _mask_comments(src):
    """把注释（行注释 / 块注释，支持嵌套）替换为等长空白，**保留换行与字符串**.

    逐字符状态机：code / string / 多行串 / 行注释 / 块注释；字符串里的 `\\(` 插值切回
    code（插值内的注释照样屏蔽）。返回与 `src` **等长**的文本，行号可原样对齐。
    ⚠️ 字符串**不**屏蔽 —— D1/D2 要找的字面量（`131072` / `"34"`）就在串里。
    """
    out = []
    n = len(src)
    i = 0
    mode_stack = ["code"]
    interp_depth = []
    block_depth = 0
    while i < n:
        ch = src[i]
        mode = mode_stack[-1]

        if mode in ("lineComment", "blockComment"):
            if mode == "lineComment":
                if ch == "\n":
                    out.append(ch)
                    mode_stack.pop()
                else:
                    out.append(" ")
                i += 1
                continue
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                out.append(" ")
                out.append(" ")
                i += 2
                if block_depth == 0:
                    mode_stack.pop()
                continue
            out.append(ch if ch == "\n" else " ")
            i += 1
            continue

        if mode == "code":
            if ch == "/" and i + 1 < n and src[i + 1] == "/":
                mode_stack.append("lineComment")
                out.append(" ")
                i += 1
                continue
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth = 1
                mode_stack.append("blockComment")
                out.append(" ")
                i += 1
                continue
            if ch == Q:
                if src[i:i + 3] == Q * 3:
                    mode_stack.append("multiline")
                    out.append(src[i:i + 3])
                    i += 3
                    continue
                mode_stack.append("string")
                out.append(ch)
                i += 1
                continue
            if ch == "(" and interp_depth:
                interp_depth[-1] += 1
                out.append(ch)
                i += 1
                continue
            if ch == ")" and interp_depth:
                interp_depth[-1] -= 1
                if interp_depth[-1] == 0:
                    interp_depth.pop()
                    mode_stack.pop()
                out.append(ch)
                i += 1
                continue
            out.append(ch)
            i += 1
            continue

        if mode == "string":
            if ch == BS:
                if i + 1 < n and src[i + 1] == "(":
                    interp_depth.append(1)
                    mode_stack.append("code")
                    out.append(src[i:i + 2])
                    i += 2
                    continue
                out.append(src[i:i + 2])
                i += 2
                continue
            if ch == Q:
                mode_stack.pop()
            out.append(ch)
            i += 1
            continue

        if mode == "multiline":
            if ch == BS:
                out.append(src[i:i + 2])
                i += 2
                continue
            if src[i:i + 3] == Q * 3:
                mode_stack.pop()
                out.append(src[i:i + 3])
                i += 3
                continue
            out.append(ch)
            i += 1
            continue

    return "".join(out)


def _extract_function_body(src, signature_needle):
    """从 `signature_needle` 起，返回其函数体（含外层大括号）的文本；找不到返回 None.

    逐字符状态机：code / string / 多行串 / 行注释 / 块注释（支持嵌套），
    只在 code 模式数大括号；`\\(` 插值切回 code（插值里的括号/大括号都算）。
    """
    idx = src.find(signature_needle)
    if idx < 0:
        return None
    n = len(src)
    i = idx
    mode_stack = ["code"]
    interp_depth = []
    block_depth = 0
    depth = 0
    started = False
    start = None

    while i < n:
        ch = src[i]
        mode = mode_stack[-1]

        if mode == "lineComment":
            if ch == "\n":
                mode_stack.pop()
            i += 1
            continue

        if mode == "blockComment":
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    mode_stack.pop()
                continue
            i += 1
            continue

        if mode == "code":
            if ch == "/" and i + 1 < n and src[i + 1] == "/":
                mode_stack.append("lineComment")
                i += 1
                continue
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth = 1
                mode_stack.append("blockComment")
                i += 1
                continue
            if ch == Q:
                if src[i:i + 3] == Q * 3:
                    mode_stack.append("multiline")
                    i += 3
                    continue
                mode_stack.append("string")
                i += 1
                continue
            if ch == "(" and interp_depth:
                interp_depth[-1] += 1
                i += 1
                continue
            if ch == ")" and interp_depth:
                interp_depth[-1] -= 1
                if interp_depth[-1] == 0:
                    interp_depth.pop()
                    mode_stack.pop()
                i += 1
                continue
            if ch == "{":
                if not started:
                    started = True
                    start = i
                depth += 1
                i += 1
                continue
            if ch == "}":
                if started:
                    depth -= 1
                    if depth == 0:
                        return src[start:i + 1]
                i += 1
                continue
            i += 1
            continue

        if mode == "string":
            if ch == BS:
                if i + 1 < n and src[i + 1] == "(":
                    interp_depth.append(1)
                    mode_stack.append("code")
                    i += 2
                    continue
                i += 2
                continue
            if ch == Q:
                mode_stack.pop()
                i += 1
                continue
            i += 1
            continue

        if mode == "multiline":
            if ch == BS:
                i += 2
                continue
            if src[i:i + 3] == Q * 3:
                mode_stack.pop()
                i += 3
                continue
            i += 1
            continue

    return None


def _decl_span(masked, start_needle, stop_needle):
    """取 `start_needle` 到 `stop_needle` 之间的文本（两者都找不到就返回 ""）."""
    a = masked.find(start_needle)
    if a < 0:
        return ""
    b = masked.find(stop_needle, a + len(start_needle))
    return masked[a:b if b >= 0 else len(masked)]


def _line_span(masked, start_needle):
    """取 `start_needle` 所在那一行（到换行为止）."""
    a = masked.find(start_needle)
    if a < 0:
        return ""
    b = masked.find("\n", a)
    return masked[a:b if b >= 0 else len(masked)]


def check(root):
    errs = []
    engine = os.path.join(root, "EscapeOS", "Engine", "PurchaseHistoryService.swift")
    history_view = os.path.join(root, "EscapeOS", "Views", "PurchaseHistoryView.swift")
    store_view = os.path.join(root, "EscapeOS", "Views", "AppStoreView.swift")
    install = os.path.join(root, "EscapeOS", "Engine", "AppStoreLocalInstallService.swift")
    detail_view = os.path.join(root, "EscapeOS", "Views", "AppStoreDetailView.swift")
    version_view = os.path.join(root, "EscapeOS", "Views", "AppStoreVersionHistoryView.swift")

    # ── D1 / D2 / D3：已购查询补全（三 media kind + storefront 轮询 + 合并）──
    if not os.path.isfile(engine):
        errs.append("[D1] 找不到 %s" % engine)
    else:
        masked = _mask_comments(io.open(engine, encoding="utf-8").read())

        # D1：query 声明段（到 storefronts 声明为止）必须含三种 media kind
        span = _decl_span(masked, "static let query", "static let storefronts")
        if not span:
            errs.append("[D1] PurchaseHistoryService.swift 里找不到 `static let query` —— 已购查询语句被删？")
        else:
            for kind in ("131072", "262144", "67108864"):
                if kind not in span:
                    errs.append("[D1] query 缺少 media kind %s —— 只带一种会漏 Mac 端 / 部分 Arcade 已购"
                                "（对齐 ipatool appstore_owned_apps.go:184 的三 kind AND）" % kind)

        # D2：storefronts 声明行必须同时含 "34" 与 "13"
        line = _line_span(masked, "static let storefronts")
        if not line:
            errs.append("[D2] 找不到 `static let storefronts` —— storefront 轮询清单被删？")
        else:
            for store in (Q + "34" + Q, Q + "13" + Q):
                if store not in line:
                    errs.append("[D2] storefronts 缺少 %s —— Configurator(34) 与 Mac App Store(13) 都要轮询"
                                "（只查一个会漏另一端的已购）" % store)

        # D2/D3：list(account:) 里真的在轮询 + 合并
        body = _extract_function_body(masked, "func list(account: inout AppStoreAccount)")
        if body is None:
            errs.append("[D2] 找不到 `list(account:)` —— 已购轮询主函数被删？")
        else:
            if "storefronts" not in body:
                errs.append("[D2] list(account:) 没有用到 storefronts —— storefront 轮询被摘掉了")
            if "requestStoreFront" not in body:
                errs.append("[D3] list(account:) 没有从 requestStoreFront 切出 storefront 前缀"
                            "（对齐 Go 的 strings.Cut(acc.StoreFront, \",\")）")
            if "merged" not in body:
                errs.append("[D3] list(account:) 没有按 id 合并（merged）—— 退回「只取一个 store 的结果」会丢条目")

    # ── D4 / D7：已购条目 → 下载入口 + 「已下架」标记 ──
    if not os.path.isfile(history_view):
        errs.append("[D4] 找不到 %s" % history_view)
    else:
        masked = _mask_comments(io.open(history_view, encoding="utf-8").read())
        if "startWithAppleID" not in masked:
            errs.append("[D4] PurchaseHistoryView 没有接 startWithAppleID —— 已购列表又退回「只读」")
        # D7：「已下架」标记（判据 = 已购里有、lookup 查不到 ⇒ 下架；仍保留下载）
        if "delistedIds" not in masked:
            errs.append("[D7] PurchaseHistoryView 没有 delistedIds —— "
                        "「已购里有 / lookup 查不到 ⇒ 已下架」的判定被删")
        elif "已下架" not in masked:
            errs.append("[D7] PurchaseHistoryView 没有「已下架」文案 —— 下架应用在列表里看不出来")

    # ── D5 / D8：搜索回落已购（且必须无条件并入）──
    if not os.path.isfile(store_view):
        errs.append("[D5] 找不到 %s" % store_view)
    else:
        masked = _mask_comments(io.open(store_view, encoding="utf-8").read())
        body = _extract_function_body(masked, "func runSearch()")
        if body is None:
            errs.append("[D5] 找不到 AppStoreView.runSearch() —— 搜索入口被删？")
        else:
            call = body.find("fallbackOwnedMatches")
            if call < 0:
                errs.append("[D5] runSearch 没有回落查已购（fallbackOwnedMatches）"
                            " —— 下架应用在公开 search 里天然缺席，搜不到就永远搜不到")
            else:
                # D8：回落那一行必须直接并入 ownedMatches，且不得再被 searchResults.isEmpty 门控
                line_start = body.rfind("\n", 0, call) + 1
                line_end = body.find("\n", call)
                line = body[line_start: line_end if line_end >= 0 else len(body)]
                if "ownedMatches" not in line:
                    errs.append("[D8] runSearch 的回落结果没有赋给 ownedMatches —— 搜到的已购项没进列表")
                if "isEmpty" in line:
                    errs.append("[D8] runSearch 仍用 searchResults.isEmpty 门控回落 —— "
                                "同名在架应用一命中，下架那条永远搜不到（必须无条件并入并按 id 去重）")

    # ── D6：目录查不到（已下架）不中止 ──
    if not os.path.isfile(install):
        errs.append("[D6] 找不到 %s" % install)
    else:
        masked = _mask_comments(io.open(install, encoding="utf-8").read())
        body = _extract_function_body(masked, "func downloadInformation(software: Software")
        if body is None:
            errs.append("[D6] 找不到 AppStoreLocalInstallService.downloadInformation —— 下载状态机被删？")
        elif "catalogUnavailable" not in body:
            errs.append("[D6] downloadInformation 没有处理 catalogUnavailable"
                        " —— 目录查不到（多为已下架）会硬失败，违背 ipatool「ErrAppNotFound 不中止」")

    # ── D9：已购响应被截断时不硬失败（DAAP 无服务端分页）──
    if os.path.isfile(engine):
        masked = _mask_comments(io.open(engine, encoding="utf-8").read())
        body = _extract_function_body(masked, "static func parseItems(")
        if body is None:
            errs.append("[D9] 找不到 PurchaseHistoryService.parseItems —— DAAP 解析被删？")
        else:
            if "guard total == returned" in body:
                errs.append("[D9] parseItems 又对「只回部分记录」硬失败（guard total == returned）"
                            " —— 被截断的响应会让整个已购列表打不开，对齐 ipatool 应接受部分结果")
            elif "total != returned" not in body:
                errs.append("[D9] parseItems 没有处理「部分记录」（total != returned）"
                            " —— 需降级为记录日志并按已返回条目继续")

    # ── D10 / D11：已购行可点进详情 + 「上架 / 下架」分段筛选 ──
    if os.path.isfile(history_view):
        masked = _mask_comments(io.open(history_view, encoding="utf-8").read())
        # D10：行内导航到 AppStoreDetailView（下架条目同样可进）
        if "NavigationLink" not in masked or "AppStoreDetailView(" not in masked:
            errs.append("[D10] PurchaseHistoryView 的已购行没有 NavigationLink 到 AppStoreDetailView"
                        " —— 已购条目又点不进详情")
        # D11：分段筛选（Picker + .segmented + 「上架」/「下架」两个分类字面量）
        if "Picker(" not in masked or ".pickerStyle(.segmented)" not in masked:
            errs.append("[D11] PurchaseHistoryView 没有分段筛选（Picker + .pickerStyle(.segmented)）")
        for label in (Q + "上架" + Q, Q + "下架" + Q):
            if label not in masked:
                errs.append("[D11] PurchaseHistoryView 的分段筛选缺少分类 %s —— "
                            "用户要能只看「上架 / 下架」" % label)

    # ── D12：下架图标来自 NB 下架库 ──
    if os.path.isfile(engine):
        masked = _mask_comments(io.open(engine, encoding="utf-8").read())
        body = _extract_function_body(masked, "static func offSaleIcons(")
        helper = _extract_function_body(masked, "static func offSaleIcon(")
        if body is None:
            errs.append("[D12] PurchaseHistoryService.offSaleIcons 不存在"
                        " —— 下架应用在已购列表里会一直只有字母块（公开 lookup 查不到它们）")
        elif helper is None:
            errs.append("[D12] offSaleIcons 缺少单条实现 offSaleIcon(for:) —— 下架图标来源被删")
        else:
            if "searchOffSaleApp" not in helper:
                errs.append("[D12] offSaleIcon 没有走 NB 下架库（searchOffSaleApp）—— 拿不到下架图标")
            if "displayIcon" not in helper:
                errs.append("[D12] offSaleIcon 没有取 displayIcon（iconPath / lookupArtwork）—— 图标来源被删")

    # ── D13：下架详情（NB 快照补全 + 不给系统安装入口）──
    if not os.path.isfile(detail_view):
        errs.append("[D13] 找不到 %s" % detail_view)
    else:
        masked = _mask_comments(io.open(detail_view, encoding="utf-8").read())
        if "var delisted: Bool" not in masked:
            errs.append("[D13] AppStoreDetailView 没有 delisted 开关 —— 下架态无从区分，详情会白屏")
        body = _extract_function_body(masked, "func mergeDelistedDetail(")
        if body is None:
            errs.append("[D13] AppStoreDetailView 没有 mergeDelistedDetail —— "
                        "下架应用 Apple lookup 天然回空，必须吃 NB 下架库内嵌的 lookup 快照")
        else:
            if "searchOffSaleApp" not in body or "lookupDetail" not in body:
                errs.append("[D13] mergeDelistedDetail 没有用 NB 下架库的 lookupDetail 补详情")
        if "if !delisted" not in masked:
            errs.append("[D13] AppStoreDetailView 没有在下架态收起「去 App Store 安装」"
                        "（系统安装页对下架应用只会报找不到）")

    # ── D14：历史版本「账号通道优先」（下架已购应用）──
    if not os.path.isfile(version_view):
        errs.append("[D14] 找不到 %s" % version_view)
    else:
        masked = _mask_comments(io.open(version_view, encoding="utf-8").read())
        if "var accountFirst: Bool" not in masked:
            errs.append("[D14] AppStoreVersionHistoryView 没有 accountFirst 开关 —— "
                        "下架已购应用的可下载版本只有账号通道给得出")
        body = _extract_function_body(masked, "func load()")
        if body is None:
            errs.append("[D14] 找不到 AppStoreVersionHistoryView.load() —— 加载入口被删？")
        elif "accountFirst" not in body:
            errs.append("[D14] load() 没有用 accountFirst 调整通道顺序 —— 下架态仍先走必然为空的三方目录")

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_delisted_download_guard.py <仓库根>")
        return 2
    root = sys.argv[1]
    if not os.path.isdir(os.path.join(root, "EscapeOS")):
        print("仓库根下找不到 EscapeOS/ ：%s" % os.path.abspath(root))
        return 2
    errs = check(root)
    print("-" * 72)
    if errs:
        for e in errs:
            print("ERROR %s" % e)
        print("命中：%d（D1 三 media kind / D2 storefront 轮询 34+13 / D3 按 id 合并 / "
              "D4 已购→下载入口 / D5 搜索回落已购 / D6 目录查不到不中止 / "
              "D7 已下架标记 / D8 搜索无条件并入已购 / D9 截断不硬失败 / "
              "D10 行可点进详情 / D11 上架下架分段筛选 / D12 NB 下架图标 / "
              "D13 下架详情 NB 快照 / D14 历史版本账号通道优先）" % len(errs))
        return 1
    print("D1 已购 query 带三种 media kind（131072 / 262144 / 67108864）：OK")
    print("D2 storefront 轮询 34 + 13：OK")
    print("D3 按 id 合并去重：OK")
    print("D4 已购条目接 startWithAppleID（下载入口）：OK")
    print("D5 搜索搜不到时回落查已购：OK")
    print("D6 目录查不到（已下架）不中止：OK")
    print("D7 已购列表标「已下架」（delistedIds + 文案）：OK")
    print("D8 搜索无条件并入已购匹配（不再被 searchResults.isEmpty 门控）：OK")
    print("D9 已购响应截断时不硬失败（对齐 ipatool 无服务端分页）：OK")
    print("D10 已购行可点进详情（NavigationLink → AppStoreDetailView）：OK")
    print("D11 已购列表带上架 / 下架分段筛选：OK")
    print("D12 下架图标来自 NB 下架库（searchOffSaleApp + displayIcon）：OK")
    print("D13 下架详情吃 NB 快照补全 + 收起系统安装入口：OK")
    print("D14 历史版本「账号通道优先」（下架已购应用）：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
