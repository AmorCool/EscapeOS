# -*- coding: utf-8 -*-
"""提交前自检 —— 把本仓现有的「防复发」脚本一次跑完。

现有十项检查（都在本目录）：
  1) swift_top_level_type_collision.py  —— 顶层类型重名普查（因 CI 炸过才写）
  2) swift_view_state_derivation.py     —— 视图层「下载状态文案」推导检查（本轮新增）
  3) swift_nb_offsale_guard.py          —— NB 下架取包链路（回退 / code=7 / 界面内部码）
  4) swift_tunnel_availability_guard.py —— 隧道可用性门控（Shadowrocket 不得用 canOpenURL 挡路）
  5) swift_tunnel_jump_target_guard.py  —— 隧道跳转目标 Surge/Loon（scheme surge:///start、loon://on + 白名单）
  6) swift_theme_blue_guard.py          —— 主题「两套蓝」防复发（trAccent 复现 / accent 非自适应）
  7) swift_i4_advanced_guard.py         —— 「开启高级功能」入口防复发（不得退回写死免责声明）
  8) swift_layout_motion_guard.py       —— 布局与动效防复发（手写等宽网格 / 手搓按压 / 品牌渐变越界）
 10) swift_delisted_download_guard.py   —— 已购/下架下载链路（三 media kind / storefront 轮询 / 搜索回落 / 目录查不到不中止 / 行可点进详情 / 上架下架筛选 / NB 下架图标 / 下架详情 NB 快照 / 历史版本账号通道优先）
 11) swift_searchbar_guard.py          —— 搜索框显示模式（滚动容器页用 `.always` 必须同时给顶部让位）
 12) swift_cellular_tunnel_guard.py    —— Cellular隧道支持（默认关 / 接线不断 / 禁快捷指令硬依赖与误导文案 / 无 Wi-Fi 硬信念文案）

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
    ("隧道可用性门控", "swift_tunnel_availability_guard.py", False),
    ("隧道跳转目标 Surge/Loon", "swift_tunnel_jump_target_guard.py", False),
    ("主题两套蓝防复发", "swift_theme_blue_guard.py", False),
    ("爱思高级功能入口", "swift_i4_advanced_guard.py", False),
    ("布局与动效防复发", "swift_layout_motion_guard.py", False),
    ("已购/下架下载链路", "swift_delisted_download_guard.py", False),
    ("搜索框显示模式防复发", "swift_searchbar_guard.py", False),
    ("Cellular隧道支持防复发", "swift_cellular_tunnel_guard.py", False),
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
