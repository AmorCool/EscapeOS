//
//  EscCDProbe.c
//  EscapeOS
//
//  只读诊断探针的 C 垫片实现（见 EscCDProbe.h 说明）。
//
//  形状照抄 `EscDDIProbe.c` / `EscBrowseApps.c`：
//  **调用 + 遍历 + 拼字符串全在 C 层**，Swift 侧只传标量、拿回文本。
//
//  ⚠️ 本文件**刻意只用 `//` 行注释**，不用跨行 `/* */` 块注释 ——
//     仓库自检脚本 `_tools_paren_scan.py` 的 C 模式剥块注释时**不保留换行**，
//     跨行块注释会让它的行号错位、报出假的「深度变负」。单行注释没有这个问题。
//

#include "EscCDProbe.h"
#include "idevice.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

// MARK: - 可增长文本缓冲（报告本体）

typedef struct {
    char  *data;
    size_t len;
    size_t cap;
    int    oom;   // 分配失败置位；此后不再追加，最后统一报错
} EscTextBuf;

static void esc_text_reserve(EscTextBuf *b, size_t extra) {
    if (b->oom) { return; }
    if (b->len + extra + 1 <= b->cap) { return; }
    size_t cap = b->cap ? b->cap : 1024;
    while (cap < b->len + extra + 1) { cap *= 2; }
    char *grown = (char *)realloc(b->data, cap);
    if (grown == NULL) { b->oom = 1; return; }
    b->data = grown;
    b->cap = cap;
}

