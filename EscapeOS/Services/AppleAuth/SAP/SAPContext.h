#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns one interpreted SAP session. Call from a single actor, never the main thread.
@interface SAPContext : NSObject
- (nullable instancetype)initWithAssetsURL:(NSURL *)url hardwareID:(NSData *)hardwareID error:(NSError **)error;
@property(nonatomic, readonly) BOOL complete;
- (nullable NSData *)exchangeData:(NSData *)data version:(uint32_t)version error:(NSError **)error;
- (nullable NSData *)signData:(NSData *)data error:(NSError **)error;

/// 资产读取过程中的异常说明（例如侧载宿主重签导致长度与官方值不同）；正常时为空串。
/// 每次初始化前清空，供上层写日志。
+ (NSString *)assetNotes;

// ─────────────────────────────────────────────────────────────────────────────
//  SAPStoreAgentContext —— `ent/download` 的包解密器
//
//  上游 ipatool 用它解密 macOS / 某些 iOS 包（`internal/sap/machine/storeagent.go`）。
//  必须是**独立的一次性会话**：加载 `storeagent` 镜像 + 用 dpInfo 初始化，
//  然后按 0x8000 分块原地解密，最后 close。
//
//  ⚠️ 与上面的 `SAPContext`（SAP 签名会话）**不共用**机器 ——
//     `storeagent` 是额外挂载的镜像，需要一个带它的新 SapMachine。
// ─────────────────────────────────────────────────────────────────────────────
@interface SAPStoreAgentContext : NSObject
/// 用 `storeagent` 资产打开一个解密会话。
/// - Parameter storeAgentURL: 含 `storeagent` 文件的目录（与另外四个资产同目录）。
/// - Parameter hardwareID: 6 字节设备标识（与 SAP 会话同一个）。
/// - Parameter dpInfo: 下载响应 `sinfs[].dpInfo`；为空直接报错。
+ (nullable instancetype)decrypterWithAssetsURL:(NSURL *)storeAgentURL
                                     hardwareID:(NSData *)hardwareID
                                         dpInfo:(NSData *)dpInfo
                                          error:(NSError **)error;

/// 解密一段（≤ 0x8000 字节）。返回解密后的新 `NSData`；nil 表示失败（error 有值）。
- (nullable NSData *)decryptChunk:(NSData *)chunk error:(NSError **)error;

/// 关闭会话（幂等）。dealloc 时也会自动关闭。
- (void)closeDecrypter;
@end
NS_ASSUME_NONNULL_END
