/* Copyright 2026 Tyler Morgan-Wall. BSD-3-Clause; see package LICENSE. */
#ifndef R_PTEX_R_H
#define R_PTEX_R_H
#include <Rinternals.h>
#include "ptex_api.h"
/* Call only on R's main thread. Retain handle for the whole native session.
 * Explicit dyn.unload() while consumers/resources exist is not supported.
 */
static inline const ptex_api_v1* ptex_api_from_R_v1(SEXP handle) {
    const ptex_api_v1* api;
    if (TYPEOF(handle) != EXTPTRSXP ||
        R_ExternalPtrTag(handle) != Rf_install("ptex.api.v1"))
        Rf_error("Expected a ptexr::ptex_api() handle");
    api = (const ptex_api_v1*)R_ExternalPtrAddr(handle);
    if (!api || api->abi_version != 1 || api->struct_size < sizeof(ptex_api_v1))
        Rf_error("Incompatible or expired ptexr runtime API");
    return api;
}
#endif
