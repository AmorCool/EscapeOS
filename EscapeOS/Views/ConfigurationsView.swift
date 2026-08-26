import SwiftUI

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
enum ConfigAccess: Equatable {
    case readWrite          // 可读可写（越狱 / iOS 27+ MHA 等）
    case readable           // 可读但不可写（iOS 26 平台限制）
    case restricted(String) // 完全受限（附原因）

    /// 用于备份说明文字。
    var description: String {
        switch self {
        case .readWrite: return "可读写"
        case .readable: return "可读取（写入受系统限制）"
        case .restricted(let reason): return "受限（\(reason)）"
        }
    }
}

/// 配置目录访问探测 + 读写 + 备份（系统组目录，需要沙盒外访问）。
enum ConfigurationsStore {
    static var sharedDevPath: String { ConfigPlistURL.sharedDevConfig.path }
    static var cloudPath: String { ConfigPlistURL.cloudConfig.path }

    /// bad_query 沙盒扩展。与原版 Erosion 一致：消费后**一直持有、不释放**（进程生命周期）。
    /// 原版 `bq.grantAccess` 从不 release，之后所有写入都靠这个存活句柄；
    /// 我们旧实现探测后立即释放，导致真正写入时扩展已失效 → 「没有权限」。
    /// 注意：此路径属于系统组（SystemGroup），不在 LiveContainer 访客容器扩展覆盖范围内，
    /// 故走的是真实 bad_query，与原版一致；不会误用「容器管理」专用的 LC 扩展。
    private static let escape = SandboxEscape()
    private static var heldHandle: SandboxEscape.Handle?

    /// 确保持有配置目录的沙盒扩展（只消费一次，之后进程内一直持有）。
    private static func ensureAccess() throws {
        if heldHandle != nil { return }
        heldHandle = try escape.consume(path: ConfigFSURL.configProfiles.path, isGroup: true)
    }

    /// 实测写入：在配置目录里写一个临时文件再删除。
    /// POSIX 的 `isWritableFile` 在沙盒内不可信（权限位可写但实际被沙盒拦截），必须真实写一次。
    private static func writeProbe() -> Bool {
        let fm = FileManager.default
        let probePath = ConfigFSURL.configProfiles.appendingPathComponent(".esc_write_probe").path
        do {
            try Data("probe".utf8).write(to: URL(fileURLWithPath: probePath), options: .atomic)
            try? fm.removeItem(atPath: probePath)
            return true
        } catch {
            return false
        }
    }

    /// 探测当前系统能否读写配置目录。
    static func probe() -> ConfigAccess {
        let fm = FileManager.default
        let dir = ConfigFSURL.configProfiles.path
        let sysVersion = UIDevice.current.systemVersion

        guard fm.fileExists(atPath: dir) else {
            return .restricted("系统配置目录不存在（路径：\(dir)）")
        }
        // 已持有扩展 → 直接实测写入
        if heldHandle != nil {
            return writeProbe() ? .readWrite : .readable
        }
        // 消费扩展并持有（不释放），再用真实写入判定
        do {
            try ensureAccess()
            if writeProbe() { return .readWrite }
            return .readable
        } catch {
            let reason = (error as? SandboxEscapeError)?.errorDescription ?? error.localizedDescription
            if MCMIntegration.isMobileHouseArrest {
                return .readable  // MHA 身份下 class-13 root 可达（读/备份可用），写受限
            }
            return .restricted("获取系统配置目录访问失败：\(reason)（iOS \(sysVersion) 下 systemgroup 写操作需越狱或 iOS 27+，读取与备份不受影响）")
        }
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

    /// 写入配置（页脚 + 监督）。写入前确保扩展持有。
    static func write(footnote: String, supervised: Bool, orgName: String) throws {
        try ensureAccess()
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
        try ensureAccess()
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

    /// 导出配置备份 zip（两个 plist + 说明.txt），返回 zip 路径。读取不依赖写权限，任何环境可用。
    static func backupZip() throws -> URL {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let backupDir = docs.appendingPathComponent("ConfigsBackups", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let zipURL = backupDir.appendingPathComponent("EscapeSpace-Configs-\(formatter.string(from: Date())).zip")

        let writer = ZipWriter()
        try writer.begin(at: zipURL)

        if fm.fileExists(atPath: sharedDevPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: sharedDevPath)) {
            try writer.addFile(name: "SharedDeviceConfiguration.plist", data: data)
        }
        if fm.fileExists(atPath: cloudPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: cloudPath)) {
            try writer.addFile(name: "CloudConfigurationDetails.plist", data: data)
        }

        let current = readCurrent()
        let note = """
        EscapeSpace 配置备份

        导出时间：\(Date())
        设备：\(UIDevice.current.name)（iOS \(UIDevice.current.systemVersion)）

        锁屏页脚：\(current.footnote.isEmpty ? "（未设置）" : current.footnote)
        监督模式：\(current.supervised ? "启用（组织：\(current.orgName.isEmpty ? "未填写" : current.orgName)）" : "关闭")

        恢复方法：将 zip 内同名 plist 放回
        /private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/
        目录（需越狱或 iOS 27+ 写权限）。
        """
        if let data = note.data(using: .utf8) {
            try writer.addFile(name: "说明.txt", data: data)
        }
        try writer.finish()
        return zipURL
    }
}

// MARK: - 视图

/// 「配置管理」：锁屏页脚 + 监督模式（MDM 配置），移植自 Erosion Configurations。
/// 支持：读写（越狱 / iOS 27+）、读取与备份（iOS 26 受限环境）、恢复。
struct ConfigurationsView: View {
    @State private var footnoteText = ""
    @State private var supervised = false
    @State private var orgName = ""
    @State private var access: ConfigAccess = .restricted("探测中…")
    @State private var showApplyConfirm = false
    @State private var showResetConfirm = false
    @State private var resultMessage = ""
    @State private var resultCanRespring = false
    @State private var showResult = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showSupervisionWarning = false
    @State private var shouldRespring = false
    @State private var shareTarget: ShareTarget?
    @State private var isBusy = false

