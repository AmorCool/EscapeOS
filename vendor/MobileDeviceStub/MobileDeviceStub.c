// MobileDevice 桩 —— 只为让 iOS 上能 dlopen 移植过来的 macOS AirTrafficHost(arm64e)。
//
// ## 为什么需要它
// macOS 的 `AirTrafficHost.framework` 的 arm64e 切片里有 3 条 `LC_LOAD_DYLIB`：
//   ordinal 1: /System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/MobileDevice
//   ordinal 2: /System/Library/Frameworks/CoreFoundation.framework/...
//   ordinal 3: /usr/lib/libSystem.B.dylib
// `MobileDevice.framework` 是 **macOS 专有**（iOS 上没有这个框架），另外两条 iOS 都有。
// 我们把 ordinal 1 的路径原地改写成
// `@executable_path/Frameworks/libMobileDeviceStub.dylib`（见 `_tmp_fw_port.py`），
// 于是 dyld 会来这里找下面这 17 个符号。
//
// ## 这 17 个符号是怎么来的（不是猜的）
// 由 `_tmp_fw_port.py` 解析 AirTrafficHost 的 `LC_DYLD_CHAINED_FIXUPS` import 表得到：
//   imports_count = 138 = 17(ordinal1) + 45(ordinal2) + 76(ordinal3)
// 其中 ordinal 1 的 17 个与 `LC_SYMTAB` 里的 undefined 符号 **17/17 完全对上**。
// 清单落盘在 `_tmp_fw/mobiledevice-imports.txt`。
//
// ## 这些函数会不会被真的调用
// **实测证据表明不会**：Grappa 生成路径（`AirFairSyncGrappaCreate` → `CoreFP`/FairPlay）
// 与 MobileDevice 无关 —— 它在 GitHub macOS runner 上**无设备**也能成功生成 84 字节 Grappa。
// 这 17 个符号只是 dyld 在 dlopen 时必须能解析出来的**占位**（chained fixups 在加载期
// 就会把全部 import 绑定完，缺一个就 dlopen 失败）。
//
// ## 返回值：**故意返回失败码，而不是 0**
// 约定：`AMDevice*` 系列 **0 = 成功**。若将来真走到 `ATHostConnectionCreate` 那条路径，
// 这些函数会被调用；此时若返回 0，调用方会认为「连上了」，然后拿着我们返回的 **NULL 句柄**
// 继续往下走 → 直接崩。返回非 0 则让框架**认为失败并干净退出**（正是我们要的结果：
// Grappa 路径本来就不需要设备连接）。所以下面所有**返回错误码**的函数一律返回 `kStubFailure`。
//
// 唯一的例外是 `AMDeviceGetInterfaceType` —— 它不是错误码接口，见其定义处的说明。

#include <stdint.h>

// 非 0 即失败；具体数值无意义（没有任何调用方能靠它成功）。
// 不刻意去凑真实的 AMD 错误码（如 0xE8000000 段），因为我们也无法保证猜对，
// 而「非 0」这个语义已经足够让调用方走失败分支。
static const int kStubFailure = -1;

// 统一用一个不透明指针代表设备/连接句柄，ABI 上与真实的 AMDeviceRef 等价。
typedef void *AMDeviceRef;
typedef void *AMDServiceConnectionRef;
typedef void *AMDeviceNotificationRef;
typedef void *CFStringRef;
typedef void *CFDictionaryRef;
typedef void *CFTypeRef;

// ---- 返回错误码：一律非 0（见文件头「返回值」一节）----

int AMDeviceConnect(AMDeviceRef device) { (void)device; return kStubFailure; }
int AMDeviceDisconnect(AMDeviceRef device) { (void)device; return kStubFailure; }
int AMDeviceStartSession(AMDeviceRef device) { (void)device; return kStubFailure; }
int AMDeviceStopSession(AMDeviceRef device) { (void)device; return kStubFailure; }
int AMDeviceValidatePairing(AMDeviceRef device) { (void)device; return kStubFailure; }

// `AMDeviceGetInterfaceType` 单独说明：它是**取值接口**，不是错误码接口 ——
// 返回的是设备当前走哪种传输的**枚举**（USB / 网络 / …），语义上**没有「失败」这一档**，
// 所以这里**不返回 kStubFailure**：
//   · `-1` 不是合法枚举值，调用方若拿它查表 / 索引 / 走 switch 可能落到未定义分支；
//   · 返回 **0** 表示「未知 / 无接口」，调用方按「不是 USB、也不是网络」处理，
//     最坏是跳过 USB 专用分支 —— 不会崩，也不会误判成「已连接」。
int AMDeviceGetInterfaceType(AMDeviceRef device) { (void)device; return 0; }

int AMDeviceNotificationSubscribe(void *callback, unsigned int a, unsigned int b,
                                  void *context, AMDeviceNotificationRef *out) {
    (void)callback; (void)a; (void)b; (void)context;
    // out 也要置空：失败时调用方不应读到未初始化的句柄。
    if (out) { *out = 0; }
    return kStubFailure;
}
int AMDeviceNotificationUnsubscribe(AMDeviceNotificationRef ref) { (void)ref; return kStubFailure; }
int AMDSecureListenForNotifications(void *a, void *b, void *c, void *d) {
    (void)a; (void)b; (void)c; (void)d; return kStubFailure;
}
int AMDSecureObserveNotification(void *a, void *b, void *c, void *d) {
    (void)a; (void)b; (void)c; (void)d; return kStubFailure;
}
int AMDSecureShutdownNotificationProxy(void *a) { (void)a; return kStubFailure; }

int AMDServiceConnectionInvalidate(AMDServiceConnectionRef connection) {
    (void)connection; return kStubFailure;
}
int AMDServiceConnectionReceive(AMDServiceConnectionRef connection, void *buffer,
                                unsigned int length) {
    (void)connection; (void)buffer; (void)length; return kStubFailure;
}
int AMDServiceConnectionSend(AMDServiceConnectionRef connection, const void *buffer,
                             unsigned int length) {
    (void)connection; (void)buffer; (void)length; return kStubFailure;
}
int AMDeviceSecureStartService(AMDeviceRef device, CFStringRef serviceName,
                               CFDictionaryRef userInfo, AMDServiceConnectionRef *out) {
    (void)device; (void)serviceName; (void)userInfo;
    if (out) { *out = 0; }
    return kStubFailure;
}

// ---- 返回指针：只能返回 NULL（没有别的「失败」表示法）----

CFStringRef AMDeviceCopyDeviceIdentifier(AMDeviceRef device) { (void)device; return 0; }
CFStringRef AMDCopyErrorText(int code) { (void)code; return 0; }
