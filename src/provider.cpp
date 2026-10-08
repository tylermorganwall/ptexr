#include "provider.h"
#include "vendor/ptex/Ptexture.h"
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
// No R API calls or exceptions leave the native runtime boundary. In particular,
// an I/O error on a renderer worker must never invoke Rf_error or R's allocator.
thread_local ptex_error io_error{};
void copy_error(ptex_error* out, const char* message) noexcept {
    if (out) {
        std::strncpy(out->message, message, sizeof(out->message) - 1);
        out->message[sizeof(out->message) - 1] = '\0';
    }
}
template<class Operation> int32_t guarded(ptex_error* error, Operation operation) noexcept {
    if (error) error->message[0] = '\0';
    io_error.message[0] = '\0';
    try {
        operation();
        if (io_error.message[0]) {
            copy_error(error, io_error.message);
            return PTEX_IO;
        }
        return PTEX_OK;
    } catch (const std::invalid_argument& e) {
        copy_error(error, e.what()); return PTEX_INVALID;
    } catch (const std::bad_alloc&) {
        copy_error(error, "Ptex allocation failed"); return PTEX_MEMORY;
    } catch (const std::exception& e) {
        copy_error(error, e.what()); return PTEX_IO;
    } catch (...) {
        copy_error(error, "Unexpected Ptex failure"); return PTEX_INTERNAL;
    }
}
class ErrorHandler : public Ptex::PtexErrorHandler {
public:
    void reportError(const char* message) override { copy_error(&io_error, message); }
};
struct CacheState {
    ErrorHandler errors;
    Ptex::PtexCache* cache = nullptr;
    ~CacheState() { if (cache) cache->release(); }
};
}

struct ptex_cache { std::shared_ptr<CacheState> state; };
struct ptex_texture {
    // Retain the cache, not a pinned file reference. Files return to its LRU
    // after each lookup so a scene with many live materials can still evict data.
    std::shared_ptr<CacheState> state;
    std::string path;
    Ptex::PtexTexture::Info info;
};

namespace {
Ptex::PtexTexture* acquire_file(const ptex_texture* texture) {
    Ptex::String diagnostic;
    auto file = texture->state->cache->get(texture->path.c_str(), diagnostic);
    if (!file) throw std::runtime_error(diagnostic.empty() ?
        "Cannot open Ptex file (possibly a cached I/O failure)" : diagnostic.c_str());
    return file;
}
const char* version() { return "2.5.4"; }
int32_t cache_create(int32_t files, uint64_t bytes, int32_t premultiply,
                     ptex_cache** out, ptex_error* error) {
    if (out) *out = nullptr;
    return guarded(error, [&] {
        if (!out || files < 1 || bytes > SIZE_MAX || (premultiply != 0 && premultiply != 1))
            throw std::invalid_argument("Invalid cache limits or premultiply flag");
        auto holder = std::make_unique<ptex_cache>();
        holder->state = std::make_shared<CacheState>();
        holder->state->cache = Ptex::PtexCache::create(files, size_t(bytes), premultiply,
                                                     nullptr, &holder->state->errors);
        if (!holder->state->cache) throw std::bad_alloc();
        *out = holder.release();
    });
}
void cache_destroy(ptex_cache* cache) { delete cache; }
int32_t cache_stats(ptex_cache* cache, ptex_stats_v1* out, ptex_error* error) {
    return guarded(error, [&] {
        if (!cache || !out) throw std::invalid_argument("Null cache or output");
        Ptex::PtexCache::Stats s{};
        cache->state->cache->getStats(s);
        *out = {s.memUsed, s.peakMemUsed, s.filesOpen, s.peakFilesOpen,
                s.filesAccessed, s.fileReopens, s.blockReads};
    });
}
int32_t texture_open(ptex_cache* cache, const char* path, ptex_texture** out, ptex_error* error) {
    if (out) *out = nullptr;
    return guarded(error, [&] {
        if (!cache || !path || !*path || !out) throw std::invalid_argument("Invalid texture open arguments");
        auto holder = std::make_unique<ptex_texture>();
        holder->state = cache->state;
        holder->path = path;
        Ptex::PtexPtr<Ptex::PtexTexture> file(acquire_file(holder.get()));
        // A failed file must not escape as a usable handle.
        if (io_error.message[0]) throw std::runtime_error(io_error.message);
        holder->info = file->getInfo();
        *out = holder.release();
    });
}
void texture_destroy(ptex_texture* texture) { delete texture; }
int32_t texture_info(ptex_texture* texture, ptex_info_v1* out, ptex_error* error) {
    return guarded(error, [&] {
        if (!texture || !out) throw std::invalid_argument("Null texture or output");
        auto s = texture->info;
        *out = {s.meshType, s.dataType, s.numFaces, s.numChannels,
                s.alphaChannel, s.uBorderMode, s.vBorderMode};
    });
}
int32_t face_info(ptex_texture* texture, int32_t face, ptex_face_v1* out, ptex_error* error) {
    return guarded(error, [&] {
        if (!texture || !out || face < 0 || face >= texture->info.numFaces)
            throw std::invalid_argument("Face index is outside the texture");
        Ptex::PtexPtr<Ptex::PtexTexture> file(acquire_file(texture));
        const auto& s = file->getFaceInfo(face);
        *out = {};
        out->width = s.res.u(); out->height = s.res.v(); out->subface = s.isSubface();
        for (int edge = 0; edge < 4; ++edge) {
            out->adjacent_faces[edge] = s.adjface(edge);
            out->adjacent_edges[edge] = s.adjedge(edge);
        }
    });
}
int32_t sample(ptex_texture* texture, const ptex_filter_v1* opts, int32_t face,
               float u, float v, float du1, float dv1, float du2, float dv2,
               int32_t first, int32_t count, float* result, ptex_error* error) {
    return guarded(error, [&] {
        if (!texture || !opts || !result || face < 0 || face >= texture->info.numFaces ||
            first < 0 || count < 1 || first >= texture->info.numChannels ||
            count > texture->info.numChannels - first)
            throw std::invalid_argument("Invalid face, channel range or output buffer");
        if (!std::isfinite(u) || !std::isfinite(v) || u < 0 || u > 1 || v < 0 || v > 1 ||
            !std::isfinite(du1) || !std::isfinite(dv1) || !std::isfinite(du2) || !std::isfinite(dv2) ||
            std::fabs(du1) > 1 || std::fabs(dv1) > 1 || std::fabs(du2) > 1 || std::fabs(dv2) > 1 ||
            !std::isfinite(opts->sharpness) || opts->sharpness < 0 || opts->sharpness > 1 ||
            opts->filter < PTEX_POINT || opts->filter > PTEX_MITCHELL ||
            (opts->lerp != 0 && opts->lerp != 1) || (opts->no_edge_blend != 0 && opts->no_edge_blend != 1))
            throw std::invalid_argument("Invalid coordinates, footprint or filter options");
        if (texture->info.meshType == Ptex::mt_triangle && u + v > 1.000001f)
            throw std::invalid_argument("Triangle coordinates must satisfy u + v <= 1");
        Ptex::PtexFilter::Options options(static_cast<Ptex::PtexFilter::FilterType>(opts->filter),
                                          opts->lerp, opts->sharpness, opts->no_edge_blend);
        // The 2.5 static evaluator builds its mutable filter state per call.
        // Sharing legacy getFilter() instances across workers would race.
        Ptex::PtexPtr<Ptex::PtexTexture> file(acquire_file(texture));
        Ptex::PtexFilter::eval(file, options, result, first, count,
                              face, u, v, du1, dv1, du2, dv2);
    });
}
const ptex_api_v1 api = {1, sizeof(ptex_api_v1), version, cache_create, cache_destroy,
    cache_stats, texture_open, texture_destroy, texture_info, face_info, sample};
}
const ptex_api_v1* ptex_provider_api() { return &api; }

