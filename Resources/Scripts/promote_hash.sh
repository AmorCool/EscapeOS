#!/usr/bin/env bash
# 计算「本次提交树里参与构建的输入」的内容 hash —— promote 复用判定的唯一真相源。
#
# 为什么必须集中到一处：
#   这个 hash 决定「tag 触发时能否复用已有产物」。若它漏掉某类构建输入，
#   那么「只改那些文件 + 打 tag」会算出与旧产物相同的 hash ⇒ promote 直接复用旧 IPA 发 Release，
#   而 Release 上挂的却是新 tag —— 发出去的东西与源码不符，且 CI 全绿看不出来。
#
# 历史缺陷（已修）：原命令只哈希 TequilaDash / TequilaDashTunnel / project.yml 三项，
#   实测以下构建输入的改动**完全不改变**该 hash：
#     Resources/Info.plist（主 App 的 INFOPLIST_FILE，版本号就在里面）
#     TequilaDash.entitlements / TequilaDash-Tunnel.entitlements
#     Resources/BundledModules/**  Resources/I4Mobile/**  Resources/AppIcon*.png
#     ZSign/**  vendor/**  Resources/Scripts/*.py
#   而 promote job（读）与 xcode-build job（写）各写了一遍同一条命令，
#   两份实现天然会再次分叉 —— 所以抽到这里，两边都只调用本脚本。
#
# 判据：整个提交树，排除**明确不参与构建**的纯文档/元数据。
#   采用「默认全收 + 显式排除」而非「白名单包含」：将来新增构建输入时**默认被纳入**（安全侧），
#   只有确认某路径与产物无关时才往排除表里加一条。
#
# 注意：git ls-tree 不支持 :(exclude) pathspec magic（实测报
#   "pathspec magic not supported by this command: exclude"），
#   所以这里用 git ls-tree 全列 + grep -Ev 的等价写法。
#
# 用法：bash Resources/Scripts/promote_hash.sh        打印 hash
#       bash Resources/Scripts/promote_hash.sh --list 打印纳入的文件数，便于核对覆盖度
set -euo pipefail

# 明确不参与构建的路径（纯文档 / CI 自身 / 仓库元数据）。
# 排除 .github 是为了避免「只改工作流」就让全部产物缓存失效。
EXCLUDE_RE="^(CHANGELOG[.]md|LICENSE|NOTICE|[.]gitignore|docs/|[.]github/)|(^|/)[^/]*[.]md$"

list_inputs() {
  git ls-tree -r --name-only HEAD | grep -Ev "$EXCLUDE_RE" || true
}

if [ "${1:-}" = "--list" ]; then
  list_inputs | wc -l
  exit 0
fi

list_inputs | while IFS= read -r f; do
  printf "%s %s\n" "$(git rev-parse "HEAD:$f")" "$f"
done | shasum -a 256 | cut -d" " -f1
