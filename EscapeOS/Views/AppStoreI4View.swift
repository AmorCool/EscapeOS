import SwiftUI

/// v0.3.298：爱思商店（专题 / 榜单）—— 走 `I4StoreClient` 的签名接口
struct AppStoreI4View: View {
    @State private var specials: [[String: Any]] = []
    @State private var apps: [[String: Any]] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var rank: I4StoreClient.Rank = .mustHave
    @State private var tab = 0
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Picker("视图", selection: $tab) {
                    Text("专题").tag(0)
                    Text("榜单").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if tab == 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(I4StoreClient.Rank.allCases) { r in
                                Button {
                                    rank = r
                                    Task { await loadApps() }
                                } label: {
                                    Text(r.title)
                                        .font(.subheadline.weight(rank == r ? .semibold : .regular))
                                        .foregroundStyle(rank == r ? Color.white : Color.primary)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(rank == r ? Color.blue : Color(.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            if loading {
                Section {
                    HStack { Spacer(); ProgressView("加载中…"); Spacer() }.padding(.vertical, 40)
                }
            } else if let errorText {
                Section {
                    VStack(spacing: 10) {
                        Text(errorText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("重试") { Task { await reload() } }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else if tab == 0 {
                specialSection
            } else {
                appSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("爱思商店")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .task { await reload() }
    }

    // MARK: 专题

    @ViewBuilder
    private var specialSection: some View {
        if specials.isEmpty {
            Section { ContentUnavailableView("暂无专题", systemImage: "square.stack.3d.up") }
        } else {
            Section("专题 · \(specials.count)") {
                ForEach(Array(specials.enumerated()), id: \.offset) { _, s in
                    NavigationLink {
                        I4SpecialAppsView(specialId: specialId(s), name: (s["name"] as? String) ?? "专题")
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: (s["icon"] as? String) ?? "")) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFill() }
                                else { Color(.tertiarySystemFill) }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text((s["name"] as? String) ?? "—").font(.subheadline.weight(.medium)).lineLimit(1)
                                Text((s["introduce"] as? String) ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                if let c = s["scount"] as? NSNumber {
                                    Text("\(c.intValue) 款应用").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: 榜单

    @ViewBuilder
    private var appSection: some View {
        if apps.isEmpty {
            Section {
                ContentUnavailableView("该榜单暂无数据", systemImage: "square.grid.2x2",
                                       description: Text("接口已签名成功，但该 remd 未返回条目"))
            }
        } else {
            Section("\(rank.title) · \(apps.count)") {
                ForEach(Array(apps.enumerated()), id: \.offset) { idx, a in
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(idx < 3 ? Color.orange : Color.secondary)
                            .frame(width: 22)
                        AsyncImage(url: URL(string: iconURL(a))) { phase in
                            if case .success(let img) = phase { img.resizable().scaledToFit() }
                            else { Color(.tertiarySystemFill) }
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appName(a)).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text((a["desc"] as? String) ?? (a["introduce"] as? String) ?? "")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button {
                            Task { await install(a) }
                        } label: {
                            Text("安装").font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.blue.opacity(0.14), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func specialId(_ s: [String: Any]) -> String {
        if let n = s["id"] as? NSNumber { return n.stringValue }
        if let str = s["id"] as? String { return str }
        return ""
    }

    private func iconURL(_ a: [String: Any]) -> String {
        (a["icon"] as? String) ?? (a["iconurl"] as? String) ?? (a["head"] as? String) ?? ""
    }

    private func appName(_ a: [String: Any]) -> String {
        (a["name"] as? String) ?? (a["appname"] as? String) ?? (a["title"] as? String) ?? "—"
    }

    // MARK: 安装

    /// 取详情 → 解析 manifest plist → 交给系统 itms-services
    private func install(_ a: [String: Any]) async {
        let bid = i4Value(a, keys: ["bundleid", "bundleId", "sourceid", "sourceId"])
        let name = i4Value(a, keys: ["name", "appname", "appName", "title"])
        guard !bid.isEmpty else {
            await MainActor.run { toast = "该条目缺少 Bundle ID，无法匹配安装包" }
            return
        }
        do {
            guard let hit = await SourcePackageLocator.find(bundleId: bid, name: name) else {
                await MainActor.run { toast = "免登录源里没有该应用" }
                return
            }
            let ipa = try await AppStoreInstallService.downloadIPA(
                urlString: hit.ipaURL,
                suggestedName: "\(bid)-\(hit.version ?? "x").ipa",
                onLog: { LoginLogger.shared.log("[爱思源] \($0)", category: .i4Store) })
            await MainActor.run {
                IPADownloadLibrary.shared.record(fileURL: ipa,
                                                 displayName: name.isEmpty ? hit.name : name,
                                                 bundleId: bid,
                                                 version: hit.version,
                                                 iconURL: i4Value(a, keys: ["icon", "iconurl"]),
                                                 source: "爱思免登录")
            }
            try await AppStoreInstallService.installLocalIPA(
                ipa.path,
                onLog: { LoginLogger.shared.log("[爱思源] \($0)", category: .i4Store) })
            IPADownloadLibrary.shared.markInstalled(fileName: ipa.lastPathComponent)
            await MainActor.run { toast = "已安装：\(name.isEmpty ? hit.name : name)" }
        } catch {
            await MainActor.run { toast = "安装失败：\(error.localizedDescription)" }
        }
    }

    // MARK: 加载

    private func reload() async {
        await loadSpecials()
        if tab == 1 { await loadApps() }
    }

    private func loadSpecials() async {
        loading = true
        errorText = nil
        do {
            specials = try await I4StoreClient.specialList()
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func loadApps() async {
        loading = true
        errorText = nil
        do {
            apps = try await I4StoreClient.appList(rank: rank)
            if apps.isEmpty { errorText = nil }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

/// v0.3.299：专题内的应用列表（`remd=2` + `specialid`）
///
/// 说明：爱思服务端对参数极敏感 —— `getAppList.xhtml` 仅在
/// `{pageSize, pageno, remd, sort}` 四参数时返回结构，多一个字段即返回空。
/// 专题内应用当前实测返回空数据（`{"app":{"id":-100}}` 或空体），
/// 因此本页在拿不到数据时给出**原始响应**，便于区分「签名/请求是否正确」与
/// 「服务端是否还有数据」，不作误导性展示。
struct I4SpecialAppsView: View {
    let specialId: String
    let name: String

    @State private var apps: [[String: Any]] = []
    @State private var raw = ""
    @State private var loading = true
    @State private var sort = 1
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Picker("类型", selection: $sort) {
                    Text("应用专题").tag(1)
                    Text("游戏专题").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if loading {
                Section { HStack { Spacer(); ProgressView("读取中…"); Spacer() }.padding(.vertical, 36) }
            } else if apps.isEmpty {
                Section("服务端返回的原始响应") {
                    Text(raw.isEmpty ? "(空响应)" : raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Text("说明：签名请求已被服务端接受（同接口在其它参数下会返回 {\"app\":…} 结构），但该专题未返回应用条目。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(name) · \(apps.count) 款") {
                    ForEach(Array(apps.enumerated()), id: \.offset) { idx, a in
                        HStack(spacing: 12) {
                            Text("\(idx + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            AsyncImage(url: URL(string: (a["icon"] as? String) ?? "")) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFit() }
                                else { Color(.tertiarySystemFill) }
                            }
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text((a["name"] as? String) ?? "—")
                                    .font(.subheadline.weight(.medium)).lineLimit(1)
                                Text((a["desc"] as? String) ?? (a["introduce"] as? String) ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Button {
                                Task { await install(a) }
                            } label: {
                                Text("安装").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .task { await load() }
        .onChange(of: sort) { _, _ in Task { await load() } }
    }

    private func load() async {
        loading = true
        apps = []
        do {
            apps = try await I4StoreClient.specialApps(specialId: specialId, sort: sort)
            raw = try await I4StoreClient.specialAppsRaw(specialId: specialId, sort: sort)
        } catch {
            raw = "请求失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func install(_ a: [String: Any]) async {
        let bid = i4Value(a, keys: ["bundleid", "bundleId", "sourceid", "sourceId"])
        let name = i4Value(a, keys: ["name", "appname", "appName", "title"])
        guard !bid.isEmpty else {
            await MainActor.run { toast = "该条目缺少 Bundle ID，无法匹配安装包" }
            return
        }
        do {
            guard let hit = await SourcePackageLocator.find(bundleId: bid, name: name) else {
                await MainActor.run { toast = "免登录源里没有该应用" }
                return
            }
            let ipa = try await AppStoreInstallService.downloadIPA(
                urlString: hit.ipaURL,
                suggestedName: "\(bid)-\(hit.version ?? "x").ipa",
                onLog: { LoginLogger.shared.log("[爱思源] \($0)", category: .i4Store) })
            await MainActor.run {
                IPADownloadLibrary.shared.record(fileURL: ipa,
                                                 displayName: name.isEmpty ? hit.name : name,
                                                 bundleId: bid,
                                                 version: hit.version,
                                                 iconURL: i4Value(a, keys: ["icon", "iconurl"]),
                                                 source: "爱思免登录")
            }
            try await AppStoreInstallService.installLocalIPA(
                ipa.path,
                onLog: { LoginLogger.shared.log("[爱思源] \($0)", category: .i4Store) })
            IPADownloadLibrary.shared.markInstalled(fileName: ipa.lastPathComponent)
            await MainActor.run { toast = "已安装：\(name.isEmpty ? hit.name : name)" }
        } catch {
            await MainActor.run { toast = "安装失败：\(error.localizedDescription)" }
        }
    }
}

/// 爱思接口返回的是 `[String: Any]`，字段名各接口大小写不一致 —— 按候选键依次取值。
private func i4Value(_ d: [String: Any], keys: [String]) -> String {
    for k in keys {
        if let v = d[k] as? String, !v.isEmpty { return v }
        if let n = d[k] as? NSNumber { return n.stringValue }
    }
    return ""
}
