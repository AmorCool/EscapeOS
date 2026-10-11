#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「开启高级功能」入口防复发检查（v0.3.xxx，第二版）.

背景（用户原话，两轮）：
    第一轮：「爱思为什么不能开启高级功能 如图 你到底有没有认真搞」
        ⇒ 旧入口是 `advancedShown = true` 直接弹一句**写死的免责声明**
          （「本机未安装该 App 时，此入口无法生效」），从不检测、也从不开启任何东西.
    第二轮：「爱思「开启高级功能」你没做好而且这个是单独一个功能」
        ⇒ ① 要**真正实现**（不是弹「尚未实现」的窗）；② 要有**独立入口**.

本版守住的不变量（第一版只守「不许退回写死声明」，本版加守「必须真实现 + 独立入口」）：

  G1  `EscapeOS/Views/I4MobileInstallView.swift` 不得再出现那句写死的免责声明
      （判据：代码里不出现「本机未安装该 App 时」）.
  G2  同文件必须**引用独立页** `I4AdvancedView(` —— 那个按钮必须连到真实现，
      不得再自己弹窗回话（删掉接线即报）.
  G3  `EscapeOS/Engine/I4PairingService.swift` 必须存在，且真的走 house_arrest 写沙盒
      （判据：同时出现 `openAppDocuments` 与 `8es1421dg.be`）.
  G4  `EscapeOS/Views/I4AdvancedView.swift` 必须存在，且连到引擎
      （判据：出现 `I4PairingService`）.
  G5  `EscapeOS/Views/TreasureBoxView.swift` 必须含独立入口回调
      （判据：出现 `onOpenI4Advanced`）.
  G6  `EscapeOS/Views/HomeView.swift` 必须把独立页接进导航栈
      （判据：出现 `I4AdvancedView(`）.
  G7  `EscapeOS/Engine/I4MobileInstallService.swift` 必须定义载体常量
      `static let agentBundleId = "com.ownbook.notes"`.

第三版新增（守住「现场配对（路径 A）」的真实现与如实回报）：

  G8  `EscapeOS/Engine/I4PairingService.swift` 必须含现场配对**真实现**
      （判据：同时出现 `lockdownd_pair` 与 `idevice_pairing_file_serialize`）——
      缺任一即报，防止「现场配对」被删成空壳.
  G9  同文件必须**如实回报设备错误**（判据：出现 `deviceError`）——
      防止把「设备拒绝 Pair」吞掉、假装成功.
  G10 `EscapeOS/Views/I4AdvancedView.swift` 必须暴露现场配对入口并渲染结果
      （判据：同时出现 `attemptLockdownPair` 与 `livePairResultCard`）.

第四版新增（守住「写入失败」的真根因修复）：

  G11 `EscapeOS/Engine/FileSharingService.swift` 必须在 house_arrest vend 之后**验活**
      （判据：出现 `verifiedSession`）—— 底层 crate 的 vend 只读应答不判 Status，
      不验活就会把 vend 失败推迟成误导性的「创建文件失败」.
  G12 `EscapeOS/Engine/I4PairingService.swift` 必须在写入前**确保载体有数据容器**
      （判据：同时出现 `ensureCarrierContainer` 与 `launchApp`）—— 载体从未启动时
      iOS 不给数据容器，直接写必失败；必须先启动一次让它建容器.

第五版新增（守住「未受信 lockdown 服务优先 + 受信回退」的真实现）：

  G13 `EscapeOS/Engine/I4PairingService.swift` 必须**先连未受信 lockdown 服务**
      （判据：同时出现 `com.apple.mobile.lockdown.remote.untrusted` 与
      `lockdownd_connect_rsd_named`）—— 配对（`Pair`）本该走未受信那条；
      退回只连受信版（上游写死）即报.
  G14 同文件必须保留**受信版回退**（判据：出现 `com.apple.mobile.lockdown.remote.trusted`）——
      旧系统 / 服务表无未受信版时仍需回退，删掉回退即报.

