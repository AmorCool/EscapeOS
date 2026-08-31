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

#endif /* SAP_UNICORN_H */
