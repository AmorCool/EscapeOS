import SwiftUI

// MARK: - 应用隐藏（移植自 Lithium AppBlockingView）

/// 已登记的可隐藏 App（名称 + Bundle ID），持久化在 @AppStorage，
/// 真正的隐藏集合来自限制描述文件的 `blockedAppBundleIDs`。
struct HiddenAppItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var bundleID: String
}

struct AppHideView: View {
    @State private var rsCurrentDict = NSMutableDictionary()
    @State private var catalog: [HiddenAppItem] = UserDefaults.standard.esc_hiddenApps

    @State private var newName = ""
    @State private var newBID = ""

    @State private var showPicker = false
    @State private var installedApps: [InstalledApp] = []
    @State private var pickerMessage = ""
    @State private var showPickerMessage = false
    @State private var isPickerLoading = false

    @State private var shareTarget: ShareTarget?
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        List {
            Section {
                TextField("名称", text: $newName)
                TextField("Bundle ID（区分大小写）", text: $newBID)
                Button("添加应用") {
                    addApp(name: newName, bundleID: newBID)
                }
                Button {
                    openPicker()
                } label: {
                    Label("从已安装应用选择", systemImage: "list.bullet")
                }
            } footer: {
                Text("关闭某 App 的开关即将其隐藏：它会从主屏幕、App 资源库与“设置”中消失，但数据会保留。Bundle ID 区分大小写。")
            }

            Section {
                ForEach(catalog) { app in
                    Toggle(isOn: hiddenBinding(app.bundleID)) {
                        HStack(spacing: 12) {
                            supervisedAppIcon(app.bundleID)
                                .resizable()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name.isEmpty ? app.bundleID : app.name)
                                    .font(.subheadline)
                                Text(app.bundleID)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            removeApp(app)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            } header: {
                Label("已登记应用", systemImage: "square.fill.text.grid.1x2")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("应用隐藏")
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
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                pickerSheet
                    .navigationTitle("选择应用")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showPicker = false }
                        }
                    }
            }
        }
        .alert("提示", isPresented: $showPickerMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(pickerMessage)
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            do {
                rsCurrentDict = try SupervisedProfileStore.load(.restrictions)
                syncCatalogFromProfile()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    // MARK: - 选择器

    private var pickerSheet: some View {
        Group {
            if isPickerLoading {
                ProgressView("正在枚举已安装应用…")
            } else if installedApps.isEmpty {
                ContentUnavailableView("暂无应用", systemImage: "app", description: Text(pickerMessage.isEmpty ? "未找到已安装应用。" : pickerMessage))
            } else {
                List(installedApps) { app in
                    Button {
                        addApp(name: app.name, bundleID: app.bundleIdentifier)
                        showPicker = false
                    } label: {
                        HStack(spacing: 12) {
                            if let icon = AppDiscovery().appIcon(for: app.bundleIdentifier) {
                                Image(uiImage: icon)
                                    .resizable()
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline)
                                Text(app.bundleIdentifier)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func openPicker() {
        let discovery = AppDiscovery()
        guard discovery.hasPairingFile else {
            pickerMessage = "未检测到配对文件，无法枚举已安装应用。请直接在上方手动填写 Bundle ID（可参考「更多 → 应用」中的列表）。"
            showPickerMessage = true
            return
        }
        isPickerLoading = true
        showPicker = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let apps = try discovery.fetchInstalledApps()
                DispatchQueue.main.async {
                    isPickerLoading = false
                    installedApps = apps
                }
            } catch {
                DispatchQueue.main.async {
                    isPickerLoading = false
                    installedApps = []
                    pickerMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 操作

    private func blockedArray() -> NSMutableArray {
        let pl = (rsCurrentDict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary
        if let existing = pl?["blockedAppBundleIDs"] as? NSMutableArray {
            return existing
        }
        let fresh = NSMutableArray()
        pl?["blockedAppBundleIDs"] = fresh
        return fresh
    }

    private func addApp(name: String, bundleID: String) {
        let bid = bundleID.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return }
        if catalog.contains(where: { $0.bundleID == bid }) {
            errorMessage = "该 Bundle ID 已存在。"
            showError = true
            return
        }
        catalog.append(HiddenAppItem(name: nm.isEmpty ? bid : nm, bundleID: bid))
        let arr = blockedArray()
        if !arr.contains(bid) { arr.add(bid) }
        newName = ""
        newBID = ""
        persistCatalog()
        persist()
    }

    private func removeApp(_ app: HiddenAppItem) {
        catalog.removeAll(where: { $0.id == app.id })
        let arr = blockedArray()
        arr.remove(app.bundleID)
        persistCatalog()
        persist()
    }

    /// 开关 ON = 可见（不在 blocked 列表）；OFF = 隐藏（在 blocked 列表）。
    private func hiddenBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(get: {
            let arr = blockedArray()
            return !arr.contains(bundleID)
        }, set: { visible in
            let arr = blockedArray()
            if visible {
                arr.remove(bundleID)
            } else {
                if !arr.contains(bundleID) { arr.add(bundleID) }
            }
            persist()
        })
    }

    private func syncCatalogFromProfile() {
        let arr = blockedArray()
        for bid in arr where !catalog.contains(where: { $0.bundleID == (bid as? String ?? "") }) {
            if let b = bid as? String {
                catalog.append(HiddenAppItem(name: b, bundleID: b))
            }
        }
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
        do {
            try SupervisedProfileStore.install(.restrictions)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func resetProfile() {
        do {
            try SupervisedProfileStore.reset(.restrictions)
            rsCurrentDict = try SupervisedProfileStore.load(.restrictions)
            catalog = []
            persistCatalog()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func persistCatalog() {
        UserDefaults.standard.esc_hiddenApps = catalog
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
