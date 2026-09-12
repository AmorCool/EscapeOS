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
NS_ASSUME_NONNULL_END
