import SwiftUI
import UIKit

/// 屏蔽域名控制台。
///
/// 原理来自用户提供的 iOS-Blocker.mobileconfig：通过
/// `com.apple.dnsSettings.managed` 负载，把域名写进
/// `SupplementalMatchDomains`，并指向一个不可达的本地 DoH 服务器
/// (`https://127.0.0.1/dns-query`)，使这些域名的解析失败从而无法访问。
/// 默认保留模板里苹果系统更新相关域名（去掉了 www.baidu.com），并允许
/// 按需启用 / 关闭以及添加任意自定义域名。生成的描述文件可在“设置 →
/// 通用 → VPN 与设备管理”中安装或移除。
struct DomainBlockerView: View {
    @State private var presets: [BlockedDomain]
    @State private var customInput = ""
    @State private var customDomains: [String]
    @State private var generatedURL: URL?
    @State private var generatedName = ""
    @State private var generatedCount = 0
    @State private var didGenerate = false
    @State private var installSheet: InstallTarget?
    @State private var shareTarget: ShareTarget?
    @State private var errorAlert: DomainBlockerAlert?

    init() {
        let store = DomainBlockerStore.shared
        _presets = State(initialValue: store.loadPresets())
        _customDomains = State(initialValue: store.loadCustom())
    }

