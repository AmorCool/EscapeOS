import SwiftUI

/// NB 源（NB Pro）的应用详情页。
///
/// ## 为什么需要它
/// 免登录商店的前两个来源（爱思、牛蛙）在列表里点一行就能进详情页，
/// 而 NB 源的入口是「粘贴 App Store 链接 / 数字 ID」——原实现只有一行结果卡，
/// **点不进去，也看不到历史版本**。用户要的是「NB 助手能搜到 App、能选历史版本下载」，
/// 所以这里把 NB 的结果也做成可进的详情页。
///
/// ## 数据来源（两段拼起来，都已在本项目里通着）
/// 1. **版本列表** → `NBStoreClient.versionList(trackID:)`，
///    实际走 `apis.bilin.eu.org/history/<trackId>`（与 AppleID 商店的历史版本同一份目录），
///    每项带 `external_identifier`（= NB 要的 `appVerId`）。
/// 2. **取包** → `NBStoreClient.package(appID:appVerId:)`，走 `/nb/app-downgrade`，
///    回 Apple CDN 直链 + `sinfs[].dataHex`。
///
/// NB 自己**没有**「一次回全量版本」的接口（`getAppHistoryList` 是取单版本的包，
/// 见 `P3_爱思助手_NB逆向工作区/NB下载接口逆向报告.md` 第十节），
/// 所以版本列表这一段**复用**已有的 bilin 目录，不新增外部依赖、不造轮胎。
///
/// ## 与另外两个免登录详情页的关系
/// NB 接口回的字段只有 `url` / `sinfs`，**没有名称、图标、截图、简介**——
/// 没有的数据不硬凑，所以这个页面不长成爱思详情页那样。
/// 「下载中」区块与安装按钮**复用**同款共用组件（`DownloadJobSection` / `InstallButton`），
/// 全项目仍然只有一套下载/安装实现。
struct NBStoreDetailView: View {

    /// App Store 数字 ID（NB 的 `appID` 与 bilin 路径参数同源）
    let trackID: String
    /// 区域（NB 的 `country` 参数；`cn` / `us` / `hk`）
    let country: String

    /// 可选的展示名：从爱思/NB 列表跳进来时带上，直接粘贴 ID 时为空。
    /// NB 接口本身不回名字，所以这里是「有就显示，没有就不显示」，不编造。
    let displayName: String?

    @ObservedObject private var center = IPADownloadCenter.shared

    @State private var versions: [NBStoreClient.NBVersion] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var showAllVersions = false
    /// 正在取包的那一行（存 `externalIdentifier`，同一时刻只允许一行在取）
    @State private var fetchingID: String?

    private let versionPageSize = 12

    private var title: String {
        if let n = displayName, !n.isEmpty { return n }
        return "App \(trackID)"
    }

    private var busyJob: IPADownloadCenter.Job? {
        center.activeJob(bundleId: nil, name: title)
    }

    private var visibleVersions: [NBStoreClient.NBVersion] {
        showAllVersions ? versions : Array(versions.prefix(versionPageSize))
    }

    var body: some View {
        List {
            if let job = busyJob { jobSection(job) }
            idSection
            if loading {
                loadingSection
            } else if let errorText {
                errorSection(errorText)
            } else {
                versionSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toastHost()
        .task { await load() }
    }

    // MARK: - 下载中

    /// 「下载中」区块 —— 与爱思/牛蛙详情页同款布局。
    ///
    /// 那两页共用的是 `I4StoreFreeDetailView.swift` 里的 `private struct DownloadJobSection`，
    /// 访问级别是 `private`（只在本文件可见）。为了不动那份既有代码、也不把它的访问级别
    /// 放大到模块级，这里按同样的排版写一份 —— 布局与行为一致，读的是同一个
    /// `IPADownloadCenter`（**下载状态仍然只有一套**，这只是渲染）。
    private func jobSection(_ job: IPADownloadCenter.Job) -> some View {
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

    // MARK: - 标识

    private var idSection: some View {
        Section {
            infoRow("App Store ID", trackID)
            infoRow("区域", country.uppercased())
        } header: {
            Text("来源")
        }
    }

    // MARK: - 历史版本

    private var versionSection: some View {
        Section {
            if versions.isEmpty {
                Text("该应用暂无历史版本")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(visibleVersions) { v in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("v\(v.version)")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let t = v.releaseTime, !t.isEmpty { chip(t, .gray) }
                                if let s = v.sizeText, !s.isEmpty { chip(s, .green) }
                            }
                        }
                        Spacer(minLength: 6)
                        if fetchingID == v.externalIdentifier {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await installVersion(v) }
                            } label: {
                                Text("获取")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !showAllVersions && versions.count > versionPageSize {
                    Button {
                        showAllVersions = true
                    } label: {
                        Text("查看全部 \(versions.count) 个版本").font(.subheadline)
                    }
                }
            }
        } header: {
            Text(versions.isEmpty ? "历史版本" : "历史版本 · \(versions.count)")
        }
    }

    // MARK: - 小组件

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.monospacedDigit()).lineLimit(1).truncationMode(.middle)
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取版本列表…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func errorSection(_ text: String) -> some View {
        Section {
            Text(text).font(.subheadline).foregroundStyle(.red)
        }
    }

    // MARK: - 加载 / 下载

    private func load() async {
        loading = true
        errorText = nil
        guard !trackID.isEmpty else {
            errorText = "缺少 App Store ID，无法查询版本"
            loading = false
            return
        }
        do {
            versions = try await NBStoreClient.versionList(trackID: trackID)
        } catch {
            errorText = "读取版本列表失败：\(error.localizedDescription)"
        }
        loading = false
    }

    /// 取某个版本的包并交给统一下载中心。
    ///
    /// NB 的 `appVerId` 就是 bilin 目录里的 `external_identifier` —— 两者同一个编号体系，
    /// 所以这里直接把 `externalIdentifier` 原样传下去，不做任何换算。
    @MainActor
    private func installVersion(_ v: NBStoreClient.NBVersion) async {
        fetchingID = v.externalIdentifier
        defer { fetchingID = nil }
        do {
            guard let pkg = try await NBStoreClient.package(appID: trackID,
                                                            appVerId: v.externalIdentifier,
                                                            country: country) else {
                ToastCenter.shared.show("该版本没有可用的安装包")
                return
            }
            await startNBDownload(trackID: trackID,
                                  package: pkg,
                                  name: displayName,
                                  version: v.version)
        } catch {
            ToastCenter.shared.show("取包失败：\(error.localizedDescription)")
        }
    }
}
