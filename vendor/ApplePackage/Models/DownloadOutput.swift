//
//  DownloadOutput.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import Foundation

public struct DownloadOutput: Codable, Hashable, Equatable, Sendable {
    public var downloadURL: String
    public var sinfs: [Sinf]
    public var bundleShortVersionString: String
    public var bundleVersion: String

    public init(
        downloadURL: String,
        sinfs: [Sinf],
        bundleShortVersionString: String,
        bundleVersion: String
    ) {
        self.downloadURL = downloadURL
        self.sinfs = sinfs
        self.bundleShortVersionString = bundleShortVersionString
        self.bundleVersion = bundleVersion
    }
}
