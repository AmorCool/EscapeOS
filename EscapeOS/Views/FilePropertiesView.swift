import SwiftUI
import CryptoKit

/// Metadata sheet for a file or folder inside another app's container.
struct FilePropertiesView: View {
    let app: InstalledApp
    let item: FileItem

    @StateObject private var vm = FilePropertiesViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("名称")) {
                    Text(item.name)
                }
                Section(header: Text("路径")) {
                    Text(item.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Button {
                        FileClipboard.copyText(item.path, confirmation: "已复制路径")
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                    }
                }
                Section(header: Text("详情")) {
                    row("类型", kindLabel)
                    row("大小", formatBytes(item.size))
                    if let modified = item.modified {
                        row("修改时间", BackupPaths.displayStamp.string(from: modified))
                    }
                    row("可读", item.isReadable ? "是" : "否")
                    row("可写", item.isWritable ? "是" : "否")
                }
                if !item.isDirectory {
                    Section(header: Text("SHA-256")) {
                        if vm.isHashing {
                            HStack {
                                ProgressView()
                                Text("计算中…")
                            }
                        } else if let hash = vm.sha256 {
                            Text(hash)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                FileClipboard.copyText(hash, confirmation: "已复制 SHA-256")
                            } label: {
                                Label("复制 SHA-256", systemImage: "doc.on.doc")
                            }
                        } else if let error = vm.errorMessage {
                            Text(error).foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if !item.isDirectory {
                    vm.hash(app: app, item: item)
                }
            }
        }
    }

    private var kindLabel: String {
        FileContentKind.classify(name: item.name, isDirectory: item.isDirectory).rawValue
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

final class FilePropertiesViewModel: ObservableObject {
    @Published var sha256: String?
    @Published var isHashing = false
    @Published var errorMessage: String?

    private let escape = SandboxEscape()
    private let files = FileService()

    func hash(app: InstalledApp, item: FileItem) {
        isHashing = true
        errorMessage = nil
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try self.escape.withHandle(for: app.containerPath) { _ in
                    try self.files.readFile(at: item.path)
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                DispatchQueue.main.async {
                    self.sha256 = digest
                    self.isHashing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isHashing = false
                }
            }
        }
    }
}
