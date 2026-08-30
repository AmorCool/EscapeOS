import Foundation

/// App Store 账户的本地存储（凭据只写在本机 Documents，不上传）。
///
/// 与 EscapeOS 侧载用的 Apple ID 凭据是**两套独立命名空间**——
/// 侧载走开发者签名服务，这里走 App Store 下载，互不影响。
final class AppStoreDownloadStore {

    static let shared = AppStoreDownloadStore()
    private init() {}

    /// 下载目录（Documents/AppStoreDownloads，文件 App 可见）。
    var downloadsDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appstore_accounts.json")
    }

    private(set) var accounts: [Account] = []

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Account].self, from: data) else {
            accounts = []
            return
        }
        accounts = list
    }

    func add(_ account: Account) {
        load()
        accounts.removeAll { $0.email == account.email }
        accounts.append(account)
        save()
    }

    func remove(_ email: String) {
        load()
        accounts.removeAll { $0.email == email }
        save()
    }

    func account(for email: String) -> Account? {
        if accounts.isEmpty { load() }
        return accounts.first { $0.email == email }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
