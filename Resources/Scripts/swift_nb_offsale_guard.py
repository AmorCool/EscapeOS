#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NB 下架取包链路防复发检查（v0.3.587）.

对应三轮修复（v0.3.586 补回退 / v0.3.587 把 code=7 如实处理 + 界面去内部码 /
v0.3.588 内嵌快照直链过期即现取），把四条**只有人工 review 才看得出**的不变量机械守住，
防「拆东补西」式回归：

  G1  `EscapeOS/Engine/NBStoreClient.swift` 的 `offSalePackage` 必须保留
      「内嵌包缺失 → 回退 `getAppHistoryList` 取包」这条回退（有人删回退即报）。
      取包调用现落在 `packageWithFallback(...)`（v0.3.592 起），故 `package(appID:...)` 与
      `packageWithFallback(...)` 二者出现其一即算通过。
  G2  同函数必须处理服务端 `code=7`（不得让 `StoreError.server(code:"7")` 直接
      冒到界面）—— 要么回 `nil`、要么转成用户看得懂的结果。
  G3  `EscapeOS/Views/I4StoreFreeView.swift` 的 `installOffSale` 里，面向用户的
      `ToastCenter.shared.show` 不得直接插 `error.localizedDescription`
      （NB 的 `StoreError.server` 会把它格式化成 `msg（7）`，内部码会随之漏给用户）。
  G4  同 `offSalePackage` 必须对**内嵌快照直链**做 `accessKeyExpired(...)` 过期判断
      （v0.3.588）—— 快照直链的 accessKey 过期即 HTTP 403，无条件用它会导致下载必失败。
  G5  `EscapeOS/Views/NBStoreDetailView.swift` 的 `installVersion`（详情页按版本取包）里，
      `ToastCenter.shared.show` 同样不得插 `error.localizedDescription`
      （v0.3.590）—— 详情页原先漏了这条约束，用户看到「取包失败：未获取到数据（7）」这种内部码。
  G6  `getAppHistoryList` 取包必须带**版本回退**（v0.3.592）：`packageWithFallback` 存在，
      且里面**真的打接口**（`package(appID:...)`）、**遍历候选版本**（`candidates`）、
      **有尝试上限**（`maxAttempts`）、**回退时记日志**（含「回退」字样）；
      并且 `offSalePackage` 必须走它 —— 最新版 `code=7` 时不再一次失败就报「库里没包」。
  G7  `packageWithFallback` 遇**上游临时故障**（`isUpstreamBusy(...)`）**不得中途 `throw`**
      （v0.3.592 补）—— 实测（`nb_fallback_chain_probe.py`）这类 `dialing … timed out`
      是**随机落在某一步**的：若在此 `throw`，一次抽风就废掉整条回退链（本该走到后面某步
      命中，却当场把「请稍后重试」甩给用户）。必须记下并 `continue`，全链都没命中再抛。
  G8  `offSalePackage` 现取之后必须**回落到内嵌快照**（v0.3.593 补）—— 内嵌快照要一直持有
      （`embeddedOffSalePackage(...)`），且 `packageWithFallback(...)` **之后**必须出现
      `return embedded`。防 v0.3.588 那处回归重演：内嵌快照过期/判不出即弃用、现取失败又
      不回落 ⇒ 有快照的 App 也拿不到任何链接，用户「获取不到下载任务」。

判据全部**只认结构/符号**（函数体里出现哪个调用 / 哪个字面量），不绑死行号、不绑死文案，
以免将来改文案就误报。函数体用逐字符状态机按大括号配对提取（跳过字符串/注释）。

用法：python3 swift_nb_offsale_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import re
import sys

BS = chr(92)   # 反斜杠
Q = chr(34)    # 双引号


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
    interp_depth = []          # 每层插值的括号深度
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


