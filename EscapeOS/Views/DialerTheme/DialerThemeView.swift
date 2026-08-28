//
//  DialerThemeView.swift
//  EscapeOS
//
//  拨号器主题：替换电话 App 容器内的 TelephonyUI 缓存，改变拨号键盘外观。
//  移植自 Ketamine 的 Customization → Passcode 板块，交互与文案已汉化。
//
//  页面是「更多」页 push 进入的次级页 —— 不要嵌套 NavigationStack（会导致
//  导航栏高度异常、标题与按钮错位），由外层 NavigationView 提供导航栏。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 视图模型

@MainActor
final class DialerThemeViewModel: ObservableObject {

    @Published private(set) var status: DialerThemeStatus?
    @Published private(set) var isScanning = false
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = ""
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var exportedURL: URL?

    private let manager = DialerThemeManager.shared
    private let defaults = UserDefaults.standard

    private static let containerPathKey = "dialerThemeContainerPath"
    private static let cacheDirectoryKey = "dialerThemeCacheDirectory"

    /// 上次定位成功的电话容器路径（缓存在 UserDefaults，避免每次进页面都全量扫描容器）。
    private var cachedContainerPath: String {
        get { defaults.string(forKey: Self.containerPathKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.containerPathKey) }
    }

    private var cachedCacheDirectory: String {
        get { defaults.string(forKey: Self.cacheDirectoryKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.cacheDirectoryKey) }
    }

    // MARK: 定位

