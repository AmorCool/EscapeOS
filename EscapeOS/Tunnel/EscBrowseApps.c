//
//  EscBrowseApps.c
//  EscapeOS
//
//  v0.3.279：instproxy Browse 的 C 垫片实现（见 EscBrowseApps.h 说明）。
//

#include "EscBrowseApps.h"
#include "idevice.h"

#include <stdlib.h>

uint8_t *esc_browse_apps_bin(struct InstallationProxyClientHandle *ip,
                             char **attrs,
                             int attrs_count,
                             uint32_t *out_len) {
    if (out_len != NULL) { *out_len = 0; }
    if (ip == NULL) { return NULL; }

    /* options: {"ClientOptions": {"ReturnAttributes": [...]}, "ApplicationType": "Any"} */
    plist_t opts = plist_new_dict();
    plist_t client_opts = plist_new_dict();
    plist_t attrs_arr = plist_new_array();
    for (int i = 0; i < attrs_count; i++) {
        if (attrs == NULL || attrs[i] == NULL) { continue; }
        plist_array_append_item(attrs_arr, plist_new_string(attrs[i]));
    }
    plist_dict_set_item(client_opts, "ReturnAttributes", attrs_arr);
    plist_dict_set_item(opts, "ClientOptions", client_opts);
    plist_dict_set_item(opts, "ApplicationType", plist_new_string("Any"));

    plist_t *apps = NULL;
    size_t count = 0;
    struct IdeviceFfiError *err = installation_proxy_browse(ip, opts, &apps, &count);
    plist_free(opts);
    if (err != NULL) {
        idevice_error_free(err);
        return NULL;
    }

    /* 打包成单个 plist array（所有权移入 root，随 root 一起释放） */
    plist_t root = plist_new_array();
    for (size_t i = 0; i < count; i++) {
        plist_array_append_item(root, apps[i]);
    }
    if (apps != NULL) {
        idevice_data_free((uint8_t *)apps, (uintptr_t)(count * sizeof(plist_t)));
    }

    char *bin = NULL;
    uint32_t bin_len = 0;
    plist_to_bin(root, &bin, &bin_len);
    plist_free(root);
    if (bin == NULL) { return NULL; }

    if (out_len != NULL) { *out_len = bin_len; }
    return (uint8_t *)bin;
}
