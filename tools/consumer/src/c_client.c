/* Ensure the installed protocol can be compiled and called from plain C. */
#define R_NO_REMAP
#include "ptex/ptex_r.h"
int c_client_validate(SEXP handle) {
    const ptex_api_v1* api = ptex_api_from_R_v1(handle);
    ptex_cache* cache = NULL;
    ptex_error error;
    if (api->cache_create(2, 1048576, 1, &cache, &error)) return 1;
    api->cache_destroy(cache);
    return 0;
}