第六版新增（守住「载体 Documents 路径必须带 /Documents 前缀」的真根因修复）：

  G15 `EscapeOS/Engine/FileSharingService.swift` 必须定义 `static let appDocumentsPath = "/Documents"`
      且 `EscapeOS/Engine/I4PairingService.swift` 必须经 `FileSharingService.appDocumentsPath`
      拼载体文件路径（判据：两文件分别出现 `appDocumentsPath`）.
      真机 iPhone 11 实证：house_arrest `VendDocuments` 会话的 **AFC 根是数据容器**，
      载体 Documents 在其下（`/Documents`）；写 `/pair.config`（容器根）⇒ AFC `FILE_OPEN`
      status 10、写 `/Documents/pair.config` ⇒ 成功. I4 曾用容器根路径直写，故报「创建文件失败」.
      退回硬编码容器根路径即报.

判据只认结构 / 符号，不绑死行号与展示文案，改文案不会误报。

用法：python3 swift_i4_advanced_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import sys


def _read(path):
    if not os.path.isfile(path):
        return None
    return io.open(path, encoding="utf-8").read()


def _strip_comments(src):
    r"""去掉注释、**保留字符串**的源码文本（G1 只在代码里找旧文案，注释里提到它不算违规）.

    逐字符状态机：行注释 / 块注释（支持嵌套）/ 单行串 / 三引号串。注释内容替换为空格
    （换行保留）；字符串原样保留（旧文案若被重新写进字符串，仍会被 G1 抓到）。
    转义 `\x` 跳过一对；`\\(` 插值不特殊处理（插值里出现 `//` 的场合本文件不存在）。
    """
    n = len(src)
    out = [' '] * n
    i = 0
    mode = "code"          # code / line / block / string / multiline
    block_depth = 0
    while i < n:
        ch = src[i]
        if mode == "line":
            if ch == "\n":
                out[i] = "\n"
                mode = "code"
            i += 1
            continue
        if mode == "block":
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    mode = "code"
                continue
            if ch == "\n":
                out[i] = "\n"
            i += 1
            continue
        if mode == "string":
            out[i] = ch
            if ch == chr(92):
                if i + 1 < n:
                    out[i + 1] = src[i + 1]
                i += 2
                continue
            if ch == '"':
                mode = "code"
            i += 1
            continue
        if mode == "multiline":
            out[i] = ch
            if ch == chr(92):
                if i + 1 < n:
                    out[i + 1] = src[i + 1]
                i += 2
                continue
            if src[i:i + 3] == '"' * 3:
                out[i + 1] = '"'
                out[i + 2] = '"'
                mode = "code"
                i += 3
                continue
            i += 1
            continue
        # mode == code
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            mode = "line"
            i += 2
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            mode = "block"
            block_depth = 1
            i += 2
            continue
        if src[i:i + 3] == '"' * 3:
            out[i] = '"'
            out[i + 1] = '"'
            out[i + 2] = '"'
            mode = "multiline"
            i += 3
            continue
        if ch == '"':
            out[i] = ch
            mode = "string"
            i += 1
            continue
        out[i] = ch
        i += 1
    return "".join(out)


