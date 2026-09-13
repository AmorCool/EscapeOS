import SwiftUI

/// v0.3.364：免登录商店的**应用详情页**。
///
/// 数据源与列表同一套（爱思 PC 端公开接口），详情走 `app4.i4.cn/appinfo.xhtml`，
/// 返回体里的 `historyversion` 即该应用在爱思的**历史版本**；安装旧版与安装当前版本
/// 共用统一下载入口 `IPADownloadCenter`（不另造下载器）。
struct I4StoreFreeDetailView: View {

    let app: I4PCStoreClient.I4App

    @State private var detail: I4PCStoreClient.I4AppDetail?
    @State private var loading = true
    @State private var errorText: String?
    @State private var showAllVersions = false
    @ObservedObject private var center = IPADownloadCenter.shared

    /// 历史版本默认只露前 8 个，其余点「查看全部」
    private let versionPageSize = 8

    private var bundleId: String? { detail?.bundleId ?? app.bundleId }
    private var displayName: String { detail?.name ?? app.name }
    private var displayIcon: String? { detail?.icon ?? app.icon }

    private var visibleVersions: [I4PCStoreClient.I4Version] {
        let all = detail?.versions ?? []
        return showAllVersions ? all : Array(all.prefix(versionPageSize))
    }

    var body: some View {
        List {
            if loading {
                loadingSection
            } else if let errorText {
                errorSection(errorText)
            } else if let d = detail {
                headerSection(d)
                infoSection(d)
                screenshotsSection(d)
                noteSections(d)
                versionSection(d)
            } else {
                errorSection("该应用暂无详情")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toastHost()
        .task { await load() }
    }

    // MARK: - 头图 + 当前版本

    private func headerSection(_ d: I4PCStoreClient.I4AppDetail) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: URL(string: displayIcon ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                    default: ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(d.name).font(.headline).lineLimit(2)
                    if let s = d.shortNote ?? app.slogan, !s.isEmpty {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let v = d.version { chip("v\(v)", .blue) }
                        if let c = d.category { chip(c, .gray) }
                    }
                }
                Spacer(minLength: 6)
                installControl(version: d.version) { installCurrent(d) }
            }
            .padding(.vertical, 2)
        }
    }

    private func infoSection(_ d: I4PCStoreClient.I4AppDetail) -> some View {
        Section {
            if let v = d.version { infoRow("版本", v) }
            if let s = d.sizeText { infoRow("大小", s) }
            if let t = d.updateTime { infoRow("更新日期", t) }
            if let c = d.category { infoRow("类别", c) }
            if let c = d.company { infoRow("作者", c) }
            if let m = d.minOS { infoRow("系统要求", "iOS \(m) 或更高版本") }
            if let l = d.language { infoRow("语言", l) }
        }
    }

    @ViewBuilder
    private func screenshotsSection(_ d: I4PCStoreClient.I4AppDetail) -> some View {
        if !d.screenshots.isEmpty {
            Section("截图") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(d.screenshots, id: \.self) { url in
                            AsyncImage(url: URL(string: url)) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFit()
                                default: Color(.secondarySystemBackground)
                                }
                            }
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
    }

    @ViewBuilder
    private func noteSections(_ d: I4PCStoreClient.I4AppDetail) -> some View {
        if let n = d.newVersionNote {
            Section("新功能") {
                Text(n).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        if let n = d.longNote {
            Section("简介") {
                Text(n).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 历史版本

    private func versionSection(_ d: I4PCStoreClient.I4AppDetail) -> some View {
        Section {
            if d.versions.isEmpty {
                Text("暂无历史版本").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(visibleVersions) { v in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("v\(v.version)").font(.subheadline.weight(.medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                if let t = v.releaseTime, !t.isEmpty { chip(t, .gray) }
                                if let s = v.sizeText { chip(s, .green) }
                            }
                            if let n = v.note, !n.isEmpty {
                                Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        installControl(version: v.version) { install(v, in: d) }
                    }
                    .padding(.vertical, 2)
                }
                if !showAllVersions && d.versions.count > versionPageSize {
                    Button {
                        showAllVersions = true
                    } label: {
                        Text("查看全部 \(d.versions.count) 个版本").font(.subheadline)
                    }
                }
            }
        } header: {
            Text(d.versions.isEmpty ? "历史版本" : "历史版本 · \(d.versions.count)")
        }
    }

    // MARK: - 小组件

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).multilineTextAlignment(.trailing)
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    /// 安装按钮：该版本正在下载/安装时显示进度，否则显示「安装」
    @ViewBuilder
    private func installControl(version: String?, action: @escaping () -> Void) -> some View {
        if let job = activeJob(version: version) {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, job.overall)))
                    .frame(width: 44)
                Text(job.stageText).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Button(action: action) {
                Text("安装")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.14), in: Capsule())
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private func activeJob(version: String?) -> IPADownloadCenter.Job? {
        center.jobs.first { job in
            guard job.phase.isBusy, job.version == version else { return false }
            if let bid = bundleId, let jb = job.bundleId { return bid == jb }
            return job.name == displayName
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在加载详情…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private func errorSection(_ text: String) -> some View {
        Section {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
        }
    }

    // MARK: - 加载 / 下载

    private func load() async {
        loading = true
        errorText = nil
        do {
            detail = try await I4PCStoreClient.detail(appId: app.id, pkagetype: app.pkgType)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func installCurrent(_ d: I4PCStoreClient.I4AppDetail) {
        start(name: d.name, bundleId: d.bundleId ?? app.bundleId,
              version: d.version, icon: d.icon ?? app.icon, url: d.ipaURL)
    }

    private func install(_ v: I4PCStoreClient.I4Version, in d: I4PCStoreClient.I4AppDetail) {
        start(name: d.name, bundleId: d.bundleId ?? app.bundleId,
              version: v.version, icon: d.icon ?? app.icon, url: v.ipaURL)
    }

    private func start(name: String, bundleId: String?, version: String?, icon: String?, url: URL?) {
        guard let url else {
            ToastCenter.shared.show("该版本没有可用的安装包地址")
            return
        }
        _ = IPADownloadCenter.shared.start(name: name,
                                           bundleId: bundleId,
                                           version: version,
                                           iconURL: icon,
                                           remoteURL: url.absoluteString,
                                           autoInstall: true)
    }
}
