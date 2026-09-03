import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

/// 文件或文件夹的详细信息.
///
/// 字段是 EscapeOS 原版属性页与 Erosion `InfoViewer` 的并集：
/// - 保留 EscapeOS 原有的 SHA-256、复制路径 / 复制哈希；
/// - 补上 Erosion 有而 EscapeOS 原本没有的：UTType、创建时间、POSIX 权限、
///   所有者 / 所属组、可执行、符号链接目标.
///
/// 所有属性都在沙盒扩展持有期间读取 —— 离开扩展后这些路径不可访问.
struct FilePropertiesView: View {
    let rootPath: String
    let item: FileItem

    @StateObject private var vm = FilePropertiesViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(item.name)
                } header: {
                    Text("名称")
                }

                Section {
                    Text(item.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Button {
                        FileClipboard.copyText(item.path, confirmation: "已复制路径")
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("路径")
                }

                Section {
                    row("类型", kindLabel)
                    row("UTType", vm.utType ?? "—")
                    if let destination = vm.symlinkDestination {
                        row("链接目标", destination)
                    }
                    row("大小", formatBytes(item.size))
                    if let created = vm.creationDate {
                        row("创建时间", created)
                    }
                    if let modified = item.modified {
                        row("修改时间", BackupPaths.displayStamp.string(from: modified))
                    }
                } header: {
                    Text("详情")
                }

                Section {
                    row("POSIX 权限", vm.posixPermissions ?? "—")
                    row("所有者", vm.owner ?? "—")
                    row("所属组", vm.group ?? "—")
                    boolRow("可读", item.isReadable)
                    boolRow("可写", item.isWritable)
                    boolRow("可执行", vm.isExecutable)
                } header: {
                    Text("权限")
                } footer: {
                    Text("所有者 / 所属组在部分受保护路径下可能无法读取，此时显示“—”.")
                }

                if !item.isDirectory {
                    Section {
                        if vm.isLoading {
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
                    } header: {
                        Text("SHA-256")
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
                vm.load(rootPath: rootPath, item: item)
            }
        }
    }

    private var kindLabel: String {
        FileContentKind.classify(name: item.name, isDirectory: item.isDirectory).rawValue
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func boolRow(_ title: String, _ value: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: value ? "checkmark" : "xmark")
                .foregroundStyle(.secondary)
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
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var utType: String?
    @Published var creationDate: String?
    @Published var posixPermissions: String?
    @Published var owner: String?
    @Published var group: String?
    @Published var isExecutable = false
    @Published var symlinkDestination: String?

    private let escape = SandboxEscape()
    private let files = FileService()

    func load(rootPath: String, item: FileItem) {
        isLoading = true
        errorMessage = nil
        utType = Self.utTypeIdentifier(for: item)

        DispatchQueue.global(qos: .utility).async {
            do {
                // 一次扩展覆盖全部读取：属性、符号链接目标、文件内容（算哈希）.
                let outcome = try self.escape.withHandle(for: rootPath) { _ -> FileAttributesSnapshot in
                    let attrs = (try? self.files.attributes(at: item.path)) ?? [:]
                    let destination = item.kind == .symlink
                        ? try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                        : nil
                    let data = item.isDirectory ? nil : (try? self.files.readFile(at: item.path))
                    return FileAttributesSnapshot(attrs: attrs, destination: destination, data: data)
                }

                let digest = outcome.data.map { data in
                    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }

                DispatchQueue.main.async {
                    self.sha256 = digest
                    self.apply(outcome.attrs)
                    self.symlinkDestination = outcome.destination
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func apply(_ attrs: [FileAttributeKey: Any]) {
        if let perms = attrs[.posixPermissions] as? NSNumber {
            let value = perms.intValue
            posixPermissions = String(format: "%04o", value)
            isExecutable = value & 0o111 != 0
        }
        owner = attrs[.ownerAccountName] as? String
        group = attrs[.groupOwnerAccountName] as? String
        if let date = attrs[.creationDate] as? Date {
            creationDate = BackupPaths.displayStamp.string(from: date)
        }
    }

    private static func utTypeIdentifier(for item: FileItem) -> String? {
        if item.isDirectory { return UTType.directory.identifier }
        let ext = (item.name as NSString).pathExtension
        guard !ext.isEmpty else { return UTType.data.identifier }
        return UTType(filenameExtension: ext)?.identifier
    }

    private struct FileAttributesSnapshot {
        let attrs: [FileAttributeKey: Any]
        let destination: String?
        let data: Data?
    }
}
