// iOS 27 device-initiated wireless pairing host — C interface.
// Implemented in rust/idevice-ffi/src/pairable_host_run.rs (jkcoxson/idevice, BSD-3).
#ifndef SI_PAIRING_H
#define SI_PAIRING_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Called once the TCP listener is bound so the caller can advertise the
// `_remotepairing-pairable-host._tcp` Bonjour service. The `txt_*` arrays and
// `service_id` point to C strings valid only for the duration of the call.
typedef void (*SiReadyCb)(void *ctx, const char *service_id, uint16_t port,
                          const char **txt_keys, const char **txt_vals, size_t txt_count);

// Called exactly once with the 6-digit setup PIN to display in the UI.
typedef void (*SiPinCb)(const char *pin, void *ctx);

typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} SiPairResult;

// Blocks the calling thread: binds a listener, calls `ready_cb` (advertise over
// Bonjour), waits for the device, drives pairing (invoking `pin_cb` with the
// setup PIN), and writes the resulting RpPairingFile to `out_path`.
// Returns 0 on success, 1 on error (see out->error), 2 if `out` is NULL.
int si_run_host(const char *bind_addr, uint16_t port,
                const char *name, const char *model,
                const char *out_path, const char *host_alt_irk_hex,
                SiReadyCb ready_cb, SiPinCb pin_cb, void *ctx,
                SiPairResult *out);

// Frees the heap strings inside a SiPairResult previously populated by si_run_host.
// The argument is `const` because Rust's `*mut` ABI matches a C `const *` and
// it lets callers pass `&result` from a nested Objective-C block (where the
// captured stack variable is implicitly const).
void si_result_free(const SiPairResult *r);

#ifdef __cplusplus
}
#endif

#endif /* SI_PAIRING_H */
