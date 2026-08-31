#ifndef SAP_UNICORN_H
#define SAP_UNICORN_H

#include <stdint.h>
#include <unicorn/unicorn.h>

// uc_query is declared with a fixed C signature in Unicorn's public API. Wrap it
// so the Go side passes an int query type and a uint64* result without contorting
// around the enum/size_t casts. On Unicorn 2.x the query type for the emulation
// timeout is UC_QUERY_TIMEOUT (4).
static inline uc_err sap_uc_query(uc_engine *engine, int type, uint64_t *out) {
	return uc_query(engine, (uc_query_type)type, (size_t *)out);
}

// uc_hook_add is VARIADIC in the Unicorn API:
//   uc_err uc_hook_add(uc_engine *uc, uc_hook *hh, int type, void *callback,
//                      void *user_data, ...);
// cgo CANNOT call variadic C functions — compiling hook.go against the raw
// uc_hook_add fails with:
//   cgo: internal/sap/unicorn/hook.go:84:13: unexpected type: ...
// Wrap it with the fixed-argument form used for UC_HOOK_CODE, whose variadic
// tail is exactly two uint64_t bounds (begin, end).
static inline uc_err sap_uc_hook_add(uc_engine *uc, uc_hook *hh, int type,
                                     void *callback, void *user_data,
                                     uint64_t begin, uint64_t end) {
	return uc_hook_add(uc, hh, type, callback, user_data, begin, end);
}

#endif /* SAP_UNICORN_H */
