import SwiftUI

// MARK: - 限制开关（移植自 Lithium Restrictions）

/// 单条限制开关（可能联动多个 payload key）。
struct SupervisedRestrictionItem: Identifiable {
    let id = UUID()
    let name: String
    let keys: [String]
    let warning: String?
}

/// 一组限制开关。
struct SupervisedRestrictionSection: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let minVersion: Double
    let items: [SupervisedRestrictionItem]
}

extension SupervisedRestrictionSection {
    /// 本地化后的限制目录（中文）。
    static let all: [SupervisedRestrictionSection] = [
        SupervisedRestrictionSection(name: "App", icon: "apps.iphone", minVersion: 0, items: [
            SupervisedRestrictionItem(name: "App Store", keys: ["allowUIAppInstallation"], warning: nil),
            SupervisedRestrictionItem(name: "安装与卸载应用", keys: ["allowAppInstallation", "allowAppRemoval"], warning: nil),
            SupervisedRestrictionItem(name: "应用内购买", keys: ["allowInAppPurchases"], warning: nil),
            SupervisedRestrictionItem(name: "Apple Music 服务", keys: ["allowMusicService", "allowRadioService"], warning: nil),
            SupervisedRestrictionItem(name: "图书商店", keys: ["allowBookstore"], warning: "若你使用依赖图书商店的漏洞工具（如 Nugget），在 iOS 26.2 开发者测试版及更早版本上请勿关闭此项，否则会破坏漏洞所需的下载能力。")
        ]),
        SupervisedRestrictionSection(name: "系统功能", icon: "gearshape", minVersion: 0, items: [
            SupervisedRestrictionItem(name: "截屏", keys: ["allowScreenShot"], warning: nil),
            SupervisedRestrictionItem(name: "Siri", keys: ["allowAssistant"], warning: nil),
            SupervisedRestrictionItem(name: "游戏中心", keys: ["allowGameCenter"], warning: nil),
            SupervisedRestrictionItem(name: "屏幕使用时间", keys: ["allowEnablingRestrictions"], warning: "关闭后可能影响“屏幕使用时间”设置，风险自负。"),
            SupervisedRestrictionItem(name: "Safari", keys: ["allowSafari"], warning: nil),
            SupervisedRestrictionItem(name: "相机", keys: ["allowCamera"], warning: nil)
        ]),
        SupervisedRestrictionSection(name: "共享与外部", icon: "sharing", minVersion: 0, items: [
            SupervisedRestrictionItem(name: "Apple Watch 配对", keys: ["allowPairedWatch"], warning: "若已配对手表，关闭会导致手表取消配对并恢复出厂。"),
            SupervisedRestrictionItem(name: "近距离设置新设备", keys: ["allowProximitySetupToNewDevice"], warning: nil),
            SupervisedRestrictionItem(name: "NFC", keys: ["allowNFC"], warning: "若有依赖 NFC 的卡片 / 通行证，关闭后将无法使用。"),
            SupervisedRestrictionItem(name: "AirDrop", keys: ["allowAirDrop"], warning: nil)
        ]),
        SupervisedRestrictionSection(name: "Apple 智能", icon: "sparkles", minVersion: 18.1, items: [
            SupervisedRestrictionItem(name: "Genmoji", keys: ["allowGenmoji"], warning: nil),
            SupervisedRestrictionItem(name: "图像魔杖", keys: ["allowImageWand"], warning: nil),
            SupervisedRestrictionItem(name: "邮件智能回复", keys: ["allowMailSmartReplies"], warning: nil),
            SupervisedRestrictionItem(name: "邮件摘要", keys: ["allowMailSummary"], warning: nil),
            SupervisedRestrictionItem(name: "个性化手写结果", keys: ["allowPersonalizedHandwritingResults"], warning: nil),
            SupervisedRestrictionItem(name: "Safari 摘要", keys: ["allowSafariSummary"], warning: nil),
            SupervisedRestrictionItem(name: "视觉智能摘要", keys: ["allowVisualIntelligenceSummary"], warning: nil),
            SupervisedRestrictionItem(name: "写作工具", keys: ["allowWritingTools"], warning: nil)
        ])
    ]
}

struct RestrictionTweaksView: View {
    @State private var rsCurrentDict = NSMutableDictionary()
    @State private var otaDelayEnabled = false
    @State private var otaDelay = 0

    @State private var shareTarget: ShareTarget?
    @State private var safariTarget: SafariTarget?
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var isBusy = false
    @State private var warningText = ""
    @State private var showWarning = false

