import SwiftUI

/// v0.3.364：免登录商店的**应用详情页**。
///
/// 数据源与列表同一套（爱思 PC 端公开接口），详情走 `app4.i4.cn/appinfo.xhtml`，
/// 返回体里的 `historyversion` 即该应用在爱思的**历史版本**；安装旧版与安装当前版本
/// 共用统一下载入口 `IPADownloadCenter`（不另造下载器）。
///
/// v0.3.368：`appinfo` 返回体里还带 `app_privacy`，直接渲染成「App 隐私」一节 —— **零额外请求**。
struct I4StoreFreeDetailView: View {

    let app: I4PCStoreClient.I4App

    @State private var detail: I4PCStoreClient.I4AppDetail?
    @State private var loading = true
    @State private var errorText: String?
    @State private var showAllVersions = false
    @ObservedObject private var center = IPADownloadCenter.shared

    /// v0.3.399：点截图 → 全屏预览（**复用** AppleID 详情页那套 `ImageGalleryViewer`，
    /// 长按存图是它自带的行为，不在爱思侧另写一套）。
    @State private var viewerTarget: ImagePreviewTarget?

    /// 历史版本默认只露前 8 个，其余点「查看全部」
    private let versionPageSize = 8

    private var bundleId: String? { detail?.bundleId ?? app.bundleId }
    private var displayName: String { detail?.name ?? app.name }
    private var displayIcon: String? { detail?.icon ?? app.icon }

    /// v0.3.367：该应用正在进行的任务。**与列表页 / 下载管理页同源** ——
    /// 全工程只有 `IPADownloadCenter` 这一套下载状态，这里只是读它。
    private var busyJob: IPADownloadCenter.Job? {
        center.activeJob(bundleId: bundleId, name: displayName)
    }

    private var visibleVersions: [I4PCStoreClient.I4Version] {
        let all = detail?.versions ?? []
        return showAllVersions ? all : Array(all.prefix(versionPageSize))
    }

    var body: some View {
        List {
            // 进度只依赖 `IPADownloadCenter`（bundleId / 名称来自列表传进来的 `app`），
            // 所以放在最外层：详情还在加载、甚至详情加载失败时，进度也照样看得见。
            if let job = busyJob { downloadSection(job) }
            if loading {
                loadingSection
            } else if let errorText {
                errorSection(errorText)
            } else if let d = detail {
                headerSection(d)
                infoSection(d)
                screenshotsSection(d)
                noteSections(d)
                privacySection(d)
                versionSection(d)
            } else {
                errorSection("该应用暂无详情")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewerTarget) { target in
            ImageGalleryViewer(urls: detail?.screenshots ?? [], startIndex: target.index)
        }
        .toastHost()
        .task { await load() }
    }

    // MARK: - 头图 + 当前版本

    /// v0.3.367：列表里点了「安装」再进详情，这里要能立刻看见**同一个任务的进度**
    /// （阶段文字 + 百分比 + 进度条 + 暂停 / 删除），样式对齐「下载管理」页。
    private func downloadSection(_ job: IPADownloadCenter.Job) -> some View {
        Section("下载中") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(job.phase == .paused ? "已暂停" : job.stageText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let v = job.version, !v.isEmpty {
                        Text("v\(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(job.overall * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, job.overall)))
                HStack(spacing: 16) {
                    Button {
                        if job.phase == .paused {
                            center.resume(job.id)
                        } else {
                            center.pause(job.id)
                        }
                    } label: {
                        Label(job.phase == .paused ? "继续" : "暂停",
                              systemImage: job.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(job.canPause ? Color.blue : Color.secondary)
                    .disabled(!job.canPause)

                    Button {
                        center.cancel(job.id)
                    } label: {
                        Label("删除安装包", systemImage: "trash")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)

                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }

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
                // v0.3.367：按「应用」而不是「版本号」匹配 —— 详情页拿到的版本号可能和
                // 列表发起下载时的不一致，旧写法会匹配不上，于是「点了安装进来却看不到进度」。
                if let job = busyJob {
                    progressChip(job)
                } else {
                    installButton { installCurrent(d) }
                }
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
                        ForEach(Array(d.screenshots.enumerated()), id: \.offset) { index, url in
                            // v0.3.399：对齐 AppleID 详情页 —— 点开全屏预览（进去后长按即可保存）。
                            // 图片尺寸 / 圆角保持原样，只加交互。
                            Button {
                                viewerTarget = ImagePreviewTarget(index: index)
                            } label: {
                                AsyncImage(url: URL(string: url)) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().scaledToFit()
                                    default: Color(.secondarySystemBackground)
                                    }
                                }
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
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

    // MARK: - App 隐私

    /// v0.3.368：App 隐私 —— 数据来自同一发 `appinfo.xhtml` 的 `app_privacy`，**零额外请求**。
    ///
    /// 爱思这份数据只有「分组（原文 heading）→ 数据类别」两层，比 App Store 粗；
    /// 所以**有什么显示什么**：不补解释句、不加 footnote、缺数据的应用整节不显示。
    @ViewBuilder
    private func privacySection(_ d: I4PCStoreClient.I4AppDetail) -> some View {
        if !d.privacyCards.isEmpty {
            Section("App 隐私") {
                ForEach(d.privacyCards) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.heading)
                            .font(.subheadline.weight(.medium))
                        ForEach(card.items) { item in
                            HStack(spacing: 8) {
                                if let icon = item.icon, let url = URL(string: icon) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        Color.clear
                                    }
                                    .frame(width: 18, height: 18)
                                }
                                Text(item.heading)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
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

    /// 历史版本行上的进度：只认**版本号完全一致**的任务
    /// （当前版本的进度不能错挂到旧版那一行）
    @ViewBuilder
    private func installControl(version: String?, action: @escaping () -> Void) -> some View {
        if let job = activeJob(version: version) {
            progressChip(job)
        } else {
            installButton(action: action)
        }
    }

    /// 进度胶囊：细进度条 + 百分比，定宽避免把左侧信息挤扁
    private func progressChip(_ job: IPADownloadCenter.Job) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: min(1, max(0, job.overall)))
                .frame(width: 40)
            Text("\(Int(job.overall * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func installButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("安装")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.blue.opacity(0.14), in: Capsule())
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func activeJob(version: String?) -> IPADownloadCenter.Job? {
        guard let version, !version.isEmpty else { return nil }
        return center.jobs.first { job in
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
