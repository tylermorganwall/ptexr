#ifndef R_PTEX_PROVIDER_H
#define R_PTEX_PROVIDER_H
#include <ptex/ptex_api.h>
const ptex_api_v1* ptex_provider_api();
/* Writer accepts interleaved u-fastest float data. Each face has its own size. */
int ptex_provider_write(const char* path, int mesh, int channels, int alpha,
                        int count, const ptex_face_v1* faces,
                        const float* const* pixels, ptex_error* error);
#endif
