import Foundation

/// Airlift 传输所需的**配对文件解析**.
///
/// 与 AirBeep 不同：AirBeep 自带 `PairingController`，在设备上跑 RPPairing host
/// 现生成配对文件；本仓**已有**配对文件基建（`TunnelContext` / `AFCService` 统一读写
/// `Documents/pairingFile.plist`，见 `AFCService.pairingPath`），故此处**只做路径解析与
/// 就绪判定**，不重复造配对流程（对齐本仓既有写法，避免两套配对来源互相打架）.
enum AirliftPairing {
    /// 配对文件路径 —— 与本仓 `AFCService` / `TunnelContext` 完全一致.
    static var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    /// 配对文件是否已导入且非空.
    ///
    /// airlift 需要真实配对内容（空文件会在握手中失败），故以**大小 > 0** 为就绪判据
    /// （与 AirBeep `accessBackend()` 的判据一致）.
    static var isReady: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: pairingPath)
        let size = attributes?[.size] as? Int ?? 0
        return size > 0
    }
}
