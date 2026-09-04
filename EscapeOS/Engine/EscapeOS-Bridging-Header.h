//
//  EscapeOS-Bridging-Header.h
//  EscapeOS
//
//  Exposes the bad_query primitive and the RPPairing tunnel context to Swift.
//

#ifndef EscapeOS_Bridging_Header_h
#define EscapeOS_Bridging_Header_h

#include "bad_query.h"
#include "zip_crypto.h"

// v0.3.8：JIT 探测——csops 读取自身代码签名标志。CS_DEBUGGED(0x10000000) 是
// 「调试器（StikDebug/debugserver）已附加并生效」的内核级判据，比 mmap MAP_JIT
// 探测准确（iOS 27 beta 实锤：mmap 成功但执行仍被 CODESIGNING Invalid Page 杀）。
#include <sys/types.h>
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#import "../Tunnel/TunnelContext.h"

// MHA branch: MCM integration layer (bad_query + MobileHouseArrest)
#import "MCM/MCMBridge.h"
#import "MCM/BQMCMIntegration.h"

// iOS 27 device-initiated wireless pairing host wrapper
#import "../Tunnel/WirelessPairing.h"

// IPA 侧载：Apple ID 登录 + 签名（isideload sign-only 路径）
#include "../Tunnel/sideload_auth.h"

// SAP 签名桥（纯软件 Unicorn 模拟 Apple CommerceKit，PR #525 移植）。
// libsap.a / sap.h 由 sapbridge/build-sap.sh 在编译前生成，位于 sapbridge/build/。
#include "sap.h"
#include "../Services/MachOLoader/uloader.h"

// 崩溃探针：把硬故障（SIGSEGV/BUS/ILL/FPE）的 信号/地址/PC 写入 fd 后重抛
void uloader_install_crash_probe(int fd);

// v0.3.122 开发证书（SideStore/AltSign 同款流程）
// 生成 RSA2048 私钥(PEM) + CSR(PEM)；输出 buffer 用 free() 释放
int zsign_gen_key_csr(char **csrPemOut, int *csrPemLen, char **keyPemOut, int *keyPemLen);
// 验证证书 PEM 与私钥 PEM 是否配对（v0.3.140）；1=配对 0=不配对/解析失败
int zsign_check_pair(const char *certPem, int certLen,
                     const char *keyPem, int keyLen);
// 真证书签名（cert/key 均为 PEM）；dbgPath = 诊断日志落盘路径（可为 NULL）
int zsign_sign_file_with_cert(const char *path, const char *bundleId,
                              const char *certPem, int certLen,
                              const char *keyPem, int keyLen,
                              const char *entXml, int entLen,
                              const char *dbgPath,
                              const char *teamId);
// v0.3.152 证书 serial 匹配（iOS 27 beta AMFI 要求库与进程签名证书同源）：
// 证书 PEM → serial hex；Mach-O 文件 CMS 叶子证书 → serial hex
int zsign_cert_serial(const char *certPem, int certLen,
                      char *outHex, int outHexLen);
int zsign_file_leaf_serial(const char *path, char *outHex, int outHexLen);
// v0.3.156 读 Mach-O 文件 CodeDirectory 的 identifier（主程序 vs dylib 对照）
int zsign_file_ident(const char *path, char *out, int outLen);
// v0.3.152 p12 导入：PKCS12_parse 提取 cert/key PEM；输出 buffer 用 free() 释放
int zsign_p12_extract(const char *p12Data, int p12Len, const char *password,
                      char **certPemOut, int *certPemLen,
                      char **keyPemOut, int *keyPemLen);

// ZSign ad-hoc 重签名（v0.3.101：LC/Nyxian 同款引擎，编进 App；对副本就地重签）
int zsign_adhoc_file(const char *path, const char *bundleId, const char *entXml, int entLen);


// 监督模式工具：通过私有 API 取已安装 App 图标（移植自 Lithium）
@interface UIImage (EscapeOSSupervised)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                                 format:(int)format
                                                  scale:(CGFloat)scale;
@end

// Lua 模块宿主（v0.3.95：Rust+mlua 解释器，编进 App 跟随签名；符号随 libidevice_ffi.a 提供）。
// 表达式求值/语句执行：结果写 outPath；返回 0=成功 -1=Lua 错误 -2=参数空。
int lua_host_eval(const char *code, const char *outPath);
int lua_host_exec(const char *code, const char *outPath);

// Lua 宿主原生 handler 注册（v0.3.102：WiFi 射频经 RSD 隧道 MCInstall SetWiFiPowerState）。
// Swift 实现阻塞执行，返回 0=成功；-1=失败。
void lua_host_set_wifi_power_fn(int (*fn)(int, char **errOut));
void lua_host_set_mcinstall_handles(void *adapter, void *handshake, const char *pairingPath);

#endif /* EscapeOS_Bridging_Header_h */
