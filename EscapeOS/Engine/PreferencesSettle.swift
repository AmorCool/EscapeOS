//
//  PreferencesSettle.swift
//  EscapeSpace
//
//  越界写**之后**的收尾 —— 让 `Preferences/` 下的改动真的守得住.
//
//  ## 要解决的问题（用户反馈 + 真机实测）
//  `Preferences/*.plist` 归 `cfprefsd` 管：它把偏好缓存在**内存**里，
//  并且会**间歇性把内存副本刷回磁盘**. 实测（2026-09-24）：
//  ```
//  原始            5764 B / 49 键
//  我写坏后          89 B /  1 键
//  我用备份还原     5764 B / 49 键  ✓
//  用户点了个开关   3556 B / 21 键  ← 又被改了
//  我再还原         5764 B / 49 键  ✓
//  60 秒后          5764 B / 49 键  ✓
//  ```
//  ⇒ 不杀它：一是**设置不生效**（进程读的是它的内存副本，**respring 也没用**）；
//            二是我们的写入**随时被它覆盖**.
//  杀掉后 `launchd` 立刻重启它，重启时**从磁盘重读** ⇒ 我们的写入才真正生效.
//
//  ## 为什么单独成文件、且由**底层写原语**调用（重要）
//  我第一版把这件事写在 `HostCapabilityService.airliftOverwrite` 里 ——
//  **只覆盖了 9 条写路径中的 1 条**（`airlift.writeMany` / `sys.supervised.set` /
//  模块自己的 `plist.tweak` 都漏了）.
//  真机复现：我调 `airlift.overwrite` 还原 SpringBoard 偏好，`settlePreferences`
//  **根本没被触发**.
//
//  ⇒ 教训：**「每一条写路径都要做的收尾」不能挂在某一条路径上，必须挂在唯一的底层原语上.**
//  现在的挂法是 `AirliftExploit.pocWriteFile` / `pocWriteMany` 里调本文件 ——
//  它们是**所有**越界写（含未来新增的）的唯一出口 ⇒ 不可能再漏.
//
//  依赖方向：`AirliftExploit` → `PreferencesSettle` → (`ProcessManagerService`, `AirliftChangeLog`)
//  没有反向依赖、没有环.
//

import Foundation

/// 越界写之后的收尾（纯静态）.
enum PreferencesSettle {

    /// 写完 `path` 之后调用. **对非 `Preferences/` 路径是零成本的空操作.**
    ///
    /// - Parameters:
    ///   - path: 刚写完的目标路径
    ///   - note: 写进改动记录的原因（例如「plist tweak 后」）
    /// - Returns: 杀掉的 `cfprefsd` 实例数；`0` = 没找到（可能对宿主不可见）
    @discardableResult
    static func after(path: String, note: String) -> Int {
        // 只对 Preferences 下的文件做 —— 其它路径（如 Caches、Passes）不归 cfprefsd 管.
        // 这条判断也是「只写 Caches 的 AirCard 一直能用」的原因（见 ref-airlift §6.5）.
        guard path.contains("/Library/Preferences/") else { return 0 }

        let killed = killCfprefsd()
        AirliftChangeLog.append(action: "kill-cfprefsd", path: path, bytes: 0,
                                verified: false,
                                note: killed > 0
                                    ? "已杀掉 \(killed) 个 cfprefsd 实例，逼它从磁盘重读（\(note)）"
                                    : "没找到 cfprefsd 进程（\(note)：设置可能不会立刻生效）")
        return killed
    }

    /// 杀掉 `cfprefsd`（用户态的偏好守护进程）.
    ///
    /// 用宿主现成的进程控制（与 `proc.signal` 同一条路），不自己发 signal.
    /// `cfprefsd` 有**多个实例**（每个用户域一个）⇒ 全杀.
    private static func killCfprefsd() -> Int {
        guard let entries = try? ProcessManagerService.shared.listProcesses() else { return 0 }
        var killed = 0
        for entry in entries
        where entry.displayName.localizedCaseInsensitiveContains("cfprefsd")
            || entry.executablePath.localizedCaseInsensitiveContains("cfprefsd") {
            if (try? ProcessManagerService.shared.sendSignal(.kill, toPID: entry.pid)) != nil {
                killed += 1
            }
        }
        return killed
    }
}