def check(root):
    errs = []
    view = os.path.join(root, "EscapeOS", "Views", "I4MobileInstallView.swift")
    engine = os.path.join(root, "EscapeOS", "Engine", "I4MobileInstallService.swift")
    pairing = os.path.join(root, "EscapeOS", "Engine", "I4PairingService.swift")
    file_sharing = os.path.join(root, "EscapeOS", "Engine", "FileSharingService.swift")
    adv_view = os.path.join(root, "EscapeOS", "Views", "I4AdvancedView.swift")
    treasure = os.path.join(root, "EscapeOS", "Views", "TreasureBoxView.swift")
    home = os.path.join(root, "EscapeOS", "Views", "HomeView.swift")

    # ---- I4MobileInstallView.swift ----
    src = _read(view)
    if src is None:
        errs.append("[G1] 找不到 %s" % view)
    else:
        code = _strip_comments(src)   # 只在代码里判 G1；注释里提到旧文案不算违规
        if "本机未安装该 App 时" in code:
            errs.append("[G1] I4MobileInstallView.swift 又出现写死的免责声明"
                        "「本机未安装该 App 时……」—— 这是「不看设备就回话」的旧 bug，已删除，勿回退")
        if "I4AdvancedView(" not in code:
            errs.append("[G2] I4MobileInstallView.swift 未引用独立页 I4AdvancedView( ——"
                        "「开启高级功能」按钮必须连到真实现，不得再自己弹窗回话")

    # ---- I4PairingService.swift（真实现：house_arrest 写沙盒）----
    psrc = _read(pairing)
    if psrc is None:
        errs.append("[G3] 找不到 %s（真实现引擎缺失）" % pairing)
    else:
        pcode = _strip_comments(psrc)
        if "openAppDocuments" not in pcode or "8es1421dg.be" not in pcode:
            errs.append("[G3] I4PairingService.swift 未真的经 house_arrest 写沙盒"
                        "（缺 openAppDocuments 或 8es1421dg.be）—— 会退回「只说不做」")
        # G8：现场配对（路径 A）真实现 —— 缺任一 FFI 符号即报，防删成空壳.
        if "lockdownd_pair" not in pcode or "idevice_pairing_file_serialize" not in pcode:
            errs.append("[G8] I4PairingService.swift 缺现场配对真实现"
                        "（需同时出现 lockdownd_pair 与 idevice_pairing_file_serialize）——"
                        "「尝试现场配对」会退回空壳")
        # G9：如实回报设备错误 —— 防把「设备拒绝 Pair」吞掉、假装成功.
        if "deviceError" not in pcode:
            errs.append("[G9] I4PairingService.swift 未如实回报设备错误（缺 deviceError）——"
                        "设备拒绝 Pair 会被吞掉，可能假装成功")
        # G12：写入前确保载体有数据容器 —— 载体从未启动时 house_arrest 拿不到 Documents.
        if "ensureCarrierContainer" not in pcode or "launchApp" not in pcode:
            errs.append("[G12] I4PairingService.swift 未在写入前确保载体有数据容器"
                        "（需同时出现 ensureCarrierContainer 与 launchApp）——"
                        "载体从未启动时会直接写、报「创建文件失败」")
        # G13：先连未受信 lockdown 服务（配对本该走的那条）—— 防退回只连受信版.
        if "com.apple.mobile.lockdown.remote.untrusted" not in pcode or "lockdownd_connect_rsd_named" not in pcode:
            errs.append("[G13] I4PairingService.swift 未先连未受信 lockdown 服务"
                        "（需同时出现 com.apple.mobile.lockdown.remote.untrusted 与 "
                        "lockdownd_connect_rsd_named）—— 配对本该走未受信那条，"
                        "退回只连受信版（上游写死）即报")
        # G14：保留受信版回退 —— 旧系统 / 服务表无未受信版时仍需回退.
        if "com.apple.mobile.lockdown.remote.trusted" not in pcode:
            errs.append("[G14] I4PairingService.swift 缺受信版回退"
                        "（需出现 com.apple.mobile.lockdown.remote.trusted）——"
                        "服务表无未受信版时需回退受信版，删掉回退即报")
        # G15：载体文件路径必须带 /Documents 前缀（经 FileSharingService.appDocumentsPath）.
        if "FileSharingService.appDocumentsPath" not in pcode:
            errs.append("[G15] I4PairingService.swift 未经 FileSharingService.appDocumentsPath "
                        "拼载体文件路径 —— house_arrest VendDocuments 的 AFC 根是数据容器，"
                        "载体 Documents 在其下（/Documents）；用容器根路径直写会报「创建文件失败」")

    # ---- FileSharingService.swift（house_arrest vend 后必须验活）----
    fsrc = _read(file_sharing)
    if fsrc is None:
        errs.append("[G11] 找不到 %s" % file_sharing)
    else:
        fcode = _strip_comments(fsrc)
        if "verifiedSession" not in fcode:
            errs.append("[G11] FileSharingService.swift 的 house_arrest vend 后未验活"
                        "（缺 verifiedSession）—— 底层 vend 只读应答不判 Status，"
                        "失败会被推迟成误导性的「创建文件失败」")
        # G15：必须定义载体 Documents 路径常量（I4 依赖它拼路径）.
        if 'static let appDocumentsPath = "/Documents"' not in fcode:
            errs.append("[G15] FileSharingService.swift 未定义 "
                        'static let appDocumentsPath = "/Documents" ——'
                        "载体 Documents 在容器根之下，缺此常量 I4 会退回容器根路径")

    # ---- I4AdvancedView.swift（独立页连到引擎）----
    vsrc = _read(adv_view)
    if vsrc is None:
        errs.append("[G4] 找不到 %s（独立入口页缺失）" % adv_view)
    else:
        vcode = _strip_comments(vsrc)
        if "I4PairingService" not in vcode:
            errs.append("[G4] I4AdvancedView.swift 未连到引擎 I4PairingService —— 独立页会是空壳")
        # G10：现场配对入口 + 结果卡 —— 防入口被删回「只写标记」.
        if "attemptLockdownPair" not in vcode or "livePairResultCard" not in vcode:
            errs.append("[G10] I4AdvancedView.swift 未暴露现场配对入口 / 结果卡"
                        "（需同时出现 attemptLockdownPair 与 livePairResultCard）")

    # ---- TreasureBoxView.swift（独立入口回调）----
    tsrc = _read(treasure)
    if tsrc is None:
        errs.append("[G5] 找不到 %s" % treasure)
    elif "onOpenI4Advanced" not in tsrc:
        errs.append("[G5] TreasureBoxView.swift 缺独立入口回调 onOpenI4Advanced ——"
                    "「开启高级功能」又会被藏回安装流程里")

    # ---- HomeView.swift（入口接进导航栈）----
    hsrc = _read(home)
    if hsrc is None:
        errs.append("[G6] 找不到 %s" % home)
    elif "I4AdvancedView(" not in hsrc:
        errs.append("[G6] HomeView.swift 未把独立页接进导航栈（缺 I4AdvancedView()）—— 入口点不动")

    # ---- I4MobileInstallService.swift（载体常量）----
    esrc = _read(engine)
    if esrc is None:
        errs.append("[G7] 找不到 %s" % engine)
    elif 'static let agentBundleId = "com.ownbook.notes"' not in esrc:
        errs.append("[G7] I4MobileInstallService.swift 缺少载体常量"
                    ' static let agentBundleId = "com.ownbook.notes"')

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_i4_advanced_guard.py <仓库根>")
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
        print("命中：%d" % len(errs))
        return 1
    print("G1 无写死免责声明：OK")
    print("G2 安装页连到独立页：OK")
    print("G3 真实现经 house_arrest 写沙盒：OK")
    print("G4 独立页连到引擎：OK")
    print("G5 百宝箱有独立入口：OK")
    print("G6 HomeView 接进导航栈：OK")
    print("G7 载体常量存在：OK")
    print("G8 现场配对真实现存在：OK")
    print("G9 如实回报设备错误：OK")
    print("G10 独立页有现场配对入口 / 结果卡：OK")
    print("G11 house_arrest vend 后验活：OK")
    print("G12 写入前确保载体有数据容器：OK")
    print("G13 先连未受信 lockdown 服务：OK")
    print("G14 保留受信版回退：OK")
    print("G15 载体 Documents 路径带 /Documents 前缀：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
