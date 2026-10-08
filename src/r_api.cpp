#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>
#include <R_ext/Utils.h>
#include "provider.h"
#include <cmath>
#include <climits>

namespace {
void check(int status, const ptex_error& error) {
    if (status != PTEX_OK) Rf_error("%s", error.message);
}
void* handle(SEXP x, const char* tag, bool allow_closed = false) {
    if (TYPEOF(x) != EXTPTRSXP || R_ExternalPtrTag(x) != Rf_install(tag))
        Rf_error("Expected a %s handle", tag);
    void* p = R_ExternalPtrAddr(x);
    if (!p && !allow_closed) Rf_error("The %s handle is closed or was serialized", tag);
    return p;
}
void cache_finalizer(SEXP x) {
    ptex_provider_api()->cache_destroy(static_cast<ptex_cache*>(R_ExternalPtrAddr(x)));
    R_ClearExternalPtr(x);
}
void texture_finalizer(SEXP x) {
    ptex_provider_api()->texture_destroy(static_cast<ptex_texture*>(R_ExternalPtrAddr(x)));
    R_ClearExternalPtr(x);
}
SEXP pointer(const char* tag, SEXP owner, R_CFinalizer_t finalizer) {
    SEXP x = PROTECT(R_MakeExternalPtr(nullptr, Rf_install(tag), owner));
    if (finalizer) R_RegisterCFinalizerEx(x, finalizer, TRUE);
    SEXP cls = PROTECT(Rf_mkString(tag));
    Rf_setAttrib(x, R_ClassSymbol, cls);
    UNPROTECT(2);
    return x;
}
int integer(SEXP x, const char* name, int minimum = 0, int maximum = INT_MAX) {
    if (TYPEOF(x) != INTSXP || XLENGTH(x) != 1 || INTEGER(x)[0] < minimum || INTEGER(x)[0] > maximum)
        Rf_error("Invalid %s", name);
    return INTEGER(x)[0];
}
const char* path_string(SEXP path) {
    if (TYPEOF(path) != STRSXP || XLENGTH(path) != 1 || STRING_ELT(path, 0) == NA_STRING)
        Rf_error("Expected one file path");
    return Rf_translateCharUTF8(STRING_ELT(path, 0));
}
SEXP named_numbers(const char* const* names, const double* values, int n) {
    SEXP out = PROTECT(Rf_allocVector(REALSXP, n));
    SEXP labels = PROTECT(Rf_allocVector(STRSXP, n));
    for (int i = 0; i < n; ++i) {
        REAL(out)[i] = values[i]; SET_STRING_ELT(labels, i, Rf_mkChar(names[i]));
    }
    Rf_setAttrib(out, R_NamesSymbol, labels);
    UNPROTECT(2);
    return out;
}
SEXP api_handle(SEXP owner) {
    SEXP out = PROTECT(pointer("ptex.api.v1", owner, nullptr));
    R_SetExternalPtrAddr(out, const_cast<ptex_api_v1*>(ptex_provider_api()));
    UNPROTECT(1);
    return out;
}
SEXP version() { return Rf_mkString(ptex_provider_api()->version()); }
SEXP cache_create(SEXP files, SEXP bytes, SEXP premultiply, SEXP owner) {
    int nfiles = integer(files, "max_files", 1);
    int premul = integer(premultiply, "premultiply", 0, 1);
    if (TYPEOF(bytes) != REALSXP || XLENGTH(bytes) != 1 || !R_FINITE(REAL(bytes)[0]) ||
        REAL(bytes)[0] < 0 || REAL(bytes)[0] > 9007199254740991.0)
        Rf_error("Invalid cache byte budget");
    SEXP out = PROTECT(pointer("ptex.cache", owner, cache_finalizer));
    ptex_cache* cache = nullptr; ptex_error error{};
    check(ptex_provider_api()->cache_create(nfiles, uint64_t(REAL(bytes)[0]), premul, &cache, &error), error);
    R_SetExternalPtrAddr(out, cache);
    UNPROTECT(1);
    return out;
}
SEXP cache_stats(SEXP cache) {
    ptex_stats_v1 s{}; ptex_error error{};
    check(ptex_provider_api()->cache_stats(static_cast<ptex_cache*>(handle(cache, "ptex.cache")), &s, &error), error);
    const char* names[] = {"memory_used", "peak_memory_used", "files_open", "peak_files_open",
                           "files_accessed", "file_reopens", "block_reads"};
    double values[] = {double(s.memory_used), double(s.peak_memory_used), double(s.files_open),
        double(s.peak_files_open), double(s.files_accessed), double(s.file_reopens), double(s.block_reads)};
    return named_numbers(names, values, 7);
}
SEXP texture_open(SEXP path, SEXP cache) {
    auto c = static_cast<ptex_cache*>(handle(cache, "ptex.cache"));
    const char* filename = path_string(path);
    SEXP out = PROTECT(pointer("ptex.texture", cache, texture_finalizer));
    ptex_texture* texture = nullptr; ptex_error error{};
    check(ptex_provider_api()->texture_open(c, filename, &texture, &error), error);
    R_SetExternalPtrAddr(out, texture);
    UNPROTECT(1);
    return out;
}
SEXP close_handle(SEXP x) {
    if (TYPEOF(x) != EXTPTRSXP) Rf_error("Expected a Ptex cache or texture handle");
    if (R_ExternalPtrTag(x) == Rf_install("ptex.cache")) cache_finalizer(x);
    else if (R_ExternalPtrTag(x) == Rf_install("ptex.texture")) texture_finalizer(x);
    else Rf_error("Expected a Ptex cache or texture handle");
    return R_NilValue;
}
SEXP texture_info(SEXP texture) {
    auto t = static_cast<ptex_texture*>(handle(texture, "ptex.texture"));
    ptex_info_v1 s{}; ptex_error error{};
    check(ptex_provider_api()->texture_info(t, &s, &error), error);
    const char* names[] = {"mesh_type", "data_type", "faces", "channels", "alpha_channel", "u_border", "v_border"};
    double values[] = {double(s.mesh_type), double(s.data_type), double(s.faces), double(s.channels),
                       double(s.alpha_channel + 1), double(s.u_border), double(s.v_border)};
    return named_numbers(names, values, 7);
}
SEXP face_info(SEXP texture, SEXP face) {
    auto t = static_cast<ptex_texture*>(handle(texture, "ptex.texture"));
    int f = integer(face, "face", 1) - 1;
    ptex_face_v1 s{}; ptex_error error{};
    check(ptex_provider_api()->face_info(t, f, &s, &error), error);
    const char* names[] = {"width", "height", "face1", "face2", "face3", "face4",
                           "edge1", "edge2", "edge3", "edge4", "subface"};
    double values[11] = {double(s.width), double(s.height)};
    for (int e = 0; e < 4; ++e) {
        values[e + 2] = s.adjacent_faces[e] + 1;
        values[e + 6] = s.adjacent_edges[e] + 1;
    }
    values[10] = s.subface;
    return named_numbers(names, values, 11);
}
SEXP sample(SEXP texture, SEXP faces, SEXP uv, SEXP footprint, SEXP first, SEXP count,
            SEXP filter, SEXP lerp, SEXP sharpness, SEXP noedge) {
    auto t = static_cast<ptex_texture*>(handle(texture, "ptex.texture"));
    int channel = integer(first, "first_channel", 1) - 1;
    int channels = integer(count, "channels", 1);
    int kind = integer(filter, "filter", 0, 7);
    int miplerp = integer(lerp, "lerp", 0, 1), edge = integer(noedge, "no_edge_blend", 0, 1);
    if (TYPEOF(faces) != INTSXP || XLENGTH(faces) > INT_MAX || TYPEOF(uv) != REALSXP ||
        TYPEOF(footprint) != REALSXP || XLENGTH(uv) != 2 * XLENGTH(faces) ||
        XLENGTH(footprint) != 4 * XLENGTH(faces) || TYPEOF(sharpness) != REALSXP || XLENGTH(sharpness) != 1)
        Rf_error("Invalid sample arrays");
    int n = int(XLENGTH(faces));
    ptex_info_v1 info{}; ptex_error error{};
    check(ptex_provider_api()->texture_info(t, &info, &error), error);
    if (channel >= info.channels || channels > info.channels - channel) Rf_error("Channel range is outside the texture");
    SEXP out = PROTECT(Rf_allocMatrix(REALSXP, n, channels));
    float* buffer = reinterpret_cast<float*>(R_alloc(channels, sizeof(float)));
    ptex_filter_v1 opts{kind, miplerp, edge, float(REAL(sharpness)[0])};
    for (int i = 0; i < n; ++i) {
        if (INTEGER(faces)[i] == NA_INTEGER || INTEGER(faces)[i] < 1) Rf_error("Invalid face index");
        if (i % 4096 == 0) R_CheckUserInterrupt();
        check(ptex_provider_api()->sample(t, &opts, INTEGER(faces)[i] - 1,
            float(REAL(uv)[i]), float(REAL(uv)[i + n]),
            float(REAL(footprint)[i]), float(REAL(footprint)[i + n]),
            float(REAL(footprint)[i + 2 * n]), float(REAL(footprint)[i + 3 * n]),
            channel, channels, buffer, &error), error);
        for (int c = 0; c < channels; ++c) REAL(out)[i + R_xlen_t(n) * c] = buffer[c];
    }
    UNPROTECT(1);
    return out;
}
SEXP write_file(SEXP path, SEXP faces, SEXP mesh, SEXP alpha, SEXP adjacency, SEXP edges) {
    const char* filename = path_string(path);
    int mesh_type = integer(mesh, "mesh", 0, 1), alpha_channel = integer(alpha, "alpha_channel", 0) - 1;
    if (TYPEOF(faces) != VECSXP || XLENGTH(faces) < 1 || XLENGTH(faces) > INT_MAX ||
        TYPEOF(adjacency) != INTSXP || TYPEOF(edges) != INTSXP ||
        XLENGTH(adjacency) != 4 * XLENGTH(faces) || XLENGTH(edges) != 4 * XLENGTH(faces))
        Rf_error("Invalid faces or adjacency");
    int n = int(XLENGTH(faces)), channels = 0;
    auto info = reinterpret_cast<ptex_face_v1*>(R_alloc(n, sizeof(ptex_face_v1)));
    auto pixels = reinterpret_cast<const float**>(R_alloc(n, sizeof(float*)));
    for (int f = 0; f < n; ++f) {
        SEXP data = VECTOR_ELT(faces, f), dim = Rf_getAttrib(data, R_DimSymbol);
        if (TYPEOF(data) != REALSXP || TYPEOF(dim) != INTSXP || XLENGTH(dim) != 3)
            Rf_error("Each face must be a numeric [u, v, channel] array");
        int w = INTEGER(dim)[0], h = INTEGER(dim)[1], c = INTEGER(dim)[2];
        if (w < 1 || h < 1 || c < 1 || c > 64 || XLENGTH(data) != R_xlen_t(w) * h * c ||
            (f && c != channels)) Rf_error("Invalid or inconsistent face dimensions");
        channels = c;
        info[f] = {}; info[f].width = w; info[f].height = h;
        for (int e = 0; e < 4; ++e) {
            if (INTEGER(adjacency)[f + n * e] == NA_INTEGER || INTEGER(edges)[f + n * e] == NA_INTEGER)
                Rf_error("Missing adjacency entries");
            info[f].adjacent_faces[e] = INTEGER(adjacency)[f + n * e] - 1;
            info[f].adjacent_edges[e] = INTEGER(edges)[f + n * e] - 1;
        }
        float* buffer = reinterpret_cast<float*>(R_alloc(size_t(XLENGTH(data)), sizeof(float)));
        pixels[f] = buffer;
        R_xlen_t plane = R_xlen_t(w) * h;
        for (R_xlen_t p = 0; p < plane; ++p) {
            for (int ch = 0; ch < c; ++ch) {
                float value = float(REAL(data)[p + plane * ch]);
                if (!std::isfinite(value)) Rf_error("Face values must be finite and representable as floats");
                buffer[p * c + ch] = value;
            }
        }
        R_CheckUserInterrupt();
    }
    ptex_error error{};
    check(ptex_provider_write(filename, mesh_type, channels, alpha_channel, n, info, pixels, &error), error);
    return R_NilValue;
}
const ptex_api_v1* get_api_v1(uint32_t version) { return version == 1 ? ptex_provider_api() : nullptr; }
}

extern "C" void attribute_visible R_init_ptexr(DllInfo* dll) {
    const R_CallMethodDef methods[] = {
        {"C_ptex_api", (DL_FUNC)&api_handle, 1},
        {"C_ptex_version", (DL_FUNC)&version, 0},
        {"C_ptex_cache", (DL_FUNC)&cache_create, 4},
        {"C_ptex_cache_stats", (DL_FUNC)&cache_stats, 1},
        {"C_ptex_open", (DL_FUNC)&texture_open, 2},
        {"C_ptex_close", (DL_FUNC)&close_handle, 1},
        {"C_ptex_info", (DL_FUNC)&texture_info, 1},
        {"C_ptex_face_info", (DL_FUNC)&face_info, 2},
        {"C_ptex_sample", (DL_FUNC)&sample, 10},
        {"C_ptex_write", (DL_FUNC)&write_file, 6},
        {nullptr, nullptr, 0}
    };
    R_registerRoutines(dll, nullptr, methods, nullptr, nullptr);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
    R_RegisterCCallable("ptexr", "ptex_get_api_v1", (DL_FUNC)&get_api_v1);
}