int ptex_provider_write(const char* path, int mesh, int channels, int alpha,
                        int count, const ptex_face_v1* faces,
                        const float* const* pixels, ptex_error* error) {
    return guarded(error, [&] {
        if (!path || !*path || mesh < 0 || mesh > 1 || channels < 1 || channels > 64 ||
            alpha < -1 || alpha >= channels || count < 1 || !faces || !pixels)
            throw std::invalid_argument("Invalid Ptex writer arguments");
        for (int f = 0; f < count; ++f) {
            const auto& info = faces[f];
            for (int n : {info.width, info.height}) {
                if (n < 1 || n > 32768 || (n & (n - 1)))
                    throw std::invalid_argument("Face dimensions must be powers of two, at most 32768");
            }
            if (!pixels[f] || (mesh == 0 && info.width != info.height))
                throw std::invalid_argument("Triangle faces must be square");
            const int edges = mesh == 0 ? 3 : 4;
            for (int e = 0; e < edges; ++e) {
                int other = info.adjacent_faces[e], edge = info.adjacent_edges[e];
                if (other < -1 || other >= count || edge < 0 || edge >= edges || other == f)
                    throw std::invalid_argument("Invalid face adjacency");
                if (other >= 0 && (faces[other].adjacent_faces[edge] != f ||
                                   faces[other].adjacent_edges[edge] != e))
                    throw std::invalid_argument("Face adjacency must be reciprocal");
            }
        }
        Ptex::String diagnostic;
        Ptex::PtexPtr<Ptex::PtexWriter> writer(Ptex::PtexWriter::open(path,
            static_cast<Ptex::MeshType>(mesh), Ptex::dt_float, channels, alpha, count, diagnostic));
        if (!writer) throw std::runtime_error(diagnostic.c_str());
        writer->setBorderModes(Ptex::m_clamp, Ptex::m_clamp);
        for (int f = 0; f < count; ++f) {
            int ul = 0, vl = 0;
            while ((1 << ul) < faces[f].width) ++ul;
            while ((1 << vl) < faces[f].height) ++vl;
            int adjacent[4], edges[4];
            for (int e = 0; e < 4; ++e) {
                adjacent[e] = faces[f].adjacent_faces[e]; edges[e] = faces[f].adjacent_edges[e];
            }
            Ptex::FaceInfo info(Ptex::Res(ul, vl), adjacent, edges);
            if (!writer->writeFace(f, info, pixels[f])) {
                writer->close(diagnostic);
                throw std::runtime_error(diagnostic.empty() ? "Ptex face write failed" : diagnostic.c_str());
            }
        }
        if (!writer->close(diagnostic)) throw std::runtime_error(diagnostic.c_str());
    });
}
