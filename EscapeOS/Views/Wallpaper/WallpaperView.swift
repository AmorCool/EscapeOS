import SwiftUI
import UniformTypeIdentifiers

/// 自定义壁纸管理页：导入 .tendies 壁纸包并应用到 PosterBoard。
/// UI 参考 Erosion 原版：大圆角卡片、浅灰背景、底部浅色胶囊按钮。
struct WallpaperView: View {
    @AppStorage("wallpaperTendies") private var tendiesArray: [TendiesObject] = []
    @AppStorage("wallpaperPBContainerPath") private var pbContainerPath = ""
    @AppStorage("wallpaperHasShownFirstRunMsg") private var hasShownFirstRunMsg = false

    @State private var showImporter = false
    @State private var isReady = false
    @State private var importError: String?
    @State private var showResetConfirm = false
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: TendiesObject?
    @State private var activeAlert: WallpaperAlert?
    @State private var showExtractor = false
    @State private var showShareSheet = false
    @State private var extractedURL: URL?

    private let columns = Array(repeating: GridItem(.flexible()), count: UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2)
    private let handler = WallpaperHandler()
    private let sandbox = SandboxEscape()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                if tendiesArray.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
        .navigationTitle("壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { setup() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 .tendies", systemImage: "arrow.down.doc")
                    }
                    .disabled(!isReady)

                    Button {
                        openPosterBoard()
                    } label: {
                        Label("打开 PosterBoard", systemImage: "arrow.up.right.square")
                    }

                    Button {
                        showExtractor = true
                    } label: {
                        Label("提取当前系统壁纸", systemImage: "square.and.arrow.up")
                    }
                    .disabled(pbContainerPath.isEmpty)

                    Divider()

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("清空所有导入", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("应用") {
                    applySelected()
                }
                .disabled(!canApply)
                .fontWeight(.semibold)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isReady {
                HStack {
                    Spacer()
                    Button {
                        showImporter = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc")
                            Text("导入 .tendies")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(Color(.secondarySystemGroupedBackground))
                                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                        )
                    }
                    Spacer()
                }
                .padding(.bottom, 8)
            }
        }
        .documentPicker(isPresented: $showImporter, allowedTypes: [.item]) { urls in
            handleImport(urls)
        }
        .sheet(isPresented: $showExtractor) {
            WallpaperExtractorSheet(pbContainerPath: pbContainerPath, onShare: { url in
                extractedURL = url
                showShareSheet = true
            })
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = extractedURL {
                ShareSheet(items: [url])
            }
        }
        .alert("导入失败", isPresented: .constant(importError != nil)) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("重置所有壁纸导入？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("将删除所有已导入的壁纸包，但不会恢复 PosterBoard 本身。")
        }
        .alert("删除壁纸包？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget { delete(target) }
                deleteTarget = nil
            }
        } message: {
            Text("“\(deleteTarget?.name ?? "")” 将被永久删除。")
        }
        .alert(item: $activeAlert) { alert in
            if alert.hasAction {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text(alert.actionTitle)) {
                        alert.action?()
                    },
                    secondaryButton: .cancel()
                )
            } else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    private struct WallpaperAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let hasAction: Bool
        let actionTitle: String
        let action: (() -> Void)?
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)

            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(width: 96, height: 96)

                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(AppTheme.accent)
                }

                VStack(spacing: 6) {
                    Text("还没有导入壁纸包")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.primary)

                    Text("导入 .tendies 文件即可开始应用自定义壁纸。\n支持 Collections、MercuryPoster 与 Videos 三类描述符。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 24)

            if !isReady {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在准备…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)
            }

            Spacer(minLength: 80)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach($tendiesArray) { $tendies in
                Button {
                    toggleSelection(tendies)
                } label: {
                    VStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(.systemBackground))
                                .frame(height: 110)
                                .overlay {
                                    if tendies.isOn {
                                        RoundedRectangle(cornerRadius: 24)
                                            .strokeBorder(AppTheme.accent, lineWidth: 2)
                                    }
                                }

                            VStack(spacing: 6) {
                                Image(systemName: tendies.targetDescr == .photos ? "play.rectangle" : "photo")
                                    .font(.system(size: 34))
                                    .foregroundStyle(AppTheme.accent)

                                if tendies.targetDescr != .wpKit {
                                    Text(tendies.targetDescr.displayName)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(AppTheme.accent.opacity(0.12))
                                        .foregroundStyle(AppTheme.accent)
                                        .clipShape(Capsule())
                                }
                            }

                            if tendies.isOn {
                                VStack {
                                    HStack {
                                        Spacer()
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(AppTheme.accent)
                                            .background(Circle().fill(Color(.systemBackground)))
                                            .padding(8)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        VStack(spacing: 2) {
                            Text(tendies.name)
                                .lineLimit(1)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                            Text("\(tendies.descrNames.count) 张壁纸")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button {
                        openDataFolder(for: tendies)
                    } label: {
                        Label("查看数据文件夹", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        deleteTarget = tendies
                        showDeleteConfirm = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    private var canApply: Bool {
        isReady
            && !pbContainerPath.isEmpty
            && FileManager.default.fileExists(atPath: WallpaperHandler.wallpapersFolder.path)
            && !selectedObjects.isEmpty
    }

    private var selectedObjects: [TendiesObject] {
        tendiesArray.filter { $0.isOn }
    }

    // MARK: - Actions

    private func setup() {
        DispatchQueue.global(qos: .userInitiated).async {
            if pbContainerPath.isEmpty {
                pbContainerPath = WallpaperHandler.discoverPosterBoardContainer()
            }
            try? FileManager.default.createDirectory(at: WallpaperHandler.wallpapersFolder, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                isReady = true
            }
        }
    }

    private func toggleSelection(_ tendies: TendiesObject) {
        guard let index = tendiesArray.firstIndex(where: { $0.id == tendies.id }) else { return }
        if !tendiesArray[index].isOn {
            let total = selectedDescriptorsCount + tendiesArray[index].descrNames.count
            if total > 15 {
                showAlert(title: "已达到上限", message: "单次最多应用 15 张壁纸。请先取消选择一个壁纸包。")
                return
            }
        }
        tendiesArray[index].isOn.toggle()
    }

    private var selectedDescriptorsCount: Int {
        tendiesArray.filter { $0.isOn }.flatMap { $0.descrNames }.count
    }

    private func handleImport(_ urls: [URL]) {
        guard let fileURL = urls.first else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let object = try handler.makeObject(from: fileURL)
                DispatchQueue.main.async {
                    withAnimation {
                        tendiesArray.append(object)
                    }
                    importError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func applySelected() {
        let selected = selectedObjects
        guard !selected.isEmpty else { return }

        if !hasShownFirstRunMsg {
            showAlert(title: "提示", message: "如果 PosterBoard 中没有出现壁纸，请尝试在设置中重置 Collections、MercuryPoster 或 Videos。") {
                hasShownFirstRunMsg = true
                proceedApply(selected)
            }
            return
        }

        let total = selected.flatMap { $0.descrNames }.count
        if total > 5 {
            showAlert(title: "壁纸数量较多", message: "一次应用超过 5 张壁纸可能导致部分壁纸无法正确显示，是否继续？") {
                proceedApply(selected)
            }
            return
        }

        proceedApply(selected)
    }

    private func proceedApply(_ objects: [TendiesObject]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = applyObjects(objects)
            DispatchQueue.main.async {
                if success {
                    showAlert(title: "应用成功", message: "请杀死后台并重新打开 PosterBoard 以查看效果。") {
                        openPosterBoard()
                    }
                } else {
                    showAlert(title: "应用失败", message: "无法写入 PosterBoard 描述符。请检查沙盒扩展是否生效，或尝试重置。")
                }
            }
        }
    }

    private func applyObjects(_ objects: [TendiesObject]) -> Bool {
        let targets = Set(objects.map(\.targetDescr))
        var handles: [SandboxEscape.Handle] = []
        defer {
            for handle in handles { sandbox.release(handle) }
        }
        for target in targets {
            let targetPath = "\(pbContainerPath)/\(target.path)"
            do {
                let handle = try sandbox.consume(path: targetPath)
                handles.append(handle)
            } catch {
                print("[wallpaper] failed to consume sandbox extension for \(targetPath): \(error)")
                return false
            }
        }

        for object in objects {
            let container = "\(pbContainerPath)/\(object.targetDescr.path)"
            for descr in object.descrNames {
                let destName = UUID().uuidString
                let dest = URL(fileURLWithPath: container).appendingPathComponent(destName)
                let source = WallpaperHandler.wallpapersFolder
                    .appendingPathComponent(object.folderName)
                    .appendingPathComponent(descr)
                do {
                    try FileManager.default.copyItem(at: source, to: dest)
                } catch {
                    print("[wallpaper] failed to copy \(source) -> \(dest): \(error)")
                    return false
                }
            }
        }
        return true
    }

    private func openDataFolder(for tendies: TendiesObject) {
        let url = WallpaperHandler.wallpapersFolder.appendingPathComponent(tendies.folderName)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.scheme = "shareddocuments"
        guard let openURL = components.url else { return }
        UIApplication.shared.open(openURL)
    }

    private func delete(_ tendies: TendiesObject) {
        let url = WallpaperHandler.wallpapersFolder.appendingPathComponent(tendies.folderName)
        try? FileManager.default.removeItem(at: url)
        withAnimation {
            tendiesArray.removeAll { $0.id == tendies.id }
        }
    }

    private func clearAll() {
        for object in tendiesArray {
            let url = WallpaperHandler.wallpapersFolder.appendingPathComponent(object.folderName)
            try? FileManager.default.removeItem(at: url)
        }
        withAnimation {
            tendiesArray.removeAll()
        }
    }

    private func openPosterBoard() {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() else {
            return
        }
        workspace.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: "com.apple.PosterBoard")
    }

    private func showAlert(title: String, message: String, action: (() -> Void)? = nil) {
        activeAlert = WallpaperAlert(
            title: title,
            message: message,
            hasAction: action != nil,
            actionTitle: "继续",
            action: action
        )
    }
}

// MARK: - 提取当前系统壁纸

/// 扫描 PosterBoard 容器中已安装的描述符，并导出为 .tendies 文件。
private struct WallpaperExtractorSheet: View {
    let pbContainerPath: String
    let onShare: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var descriptors: [WallpaperHandler.ExtractableDescriptor] = []
    @State private var selected = Set<WallpaperHandler.ExtractableDescriptor.ID>()
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var errorMessage: String?

    private let handler = WallpaperHandler()
    private let sandbox = SandboxEscape()

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("正在扫描 PosterBoard…")
                } else if descriptors.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("提取系统壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") { exportSelected() }
                        .disabled(selected.isEmpty || isExporting)
                }
            }
        }
        .onAppear(perform: load)
        .alert("导出失败", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("未找到可提取的壁纸")
                .font(.headline)
            Text("PosterBoard 容器中没有已安装的自定义描述符，或当前无权限读取。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var listContent: some View {
        List {
            Section {
                Button(selected.count == descriptors.count ? "取消全选" : "全选") {
                    if selected.count == descriptors.count {
                        selected.removeAll()
                    } else {
                        selected = Set(descriptors.map(\.id))
                    }
                }
                .disabled(isExporting)
            }

            ForEach(descriptors) { descriptor in
                HStack(spacing: 12) {
                    Image(systemName: selected.contains(descriptor.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected.contains(descriptor.id) ? AppTheme.accent : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(descriptor.name)
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 6) {
                            Text(descriptor.provider.displayName)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.accent.opacity(0.12))
                                .foregroundStyle(AppTheme.accent)
                                .clipShape(Capsule())
                            Text("\(descriptor.fileCount) 个文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selected.contains(descriptor.id) {
                        selected.remove(descriptor.id)
                    } else {
                        selected.insert(descriptor.id)
                    }
                }
                .disabled(isExporting)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在打包…")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let found = try handler.extractableDescriptors(from: pbContainerPath, using: sandbox)
                DispatchQueue.main.async {
                    descriptors = found
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func exportSelected() {
        let targets = descriptors.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fm = FileManager.default
                let exportsFolder = BackupPaths.documentsDirectory()
                    .appendingPathComponent("TendiesExports", isDirectory: true)
                try fm.createDirectory(at: exportsFolder, withIntermediateDirectories: true)
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let fileName = "Extracted_\(dateFormatter.string(from: Date())).tendies"
                let destination = exportsFolder.appendingPathComponent(fileName)

                try handler.exportTendies(
                    descriptors: targets,
                    from: pbContainerPath,
                    to: destination,
                    using: sandbox
                )

                DispatchQueue.main.async {
                    isExporting = false
                    onShare(destination)
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Array AppStorage support

extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data) else {
            return nil
        }
        self = result
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return result
    }
}
