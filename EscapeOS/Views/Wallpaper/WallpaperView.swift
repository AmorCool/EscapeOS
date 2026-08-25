import SwiftUI
import UniformTypeIdentifiers

/// 自定义壁纸管理页：导入 .tendies 壁纸包并应用到 PosterBoard。
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

    private let columns = Array(repeating: GridItem(.flexible()), count: UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2)
    private let handler = WallpaperHandler()
    private let sandbox = SandboxEscape()

    var body: some View {
        ScrollView {
            if tendiesArray.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { setup() }
        .safeAreaInset(edge: .bottom) {
            if isReady {
                Button {
                    showImporter = true
                } label: {
                    Label("导入 .tendies", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
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
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
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
        VStack(spacing: 16) {
            if !isReady {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在准备…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal)
            } else {
                InfoActionCard(
                    icon: "photo.on.rectangle.angled",
                    title: "还没有导入壁纸包",
                    message: "导入 .tendies 文件即可开始应用自定义壁纸。支持 Collections、MercuryPoster 与 Videos 三类描述符。",
                    actionTitle: "导入 .tendies",
                    action: { showImporter = true }
                )
                .padding(.horizontal)
            }
        }
        .padding(.top, 24)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach($tendiesArray) { $tendies in
                Button {
                    toggleSelection(tendies)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: tendies.targetDescr == .photos ? "play.rectangle" : "photo")
                            .imageScale(.large)
                            .foregroundStyle(AppTheme.accent)
                        VStack(spacing: 2) {
                            Text(tendies.name)
                                .lineLimit(1)
                                .font(.subheadline.weight(.medium))
                            Text("\(tendies.descrNames.count) 张壁纸")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if tendies.targetDescr != .wpKit {
                            Text(tendies.targetDescr.displayName)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.accent.opacity(0.12))
                                .foregroundStyle(AppTheme.accent)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay {
                                if tendies.isOn {
                                    RoundedRectangle(cornerRadius: 20)
                                        .strokeBorder(AppTheme.accent, lineWidth: 2)
                                }
                            }
                    )
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
        .padding(.horizontal)
        .padding(.top, 8)
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

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let fileURL) = result else { return }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

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
        // 1. 为每个目标路径获取沙盒扩展。
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

        // 2. 复制描述符到 PosterBoard 容器。
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
