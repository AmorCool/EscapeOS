import Foundation
import UIKit
import Network   // LocalShortcutServer 用 NWListener / NWParameters / NWConnection

/// 把「关/开蜂窝数据」两个快捷指令**静默装进系统**，让用户完全不用手动建.
///
/// ## 为什么需要这个
/// SideStore 的 `CellularRefreshManager` 靠 `shortcuts://run-shortcut?name=TurnOffData`
/// 临时关蜂窝，但**它自己不提供快捷指令** —— 用户没建就报
/// 「Could not find the shortcut 'TurnOffData'」（见 SideStore issue #1393 / #1413 / #1191）。
/// 本类补上这一环：**自动把 `.shortcut` 文件导入系统**。
///
/// ## 机制（Apple 官方支持）
/// ```
/// shortcuts://import-shortcut?url=<.shortcut 文件 URL>&name=<名称>&silent=true
/// ```
/// - `silent=true` = **导入但不打开界面**（这正是「不跳界面」的关键）
/// - 来源：Apple 官方支持文档「使用 URL 方案导入快捷指令」
///
/// ## 提供的两个快捷指令
/// | 名称 | 动作 | 用途 |
/// |---|---|---|
/// | `TurnOffData` | 打开「飞行模式」 | 蜂窝下建隧道前，先断掉蜂窝 |
/// | `TurnOnData` | 关闭「飞行模式」 | 用完恢复 |
///
/// **为什么用「飞行模式」而不是「蜂窝数据」**：iOS 快捷指令的动作库里
/// **没有**「开关蜂窝数据」这个动作（只有 `is.workflow.actions.airplanemode.set`）。
/// 蜂窝场景本来就没有 Wi-Fi，所以开飞行模式等价于「关掉蜂窝」，副作用可接受。
/// 若将来 iOS 补了蜂窝动作，只需改 `offActionIdentifier`。
///
/// ⚠️ **未验证项**（如实标注）：`.shortcut` 的 plist 结构、以及 `file://` URL
/// 能否被「快捷指令」App 接受，都需要**真机验证**。本类先按 Apple 文档与
/// 公开的 `.shortcut` 格式实现，首次真机跑通前不要当成「已可用」。
enum CellularShortcutInstaller {

    // MARK: - 对外入口

    /// 确保两个快捷指令已装进系统（幂等：已装过就直接返回）.
    ///
    /// 调用时机：用户**打开**「Cellular隧道支持」开关时（见 `CellularTunnelManager`）。
    /// 用 `@MainActor` 是因为最后要 `UIApplication.shared.open`。
    @MainActor
    @discardableResult
    static func ensureInstalled() async -> Bool {
        // 已经装过就不重复导入（避免每次开开关都弹一次系统确认）
        guard !hasImported else {
            LoginLogger.shared.log("[Cellular] 快捷指令已装过，跳过导入", category: .general)
            return true
        }

        let offOK = await importShortcut(name: offShortcutName, action: offActionIdentifier, actionValue: true)
        let onOK = await importShortcut(name: onShortcutName, action: onActionIdentifier, actionValue: false)

        if offOK && onOK {
            hasImported = true
            LoginLogger.shared.log("[Cellular] 两个快捷指令已静默导入", category: .general)
        } else {
            LoginLogger.shared.log("[Cellular] 快捷指令导入未全部成功（off=\(offOK) on=\(onOK)）", category: .general)
        }
        return offOK && onOK
    }

    // MARK: - 常量

    /// 与 `CellularTunnelManager` 的默认名一致.
    static let offShortcutName = "TurnOffData"
    static let onShortcutName = "TurnOnData"

    /// 「设定飞行模式」动作（iOS 快捷指令动作库里的稳定 ID）.
    /// `OnValue = true` 开飞行模式（= 断蜂窝）；`false` 关飞行模式（= 恢复）.
    static let offActionIdentifier = "is.workflow.actions.airplanemode.set"
    static let onActionIdentifier = "is.workflow.actions.airplanemode.set"

    /// 已导入标记（避免重复导入）。
    private static let importedKey = "TequilaDash.CellularShortcutsImported"
    private static var hasImported: Bool {
        get { UserDefaults.standard.bool(forKey: importedKey) }
        set { UserDefaults.standard.set(newValue, forKey: importedKey) }
    }

    // MARK: - 导入