    /// `force == true` 时忽略缓存重新扫描（系统更新后容器 UUID 会变，用得上）。
    func scan(force: Bool = false) {
        if !force, !cachedContainerPath.isEmpty, !cachedCacheDirectory.isEmpty {
            status = DialerThemeStatus(
                containerPath: cachedContainerPath,
                cacheDirectoryName: cachedCacheDirectory,
                pngCount: 0,
                hasBackup: manager.hasBackup
            )
            refreshCount()
            return
        }

        isScanning = true
        // 闭包内只捕获 Sendable 局部值；错误在后台就地转成 String 再跨 actor。
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<DialerThemeStatus, String>
            do {
                outcome = .success(try DialerThemeManager.shared.discoverStatus())
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                switch outcome {
                case .success(let status):
                    self.cachedContainerPath = status.containerPath
                    self.cachedCacheDirectory = status.cacheDirectoryName
                    self.status = status
                case .failure(let message):
                    self.status = nil
                    self.cachedContainerPath = ""
                    self.cachedCacheDirectory = ""
                    self.errorMessage = message
                }
            }
        }
    }

    /// 只刷新缓存目录里的 PNG 数量，不重新扫描容器（快）。
    private func refreshCount() {
        guard !cachedContainerPath.isEmpty, !cachedCacheDirectory.isEmpty else { return }
        let snapshot = DialerThemeStatus(
            containerPath: cachedContainerPath,
            cacheDirectoryName: cachedCacheDirectory,
            pngCount: 0,
            hasBackup: manager.hasBackup
        )
        let cachePath = snapshot.cachePath
        Task.detached(priority: .utility) { [weak self] in
            // 实例建在闭包内（避免捕获 non-Sendable 对象），且必须贯穿
            // consume / release：SandboxEscape 用实例内的 liveHandles 集合判定
            // 句柄是否有效，两个实例会让 release 空转。
            let escape = SandboxEscape()
            var count = 0
            if let handle = try? escape.consume(path: cachePath, create: true) {
                defer { escape.release(handle) }
                count = ((try? FileManager.default.contentsOfDirectory(atPath: cachePath)) ?? [])
                    .filter { $0.lowercased().hasSuffix(".png") }
                    .count
            }
            let hasBackup = DialerThemeManager.shared.hasBackup
            await MainActor.run {
                guard let self else { return }
                self.status = DialerThemeStatus(
                    containerPath: snapshot.containerPath,
                    cacheDirectoryName: snapshot.cacheDirectoryName,
                    pngCount: count,
                    hasBackup: hasBackup
                )
            }
        }
    }

    // MARK: 应用 / 恢复 / 导出

    func apply(urls: [URL]) {
        guard let cachePath = status?.cachePath, !isBusy else { return }
        begin("正在应用主题")
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<String, String>
            do {
                let count = try DialerThemeManager.shared.apply(sources: urls, cachePath: cachePath)
                outcome = .success("已替换 \(count) 张键盘图片。重新打开电话 App 即可看到效果。")
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await MainActor.run {
                guard let self else { return }
                self.finish(outcome, refresh: true)
            }
        }
    }

    func restore() {
        guard let cachePath = status?.cachePath, !isBusy else { return }
        begin("正在恢复原生主题")
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<String, String>
            do {
                let count = try DialerThemeManager.shared.restoreOriginal(cachePath: cachePath)
                outcome = .success("已恢复 \(count) 张原生键盘图片，重新打开电话 App 生效。")
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await MainActor.run {
                guard let self else { return }
                self.finish(outcome, refresh: true)
            }
        }
    }

    func export() {
        guard let cachePath = status?.cachePath, !isBusy else { return }
        begin("正在导出主题")
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<URL, String>
            do {
                outcome = .success(try DialerThemeManager.shared.exportCurrentTheme(cachePath: cachePath))
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                switch outcome {
                case .success(let url): self.exportedURL = url
                case .failure(let message): self.errorMessage = message
                }
            }
        }
    }

    // MARK: 重启电话 App

    /// 结束电话进程，让它下次启动时重新读取缓存里的键盘图片。
    /// 需要配对文件 + LocalDevVPN；失败时提示用户手动上滑关闭。
    func relaunchPhoneApp() {
        guard !isBusy else { return }
        begin("正在重启电话 App")
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<String, String>
            do {
                let processes = try ProcessManagerService.shared.listProcesses()
                let targets = processes.filter { $0.executablePath.contains("MobilePhone") }
                if targets.isEmpty {
                    outcome = .failure("当前没有正在运行的电话进程，直接打开电话 App 即可。")
                } else {
                    for process in targets {
                        try? ProcessManagerService.shared.sendSignal(.kill, toPID: process.pid)
                    }
                    outcome = .success("已结束电话进程（\(targets.count) 个），重新打开电话 App 即可看到新主题。")
                }
            } catch {
                outcome = .failure("自动重启失败：\(error.localizedDescription)\n请手动上滑关闭电话 App 后重新打开。")
            }
            await MainActor.run {
                guard let self else { return }
                self.finish(outcome, refresh: false)
            }
        }
    }

    // MARK: 内部

    /// 开始一项需要进度遮罩的后台任务。
    private func begin(_ message: String) {
        isBusy = true
        busyMessage = message
    }

    /// 在主线程收尾：`refresh` 为真时顺带刷新图片数量（应用/恢复后数量会变）。
    private func finish(_ outcome: Result<String, String>, refresh: Bool) {
        isBusy = false
        switch outcome {
        case .success(let message):
            successMessage = message
            if refresh { refreshCount() }
        case .failure(let message):
            errorMessage = message
        }
    }
}

// MARK: - 页面

struct DialerThemeView: View {

    @StateObject private var viewModel = DialerThemeViewModel()
    @State private var showImporter = false
    @State private var showRestoreConfirm = false
    @State private var showShareSheet = false

    private let passthmType = UTType(filenameExtension: "passthm", conformingTo: .data) ?? .data

