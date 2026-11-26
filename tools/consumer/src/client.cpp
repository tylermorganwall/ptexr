#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>
#include "ptex/ptex_r.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <thread>
#include <vector>

extern "C" int c_client_validate(SEXP);

static SEXP runtime_test(SEXP handle, SEXP path) {
    const auto* api = ptex_api_from_R_v1(handle);
    if (c_client_validate(handle)) Rf_error("C consumer failed");
    // Check the alternative registered entry point resolves to the same ABI.
    using getter = const ptex_api_v1* (*)(uint32_t);
    auto get_api = reinterpret_cast<getter>(R_GetCCallable("ptexr", "ptex_get_api_v1"));
    if (get_api(1) != api || get_api(2) != nullptr) Rf_error("Registered ABI negotiation failed");
    ptex_cache* cache = nullptr;
    ptex_texture* texture = nullptr;
    ptex_error error{};
    if (api->cache_create(2, 1048576, 1, &cache, &error)) Rf_error("%s", error.message);
    if (api->texture_open(cache, CHAR(STRING_ELT(path, 0)), &texture, &error)) {
        api->cache_destroy(cache); Rf_error("%s", error.message);
    }
    api->cache_destroy(cache); // texture keeps its native cache alive
    int failures = 0;
    {
        std::atomic<int> errors{0};
        std::vector<std::thread> workers;
        // All threads sample one shared texture through the table. No R calls.
        try {
            for (int t = 0; t < 6; ++t) workers.emplace_back([&] {
                ptex_filter_v1 filter{PTEX_BSPLINE, 1, 0, 0};
                ptex_error err{};
                for (int i = 0; i < 10000; ++i) {
                    float out[3]{};
                    int face = i % 2;
                    int code = api->sample(texture, &filter, face, face ? 0.f : 1.f,
                        .5f, .25f, 0, 0, .25f, 0, 3, out, &err);
                    if (code || std::fabs(out[0] - .5f) > 1e-5f ||
                        std::fabs(out[1]) > 1e-5f || std::fabs(out[2] - .5f) > 1e-5f)
                        ++errors;
                }
            });
        } catch (...) { ++errors; }
        for (auto& worker : workers) worker.join();
        ptex_filter_v1 filter{PTEX_POINT, 0, 0, 0}; float out[3]{};
        if (api->sample(texture, &filter, -1, .5f, .5f, 0, 0, 0, 0, 0, 3, out, &error) != PTEX_INVALID)
            ++errors;
        if (!std::strlen(error.message)) ++errors;
        if (api->sample(texture, &filter, 0, .5f, .5f, 0, 0, 0, 0, 2, 2, out, &error) != PTEX_INVALID)
            ++errors;
        failures = errors.load();
    }
    api->texture_destroy(texture);
    if (failures) Rf_error("Runtime consumer had %d failures", failures);
    return Rf_ScalarInteger(60000);
}
extern "C" void attribute_visible R_init_ptexconsumer(DllInfo* dll) {
    const R_CallMethodDef methods[] = {
        {"C_runtime_test", (DL_FUNC)&runtime_test, 2}, {nullptr, nullptr, 0}
    };
    R_registerRoutines(dll, nullptr, methods, nullptr, nullptr);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
