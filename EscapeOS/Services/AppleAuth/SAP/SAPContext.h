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
@end

typedef NS_ENUM(NSInteger, SAPStoreAgentErrorCode) {
    /// 成功
    SAPStoreAgentErrorNone = 0,
    /// 资产缺失 / 长度或摘要与官方值不符
    SAPStoreAgentErrorAssets = 1,
    /// 参数不合法（hardwareID 不是 6 字节、dpInfo 为空、DSID 为 0 …）
    SAPStoreAgentErrorInvalidArgument = 2,
    /// 解释执行 `storeagent` 失败
    SAPStoreAgentErrorMachine = 3,
    /// 生成结果为空
    SAPStoreAgentErrorEmptyResult = 4,
};

// ─────────────────────────────────────────────────────────────────────────────
//  SAPStoreAgentContext —— `ent/download` 的包解密器
//
//  上游 ipatool 用它解密 macOS / 某些 iOS 包（`internal/sap/machine/storeagent.go`）。
//  必须是**独立的一次性会话**：加载 `storeagent` 镜像 + 用 dpInfo 初始化，
//  然后按 0x8000 分块原地解密，最后 close。
//
//  ⚠️ 与上面的 `SAPContext`（SAP 签名会话）**不共用**机器 ——
//     `storeagent` 是额外挂载的镜像，需要一个带它的新 SapMachine。
//
//  ⚠️ v0.3.545：本类的**解密会话**部分（`-initWithAssetsURL:hardwareID:dpInfo:error:`
//     / `-decryptChunk:error:` / `-closeDecrypter`）在 Swift 侧**目前没有任何调用点**
//     —— 也就是说这部分还没真正接进下载链，只有下面的 kbsync 在用 storeagent。
//     留着是为了下一步接包解密；不要据此以为解密已经通了。
//
//  ⚠️ v0.3.545（CI 修复）：**这里的报错一律用 `NSError **`，不用 `NSError **` 的
//     `nullable` 修饰** —— v0.3.544 的 CI 在
//     `KBSyncProvider.swift:70` 报 `error: extra argument 'error' in call`。
//     成因是 `NS_ASSUME_NONNULL_BEGIN` 让出参带上非空假设，Swift importer 对
//     `NSError **` 的形状判定不一致（同一个文件里 `SAPContext` 的方法却没事）。
//     统一改成返回 `NSError * _Nullable *`，并在 Swift 侧**不用 `try` 语法糖**
//     （见 `KBSyncProvider.generate`）—— 两处一起改才稳。
// ─────────────────────────────────────────────────────────────────────────────
@interface SAPStoreAgentContext : NSObject
/// 用 `storeagent` 资产打开一个解密会话。
/// - Parameter storeAgentURL: 含 `storeagent` 文件的目录（与另外四个资产同目录）。
/// - Parameter hardwareID: 6 字节设备标识（与 SAP 会话同一个）。
/// - Parameter dpInfo: 下载响应 `sinfs[].dpInfo`；为空直接报错。
+ (nullable instancetype)decrypterWithAssetsURL:(NSURL *)storeAgentURL
                                     hardwareID:(NSData *)hardwareID
                                         dpInfo:(NSData *)dpInfo
                                          error:(NSError * _Nullable * _Nullable)error;

/// 解密一段（≤ 0x8000 字节）。返回解密后的新 `NSData`；nil 表示失败（error 有值）。
- (nullable NSData *)decryptChunk:(NSData *)chunk error:(NSError * _Nullable * _Nullable)error;

/// 关闭会话（幂等）。dealloc 时也会自动关闭。
- (void)closeDecrypter;

// ─────────────────────────────────────────────────────────────────────────────
//  kbsync 生成 —— `ent/download` 的请求凭据
//
//  对齐上游 ipatool `internal/sap/machine/kbsync.go` 的 `GenerateKBSync`。
//
//  ⚠️ **与解密器不是同一条路径**：kbsync 不需要 `dpInfo`、也**不开解密会话**，
//     只要「带 storeagent 的机器 + hardwareID + DSID」就能算出来。
//     上游注释原话：
//       > creates the account and hardware bound FairPlay data required by the
//       > bag's ent/download endpoint, without opening a decryption session.
//
//  因此做成**类方法**（一次性调用，不持有对象）；内部会自己建一台
//  `CreateWithStoreAgent` 机器、算完即弃。
// ─────────────────────────────────────────────────────────────────────────────
/// 生成 `ent/download` 请求体里 `kbsync` 字段用的字节串。
/// - Parameter storeAgentURL: 含 `storeagent` 文件的目录（与另外四个资产同目录）。
/// - Parameter hardwareID: 6 字节设备标识（= guid 的十六进制解码，与 SAP 会话同一个）。
/// - Parameter dsid: 账号 DirectoryServicesIdentifier 的**数值**；为 0 直接报错（上游硬门）。
+ (nullable NSData *)generateKBSyncWithAssetsURL:(NSURL *)storeAgentURL
                                      hardwareID:(NSData *)hardwareID
                                            dsid:(uint64_t)dsid
                                           error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