    private var systemVersion: Double {
        let v = UIDevice.current.systemVersion
        // 取主版本.次版本，例如 "18.5" -> 18.5
        let parts = v.split(separator: ".").prefix(2).compactMap { Double($0) }
        if parts.count == 2 { return parts[0] + parts[1] / 10.0 }
        return parts.first ?? 0
    }

    var body: some View {
        List {
            // OTA 延迟更新
            Section {
                Toggle("延迟 OTA 更新", isOn: $otaDelayEnabled)
                    .onChange(of: otaDelayEnabled) { enable in
                        payloadContent()?["forceDelayedSoftwareUpdates"] = enable
                        persist()
                    }
                if otaDelayEnabled {
                    HStack {
                        Text("延迟天数")
                        Spacer()
                        TextField("90", value: $otaDelay, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: otaDelay) { int in
                                var delay = min(int, 90)
                                payloadContent()?["enforcedSoftwareUpdateDelay"] = delay
                                otaDelay = delay
                                persist()
                            }
                    }
                }
            } header: {
                Label("OTA 更新", systemImage: "arrow.down.circle")
            } footer: {
                Text("最多可延迟 90 天（约 3 个月）。若当前系统版本高于目标版本，延迟更新不会生效。")
            }

            // 应用隐藏入口
            Section {
                NavigationLink(destination: AppHideView()) {
                    Label("应用隐藏", systemImage: "eye.slash")
                }
            } footer: {
                Text("进入后可隐藏指定 App（同时将其从“设置”与 App 资源库中移除，数据保留）。")
            }

            // 限制分组
            ForEach(SupervisedRestrictionSection.all) { section in
                if section.minVersion <= systemVersion {
                    Section {
                        ForEach(section.items) { item in
                            HStack(spacing: 10) {
                                Toggle(item.name, isOn: restrictionBinding(item.keys))
                                if let warning = item.warning {
                                    Button {
                                        warningText = warning
                                        showWarning = true
                                    } label: {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    } header: {
                        Label(section.name, systemImage: section.icon)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("限制开关")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .supervisedInstallFooter {
            installProfile()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        exportProfile()
                    } label: {
                        Label("导出描述文件", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        resetProfile()
                    } label: {
                        Label("重置为默认", systemImage: "gobackward")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .sheet(item: $safariTarget, onDismiss: { ProfileHTTPServer.shared.stop() }) { target in
            SafariSheet(url: target.url)
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("提示", isPresented: $showWarning) {
            Button("好", role: .cancel) {}
        } message: {
            Text(warningText)
        }
        .onAppear {
            do {
                rsCurrentDict = try SupervisedProfileStore.load(.restrictions)
                if let pl = payloadContent() {
                    otaDelayEnabled = pl["forceDelayedSoftwareUpdates"] as? Bool ?? false
                    otaDelay = pl["enforcedSoftwareUpdateDelay"] as? Int ?? 0
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    // MARK: - 辅助

    /// PayloadContent[0]（NSMutableDictionary）。
    private func payloadContent() -> NSMutableDictionary? {
        (rsCurrentDict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary
    }

    /// 多 key 联动的开关绑定。
    private func restrictionBinding(_ keys: [String]) -> Binding<Bool> {
        Binding(get: {
            guard let pl = payloadContent() else { return true }
            return pl[keys.first ?? ""] as? Bool ?? true
        }, set: { enabled in
            guard let pl = payloadContent() else { return }
            for key in keys { pl[key] = enabled }
            persist()
        })
    }

    private func persist() {
        do {
            try SupervisedProfileStore.save(.restrictions, dict: rsCurrentDict)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func installProfile() {
        isBusy = true
        do {
            safariTarget = SafariTarget(url: try SupervisedProfileStore.installURL(.restrictions))
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isBusy = false
    }

    private func resetProfile() {
        do {
            try SupervisedProfileStore.reset(.restrictions)
            rsCurrentDict = try SupervisedProfileStore.load(.restrictions)
            if let pl = payloadContent() {
                otaDelayEnabled = pl["forceDelayedSoftwareUpdates"] as? Bool ?? false
                otaDelay = pl["enforcedSoftwareUpdateDelay"] as? Int ?? 0
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func exportProfile() {
        do {
            let url = try SupervisedProfileStore.exportURL(.restrictions)
            shareTarget = ShareTarget(url: url)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
