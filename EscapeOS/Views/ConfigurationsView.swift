import SwiftUI
import UniformTypeIdentifiers

// MARK: - 配置管理（移植自 Erosion「Configurations」）

/// 系统配置目录路径（MDM 描述文件位置）。
enum ConfigFSURL {
    static let sysGroup = URL(fileURLWithPath: "/private/var/containers/Shared/SystemGroup")
    static let configProfiles = sysGroup.appendingPathComponent("systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles")
}

enum ConfigPlistURL {
    static let sharedDevConfig = ConfigFSURL.configProfiles.appendingPathComponent("SharedDeviceConfiguration.plist")
    static let cloudConfig = ConfigFSURL.configProfiles.appendingPathComponent("CloudConfigurationDetails.plist")
}

/// 系统配置目录访问能力探测结果。
enum ConfigAccess {
    case readWrite          // 可读可写（越狱 / iOS 27+ MHA 等）
    case readable           // 可读但不可写（iOS 26 平台限制）
    case restricted(String) // 完全受限（附原因）
}

/// 配置目录访问探测 + 读写（系统组目录，需要沙盒外访问）。
enum ConfigurationsStore {
    static var sharedDevPath: String { ConfigPlistURL.sharedDevConfig.path }
    static var cloudPath: String { ConfigPlistURL.cloudConfig.path }

    /// 探测当前系统能否读写配置目录。iOS 26（无越狱）下写 systemgroup 被平台堵死，
    /// 与 MHA class-13 的结论一致（读可用、写需 iOS 27 或越狱）。
    static func probe() -> ConfigAccess {
        let fm = FileManager.default
        let dir = ConfigFSURL.configProfiles.path
        let sysVersion = UIDevice.current.systemVersion

        // 1) 越狱 / 有直接权限：读写都通
        if fm.isWritableFile(atPath: dir) {
            return .readWrite
        }
        // 2) 目录本身可达（可读）
        if fm.fileExists(atPath: dir) {
            // 尝试 bad_query / MHA 扩展拿写权限（iOS 26 会失败）
            let escape = SandboxEscape()
            do {
                let handle = try escape.consume(path: dir, isGroup: true)
                defer { escape.release(handle) }
                // bad_query 成功通常表示可读写；再验证一下目录可写
                if fm.isWritableFile(atPath: dir) {
                    return .readWrite
                }
                return .readable
            } catch {
                let reason = (error as? SandboxEscapeError)?.errorDescription ?? error.localizedDescription
                if MCMIntegration.isMobileHouseArrest {
                    return .readable  // MHA 身份下 class-13 root 可达（读/备份可用），写受限
                }
                return .restricted("写入系统配置目录失败：\(reason)（iOS \(sysVersion) 下 systemgroup 写操作需越狱或 iOS 27+，读取与备份不受影响）")
            }
        }
        // 3) 目录不存在（异常设备）
        return .restricted("系统配置目录不存在（路径：\(dir)）")
    }

    /// 读取当前配置（锁屏页脚 / 监督 / 组织名称）。失败返回 nil 字段。
    static func readCurrent() -> (footnote: String, supervised: Bool, orgName: String) {
        var footnote = ""
        var supervised = false
        var org = ""
        if let dict = NSDictionary(contentsOfFile: sharedDevPath) as? [String: Any] {
            footnote = dict["LockScreenFootnote"] as? String ?? ""
        }
        if let dict = NSDictionary(contentsOfFile: cloudPath) as? [String: Any] {
            supervised = dict["IsSupervised"] as? Bool ?? false
            org = dict["OrganizationName"] as? String ?? ""
        }
        return (footnote, supervised, org)
    }

    /// 写入配置。仅当访问状态允许（readWrite）；否则抛错说明平台限制。
    static func write(footnote: String, supervised: Bool, orgName: String) throws {
        let fm = FileManager.default
        // 确保目录存在
        try fm.createDirectory(atPath: ConfigFSURL.configProfiles.path, withIntermediateDirectories: true)

        let ftDict: [String: Any] = ["LockScreenFootnote": footnote]
        let ftData = try PropertyListSerialization.data(fromPropertyList: ftDict, format: .binary, options: 0)
        try ftData.write(to: ConfigPlistURL.sharedDevConfig)

        var ccDict = NSMutableDictionary(contentsOfFile: cloudPath) ?? NSMutableDictionary()
        ccDict["IsSupervised"] = supervised
        if supervised, !orgName.isEmpty {
            ccDict["OrganizationName"] = orgName
        } else {
            ccDict.removeObject(forKey: "OrganizationName")
        }
        let ccData = try PropertyListSerialization.data(fromPropertyList: ccDict, format: .binary, options: 0)
        try ccData.write(to: ConfigPlistURL.cloudConfig)
    }

