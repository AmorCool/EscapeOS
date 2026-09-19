//
//  EscDDIProbe.c
//  EscapeOS
//
//  只读 DDI 探针的 C 垫片实现（见 EscDDIProbe.h 说明）。
//
//  形状照抄 `EscBrowseApps.c`：**调用 + 遍历 + 序列化全在 C 层**，
//  Swift 侧只传句柄、拿回 bplist 字节。
//

#include "EscDDIProbe.h"
#include "idevice.h"

#include <stdlib.h>
#include <string.h>

/// 把 `IdeviceFfiError` 拼成 malloc 字符串（调用方 `free`）。
/// 失败返回 NULL（调用方按「没有更细的原因」处理）。
static char *esc_ddi_error_string(struct IdeviceFfiError *err, const char *fallback) {
    const char *msg = fallback;
    if (err != NULL && err->message != NULL) {
        msg = err->message;
    }
    if (msg == NULL) { return NULL; }
    size_t n = strlen(msg) + 1;
    char *out = (char *)malloc(n);
    if (out == NULL) { return NULL; }
    memcpy(out, msg, n);
    return out;
}

unsigned char *esc_ddi_copy_devices(struct AdapterHandle *adapter,
                                    struct RsdHandshakeHandle *handshake,
                                    unsigned int *out_len,
                                    char **out_err) {
    if (out_len != NULL) { *out_len = 0; }
    if (out_err != NULL) { *out_err = NULL; }

    if (adapter == NULL || handshake == NULL) {
        if (out_err != NULL) {
            *out_err = esc_ddi_error_string(NULL, "adapter / handshake 为空");
        }
        return NULL;
    }

    /* 1) 连 image_mounter —— 本垫片唯一一条服务连接 */
    struct ImageMounterHandle *mounter = NULL;
    struct IdeviceFfiError *err =
        image_mounter_connect_rsd(adapter, handshake, &mounter);
    if (err != NULL || mounter == NULL) {
        if (out_err != NULL) {
            *out_err = esc_ddi_error_string(err, "image_mounter_connect_rsd 失败");
        }
        if (err != NULL) { idevice_error_free(err); }
        return NULL;
    }

    /* 2) 取「已挂载开发者镜像」清单 */
    plist_t *devices = NULL;
    size_t count = 0;
    err = image_mounter_copy_devices(mounter, &devices, &count);

    /* 3) 立刻释放服务连接（探针铁律：一次只建一条，用完立刻 free） */
    image_mounter_free(mounter);

    if (err != NULL) {
        if (out_err != NULL) {
            *out_err = esc_ddi_error_string(err, "image_mounter_copy_devices 失败");
        }
        idevice_error_free(err);
        return NULL;
    }

    /* 4) 打包成单个 plist array：元素**所有权移入 root**，随 root 一起释放 */
    plist_t root = plist_new_array();
    for (size_t i = 0; i < count; i++) {
        plist_array_append_item(root, devices[i]);
    }

    /* 5) 外层指针数组的所有权说明（**如实写，不美化**）：
     *    Rust 侧用 `Box::leak(boxed_slice)` 交出这个数组
     *    （`rust/idevice-ffi/src/mobile_image_mounter.rs:172-173`），本库**没有**为这条
     *    来源提供释放函数：
     *      · `idevice_plist_array_free` 只 free 每个**元素**（`rust/idevice-ffi/src/lib.rs:469-476`）
     *        —— 而这里元素所有权已经移入 `root`，再调它 = **double free**，所以不能调；
     *      · `idevice_outer_slice_free` 的文档写死「只适用于 `idevice_usbmuxd_get_devices`」
     *        （`idevice.h:1054-1064`），拿它释放别的来源是**未验证用法**。
     *    ⇒ 外层数组（`count * sizeof(plist_t)` 字节）**故意泄漏**。
     *      一次性只读探针，可接受。
     *    （对照：`EscBrowseApps.c` 对 `installation_proxy_browse` 的同形数组调了
     *      `idevice_data_free`。那是另一条来源，**本垫片不照搬**。）
     */

    char *bin = NULL;
    uint32_t bin_len = 0;
    plist_to_bin(root, &bin, &bin_len);
    plist_free(root);
    if (bin == NULL) {
        if (out_err != NULL) {
            *out_err = esc_ddi_error_string(NULL, "plist_to_bin 失败");
        }
        return NULL;
    }

    if (out_len != NULL) { *out_len = bin_len; }
    return (unsigned char *)bin;
}
