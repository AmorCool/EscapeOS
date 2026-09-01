//
//  HotfixService.swift
//  EscapeSpace
//
//  热补丁系统（v0.3.66）：
//
//  一期（签名 + 声明式）：
//   - 热补丁模块 = module.json 含 "hotfix" 键的模块，必须携带官方 ed25519 签名
//     （zip 根目录 signature.sig = 对 module.json 原始字节的签名，base64）
//   - 导入时验签：公钥 raw32 编译进 app（Curve25519/CryptoKit），验签失败拒绝安装
//   - 声明式补丁（hotfix.patches[]）：
//       feature_flag  key + value(Bool)  → 功能可见性接管（如 feature.xxx.hidden）
//       text          key + value(String) → 文案覆盖
//
//  二期（JS 引擎）：
//   - 签名模块可携带 hotfix.js，由 JavaScriptCore 执行
//   - 桥接对象 escape：log / setFlag / setOverride / moduleVersion
//   - app 启动与模块变更时执行；异常捕获进日志
//
//  安全模型：
//   - 无签名 = 无热补丁能力（普通 signal 模块不受影响）
//   - JS 沙箱内无文件/网络 API，仅能通过 escape 桥影响声明式状态
//

import CryptoKit
import Foundation
import JavaScriptCore

final class HotfixService: NSObject, ObservableObject {
    static let shared = HotfixService()

    /// EscapeSpace 官方热补丁签名公钥（ed25519 raw 32B，编译进 app）
    static let officialPublicKeyB64 = "Vge1iNGCJ8a6k08355qeswZ9rzwWcpmdVElf5JHRaBs="

    /// 聚合后的功能开关（声明式补丁 + JS setFlag 合并结果）
    @Published private(set) var featureFlags: [String: Bool] = [:]
    /// 聚合后的文案覆盖
    @Published private(set) var textOverrides: [String: String] = [:]
    /// JS 补丁加载状态
    @Published private(set) var jsModulesLoaded: [String] = []
    /// JS 运行日志（调试用，保留最近 50 条）
    @Published private(set) var jsLog: [String] = []

    private init() {
        super.init()
    }

    // MARK: 验签

    /// 校验 module.json 原始字节与 base64 签名是否匹配官方公钥
    static func verifySignature(manifestData: Data, signatureB64: String) -> Bool {
        guard let signature = Data(base64Encoded: signatureB64) else { return false }
        guard let keyData = Data(base64Encoded: officialPublicKeyB64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: manifestData)
    }

    // MARK: 聚合（app 启动 / 模块变更时调用）

    func reload() {
        var flags: [String: Bool] = [:]
        var texts: [String: String] = [:]
        var loaded: [String] = []
        var log: [String] = []

        for module in ModuleService.shared.listModules() {
            guard ModuleService.shared.isEnabled(id: module.id),
                  let hotfix = module.hotfix else { continue }

            // 声明式补丁
            for patch in hotfix.patches ?? [] {
                switch patch.type {
                case "feature_flag":
                    if let b = patch.valueBool { flags[patch.key] = b }
                case "text":
                    if let t = patch.valueText { texts[patch.key] = t }
                default:
                    break
                }
            }

            // JS 补丁（二期）
            if hotfix.hasScript {
                let scriptURL = module.installURL.appendingPathComponent(hotfix.scriptName)
                if let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
                    runScript(source, module: module, into: &flags, into: &texts)
                    loaded.append(module.id)
                }
            }
        }

        DispatchQueue.main.async {
            self.featureFlags = flags
            self.textOverrides = texts
            self.jsModulesLoaded = loaded
        }
        _ = log
    }

    /// 功能隐藏查询（MoreView 集成点）：热补丁可隐藏任意功能入口
    func isFeatureHidden(_ featureId: String) -> Bool {
        featureFlags["feature.\(featureId).hidden"] == true
    }

    // MARK: JS 引擎（二期，JavaScriptCore）

    private func runScript(
        _ source: String,
        module: EscapeModule,
        into flags: inout [String: Bool],
        into texts: inout [String: String]
    ) {
        let ctx = JSContext()!
        ctx.name = "hotfix:\(module.id)"
        ctx.exceptionHandler = { _, exception in
            let msg = exception?.toString() ?? "未知异常"
            print("[Hotfix][JS][\(module.id)] 异常: \(msg)")
        }

        let bridge = JSValue(newObjectIn: ctx)!
        bridge.setValue({ [weak self] args in
            let msg = args?.first.map { "\($0)" } ?? ""
            print("[Hotfix][JS][\(module.id)] \(msg)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.jsLog.append("[\(module.id)] \(msg)")
                if self.jsLog.count > 50 { self.jsLog.removeFirst(self.jsLog.count - 50) }
            }
        }, forKeyedSubscript: "log")

        bridge.setValue({ [weak self] args in
            guard let key = args?[0] as? String,
                  let value = args?[1] as? Bool else { return }
            DispatchQueue.main.async {
                flags[key] = value
                self?.featureFlags[key] = value
            }
        }, forKeyedSubscript: "setFlag")

        bridge.setValue({ [weak self] args in
            guard let key = args?[0] as? String,
                  let value = args?[1] as? String else { return }
            DispatchQueue.main.async {
                texts[key] = value
                self?.textOverrides[key] = value
            }
        }, forKeyedSubscript: "setOverride")

        bridge.setValue(module.version, forKeyedSubscript: "moduleVersion")
        bridge.setValue(module.id, forKeyedSubscript: "moduleId")

        ctx.setObject(bridge, forKeyedSubscript: "escape")
        ctx.evaluateScript(source)
    }
}
