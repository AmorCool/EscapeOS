//
//  AssetCatalogIcon.h
//  EscapeOS
//
//  从编译后的资源目录（Assets.car）读应用图标，供「共享转换」取高清图标。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 从 `Assets.car` 取 `iconName` 的最大 rendition 并重编码为 PNG。
///
/// 现代 IPA 的 1024 图标只编在 `Assets.car` 里，散装 PNG 只是给老系统兜底的小图。
/// CoreUI 是私有框架，故用 dlopen + objc_msgSend 动态调用：任一步取不到
/// （CoreUI 不可用 / 无该名字 / 无图 / 初始化失败）都返回 nil —— 调用方据此
/// 原样回落散装 PNG，绝不因它让功能退化或崩溃。
NSData * _Nullable ESIconPNGDataFromAssetCatalog(NSURL *carURL, NSString *iconName);

NS_ASSUME_NONNULL_END
