#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""版本号三处同步防复发检查.

背景：HARD-RULES §22 只写了「project.yml + Resources/Info.plist 两处同步」，
但 project.yml 里**有三个 target 各带一份版本号**，第三处（隧道扩展
TequilaDashTunnel）长期没人管 —— 实测停在 0.3.587 / 881，落后主 App 33 个版本。

危害：iOS 要求主 App 与其 app-extension 的 CFBundleVersion 一致（或不低于），
不一致时安装/升级可被拒，或系统把扩展判为过期 —— 而扩展正是「内置隧道」的载体，
表现为隧道功能时灵时不灵，且报错与版本毫无关联，极难归因。

本脚本把三处口径机械守住：

  V1  project.yml 顶层 settings.base 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION
  V2  Resources/Info.plist 的 CFBundleShortVersionString / CFBundleVersion
  V3  project.yml 内**每个** target 自己的版本号（当前只有 TequilaDashTunnel）

V1 与 V2 必须相等（发版那一刻两者是同一份事实的两个副本）。
V3 每个 target 必须与 V1 相等 —— 扩展不能落后，也不能超前。

判据只认键名与值，不绑行号。

用法：python3 swift_version_sync_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import os
import re
import sys


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def find_key(text, key):
    """在文本里找 'KEY: "value"' 或 'KEY = value' 形式，返回第一个匹配值。"""
    m = re.search(r"^\s*" + re.escape(key) + r"\s*[:=]\s*\"?([0-9][0-9A-Za-z._]*)\"?\s*$",
                  text, re.MULTILINE)
    return m.group(1) if m else None


def find_all_keys(text, key):
    """返回所有 'KEY: "value"' 的出现（带行号）。"""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^\s*" + re.escape(key) + r"\s*:\s*\"?([0-9][0-9A-Za-z._]*)\"?\s*$", line)
        if m:
            out.append((i, m.group(1)))
    return out


def parse_plist_versions(plist_text):
    """Info.plist 里 <key>CFBundleShortVersionString</key> 后紧跟 <string>0.3.620</string>。"""
    def grab(key):
        m = re.search(
            r"<key>" + re.escape(key) + r"</key>\s*<string>([^<]*)</string>",
            plist_text)
        return m.group(1).strip() if m else None
    return grab("CFBundleShortVersionString"), grab("CFBundleVersion")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    proj = os.path.join(root, "project.yml")
    plist = os.path.join(root, "Resources", "Info.plist")
    for p in (proj, plist):
        if not os.path.isfile(p):
            print("找不到 %s" % p)
            return 2

    proj_text = read(proj)
    plist_text = read(plist)

    hits = []

    # ---- V1：project.yml 顶层 settings.base ----
    # 顶层那块在 'settings:\n  base:' 之下；这里取**第一个**出现的两键即为顶层底板。
    top_marketing = find_key(proj_text, "MARKETING_VERSION")
    top_build = find_key(proj_text, "CURRENT_PROJECT_VERSION")
    print("V1 project.yml 顶层   MARKETING_VERSION=%s  CURRENT_PROJECT_VERSION=%s"
          % (top_marketing, top_build))

    # ---- V2：Info.plist ----
    plist_marketing, plist_build = parse_plist_versions(plist_text)
    print("V2 Info.plist         CFBundleShortVersionString=%s  CFBundleVersion=%s"
          % (plist_marketing, plist_build))

    if top_marketing is None or top_build is None:
        hits.append("V1 project.yml 顶层缺少 MARKETING_VERSION / CURRENT_PROJECT_VERSION")
    if plist_marketing is None or plist_build is None:
        hits.append("V2 Resources/Info.plist 缺少 CFBundleShortVersionString / CFBundleVersion")

    if top_marketing and plist_marketing and top_marketing != plist_marketing:
        hits.append("版本号不一致：project.yml 顶层 MARKETING_VERSION=%s / Info.plist CFBundleShortVersionString=%s"
                    % (top_marketing, plist_marketing))
    if top_build and plist_build and top_build != plist_build:
        hits.append("构建号不一致：project.yml 顶层 CURRENT_PROJECT_VERSION=%s / Info.plist CFBundleVersion=%s"
                    % (top_build, plist_build))

    # ---- V3：每个 target 自己那份 ----
    # project.yml 用 'targets:' 下一层的两空格缩进 target 名，其下 'settings:\n      base:' 里写版本。
    # 简化判据：所有 MARKETING_VERSION 出现处（除第一处顶层底板）都必须与 V1 相等。
    all_marketing = find_all_keys(proj_text, "MARKETING_VERSION")
    all_build = find_all_keys(proj_text, "CURRENT_PROJECT_VERSION")

    for (lineno, value) in all_marketing[1:]:
        print("V3 project.yml:%-5d MARKETING_VERSION=%s" % (lineno, value))
        if top_marketing and value != top_marketing:
            hits.append("project.yml:%d 的 MARKETING_VERSION=%s 与顶层 %s 不一致"
                        % (lineno, value, top_marketing))

    for (lineno, value) in all_build[1:]:
        print("V3 project.yml:%-5d CURRENT_PROJECT_VERSION=%s" % (lineno, value))
        if top_build and value != top_build:
            hits.append("project.yml:%d 的 CURRENT_PROJECT_VERSION=%s 与顶层 %s 不一致"
                        % (lineno, value, top_build))

    print("-" * 60)
    if hits:
        print("命中: %d" % len(hits))
        for h in hits:
            print("  x %s" % h)
        return 1
    print("命中: 0")
    print("OK 版本号三处（project.yml 顶层 / Info.plist / 各 target）一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
