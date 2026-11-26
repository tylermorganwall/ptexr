/* Copyright 2026 Tyler Morgan-Wall. BSD-3-Clause; see package LICENSE.
 * Pure C runtime protocol. No Ptex, STL, or R objects cross this interface.
 * Face, edge and channel indices are ZERO BASED. See runtime-api documentation.
 */
#ifndef R_PTEX_API_H
#define R_PTEX_API_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ptex_cache ptex_cache;
typedef struct ptex_texture ptex_texture;
enum ptex_status { PTEX_OK = 0, PTEX_INVALID = 1, PTEX_IO = 2,
                   PTEX_MEMORY = 3, PTEX_INTERNAL = 4 };
enum ptex_filter { PTEX_POINT = 0, PTEX_BILINEAR, PTEX_BOX, PTEX_GAUSSIAN,
                   PTEX_BICUBIC, PTEX_BSPLINE, PTEX_CATMULLROM, PTEX_MITCHELL };
/* Optional caller-owned error buffer. Every operation clears it first. */
typedef struct { char message[512]; } ptex_error;
typedef struct {
    int32_t mesh_type; /* 0: triangle, 1: quad */
    int32_t data_type; /* 0: uint8, 1: uint16, 2: half, 3: float */
    int32_t faces, channels, alpha_channel; /* -1: no alpha */
    int32_t u_border, v_border; /* 0: clamp, 1: black, 2: periodic */
} ptex_info_v1;
typedef struct {
    int32_t width, height;
    int32_t adjacent_faces[4]; /* -1: boundary */
    int32_t adjacent_edges[4];
    int32_t subface;
} ptex_face_v1;
typedef struct {
    uint64_t memory_used, peak_memory_used, files_open, peak_files_open;
    uint64_t files_accessed, file_reopens, block_reads;
} ptex_stats_v1;
typedef struct {
    int32_t filter, lerp, no_edge_blend;
    float sharpness; /* [0,1], relevant to general bicubic */
} ptex_filter_v1;
typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    const char* (*version)(void);
    int32_t (*cache_create)(int32_t max_files, uint64_t max_bytes,
                            int32_t premultiply, ptex_cache** out, ptex_error* error);
    void (*cache_destroy)(ptex_cache* cache);
    int32_t (*cache_stats)(ptex_cache* cache, ptex_stats_v1* out, ptex_error* error);
    int32_t (*texture_open)(ptex_cache* cache, const char* path,
                            ptex_texture** out, ptex_error* error);
    void (*texture_destroy)(ptex_texture* texture);
    int32_t (*texture_info)(ptex_texture* texture, ptex_info_v1* out, ptex_error* error);
    int32_t (*face_info)(ptex_texture* texture, int32_t face,
                         ptex_face_v1* out, ptex_error* error);
    /* Footprint parallelogram sides are (du1,dv1) and (du2,dv2).
     * result must have room for count floats. No implicit colour conversion.
     * Different threads may sample the same texture concurrently.
     */
    int32_t (*sample)(ptex_texture* texture, const ptex_filter_v1* options,
                      int32_t face, float u, float v,
                      float du1, float dv1, float du2, float dv2,
                      int32_t first_channel, int32_t count,
                      float* result, ptex_error* error);
} ptex_api_v1;

#ifdef __cplusplus
}
#endif
#endif