    var body: some View {
        List {
            Section {
                InfoActionCard(
                    icon: "globe.badge.xmark",
                    title: "屏蔽域名",
                    message: "将域名加入系统 DNS 屏蔽列表（指向不可达的本地解析服务），使其无法访问。默认包含 iOS 系统更新相关域名，可按需关闭或添加自定义域名。生成的描述文件需在“设置 → 通用 → VPN 与设备管理”中安装。"
                )
            }

            Section {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    Toggle(preset.host, isOn: $presets[index].enabled)
                        .onChange(of: presets[index].enabled) { _ in
                            DomainBlockerStore.shared.savePresets(presets)
                        }
                }
            } header: {
                Label("默认屏蔽（iOS 系统更新相关）", systemImage: "applelogo")
            } footer: {
                Text("这些域名为 Apple 系统更新 / 验证服务，默认开启。关闭后对应域名将不再被屏蔽。")
            }

            Section {
                HStack(spacing: 10) {
                    TextField("输入要屏蔽的域名，如 ads.example.com", text: $customInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { addCustomDomain() }
                    Button("添加") { addCustomDomain() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(customInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                ForEach(customDomains, id: \.self) { host in
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(host)
                            .font(.subheadline)
                        Spacer()
                    }
                }
                .onDelete { indices in
                    customDomains.remove(atOffsets: indices)
                    DomainBlockerStore.shared.saveCustom(customDomains)
                }
            } header: {
                Label("自定义域名", systemImage: "plus.circle")
            } footer: {
                Text("添加的自定义域名会保存在本机，重启应用后仍然保留。左滑可删除。")
            }

            Section {
                Button {
                    generate()
                } label: {
                    HStack {
                        Spacer()
                        Label("生成描述文件", systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            if didGenerate, let url = generatedURL {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已生成描述文件")
                                .font(.subheadline.weight(.semibold))
                            Text("包含 \(generatedCount) 个域名 · \(generatedName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }

                    Button {
                        installSheet = InstallTarget(url: url)
                    } label: {
                        Label("载入描述文件（安装到设置）", systemImage: "arrow.down.doc.fill")
                    }

                    Button {
                        shareTarget = ShareTarget(url: url)
                    } label: {
                        Label("分享 / 保存到文件", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Label("下一步", systemImage: "chevron.forward")
                } footer: {
                    Text("点击“载入描述文件”后系统会弹出“设置”以安装描述文件；也可选“分享 / 保存到文件”，在“文件” App 中打开后安装。安装后可在“设置 → 通用 → VPN 与设备管理”中移除。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("屏蔽域名")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $installSheet, onDismiss: { installSheet = nil }) { target in
            ProfileInstaller(url: target.url) { installSheet = nil }
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .alert(item: $errorAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - Actions

    private func addCustomDomain() {
        var host = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        // 去掉协议头、路径、端口，只保留主机名。
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        host = host.components(separatedBy: "/").first ?? host
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !host.isEmpty, host.contains(".") else {
            errorAlert = DomainBlockerAlert(title: "无效域名", message: "请输入有效的域名，例如 example.com。")
            return
        }

        let exists = (presets.filter { $0.enabled }.map { $0.host.lowercased() }
                      + customDomains.map { $0.lowercased() })
                      .contains(host)
        if exists {
            errorAlert = DomainBlockerAlert(title: "已存在", message: "域名 \(host) 已在屏蔽列表中。")
            customInput = ""
            return
        }

        customDomains.append(host)
        customInput = ""
        DomainBlockerStore.shared.saveCustom(customDomains)
    }

    private func generate() {
        let enabledPresetHosts = presets.filter { $0.enabled }.map { $0.host }
        let all = enabledPresetHosts + customDomains

        // 去重并保持顺序。
        var seen = Set<String>()
        var unique: [String] = []
        for host in all {
            let key = host.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(host)
            }
        }

        guard !unique.isEmpty else {
            errorAlert = DomainBlockerAlert(title: "没有域名", message: "请至少启用一个默认域名或添加自定义域名。")
            return
        }

        do {
            let data = try Self.buildProfileXML(domains: unique)
            let fm = FileManager.default
            let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DomainBlocker")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "blocked-domains.mobileconfig"
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            generatedURL = url
            generatedName = name
            generatedCount = unique.count
            didGenerate = true
        } catch {
            errorAlert = DomainBlockerAlert(title: "生成失败", message: error.localizedDescription)
        }
    }

    // MARK: - Profile builder

    /// 构造与 iOS-Blocker.mobileconfig 同构的 DNS 屏蔽描述文件。
    static func buildProfileXML(domains: [String]) throws -> Data {
        let dnsPayload: [String: Any] = [
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.escapeos.blocker.dns",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "屏蔽域名 (HTTPS DNS)",
            "DNSSettings": [
                "DNSProtocol": "HTTPS",
                "ServerURL": "https://127.0.0.1/dns-query",
                "SupplementalMatchDomains": domains
            ]
        ]

        let root: [String: Any] = [
            "PayloadContent": [dnsPayload],
            "PayloadDisplayName": "屏蔽域名",
            "PayloadDescription": "通过屏蔽自定义域名限制访问，对其它网络流量无影响。文件未签名属正常现象，可在“设置 → 通用 → VPN 与设备管理”中安装或移除。",
            "PayloadIdentifier": "com.escapeos.blocker",
            "PayloadOrganization": "EscapeSpace",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "ConsentText": ["default": "仅在本地测试用途"]
        ]

        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}

// MARK: - Models

/// 一条待屏蔽的域名（预设或自定义）。
struct BlockedDomain: Identifiable {
    let id = UUID()
    let host: String
    var enabled: Bool
    let isPreset: Bool
}

private struct DomainBlockerAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Identifiable wrapper carrying a profile URL to the install sheet.
private struct InstallTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// 持久化默认域名的启用状态与自定义域名列表。
final class DomainBlockerStore {
    static let shared = DomainBlockerStore()

    private let presetsKey = "domainblocker_presets"
    private let customKey = "domainblocker_custom"

    /// 默认屏蔽的苹果系统更新 / 验证相关域名（来自 iOS-Blocker.mobileconfig，已移除 www.baidu.com）。
    private let presetHosts: [String] = [
        "mesu.apple.com",
        "gdmf.apple.com",
        "xp.apple.com",
        "updates-http.cdn-apple.com",
        "updates.cdn-apple.com",
        "applednld.apple.com",
        "gs.apple.com",
        "gg.apple.com",
        "ns.itunes.apple.com",
        "swdist.apple.com",
        "swcdn.apple.com",
        "swpost.apple.com",
        "swquery.apple.com",
        "oscdn.apple.com",
        "osrecovery.apple.com",
        "skl.apple.com",
        "smp-device-content.apple.com",
        "beta.apple.com",
        "ocsp.apple.com",
        "ocsp2.apple.com",
        "valid.apple.com",
        "crl.apple.com",
        "crl.entrust.net",
        "certs.apple.com",
        "appattest.apple.com",
        "vpp.itunes.apple.com"
    ]

    func loadPresets() -> [BlockedDomain] {
        let map = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: Bool] ?? [:]
        return presetHosts.map { host in
            BlockedDomain(host: host, enabled: map[host] ?? true, isPreset: true)
        }
    }

    func savePresets(_ presets: [BlockedDomain]) {
        var map: [String: Bool] = [:]
        for preset in presets where preset.isPreset {
            map[preset.host] = preset.enabled
        }
        UserDefaults.standard.set(map, forKey: presetsKey)
    }

    func loadCustom() -> [String] {
        UserDefaults.standard.array(forKey: customKey) as? [String] ?? []
    }

    func saveCustom(_ custom: [String]) {
        UserDefaults.standard.set(custom, forKey: customKey)
    }
}

// MARK: - Profile installer

/// 通过 UIDocumentInteractionController 把 .mobileconfig 交给系统，
/// 系统会将其路由到“设置”以安装描述文件。若设备未直接提供“设置”入口，
/// 则回退为选项菜单（AirDrop / 存储到“文件”）。
struct ProfileInstaller: UIViewControllerRepresentable {
    let url: URL
    var onFinished: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.present(from: controller)
    }

    final class Coordinator: NSObject, UIDocumentInteractionControllerDelegate {
        let parent: ProfileInstaller
        var dic: UIDocumentInteractionController?
        var didPresent = false

        init(_ parent: ProfileInstaller) {
            self.parent = parent
        }

        func present(from vc: UIViewController) {
            guard !didPresent else { return }
            didPresent = true

            let dic = UIDocumentInteractionController(url: parent.url)
            dic.delegate = self
            dic.uti = "com.apple.mobileconfig"
            dic.name = parent.url.lastPathComponent
            self.dic = dic

            // 等待 sheet 的视图进入窗口层级后再弹出，避免
            // “view is not in the window hierarchy” 警告。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let rect = vc.view.bounds
                let opened = dic.presentOpenInMenu(from: rect, in: vc.view, animated: true)
                if !opened {
                    dic.presentOptionsMenu(from: rect, in: vc.view, animated: true)
                }
            }
        }

        func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
            parent.onFinished()
        }

        func documentInteractionControllerDidDismissOptionsMenu(_ controller: UIDocumentInteractionController) {
            parent.onFinished()
        }
    }
}
