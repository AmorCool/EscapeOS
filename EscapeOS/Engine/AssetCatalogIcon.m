//
//  AssetCatalogIcon.m
//  EscapeOS
//
//  CoreUI（私有框架）动态调用：从 Assets.car 取应用图标的最大 rendition。
//
//  为什么用 dlopen + objc_msgSend 而非直接引用类符号：CoreUI 未链接，直接引用
//  `_OBJC_CLASS_$_CUICatalog` 会产生 Undefined symbols（与本仓 LSApplicationWorkspace 同坑）。
//  任何一步取不到都返回 nil，把不确定性封在回落里 —— 调用方照走散装 PNG。
//

#import "AssetCatalogIcon.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// objc_msgSend 在 arm64 上必须按精确原型强转，否则参数/返回值会被 ABI 截断。
// initWithURL:error: 的第二个参数是 NSError **（不是对象），单独一个原型。
typedef id (*ESCatalogInit)(id, SEL, id, NSError **);
typedef id (*ESCatalogImageWithName)(id, SEL, id);
typedef id (*ESCatalogImageWithNameScale)(id, SEL, id, double);
typedef CGImageRef (*ESNamedImageImage)(id, SEL);

NSData * _Nullable ESIconPNGDataFromAssetCatalog(NSURL *carURL, NSString *iconName)
{
    if (carURL == nil || iconName.length == 0) return nil;

    static Class catalogClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI",
                              RTLD_NOW | RTLD_LOCAL);
        if (handle == NULL) return;
        catalogClass = NSClassFromString(@"CUICatalog");
    });
    if (catalogClass == Nil) return nil;

    SEL initSel = NSSelectorFromString(@"initWithURL:error:");
    if (![catalogClass instancesRespondToSelector:initSel]) return nil;
    id catalog = [catalogClass alloc];
    catalog = ((ESCatalogInit)objc_msgSend)(catalog, initSel, carURL, NULL);
    if (catalog == nil) return nil;

    SEL scaleSel = NSSelectorFromString(@"imageWithName:scale:");
    SEL plainSel = NSSelectorFromString(@"imageWithName:");
    SEL imageSel = NSSelectorFromString(@"image");

    // 逐个 scale 取图，留像素最大的那一档（不同 iOS 上最大 rendition 落在哪档不定）。
    CGImageRef best = NULL;
    NSUInteger bestPixels = 0;
    for (NSNumber *scaleValue in @[@3.0, @2.0, @1.0]) {
        id named = nil;
        if ([catalog respondsToSelector:scaleSel]) {
            named = ((ESCatalogImageWithNameScale)objc_msgSend)(catalog, scaleSel,
                                                               iconName, scaleValue.doubleValue);
        }
        if (named == nil && [catalog respondsToSelector:plainSel]) {
            named = ((ESCatalogImageWithName)objc_msgSend)(catalog, plainSel, iconName);
        }
        if (named == nil || ![named respondsToSelector:imageSel]) continue;
        CGImageRef cg = ((ESNamedImageImage)objc_msgSend)(named, imageSel);
        if (cg == NULL) continue;
        NSUInteger pixels = (NSUInteger)CGImageGetWidth(cg) * (NSUInteger)CGImageGetHeight(cg);
        if (pixels > bestPixels) {
            if (best != NULL) CGImageRelease(best);
            best = CGImageRetain(cg);   // named 出作用域即释放，这里必须自己持一份。
            bestPixels = pixels;
        }
    }
    if (best == NULL) return nil;

    UIImage *image = [UIImage imageWithCGImage:best];
    CGImageRelease(best);
    return UIImagePNGRepresentation(image);
}