    var body: some View {
        content
            .navigationTitle("拨号器主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.scan(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isScanning || viewModel.isBusy)
                }
            }
            .task { viewModel.scan() }
            .documentPicker(
                isPresented: $showImporter,
                allowedTypes: [passthmType, .zip, .png],
                allowsMultipleSelection: true
            ) { urls in
                viewModel.apply(urls: urls)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = viewModel.exportedURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("恢复原生主题？", isPresented: $showRestoreConfirm) {
                Button("取消", role: .cancel) {}
                Button("恢复", role: .destructive) { viewModel.restore() }
            } message: {
                Text("将用首次应用主题时备份的原图覆盖当前的键盘图片。")
            }
            .alert("出错了", isPresented: errorBinding) {
                Button("好", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("完成", isPresented: successBinding) {
                Button("好", role: .cancel) { viewModel.successMessage = nil }
            } message: {
                Text(viewModel.successMessage ?? "")
            }
            .onChange(of: viewModel.exportedURL) { url in
                if url != nil { showShareSheet = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        List {
            statusSection
            actionsSection
            relaunchSection
            notesSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0)
        .overlay {
            if viewModel.isBusy {
                ZStack {
                    Color(.systemBackground).opacity(0.6)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(viewModel.busyMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: 分区

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if viewModel.isScanning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在定位电话 App 容器…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else if let status = viewModel.status {
                LabeledContent("缓存目录") {
                    Text(status.cacheDirectoryName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("键盘图片") {
                    Text(status.pngCount > 0 ? "\(status.pngCount) 张" : "—")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("原生备份") {
                    Text(status.hasBackup ? "已备份" : "未备份")
                        .font(.subheadline)
                        .foregroundStyle(status.hasBackup ? .green : .secondary)
                }
            } else {
                InfoActionCard(
                    icon: "exclamationmark.triangle.fill",
                    iconTint: .orange,
                    title: "未定位到电话容器",
                    message: "请确认设备可使用电话功能，并打开一次拨号键盘让系统生成缓存，然后点右上角刷新重试。",
                    actionTitle: "重新扫描",
                    action: { viewModel.scan(force: true) }
                )
            }
        } header: {
            Text("状态")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label("导入主题包或图片", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.status == nil)

            Button {
                showRestoreConfirm = true
            } label: {
                Label("恢复原生主题", systemImage: "arrow.uturn.left")
                    .foregroundStyle(viewModel.status?.hasBackup == true ? .red : .secondary)
            }
            .disabled(viewModel.status?.hasBackup != true)

            Button {
                // 先清空：连续两次导出拿到的是同一个 URL，值没变化 onChange 不触发，
                // 分享面板就弹不出来了。
                viewModel.exportedURL = nil
                viewModel.export()
            } label: {
                Label("导出当前主题", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.status == nil)
        } header: {
            Text("操作")
        } footer: {
            Text("支持 .passthm / .zip 主题包，也支持直接在文件 App 里多选 PNG 图片导入。图片按「文件名去掉语言前缀」匹配，同名即替换，无需打包。")
        }
    }

    private var relaunchSection: some View {
        Section {
            Button {
                viewModel.relaunchPhoneApp()
            } label: {
                Label("重启电话 App", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.status == nil)
        } footer: {
            Text("主题写入缓存后需重新打开电话 App 才会生效（不需要重启设备）。此项通过隧道结束电话进程，需要配对文件与 LocalDevVPN；若失败请手动上滑关闭电话 App 再打开。")
        }
    }

    private var notesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("原理")
                    .font(.subheadline.weight(.semibold))
                Text("电话 App 通过 TelephonyUI 渲染拨号键盘，渲染结果以 PNG 缓存进自己的容器。缓存命中时不会重新生成，因此替换这些 PNG 即改变键盘外观。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("该路径在电话 App 沙盒内，需通过 bad_query 让 containermanagerd 代为签发沙盒扩展才能写入（iOS 26.0–26.6.1）。同一张图在各语言下各有一份且内容相同，故按去掉语言前缀后的文件名匹配，一次替换覆盖全部语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("说明")
        }
    }

    // MARK: 绑定

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var successBinding: Binding<Bool> {
        Binding(
            get: { viewModel.successMessage != nil },
            set: { if !$0 { viewModel.successMessage = nil } }
        )
    }
}