def _toast_show_arg_leaks_localized(body):
    """body 里是否有 `ToastCenter.shared.show(...)` 的实参插了 `localizedDescription`.

    只做「就近」判断：`ToastCenter.shared.show(` 之后到本语句结束（`)` 或 `;`）之间
    出现 `localizedDescription` 即算泄漏。够用且不误伤 `LoginLogger` 日志（它允许带原始 error）。
    """
    needle = "ToastCenter.shared.show("
    leaks = []
    pos = 0
    while True:
        k = body.find(needle, pos)
        if k < 0:
            break
        j = k + len(needle)
        depth = 1
        buf = []
        while j < len(body) and depth > 0:
            c = body[j]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            buf.append(c)
            j += 1
        if "localizedDescription" in "".join(buf):
            leaks.append("".join(buf).strip()[:120])
        pos = j + 1
    return leaks


def check(root):
    errs = []
    engine = os.path.join(root, "EscapeOS", "Engine", "NBStoreClient.swift")
    view = os.path.join(root, "EscapeOS", "Views", "I4StoreFreeView.swift")

    # ── G1 / G2：引擎侧回退 + code=7 处理 ──
    if not os.path.isfile(engine):
        errs.append("[G1] 找不到 %s" % engine)
    else:
        src = io.open(engine, encoding="utf-8").read()
        body = _extract_function_body(src, "func offSalePackage(")
        if body is None:
            errs.append("[G1] NBStoreClient.swift 里找不到 offSalePackage —— 下架取包入口被删？")
        else:
            if ("package(appID:" not in body) and ("packageWithFallback(" not in body):
                errs.append("[G1] offSalePackage 没有回退调用 getAppHistoryList 取包"
                            "（package(appID:...) / packageWithFallback(...) 都找不到）"
                            " —— 内嵌包缺失时又会直接失败")
            if '"7"' not in body:
                errs.append("[G2] offSalePackage 没有处理服务端 code=7"
                            " —— StoreError.server(code:\"7\") 会直接冒到界面（内部码漏给用户）")
            if "accessKeyExpired(" not in body:
                errs.append("[G4] offSalePackage 直接用了内嵌快照直链而没做 accessKey 过期判断"
                            " —— 快照直链的 accessKey 过期即 HTTP 403，下载必失败"
                            "（v0.3.588 实测 8/8 全 403；过期/判不出都必须改现取）")

            # ── G8：现取之后必须回落到内嵌快照（v0.3.593 补）──
            # v0.3.588 的回归：内嵌快照过期/判不出即弃用，现取失败（nil / throw）又不回落
            # ⇒ 有快照的 App 也拿不到链接，用户「获取不到下载任务」。这里机械守住两点：
            #   ① 内嵌快照要一直持有（`embeddedOffSalePackage(...)`）；
            #   ② `packageWithFallback(...)` **之后**必须出现 `return embedded`。
            if "embeddedOffSalePackage(" not in body:
                errs.append("[G8] offSalePackage 不再持有内嵌快照（缺 embeddedOffSalePackage(...)）"
                            " —— 快照兜底被删，现取失败就回 nil，用户「获取不到下载任务」")
            else:
                idx_fb = body.find("packageWithFallback(")
                if idx_fb >= 0 and "return embedded" not in body[idx_fb:]:
                    errs.append("[G8] offSalePackage 现取之后没有回落到内嵌快照"
                                "（packageWithFallback(...) 之后缺 return embedded）"
                                " —— 现取一失败又回 nil（v0.3.588 回归：有快照也拿不到链接）")

        # ── G6：getAppHistoryList 取包必须带「版本回退」（v0.3.592）──
        fb = _extract_function_body(src, "func packageWithFallback(")
        if fb is None:
            errs.append("[G6] NBStoreClient.swift 里找不到 packageWithFallback"
                        " —— 「最新版 code=7 自动换旧版本」的回退被删了？")
        else:
            if "package(appID:" not in fb:
                errs.append("[G6] packageWithFallback 没有真正打 getAppHistoryList"
                            "（缺 package(appID:...)）")
            if "candidates" not in fb:
                errs.append("[G6] packageWithFallback 没有遍历候选版本（缺 candidates）"
                            " —— 回退链断了")
            if "maxAttempts" not in fb:
                errs.append("[G6] packageWithFallback 没有尝试上限（缺 maxAttempts）—— 会无限试")
            if "回退" not in fb:
                errs.append("[G6] packageWithFallback 回退时不记日志（缺「回退」字样）"
                            " —— 出问题无法排查")

            # ── G7：上游临时故障不得中途中断回退链（v0.3.592 补）──
            # 实测（nb_fallback_chain_probe.py）dialing 超时是**随机落在某一步**的：
            # 若在 `isUpstreamBusy(...)` 分支里直接 `throw`，一次抽风就废掉整条链
            # （本该走到后面某步命中却当场报错）。必须记下并 `continue`。
            if "isUpstreamBusy(" not in fb:
                errs.append("[G7] packageWithFallback 不再区分「上游临时故障」"
                            " —— 会把临时故障当成「库里没包」如实报错（用户重试也没用）")
            elif re.search(r"isUpstreamBusy\([^)]*\)\s*\{\s*throw", fb):
                errs.append("[G7] packageWithFallback 在「上游临时故障」分支里 throw"
                            " —— 中途中断整条回退链；一次抽风就废掉本该成功的回退"
                            "（应记下并 continue，见 nb_fallback_chain_probe.py 实测）")
        if body is not None and "packageWithFallback(" not in body:
            errs.append("[G6] offSalePackage 没走 packageWithFallback"
                        " —— 最新版 code=7 时不会回退旧版本，一次失败就报「库里没包」")

    # ── G3：界面不得把原始 error 甩给用户 ──
    if not os.path.isfile(view):
        errs.append("[G3] 找不到 %s" % view)
    else:
        src = io.open(view, encoding="utf-8").read()
        body = _extract_function_body(src, "func installOffSale(")
        if body is None:
            errs.append("[G3] I4StoreFreeView.swift 里找不到 installOffSale")
        else:
            leaks = _toast_show_arg_leaks_localized(body)
            for arg in leaks:
                errs.append("[G3] installOffSale 把原始 error 直接弹给用户（内部码会漏出）："
                            "ToastCenter.shared.show(%s)" % arg)

    # ── G5：NB 详情页取包也不得把原始 error 甩给用户（v0.3.590 补）──
    detail = os.path.join(root, "EscapeOS", "Views", "NBStoreDetailView.swift")
    if not os.path.isfile(detail):
        errs.append("[G5] 找不到 %s" % detail)
    else:
        src = io.open(detail, encoding="utf-8").read()
        body = _extract_function_body(src, "func installVersion(")
        if body is None:
            errs.append("[G5] NBStoreDetailView.swift 里找不到 installVersion")
        else:
            leaks = _toast_show_arg_leaks_localized(body)
            for arg in leaks:
                errs.append("[G5] installVersion 把原始 error 直接弹给用户（内部码会漏出）："
                            "ToastCenter.shared.show(%s)" % arg)

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_nb_offsale_guard.py <仓库根>")
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
        print("命中：%d（G1 回退 / G2 code=7 / G3 界面内部码 / G4 快照过期 / G5 详情页内部码"
              " / G6 版本回退 / G7 上游故障不中断 / G8 快照兜底）" % len(errs))
        return 1
    print("G1 回退 getAppHistoryList：OK")
    print("G2 code=7 处理：OK")
    print("G3 界面无内部码泄漏：OK")
    print("G4 内嵌快照 accessKey 过期判断：OK")
    print("G5 详情页无内部码泄漏：OK")
    print("G6 版本回退（code=7 换旧版本）：OK")
    print("G7 上游临时故障不中断回退链：OK")
    print("G8 现取失败回落内嵌快照：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
