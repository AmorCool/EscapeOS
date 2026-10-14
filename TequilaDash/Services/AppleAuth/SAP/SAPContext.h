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
//  注意： 与上面的 `SAPContext`（SAP 签名会话）**不共用**机器 ——
//     `storeagent` 是额外挂载的镜像，需要一个带它的新 SapMachine。
//
//  注意： v0.3.545：本类的**解密会话**部分（`-initWithAssetsURL:hardwareID:dpInfo:error:`
//     / `-decryptChunk:error:` / `-closeDecrypter`）在 Swift 侧**目前没有任何调用点**
//     —— 也就是说这部分还没真正接进下载链，只有下面的 kbsync 在用 storeagent。
//     留着是为了下一步接包解密；不要据此以为解密已经通了。
//
//  注意： v0.3.548 定案（前三版都在这里栽了，写清楚免得再踩）：
//
//     v0.3.544 / 545 / 546 连续三版 CI 都报同一条
//     `KBSyncProvider.swift: error: extra argument 'error' in call`。
//     真因**不是** `.h` 的出参类型写得不对 ——
//     是 Swift 侧调用时多传了一个 `error:` 实参。
//
//     ObjC 的 `NSError **` 出参在 Swift 侧会被 importer **改写进 `throws`**：
//       · 参数列表里**没有** `error` 这个 label 了；
//       · 返回类型包成 `Optional`，失败原因走抛错。
//     所以正确写法是：
//       `let blob = try SAPStoreAgentContext.generateKBSync(withAssetsURL:hardwareID:dsid:)`
//     **不带 error 实参、要带 try**。
//
//     判据：同文件的 `SAPContext` 一直是这么调的（`try signer.exchangeData(cert, version: 200)`），
//     从来没报错 —— 两个类用的是同一套 ObjC 出参约定，写法当然也一样。
//
//     ⇒ 出参类型**全文件统一用 `NSError **`**，不要加 `_Nullable * _Nullable`
//       （v0.3.545/546 试过，没用，还制造了 `.h` 与 `.mm` 不一致这个新问题）。
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

// ─────────────────────────────────────────────────────────────────────────────
//  kbsync 生成 —— `ent/download` 的请求凭据
//
//  对齐上游 ipatool `internal/sap/machine/kbsync.go` 的 `GenerateKBSync`。
//
//  注意： **与解密器不是同一条路径**：kbsync 不需要 `dpInfo`、也**不开解密会话**，
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
                                           error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