    /// 生成 `.shortcut` 文件 → 起本地 HTTP 服务提供它 → 调 `import-shortcut` 导入.
    ///
    /// v0.3.615 **修 bug**：不再先试 `file://`。
    ///
    /// 用户实测报错：「导入失败 提供的快捷指令URL无效」。
    /// 根因：`UIApplication.shared.open(file://…)` 会返回 `true`（**系统只是受理了这个 URL**，
    /// 不代表「快捷指令」App 接受它），于是旧代码认为成功、**永远不回落 HTTP**；
    /// 而「快捷指令」App 拿到 `file://` 会直接判为无效 URL。
    /// ⇒ 现在**只走 HTTP**（`http://127.0.0.1:<port>/<name>.shortcut`）。
    @MainActor
    private static func importShortcut(name: String, action: String, actionValue: Bool) async -> Bool {
        guard let fileURL = writeShortcutFile(name: name, action: action, actionValue: actionValue) else {
            LoginLogger.shared.log("[Cellular] 生成 \(name).shortcut 失败", category: .general)
            return false
        }

        // 「快捷指令」App 只接受可下载的 http(s) URL —— file:// 会被判「URL 无效」。
        guard let httpURL = LocalShortcutServer.shared.serve(fileURL: fileURL, as: "\(name).shortcut") else {
            LoginLogger.shared.log("[Cellular] 起本地 HTTP 服务失败，无法提供 \(name).shortcut", category: .general)
            return false
        }
        return await openImportURL(httpURL, name: name) ?? false
    }

    /// 打开 `shortcuts://import-shortcut?...`，返回系统是否受理.
    @MainActor
    private static func openImportURL(_ fileURL: URL, name: String) async -> Bool? {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "import-shortcut"
        c.queryItems = [
            URLQueryItem(name: "url", value: fileURL.absoluteString),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "silent", value: "true"),   // 关键：导入但不打开界面
        ]
        guard let url = c.url else { return nil }

        LoginLogger.shared.log("[Cellular] 导入快捷指令 \(name)：\(url.absoluteString.prefix(120))…", category: .general)
        return await UIApplication.shared.open(url)
    }

    /// 生成 `.shortcut`（plist）文件到 App 的 Caches 目录，返回文件 URL.
    ///
    /// 结构参照公开的 `.shortcut` 格式（iOS 15+）：顶层 `WFWorkflowActions` 数组，
    /// 每个元素含 `WFWorkflowActionIdentifier` + `WFWorkflowActionParameters`。
    private static func writeShortcutFile(name: String, action: String, actionValue: Bool) -> URL? {
        let actionDict: [String: Any] = [
            "WFWorkflowActionIdentifier": action,
            "WFWorkflowActionParameters": ["OnValue": actionValue],
        ]

        let root: [String: Any] = [
            "WFWorkflowClientVersion": "1200",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 4282601983,
                "WFWorkflowIconGlyphNumber": 59511,
            ],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowTypes": [],
            "WFWorkflowActions": [actionDict],
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CellularShortcuts", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(name).shortcut")
            try data.write(to: url, options: .atomic)
            LoginLogger.shared.log("[Cellular] 已生成 \(url.lastPathComponent)（\(data.count) 字节）", category: .general)
            return url
        } catch {
            LoginLogger.shared.log("[Cellular] 写 .shortcut 失败：\(error.localizedDescription)", category: .general)
            return nil
        }
    }

    /// 用户手动删掉快捷指令后重新装（设置页的「重装快捷指令」按钮用）.
    static func resetImportedFlag() {
        hasImported = false
    }
}

// MARK: - 本地 HTTP 服务

/// 极简本地 HTTP 服务：只用来把 `.shortcut` 文件以 `http://127.0.0.1:<port>/<name>` 提供出去.
///
/// 为什么需要它：Apple 的 `shortcuts://import-shortcut?url=` 期望一个**可下载的 URL**，
/// `file://` 在某些 iOS 版本上不被接受（需真机验证）。这里用 `Network.framework` 起一个
/// 只监听回环的最小服务兜底，不依赖本仓的 `IPALocalHTTPServer`（那个是给 IPA 分发用的，
/// 绑定在 LAN 地址上，不适合这里）。
final class LocalShortcutServer: @unchecked Sendable {
    static let shared = LocalShortcutServer()
    private init() {}

    private var listener: NWListener?
    private var routes: [String: Data] = [:]
    private var port: UInt16 = 0
    private let lock = NSLock()

    /// 把文件挂到 `/<name>` 并确保服务在跑，返回可访问的 URL.
    func serve(fileURL: URL, as name: String) -> URL? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        lock.lock()
        routes["/" + name] = data
        let existingPort = port
        lock.unlock()

        if existingPort != 0 {
            return URL(string: "http://127.0.0.1:\(existingPort)/\(name)")
        }

        guard startIfNeeded() else { return nil }
        lock.lock()
        let p = port
        lock.unlock()
        guard p != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(p)/\(name)")
    }

    private func startIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if listener != nil { return true }

        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: .any)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let p = l.port?.rawValue {
                    self.lock.lock(); self.port = p; self.lock.unlock()
                    LoginLogger.shared.log("[Cellular] 本地快捷指令服务已起，端口 \(p)", category: .general)
                }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
            // 等端口就绪（最多 2 秒）
            let deadline = Date().addingTimeInterval(2)
            while port == 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return port != 0
        } catch {
            LoginLogger.shared.log("[Cellular] 起本地服务失败：\(error.localizedDescription)", category: .general)
            return false
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

            self.lock.lock()
            let body = self.routes[path]
            self.lock.unlock()

            let header: String
            let payload: Data
            if let body {
                header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                payload = Data(header.utf8) + body
            } else {
                header = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                payload = Data(header.utf8)
            }
            conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
