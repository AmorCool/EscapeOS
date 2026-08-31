//
//  CommerceKitSpike.m
//  EscapeOS
//
//  P0 spike（待删）：在真机上验证 Apple 私有框架 CommerceKit 的 CKSigningSession
//  能否被本 App（LiveContainer 访客沙盒）调用并产出 SAP 签名。
//  逻辑逐行对齐 ipatool-sapfix 的 pkg/mescal/signer_darwin.m（已获用户授权移植）。
//

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// CKSigningSession 是 CommerceKit 私有类；用协议声明其方法签名以满足编译器，
// 运行时通过 NSClassFromString 取得真实类（与 ipatool 做法一致）。
@protocol CKSigningSessionProto <NSObject>
- (instancetype)initWithStoreClient:(id)storeClient;
- (void)openSessionWithCompletionHandler:(void (^)(void))completionHandler;
- (NSData *)signData:(NSData *)data error:(NSError **)error;
- (void)closeSession;
- (BOOL)isSessionOpen;
@end

static void *commerceKitHandle;
static char commerceKitLoadError[512];

static void loadCommerceKit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        commerceKitHandle = dlopen(
            "/System/Library/PrivateFrameworks/CommerceKit.framework/CommerceKit",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (commerceKitHandle == NULL) {
            const char *message = dlerror();
            snprintf(
                commerceKitLoadError,
                sizeof(commerceKitLoadError),
                "%s",
                message != NULL ? message : "failed to load CommerceKit"
            );
        }
    });
}

// 与 ipatool 的 int ipatool_mescal_sign(...) 签名一致，仅改名。
int commercekit_sap_sign(
    const unsigned char *input,
    size_t inputLength,
    unsigned char **output,
    size_t *outputLength,
    char **errorMessage
) {
    if (output == NULL || outputLength == NULL) {
        if (errorMessage != NULL) *errorMessage = strdup("invalid SAP signing output parameters");
        return 2;
    }

    *output = NULL;
    *outputLength = 0;
    if (errorMessage != NULL) *errorMessage = NULL;

    @autoreleasepool {
        loadCommerceKit();
        if (commerceKitHandle == NULL) {
            if (errorMessage != NULL) *errorMessage = strdup(commerceKitLoadError);
            return 1;
        }

        Class signingSessionClass = NSClassFromString(@"CKSigningSession");
        if (signingSessionClass == Nil) {
            if (errorMessage != NULL) *errorMessage = strdup("CKSigningSession is missing from CommerceKit");
            return 1;
        }

        id<CKSigningSessionProto> session = [(id<CKSigningSessionProto>)[signingSessionClass alloc] initWithStoreClient:nil];
        if (session == nil) {
            if (errorMessage != NULL) *errorMessage = strdup("CommerceKit could not create a SAP signing session");
            return 2;
        }

        dispatch_semaphore_t opened = dispatch_semaphore_create(0);
        [session openSessionWithCompletionHandler:^{
            dispatch_semaphore_signal(opened);
        }];

        long waitResult = dispatch_semaphore_wait(
            opened,
            dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)
        );
        if (waitResult != 0) {
            [session closeSession];
            if (errorMessage != NULL) *errorMessage = strdup("timed out opening the Apple SAP signing session");
            return 2;
        }

        if ([session respondsToSelector:@selector(isSessionOpen)] && ![session isSessionOpen]) {
            [session closeSession];
            if (errorMessage != NULL) *errorMessage = strdup("Apple SAP signing session did not open");
            return 2;
        }

        NSData *data = [NSData dataWithBytes:input length:inputLength];
        NSError *signingError = nil;
        NSData *signature = [session signData:data error:&signingError];
        [session closeSession];

        if (signature == nil) {
            if (errorMessage != NULL) {
                const char *message = signingError.localizedDescription.UTF8String;
                *errorMessage = strdup(message != NULL ? message : "CommerceKit could not sign the Apple action");
            }
            return 2;
        }

        NSUInteger signatureLength = signature.length;
        unsigned char *signatureCopy = malloc(signatureLength);
        if (signatureCopy == NULL) {
            if (errorMessage != NULL) *errorMessage = strdup("failed to allocate memory for the SAP signature");
            return 2;
        }

        [signature getBytes:signatureCopy length:signatureLength];

        *output = signatureCopy;
        *outputLength = signatureLength;
        return 0;
    }
}
