# -*- coding: utf-8 -*-
"""提交前自检 —— 把本仓现有的「防复发」脚本一次跑完。

现有三项检查（都在本目录）：
  1) swift_top_level_type_collision.py  —— 顶层类型重名普查（因 CI 炸过才写）
  2) swift_view_state_derivation.py     —— 视图层「下载状态文案」推导检查（本轮新增）
  3) swift_nb_offsale_guard.py          —— NB 下架取包链路（回退 / code=7 / 界面内部码）

为什么合并成「一个入口」而不是「一个脚本」：
  两项检查的**输入、口径、退出码**都独立，各自的报告/豁免表也各管一摊；把逻辑塞进
  一个文件只会让两边互相牵制。所以这里只做**编排**（subprocess 依次跑），不合并逻辑。
  将来加检查 = 往 CHECKS 里加一行。

用法：
    python swift_precommit_check.py [仓库根，默认 .] [--strict]
    （仓库根 = 含 EscapeOS/ 的那一层，即 P1_EscapeOS_宿主仓库）
退出码：0 = 全部通过；1 = 有任一检查失败；2 = 参数/路径错误。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable or "python"

# (标题, 脚本文件名, 是否支持 --strict)
CHECKS = [
    ("顶层类型重名普查", "swift_top_level_type_collision.py", False),
    ("视图层状态文案推导", "swift_view_state_derivation.py", True),
    ("NB 下架取包链路", "swift_nb_offsale_guard.py", False),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv[1:]
    root = args[0] if args else "."
    if not os.path.isdir(os.path.join(root, "EscapeOS")):
        print("仓库根下找不到 EscapeOS/ ：%s" % os.path.abspath(root))
        return 2

    failed = []
    for title, script, takes_strict in CHECKS:
        path = os.path.join(HERE, script)
        print("=" * 72)
        print("▶ %s  (%s)" % (title, script))
        print("-" * 72)
        cmd = [PY, path, root] + (["--strict"] if (strict and takes_strict) else [])
        sys.stdout.flush()          # 否则父进程缓冲会把标题排到子进程输出之后
        rc = subprocess.call(cmd)
        if rc != 0:
            failed.append(title)

    print("=" * 72)
    if failed:
        print("✗ 提交前自检未通过：%s" % "、".join(failed))
        return 1
    print("✓ 提交前自检全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
