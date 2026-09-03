import Foundation

/// 可拆卸 dylib 模块的设备端重签名（v0.3.101）。
///
/// 历史（2026-09-02/03 实测链）：
/// 1. module-esc edge 的 openlist.dylib 签名页哈希失配 32755/32868 → 内核拒 dlopen。
/// 2. v0.3.94：CodeDirectory v0x20400 头部实为 88B（spare3/codeLimit64/execSeg*），
///    只写 52B 会让哈希覆盖 codeLimit64/execSeg → 垃圾字段。
/// 3. v0.3.99：flags 必须带 CS_ADHOC(0x2)（无 CMS 时验证器据此走纯哈希路径）。
/// 4. v0.3.100：以上全修好后设备端仍 invalid —— **内核按 vnode 缓存校验判决**：
///    曾被 dlopen 拒过的文件，原地改签名不失效缓存（Apple 官方文档、LC zsign.mm
///    注释、Nyxian vnode_recover 三方印证）。
/// 5. ★ v0.3.101：放弃手搓签名——**嵌入 LC/Nyxian 同款 ZSign 引擎**（其 ad-hoc
///    产物在本环境被证明可加载：LC 访客二进制与 tweak dylib 全部在跑）。
///    流程：复制到全新 UUID 文件（全新 vnode）→ zsign 就地重签 → dlopen 新路径。
enum MachoReSign {
    enum ReSignError: Error, LocalizedError {
        case copyFailed(String)
        case zsignFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let m): return "复制失败: \(m)"
            case .zsignFailed(let c): return "zsign 失败: code \(c)（-1 InitAdhoc -2 Init -3 Sign）"
            }
        }
    }

    /// 复制到全新文件并 zsign ad-hoc 重签，返回副本 URL。
    /// bundleId 用模块 id（CodeDirectory identifier）。
    static func rebuildToNewFile(at original: URL, bundleId: String) throws -> URL {
        let dir = original.deletingLastPathComponent()
        // 清理旧重签副本（防磁盘配额累积）
        if let olds = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in olds where f.lastPathComponent.contains("-rs-") {
                try? FileManager.default.removeItem(at: f)
            }
        }
        let uid = UUID().uuidString.prefix(8)
        let newURL = dir.appendingPathComponent(
            original.deletingPathExtension().lastPathComponent + "-rs-\(uid).dylib")
        do {
            try FileManager.default.copyItem(at: original, to: newURL)
        } catch {
            throw ReSignError.copyFailed(error.localizedDescription)
        }

        // 最小空 entitlements（zsign adhoc 需要一个 plist 输入）
        let ent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " +
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict/></plist>"
        var code: Int32 = -99
        ent.withCString { e in
            newURL.path.withCString { p in
                bundleId.withCString { bid in
                    code = zsign_adhoc_file(p, bid, e, Int32(strlen(e)))
                }
            }
        }
        guard code == 0 else { throw ReSignError.zsignFailed(code) }
        return newURL
    }
}
