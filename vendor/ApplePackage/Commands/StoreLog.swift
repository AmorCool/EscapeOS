//
//  StoreLog.swift
//  ApplePackage
//
//  v0.3.329：下载/购买链路的诊断统一出口。
//  原来用 `print` 只进 stdout（设备控制台），用户在「商店日志」页看不到 ——
//  排查时抓不到。这里统一写进 App 内日志（`LoginLogger`，分类 appStore），
//  用户能直接从界面复制出来。
//
import Foundation

func storeLog(_ message: String) {
    LoginLogger.shared.log("[商店] \(message)", category: .appStore)
}
