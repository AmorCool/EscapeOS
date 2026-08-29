import Foundation
import SwiftUI

/// plist 结构化编辑器的状态与读写。
///
/// 移植自 Erosion 的 `PlistManager`，但有两处关键改动：
/// 1. **不是单例** —— 每个 plist 文件一个实例，避免多个页面互相踩数据。
/// 2. **读写都走 SandboxEscape + FileService** —— plist 在别的 App 容器里，
///    离开沙盒扩展既读不到也写不回（Erosion 是独立 App，能直接写）。
/// `Result` 的 `Failure` 必须遵循 `Error`，而 `String` 不遵循；包一层既满足协议
/// 约束，又是 Sendable（后台写文件的结果要跨 actor 边界回主线程）。
private struct PlistSaveFailure: Error {
    let message: String
}

@MainActor
final class PlistEditorViewModel: ObservableObject {

    /// 顶层条目数组。约定 `items[0]` 是虚拟的 Root 节点，真正的键值对在它的 `dictVal` 里
    /// —— 这样替换 / 删除递归函数有统一的入口（与 Erosion 一致）。
    @Published var items: [PlistItem] = []
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    let rootPath: String
    let item: FileItem

    private let initialData: Data

    init(rootPath: String, item: FileItem, initialData: Data) {
        self.rootPath = rootPath
        self.item = item
        self.initialData = initialData
        load(data: initialData)
    }

    /// 顶层字典（Root 节点的子项）。
    var rootChildren: [PlistItem] {
        items.first?.dictVal ?? []
    }

    // MARK: - 加载

    func load(data: Data) {
        isLoading = true
        errorMessage = nil

        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dict = plist as? [String: Any] else {
                // 数组 / 其它根类型：包一层虚拟 Root，让用户仍能看到内容。
                var root = PlistItem(key: "Root", value: ["value": plist], isExpanded: true)
                root.type = .dict
                items = [root]
                isLoading = false
                return
            }
            var root = PlistItem(key: "Root", value: dict, isExpanded: true)
            root.type = .dict
            root.dictVal = dict.map { PlistItem(key: $0.key, value: $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            items = [root]
        } catch {
            errorMessage = "无法解析这个 plist：\(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - 增删改

    /// 用 `updated` 替换树中同 id 的节点（不改 key 时用）。
    func replace(_ updated: PlistItem) {
        _ = replaceRecursively(in: &items, with: updated)
    }

    func delete(_ target: PlistItem) {
        _ = deleteRecursively(in: &items, id: target.id)
    }

    func addChild(_ child: PlistItem, to parent: PlistItem) {
        var updated = parent
        updated.dictVal.insert(child, at: 0)
        replace(updated)
    }

    // MARK: - 保存

    /// 把整棵树序列化成二进制 plist 写回原文件。
    func save() {
        guard !isSaving else { return }
        guard let root = items.first else { return }

        var dictionary = [String: Any]()
        for child in root.dictVal {
            dictionary[child.key] = child.rawValue()
        }

        let payload: Data
        do {
            payload = try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .binary,
                options: 0
            )
        } catch {
            errorMessage = "序列化失败：\(error.localizedDescription)"
            return
        }

        isSaving = true
        errorMessage = nil
        let rootPath = self.rootPath
        let path = item.path

        // 后台串行化 + 在闭包内创建实例，避免跨 actor 捕获非 Sendable 对象。
        Task.detached(priority: .userInitiated) { [weak self] in
            let escape = SandboxEscape()
            let files = FileService()
            let outcome: Result<Void, PlistSaveFailure>
            do {
                try escape.withHandle(for: rootPath) { _ in
                    try files.writeFile(data: payload, to: path)
                }
                outcome = .success(())
            } catch {
                outcome = .failure(PlistSaveFailure(message: error.localizedDescription))
            }

            await MainActor.run {
                guard let self else { return }
                self.isSaving = false
                switch outcome {
                case .success:
                    self.successMessage = "已写回文件。返回后重新打开可看到最新内容。"
                case .failure(let failure):
                    self.errorMessage = "写入失败：\(failure.message)"
                }
            }
        }
    }

    // MARK: - 递归工具

    private func replaceRecursively(in items: inout [PlistItem], with newItem: PlistItem) -> Bool {
        for index in items.indices {
            if items[index].id == newItem.id {
                items[index] = newItem
                return true
            }
            if replaceRecursively(in: &items[index].dictVal, with: newItem) {
                return true
            }
        }
        return false
    }

    private func deleteRecursively(in items: inout [PlistItem], id: UUID) -> Bool {
        for index in items.indices {
            if items[index].id == id {
                items.removeAll { $0.id == id }
                return true
            }
            if deleteRecursively(in: &items[index].dictVal, id: id) {
                return true
            }
        }
        return false
    }
}