    /// 恢复出厂：删除页脚文件 + 清除监督。
    static func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: sharedDevPath) {
            try fm.removeItem(atPath: sharedDevPath)
        }
        var ccDict = NSMutableDictionary(contentsOfFile: cloudPath) ?? NSMutableDictionary()
        ccDict["IsSupervised"] = false
        ccDict.removeObject(forKey: "OrganizationName")
        let ccData = try PropertyListSerialization.data(fromPropertyList: ccDict, format: .binary, options: 0)
        try ccData.write(to: ConfigPlistURL.cloudConfig)
    }
}

// MARK: - 视图

/// 「配置管理」：锁屏页脚 + 监督模式（MDM 配置），移植自 Erosion Configurations。
/// iOS 26（无越狱）下写入受限——页内会显示访问能力探测结果；读取/备份可用。
struct ConfigurationsView: View {
    @State private var footnoteText = ""
    @State private var supervised = false
    @State private var orgName = ""
    @State private var access: ConfigAccess = .restricted("探测中…")
    @State private var showApplyConfirm = false
    @State private var showResetConfirm = false
    @State private var resultMessage = ""
    @State private var showResult = false
    @State private var errorMessage = ""
    @State private var showError = false

    private var isWritable: Bool {
        if case .readWrite = access { return true }
        return false
    }

    var body: some View {
        List {
            accessSection
            footnoteSection
            supervisionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配置管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("应用") {
                    if isWritable {
                        apply()
                    } else {
                        errorMessage = "当前系统（iOS \(UIDevice.current.systemVersion)）无法写入系统配置目录。\n\n此操作需要越狱环境，或 iOS 27+ 的证书直装形态。已支持读取与备份。"
                        showError = true
                    }
                }
                .disabled(!isWritable)
            }
        }
        .onAppear {
            access = ConfigurationsStore.probe()
            let current = ConfigurationsStore.readCurrent()
            footnoteText = current.footnote
            supervised = current.supervised
            orgName = current.orgName
        }
        .alert("应用配置", isPresented: $showApplyConfirm) {
            Button("应用", role: .destructive) { apply() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将写入锁屏页脚与监督设置。若设备已配置 MDM，请勿改动监督开关。")
        }
        .alert("恢复配置", isPresented: $showResetConfirm) {
            Button("确认恢复", role: .destructive) { reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除锁屏页脚并使设备取消监督状态。")
        }
        .alert("操作结果", isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 访问能力

    private var accessSection: some View {
        Section {
            HStack(spacing: 10) {
                switch access {
                case .readWrite:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("可读写")
                        .font(.subheadline)
                case .readable:
                    Image(systemName: "eye.fill").foregroundColor(.orange)
                    Text("可读取（写入受系统限制）")
                        .font(.subheadline)
                case .restricted(let reason):
                    Image(systemName: "lock.fill").foregroundColor(.red)
                    Text("受限")
                        .font(.subheadline)
                }
                Spacer()
                Button("重新检测") {
                    access = ConfigurationsStore.probe()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            switch access {
            case .readWrite:
                Text("当前环境可读写系统配置目录（越狱或 iOS 27+ 形态）。修改后需要重新启动（Respring）才能生效。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .readable:
                Text("iOS 26（无越狱）下无法写入系统配置目录——这是系统限制（与容器 class-13 一致）。可正常读取与备份现有配置；写入需越狱或 iOS 27+。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .restricted(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("访问能力")
        }
    }

    // MARK: - 锁屏页脚

    private var footnoteSection: some View {
        Section {
            // 简易锁屏预览
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Text(footnoteText.isEmpty ? "（未设置页脚）" : footnoteText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Capsule()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 60, height: 3)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            TextField("自定义锁屏页脚（如设备名称）", text: $footnoteText)
        } header: {
            Text("锁屏页脚")
        } footer: {
            Text("将写入 SharedDeviceConfiguration.plist 的 LockScreenFootnote 字段。")
        }
    }

    // MARK: - 监督

    private var supervisionSection: some View {
        Section {
            Toggle(isOn: $supervised) {
                Label("启用监督模式", systemImage: "eye.fill")
            }
            if supervised {
                TextField("组织名称", text: $orgName)
            }
        } header: {
            Text("监督模式")
        } footer: {
            Text("⚠️ 若设备已由 MDM 配置管理，请勿改动此开关。启用后重启可能出现设置引导页，风险自负。")
        }
    }

    // MARK: - 操作

    private func apply() {
        do {
            try ConfigurationsStore.write(footnote: footnoteText, supervised: supervised, orgName: orgName)
            resultMessage = "配置已应用。\n\n重新启动（Respring）后生效。"
            showResult = true
        } catch {
            errorMessage = "写入失败：\(error.localizedDescription)"
            showError = true
        }
    }

    private func reset() {
        do {
            try ConfigurationsStore.reset()
            resultMessage = "配置已恢复（页脚已删除、监督已关闭）。\n\n重新启动（Respring）后生效。"
            showResult = true
            footnoteText = ""
            supervised = false
            orgName = ""
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
            showError = true
        }
    }
}
