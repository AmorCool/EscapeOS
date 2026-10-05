//
//  SignatureInjector.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import Foundation

public enum SignatureInjector {
    public static func inject(
        sinfs: [Sinf],
        into packagePath: String
    ) async throws {
        let archive = try ApplePackageArchive(url: URL(fileURLWithPath: packagePath), accessMode: .update)

        let bundleName = try readBundleName(from: archive)

        if let manifest = try readManifestPlist(from: archive) {
            try injectFromManifest(manifest, into: archive, sinfs: sinfs, bundleName: bundleName)
        } else if let info = try readInfoPlist(from: archive) {
            try injectFromInfo(info, into: archive, sinfs: sinfs, bundleName: bundleName)
        } else {
            try ensureFailed("could not read manifest or info plist")
        }
        // EscapeSpace 适配：shim 的追加条目在 flush 时统一落盘（重写中央目录）。
        try archive.flush()
    }

    private static func readBundleName(from archive: ApplePackageArchive) throws -> String {
        for entry in archive {
            if entry.path.contains(".app/Info.plist"), !entry.path.contains("/Watch/") {
                let components = entry.path.split(separator: "/")
                if components.count >= 2 {
                    let appName = components[components.count - 2]
                    return String(appName.replacingOccurrences(of: ".app", with: ""))
                }
            }
        }
        try ensureFailed("could not read bundle name")
    }

    private static func readManifestPlist(from archive: ApplePackageArchive) throws -> PackageManifest? {
        for entry in archive {
            if entry.path.hasSuffix(".app/SC_Info/Manifest.plist") {
                var data = Data()
                _ = try archive.extract(entry, consumer: { data.append($0) })
                let manifest = try PropertyListDecoder().decode(PackageManifest.self, from: data)
                return manifest
            }
        }
        return nil
    }

    private static func readInfoPlist(from archive: ApplePackageArchive) throws -> PackageInfo? {
        for entry in archive {
            if entry.path.contains(".app/Info.plist") {
                var data = Data()
                _ = try archive.extract(entry, consumer: { data.append($0) })
                let info = try PropertyListDecoder().decode(PackageInfo.self, from: data)
                return info
            }
        }
        return nil
    }

    private static func injectFromManifest(
        _ manifest: PackageManifest,
        into archive: ApplePackageArchive,
        sinfs: [Sinf],
        bundleName: String
    ) throws {
        // ⚠️ 这里**有意不做**路径校验（不判 `..`/绝对路径/封存路径），不是遗漏 —— 说明如下，
        // 以免后来者按「Engine 侧有校验、这里没有」误判为漏洞：
        //
        // · 本方法只走 **AppleID 正版下载通道**（唯一调用点：
        //   `AppStoreLocalInstallService.downloadAndInstall`）。它读的 `Manifest.plist` 来自
        //   **刚从 Apple CDN 下载的那个 IPA 自带**，不是用户/第三方可提供的输入。
        // · 「下载地址必须落在 Apple 自有域」这条前提由上游**强制**（v0.3.571：
        //   `AppStoreInstallService.downloadIPA(hostPolicy:)` 对初始 URL 与每次重定向都查
        //   `StoreAuthenticationProtocol.isAppleHost`）。该前提一旦不成立，本方法的输入就不可信。
        // · 真正处理**不可信输入**（用户导入 / 免登录源包）的是 Engine 侧
        //   `IPADownloadCenter.collectSinfTargets`，那里有完整的 ZIP-slip 校验 + 封存三判据 + 写后复读。
        // · 另注：`archive[fullPath] != nil` 的存在性检查顺带挡住了「覆盖已存在条目」
        //   （例如 `SC_Info/Manifest.plist`）；但它**看不到本轮已追加的条目**，故不防重名。
        //
        // ⇒ 若将来出现「把非 Apple 来源的 IPA 送进本方法」的新入口，**必须先补路径校验**，
        //    否则此处会成为无校验的写入原语。
        for (index, sinfPath) in manifest.sinfPaths.enumerated() {
            guard index < sinfs.count else { continue }
            let sinf = sinfs[index]
            let fullPath = "Payload/\(bundleName).app/\(sinfPath)"
            if archive[fullPath] != nil {
                try ensureFailed("sinf file already exists: \(fullPath)")
            }
            try archive.addEntry(with: fullPath, type: .file, uncompressedSize: Int64(sinf.sinf.count), compressionMethod: .deflate, provider: { (position: Int64, size: Int) -> Data in
                let start = sinf.sinf.startIndex.advanced(by: Int(position))
                let end = start.advanced(by: size)
                return sinf.sinf.subdata(in: start ..< end)
            })
        }
    }

    private static func injectFromInfo(
        _ info: PackageInfo,
        into archive: ApplePackageArchive,
        sinfs: [Sinf],
        bundleName: String
    ) throws {
        guard let sinf = sinfs.first else { return }
        let sinfPath = "Payload/\(bundleName).app/SC_Info/\(info.bundleExecutable).sinf"
        if archive[sinfPath] != nil {
            try ensureFailed("sinf file already exists: \(sinfPath)")
        }
        try archive.addEntry(with: sinfPath, type: .file, uncompressedSize: Int64(sinf.sinf.count), compressionMethod: .deflate, provider: { (position: Int64, size: Int) -> Data in
            let start = sinf.sinf.startIndex.advanced(by: Int(position))
            let end = start.advanced(by: size)
            return sinf.sinf.subdata(in: start ..< end)
        })
    }
}

private struct PackageManifest: Decodable {
    let sinfPaths: [String]

    enum CodingKeys: String, CodingKey {
        case sinfPaths = "SinfPaths"
    }
}

private struct PackageInfo: Decodable {
    let bundleExecutable: String

    enum CodingKeys: String, CodingKey {
        case bundleExecutable = "CFBundleExecutable"
    }
}