    private var isWritable: Bool {
        if case .readWrite = access { return true }
        return false
    }

    var body: some View {
        List {
            accessSection
            backupSection
            footnoteSection
            supervisionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配置管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showResetConfirm = true
                } label: {
                    Label("恢复", systemImage: "gobackward")
                }
                .disabled(!isWritable)
                Button("应用") {
                    if isWritable {
                        showApplyConfirm = true
                    } else {
                        errorMessage = "当前系统（iOS \(UIDevice.current.systemVersion)）无法写入系统配置目录。\n\n此操作需要越狱环境，或 iOS 27+ 的证书直装形态。已支持读取、备份与导出。"
                        showError = true
                    }
                }
                .disabled(!isWritable)
            }
        }
        .onAppear {
            probeAccess()
            let current = ConfigurationsStore.readCurrent()
            footnoteText = current.footnote
            supervised = current.supervised
            orgName = current.orgName
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .overlay {
            if shouldRespring {
                RespringView()
                    .brightness(-1.0)
                    .ignoresSafeArea()
            }
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
            if resultCanRespring {
                Button("Respring") { shouldRespring = true }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("监督模式警告", isPresented: $showSupervisionWarning) {
            Button("好", role: .cancel) {}
        } message: {
            Text("若设备已由 MDM 配置管理，请勿改动此开关。启用后重新启动（Respring）可能出现设置引导页，风险自负。")
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
                case .restricted:
                    Image(systemName: "lock.fill").foregroundColor(.red)
                    Text("受限")
                        .font(.subheadline)
                }
                Spacer()
                Button("重新检测") {
                    probeAccess()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        } header: {
            Text("访问能力")
        }
    }

    // MARK: - 备份

    private var backupSection: some View {
        Section {
            Button {
                backupAndShare()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.blue)
                        .frame(width: 30, height: 30)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("备份并分享配置")
                            .font(.subheadline)
                        Text("导出两个 plist 为 zip（含说明），可隔空投送 / 存文件 / 分享。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .disabled(isBusy)
        } header: {
            Text("备份")
        } footer: {
            Text("备份不依赖写权限，任何环境都可导出当前已读到的配置。")
        }
    }

    // MARK: - 锁屏页脚

    private var footnoteSection: some View {
        Section {
            // 锁屏预览（与原版 Erosion 一致：solarium 图片背景 + 居中文本 + 下划线）
            VStack(spacing: 8) {
                Text(footnoteText.isEmpty ? "（未设置页脚）" : footnoteText)
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(height: 10)
                Capsule()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 145, height: 4)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .listRowInsets(EdgeInsets())
            .listRowBackground(
                Group {
                    if let img = solariumImage {
                        img.resizable().scaledToFill().offset(y: 10)
                    } else {
                        Color(.systemGroupedBackground)
                    }
                }
            )
            TextField("自定义锁屏页脚（如设备名称）", text: $footnoteText)
        } header: {
            Text("锁屏页脚")
        } footer: {
            Text("将写入 SharedDeviceConfiguration.plist 的 LockScreenFootnote 字段。")
        }
    }

    /// solarium 锁屏背景图（Resources/solarium.jpg，随包携带）。
    private var solariumImage: Image? {
        guard let path = Bundle.main.path(forResource: "solarium", ofType: "jpg"),
              let ui = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: ui)
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
            HStack {
                Text("监督模式")
                Spacer()
                Button {
                    showSupervisionWarning = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("若设备已由 MDM 配置管理，请勿改动此开关。启用后重新启动可能出现设置引导页，风险自负。")
        }
    }

    // MARK: - 操作

    private func probeAccess() {
        access = ConfigurationsStore.probe()
    }

    private func apply() {
        do {
            try ConfigurationsStore.write(footnote: footnoteText, supervised: supervised, orgName: orgName)
            resultMessage = "配置已应用。\n\nRespring 后生效。"
            resultCanRespring = true
            showResult = true
        } catch {
            errorMessage = "写入失败：\(error.localizedDescription)"
            resultCanRespring = false
            showError = true
        }
    }

    private func reset() {
        do {
            try ConfigurationsStore.reset()
            resultMessage = "配置已恢复（页脚已删除、监督已关闭）。\n\nRespring 后生效。"
            resultCanRespring = true
            showResult = true
            footnoteText = ""
            supervised = false
            orgName = ""
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
            resultCanRespring = false
            showError = true
        }
    }

    private func backupAndShare() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try ConfigurationsStore.backupZip()
                DispatchQueue.main.async {
                    isBusy = false
                    shareTarget = ShareTarget(url: url)
                }
            } catch {
                DispatchQueue.main.async {
                    isBusy = false
                    errorMessage = "备份失败：\(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
}
