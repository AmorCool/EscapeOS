import SwiftUI

// MARK: - 通知管理（移植自 Lithium NotificationsView）

/// 已登记的通知管理项（名称 + Bundle ID + 是否允许通知）。
struct NotificationEntry: Identifiable, Codable {
    var id = UUID()
    var name: String
    var bundleID: String
    var isOn: Bool = true
}

struct NotificationManageView: View {
    @State private var nsCurrentDict = NSMutableDictionary()
    @State private var catalog: [NotificationEntry] = UserDefaults.standard.esc_notificationApps

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
                Text("关闭某 App 的开关后将完全收不到它的通知（可能包含关键提醒）。Bundle ID 区分大小写。")
            }

            Section {
                ForEach($catalog) { $app in
                    Toggle(isOn: $app.isOn) {
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
                    .onChange(of: app.isOn) { _ in
                        applyToProfile(bundleID: app.bundleID, enabled: app.isOn)
                        persistCatalog()
                        persist()
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
        .navigationTitle("通知管理")
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
        .onAppear(perform: reload)
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

    private func reload() {
        do {
            nsCurrentDict = try SupervisedProfileStore.load(.notifications)
            syncFromProfile()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func notificationArray() -> NSMutableArray {
        let pl = (nsCurrentDict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary
        if let existing = pl?["NotificationSettings"] as? NSMutableArray {
            return existing
        }
        let fresh = NSMutableArray()
        pl?["NotificationSettings"] = fresh
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
        let entry = NotificationEntry(name: nm.isEmpty ? bid : nm, bundleID: bid, isOn: true)
        catalog.append(entry)
        persistCatalog()

        let arr = notificationArray()
        arr.add(["BundleIdentifier": bid, "NotificationsEnabled": true])
        newName = ""
        newBID = ""
        persist()
    }

    private func removeApp(_ app: NotificationEntry) {
        catalog.removeAll(where: { $0.id == app.id })
        let arr = notificationArray()
        for item in arr where (item as? [String: Any])?["BundleIdentifier"] as? String == app.bundleID {
            arr.remove(item)
            break
        }
        persistCatalog()
        persist()
    }

    private func applyToProfile(bundleID: String, enabled: Bool) {
        let arr = notificationArray()
        for item in arr {
            guard let dict = item as? NSMutableDictionary,
                  let stored = dict["BundleIdentifier"] as? String, stored == bundleID else { continue }
            dict["NotificationsEnabled"] = enabled
        }
    }

    private func syncFromProfile() {
        let arr = notificationArray()
        for item in arr {
            guard let dict = item as? [String: Any],
                  let bid = dict["BundleIdentifier"] as? String,
                  let isOn = dict["NotificationsEnabled"] as? Bool else { continue }
            if let idx = catalog.firstIndex(where: { $0.bundleID == bid }) {
                catalog[idx].isOn = isOn
            } else {
                catalog.append(NotificationEntry(name: "未知应用", bundleID: bid, isOn: isOn))
            }
        }
    }

    private func persist() {
        do {
            try SupervisedProfileStore.save(.notifications, dict: nsCurrentDict)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func installProfile() {
        do {
            try SupervisedProfileStore.install(.notifications)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func resetProfile() {
        do {
            try SupervisedProfileStore.reset(.notifications)
            catalog = []
            persistCatalog()
            reload()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func persistCatalog() {
        UserDefaults.standard.esc_notificationApps = catalog
    }

    private func exportProfile() {
        do {
            let url = try SupervisedProfileStore.exportURL(.notifications)
            shareTarget = ShareTarget(url: url)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
