import SwiftUI
import UIKit

/// 开发者镜像（DDI / DMG）下载页。
/// 参考 StikDebug 的 Redownload DDI：下载 Xcode_iOS_DDI_Personalized 中的
/// BuildManifest.plist、Image.dmg、Image.dmg.trustcache 到 Documents/DDI/，
/// 完成后打包成 DMG.zip 并弹出系统分享。
struct DDIDownloadView: View {
    @State private var state = DDIDownloadState()
    @State private var shareURL: URL?

    private let items = DDIDownloadItem.allItems

    var body: some View {
        List {
            Section {
                InfoActionCard(
                    icon: "iphone.and.arrow.forward",
                    title: "开发者镜像",
                    message: "下载 Xcode 个性化 DDI 镜像（Image.dmg、BuildManifest.plist、TrustCache）到 EscapeSpace 的 Documents/DDI 目录，完成后自动打包为 DMG.zip。文件可用于侧载调试工具挂载 DDI。",
                    actionTitle: state.isRunning ? "下载中…" : "重新下载",
                    action: { startDownload() },
                    disabled: state.isRunning
                )
            }

            if state.isRunning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: state.progress, total: 1.0)
                            .progressViewStyle(.linear)
                        Text(state.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("进度", systemImage: "timer")
                }
            }

            if let shareURL = shareURL {
                Section {
                    Button {
                        shareFile(shareURL)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .foregroundStyle(AppTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("分享 DMG.zip")
                                    .font(.subheadline.weight(.semibold))
                                Text(shareURL.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Label("已就绪", systemImage: "checkmark.circle")
                }
            }

            Section {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline)
                            Text(item.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Label("包含文件", systemImage: "doc.on.doc")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("开发者镜像")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $state.shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .alert(item: $state.errorAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onAppear {
            scanExistingZip()
        }
    }

    private func scanExistingZip() {
        let fm = FileManager.default
        let zipURL = DDIDownloadPaths.zipURL
        if fm.fileExists(atPath: zipURL.path) {
            shareURL = zipURL
        }
    }

    private func startDownload() {
        state.start()
        Task {
            await performRedownload()
        }
    }

    @MainActor
    private func performRedownload() async {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ddiDir = docs.appendingPathComponent("DDI")
        let zipURL = ddiDir.appendingPathComponent("DMG.zip")

        do {
            // 清理旧文件
            if fm.fileExists(atPath: ddiDir.path) {
                try fm.removeItem(at: ddiDir)
            }
            try fm.createDirectory(at: ddiDir, withIntermediateDirectories: true)

            let total = Double(items.count)
            for (index, item) in items.enumerated() {
                state.setStatus("正在下载 \(item.name)…")
                let dest = ddiDir.appendingPathComponent(item.fileName)
                try await downloadFile(from: item.urlString, to: dest)
                state.setProgress((Double(index) + 1.0) / (total + 1.0))
            }

            state.setStatus("正在打包 DMG.zip…")
            try createZip(at: zipURL, sourceDirectory: ddiDir, excluding: zipURL.lastPathComponent)
            state.setProgress(1.0)
            state.setStatus("完成")

            shareURL = zipURL
            state.presentShare(url: zipURL)
        } catch {
            state.fail("下载或打包失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func downloadFile(from urlString: String, to destinationURL: URL) async throws {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else {
            throw DDIDownloadError.invalidURL(urlString)
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw DDIDownloadError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: temporaryURL, to: destinationURL)
    }

    @MainActor
    private func createZip(at zipURL: URL, sourceDirectory: URL, excluding: String) throws {
        let fm = FileManager.default
        let writer = ZipWriter()
        try writer.begin(at: zipURL)

        let entries = try fm.contentsOfDirectory(atPath: sourceDirectory.path)
            .filter { $0 != excluding }
        for entry in entries {
            let fileURL = sourceDirectory.appendingPathComponent(entry)
            let data = try Data(contentsOf: fileURL)
            try writer.addFile(name: entry, data: data, modified: Date())
        }

        try writer.finish()
    }

    private func shareFile(_ url: URL) {
        state.presentShare(url: url)
    }
}

// MARK: - Model

@MainActor
@Observable
private final class DDIDownloadState {
    var isRunning = false
    var progress: Double = 0
    var status: String = ""
    var shareTarget: ShareTarget?
    var errorAlert: DDIDownloadAlert?

    func start() {
        isRunning = true
        progress = 0
        status = "准备下载…"
        errorAlert = nil
    }

    func setProgress(_ value: Double) {
        progress = value
    }

    func setStatus(_ text: String) {
        status = text
    }

    func fail(_ message: String) {
        isRunning = false
        errorAlert = DDIDownloadAlert(title: "下载失败", message: message)
    }

    func presentShare(url: URL) {
        shareTarget = ShareTarget(url: url)
    }
}

private struct DDIDownloadAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct DDIDownloadItem: Identifiable {
    let id = UUID()
    let name: String
    let fileName: String
    let relativePath: String
    let urlString: String
    let icon: String

    static let allItems: [DDIDownloadItem] = [
        .init(
            name: "Build Manifest",
            fileName: "BuildManifest.plist",
            relativePath: "DDI/BuildManifest.plist",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist",
            icon: "doc.text"
        ),
        .init(
            name: "Image",
            fileName: "Image.dmg",
            relativePath: "DDI/Image.dmg",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg",
            icon: "internaldrive"
        ),
        .init(
            name: "TrustCache",
            fileName: "Image.dmg.trustcache",
            relativePath: "DDI/Image.dmg.trustcache",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache",
            icon: "checkmark.shield"
        )
    ]
}

private struct DDIDownloadPaths {
    static let zipURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("DDI/DMG.zip")
    }()
}

enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "无效的下载地址：\(string)"
        case .badStatus(let code):
            return "服务器返回 HTTP \(code)"
        }
    }
}
