#ifndef bad_query_h
#define bad_query_h

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group);

// Generalized escape: query `container_class` for `identifier`, then walk
// `levels` "../" back to the root before appending `path`.
int64_t bad_query_ex(char *path, bool create, uint64_t container_class,
                     char *identifier, bool is_group, int levels);

// Approach D fallback: use a system daemon's class-10 container (e.g.
// com.apple.lsd, InternalDaemon) as the traversal base on iOS 26 when the
// systemgroup and App Group routes both fail.
int64_t bad_query_internal_daemon(char *path, bool create);

char *bad_query_list(char *path, int64_t max_inode);
void bad_query_release(int64_t handle);

// Consume a sandbox extension token (e.g. issued by the LiveContainer host for
// the MobileGestalt cache container) directly in THIS process. Returns the
// extension handle (>= 0 on success) or a negative error code:
//   -2 token is NULL, -3 sandbox_extension_consume symbol missing.
// Used so EscapeOS itself (not just the LiveProcess parent) holds the grant,
// which is required for in-place writes inside LiveContainer on iOS 26.
int64_t mg_consume_token(const char *token);

// Issue a raw sandbox extension for `path` in THIS process and immediately
// consume it, returning the handle (>= 0) on success or a negative error:
//   -1 libsystem_sandbox.dylib missing, -2 issue_file symbol missing,
//   -3 issue_file returned NULL for both read-write and read classes
//      (platform/entitlement policy denied), -4 consume symbol missing,
//   -5 path is NULL.
// Used as the primary MobileGestalt write path inside LiveContainer on iOS 26:
// the host-issued-token handoff has proven unreliable, so we issue+consume
// in-process where it can be diagnosed from the guest's own (capturable) log.
int64_t mg_issue_and_consume(const char *path);

#endif /* bad_query_h */