static void esc_text_puts(EscTextBuf *b, const char *s) {
    if (s == NULL) { s = "(null)"; }
    size_t n = strlen(s);
    esc_text_reserve(b, n);
    if (b->oom) { return; }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void esc_text_printf(EscTextBuf *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char stack[1024];
    int n = vsnprintf(stack, sizeof(stack), fmt, ap);
    va_end(ap);
    if (n < 0) { return; }
    if ((size_t)n < sizeof(stack)) { esc_text_puts(b, stack); return; }
    char *heap = (char *)malloc((size_t)n + 1);
    if (heap == NULL) { b->oom = 1; return; }
    va_start(ap, fmt);
    vsnprintf(heap, (size_t)n + 1, fmt, ap);
    va_end(ap);
    esc_text_puts(b, heap);
    free(heap);
}

// MARK: - 错误原文（**如实记录，不美化**）

static char *esc_cd_error_string(const char *fallback) {
    if (fallback == NULL) { return NULL; }
    size_t n = strlen(fallback) + 1;
    char *out = (char *)malloc(n);
    if (out == NULL) { return NULL; }
    memcpy(out, fallback, n);
    return out;
}

// 把 `IdeviceFfiError` 的 code + message 原样写进报告（不是写进 out_err）。
static void esc_cd_note_error(EscTextBuf *b, const char *label, struct IdeviceFfiError *err) {
    if (err != NULL) {
        esc_text_printf(b, "  %s：code=%d sub_code=%d message=%s\n",
                        label, (int)err->code, (int)err->sub_code,
                        err->message != NULL ? err->message : "(null)");
    } else {
        esc_text_printf(b, "  %s：（调用未返回错误对象）\n", label);
    }
}

// 收尾：把缓冲交给调用方（调用方 free）。分配失败 ⇒ 返回 NULL + out_err。
static unsigned char *esc_text_finish(EscTextBuf *b, unsigned int *out_len, char **out_err) {
    if (b->oom || b->data == NULL) {
        if (b->data != NULL) { free(b->data); }
        b->data = NULL;
        if (out_err != NULL) {
            *out_err = esc_cd_error_string("报告缓冲分配失败（内存不足）");
        }
        return NULL;
    }
    if (out_len != NULL) { *out_len = (unsigned int)b->len; }
    return (unsigned char *)b->data;
}

// MARK: - 探针主体

unsigned char *esc_cd_probe_run(const char *pairing_path,
                                const char *device_ip,
                                uint16_t lockdown_port,
                                const char *label,
                                unsigned int *out_len,
                                char **out_err) {
    if (out_len != NULL) { *out_len = 0; }
    if (out_err != NULL) { *out_err = NULL; }

    EscTextBuf buf;
    memset(&buf, 0, sizeof(buf));

    if (pairing_path == NULL || device_ip == NULL || label == NULL) {
        if (out_err != NULL) {
            *out_err = esc_cd_error_string("pairing_path / device_ip / label 为空");
        }
        return NULL;
    }

    esc_text_puts(&buf, "--- 调用链（每一步失败即停止后续步骤，错误原文照抄）---\n");

    // [0] 前置：解析目标 IP。
    // 顺序说明：任务给的顺序是「先读配对文件、再构造 sockaddr」，但 `idevice_tcp_provider_new`
    // 会**消费**配对文件句柄，若在读完配对文件之后才发现 IP 非法，那个句柄就没人能再释放
    // （头文件明写 "consumed must never be used again"）。IP 解析是纯计算，提前到最前
    // 可以在失败路径上不留悬空句柄。报告里仍按调用顺序编号。
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(lockdown_port);
    esc_text_puts(&buf, "\n[0] 前置\n");
    esc_text_printf(&buf, "  · 目标 = %s:%u\n", device_ip, (unsigned)lockdown_port);
    esc_text_printf(&buf, "  · label = %s\n", label);
    esc_text_printf(&buf, "  · 配对文件 = %s\n", pairing_path);
    if (inet_pton(AF_INET, device_ip, &addr.sin_addr) != 1) {
        esc_text_printf(&buf, "  ❌ 目标 IP 非法（inet_pton 失败）：%s\n", device_ip);
        esc_text_puts(&buf, "\n结论：目标 IP 非法，探针终止（此时尚未读配对文件，无句柄泄漏）。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · IP 解析 OK\n");

    // [1] lockdown 配对文件（**不是** rp_pairing_file_read）
    esc_text_puts(&buf, "\n[1] idevice_pairing_file_read（lockdown 配对文件）\n");
    struct IdevicePairingFile *pairing = NULL;
    struct IdeviceFfiError *err = idevice_pairing_file_read(pairing_path, &pairing);
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ idevice_pairing_file_read 失败", err);
        idevice_error_free(err);
        esc_text_puts(&buf, "\n结论：配对文件读不出来，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (pairing == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空句柄（无错误对象）\n");
        esc_text_puts(&buf, "\n结论：配对文件句柄为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · OK\n");

    // [2] TCP provider —— ⚠️ 本调用**消费** pairing，此后永不触碰（不 free）
    esc_text_puts(&buf, "\n[2] idevice_tcp_provider_new（⚠️ 消费 pairing，此后不再 free 它）\n");
    struct IdeviceProviderHandle *provider = NULL;
    err = idevice_tcp_provider_new((const idevice_sockaddr *)&addr, pairing, label, &provider);
    pairing = NULL;   // 已被消费：置空以防后续误用（不是释放）
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ idevice_tcp_provider_new 失败", err);
        idevice_error_free(err);
        esc_text_puts(&buf, "\n结论：建 provider 失败（LocalDevVPN 未连接 / 配对文件与设备不匹配？），探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (provider == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空句柄（无错误对象）\n");
        esc_text_puts(&buf, "\n结论：provider 句柄为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · OK\n");

    // [3] CoreDeviceProxy
    esc_text_puts(&buf, "\n[3] core_device_proxy_connect\n");
    struct CoreDeviceProxyHandle *proxy = NULL;
    err = core_device_proxy_connect(provider, &proxy);
    // provider 不参与 proxy 的生命周期（头文件未写消费），**成功失败都立刻释放**，避免泄漏。
    idevice_provider_free(provider);
    provider = NULL;
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ core_device_proxy_connect 失败", err);
        idevice_error_free(err);
        esc_text_puts(&buf, "\n结论：连不上 CoreDeviceProxy，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (proxy == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空句柄（无错误对象）\n");
        esc_text_puts(&buf, "\n结论：CoreDeviceProxy 句柄为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · OK（provider 已释放）\n");

    // [4] ★ 必须在下一次调用之前取端口（下一次会消费 proxy）
    esc_text_puts(&buf, "\n[4] core_device_proxy_get_server_rsd_port（★ 必须在 [5] 之前）\n");
    uint16_t rsdPort = 0;
    err = core_device_proxy_get_server_rsd_port(proxy, &rsdPort);
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ core_device_proxy_get_server_rsd_port 失败", err);
        idevice_error_free(err);
        core_device_proxy_free(proxy);
        esc_text_puts(&buf, "\n结论：拿不到隧道内 RSD 端口，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_printf(&buf, "  · server_rsd_port = %u\n", (unsigned)rsdPort);

    // [5] software TCP adapter —— ⚠️ 本调用**消费** proxy
    esc_text_puts(&buf, "\n[5] core_device_proxy_create_tcp_adapter（⚠️ 消费 proxy，此后不再 core_device_proxy_free）\n");
    struct AdapterHandle *cdAdapter = NULL;
    err = core_device_proxy_create_tcp_adapter(proxy, &cdAdapter);
    proxy = NULL;     // 已被消费：置空以防后续误用（不是释放）
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ core_device_proxy_create_tcp_adapter 失败", err);
        idevice_error_free(err);
        esc_text_puts(&buf, "\n结论：建 software tunnel adapter 失败，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (cdAdapter == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空句柄（无错误对象）\n");
        esc_text_puts(&buf, "\n结论：adapter 句柄为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · OK\n");

    // [6] 隧道内连 RSD 端口
    esc_text_puts(&buf, "\n[6] adapter_connect(cdAdapter, rsdPort) —— 隧道内新开一条流\n");
    struct ReadWriteOpaque *stream = NULL;
    err = adapter_connect(cdAdapter, rsdPort, &stream);
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ adapter_connect 失败", err);
        idevice_error_free(err);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：隧道内连不上 RSD 端口，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (stream == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空流（无错误对象）\n");
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：RSD 流为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · OK\n");

    // [7] ★ 第二个 RSD 握手 —— ⚠️ 本调用**消费** stream
    esc_text_puts(&buf, "\n[7] ★ rsd_handshake_new(stream) —— 第二个 RSD 握手（⚠️ 消费 stream）\n");
    struct RsdHandshakeHandle *cdHandshake = NULL;
    err = rsd_handshake_new(stream, &cdHandshake);
    stream = NULL;    // 已被消费：置空以防后续误用（不是释放）
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ rsd_handshake_new 失败", err);
        idevice_error_free(err);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：第二个 RSD 握手失败，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (cdHandshake == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空句柄（无错误对象）\n");
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：第二个握手句柄为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · OK\n");

    // [8] 服务表（只读内存结构，不建连）
    esc_text_puts(&buf, "\n[8] rsd_get_services（只读内存结构，不建连）\n");
    struct CRsdServiceArray *services = NULL;
    err = rsd_get_services(cdHandshake, &services);
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ rsd_get_services 失败", err);
        idevice_error_free(err);
        rsd_handshake_free(cdHandshake);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：取不到服务表，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (services == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空（无错误对象）\n");
        rsd_handshake_free(cdHandshake);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：服务表为空，探针终止。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }

    const char *kTargetService = "com.apple.coredevice.appservice";
    const char *kCoreDevicePrefix = "com.apple.coredevice";
    int targetFound = 0;
    size_t coreDeviceCount = 0;
    size_t total = services->count;

    esc_text_printf(&buf, "  · 服务总数 = %lu\n", (unsigned long)total);
    esc_text_puts(&buf, "  · 全表（name / port / remoteXPC）：\n");
    if (services->services == NULL) {
        esc_text_puts(&buf, "      ⚠️ services 指针为空（count 与指针不一致）\n");
    } else {
        for (size_t i = 0; i < total; i++) {
            const char *name = services->services[i].name;
            if (name == NULL) { name = "(null)"; }
            esc_text_printf(&buf, "      [%3lu] %-58s port=%-6u remoteXPC=%s\n",
                            (unsigned long)i,
                            name,
                            (unsigned)services->services[i].port,
                            services->services[i].uses_remote_xpc ? "true" : "false");
            if (strcmp(name, kTargetService) == 0) { targetFound = 1; }
            if (strncmp(name, kCoreDevicePrefix, strlen(kCoreDevicePrefix)) == 0) {
                coreDeviceCount++;
            }
        }
    }

    esc_text_puts(&buf, "\n[8.1] ★ 判据\n");
    esc_text_printf(&buf, "  · %s → %s\n", kTargetService,
                    targetFound ? "在表里 ✅" : "❌ 不在表里");
    esc_text_printf(&buf, "  · com.apple.coredevice.* 共 %lu 条\n", (unsigned long)coreDeviceCount);
    esc_text_puts(&buf, "  · 对照：RPPairing 隧道那条握手 19 次真机 dump 里 coredevice 整块 0 条\n");

    // [9] ★ 端到端：**即使服务不在表里也照跑** —— 失败原文本身就是证据
    esc_text_puts(&buf, "\n[9] ★ 端到端：app_service_connect_rsd(cdAdapter, cdHandshake)\n");
    if (!targetFound) {
        esc_text_puts(&buf, "  （服务不在表里，仍按任务要求继续尝试：预期失败，失败原文即证据）\n");
    }
    struct AppServiceHandle *appService = NULL;
    err = app_service_connect_rsd(cdAdapter, cdHandshake, &appService);
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ app_service_connect_rsd 失败", err);
        idevice_error_free(err);
        rsd_free_services(services);
        rsd_handshake_free(cdHandshake);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：连不上 app_service —— 进程管理那条路在这条链上仍然不通。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    if (appService == NULL) {
        esc_text_puts(&buf, "  ❌ 返回空句柄（无错误对象）\n");
        rsd_free_services(services);
        rsd_handshake_free(cdHandshake);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：app_service 句柄为空。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }
    esc_text_puts(&buf, "  · 连接成功 ✅\n");

    esc_text_puts(&buf, "\n[10] ★ 端到端：app_service_list_processes\n");
    struct ProcessTokenC *processes = NULL;
    uintptr_t pcount = 0;
    err = app_service_list_processes(appService, &processes, &pcount);
    if (err != NULL) {
        esc_cd_note_error(&buf, "❌ app_service_list_processes 失败", err);
        idevice_error_free(err);
        app_service_free(appService);
        rsd_free_services(services);
        rsd_handshake_free(cdHandshake);
        adapter_free(cdAdapter);
        esc_text_puts(&buf, "\n结论：app_service 连上了，但进程列表拿不到（失败原文见上）。\n");
        return esc_text_finish(&buf, out_len, out_err);
    }

    esc_text_printf(&buf, "  ★ 返回进程条数 = %lu\n", (unsigned long)pcount);
    if (processes != NULL) {
        // 全量可能上千条；只列前 50 条（条数本身已是判据，明细仅供核对）。
        uintptr_t shown = pcount < 50 ? pcount : 50;
        esc_text_printf(&buf, "  · 前 %lu 条（pid / executable_url）：\n", (unsigned long)shown);
        for (uintptr_t i = 0; i < shown; i++) {
            const char *url = processes[i].executable_url;
            esc_text_printf(&buf, "      pid=%-7u %s\n",
                            (unsigned)processes[i].pid,
                            url != NULL ? url : "(无 executable_url)");
        }
        if (pcount > shown) {
            esc_text_printf(&buf, "      …（其余 %lu 条省略）\n", (unsigned long)(pcount - shown));
        }
        app_service_free_process_list(processes, pcount);
    } else {
        esc_text_puts(&buf, "  · 进程数组指针为空（条数为 0）\n");
    }
    app_service_free(appService);

    esc_text_puts(&buf, "\n[11] 结论\n");
    if (targetFound && pcount > 0) {
        esc_text_puts(&buf, "  ⇒ **CoreDeviceProxy 隧道内的第二个 RSD 握手这条路是通的**：\n");
        esc_text_puts(&buf, "     服务表里有 com.apple.coredevice.appservice，且进程列表拿到非零条数。\n");
        esc_text_puts(&buf, "     ⇒ DeviceControlService.withAppService 应改走这条路（等 lead 决定）。\n");
    } else if (!targetFound) {
        esc_text_puts(&buf, "  ⇒ 这条握手**也没有**广播 com.apple.coredevice.appservice。\n");
        esc_text_puts(&buf, "     ⇒ 「换隧道」解释不了 ServiceNotFound，要转向「DDI 未挂」那条假设\n");
        esc_text_puts(&buf, "       （对照 SSH 命令 ddiprobe 的结果）。\n");
    } else {
        esc_text_puts(&buf, "  ⇒ 服务在表里，但进程列表条数为 0 —— 连接层通了、应用层没数据，需单独查。\n");
    }
    esc_text_puts(&buf, "  注：以上均为**设备侧一次性只读观测**，本机（Windows）无法验证真机行为。\n");

    // 收尾释放：顺序与 TunnelContext 一致（先握手、后 adapter）
    rsd_free_services(services);
    rsd_handshake_free(cdHandshake);
    adapter_free(cdAdapter);

    return esc_text_finish(&buf, out_len, out_err);
}
