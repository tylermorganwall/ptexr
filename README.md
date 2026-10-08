
<!-- README.md is generated from README.Rmd. Please edit that file. -->

# ptexr: per-face textures for R and native renderers

`ptexr` lets you read, write, inspect, and sample Ptex textures from R.
Ptex stores a separate texture for each face of a polygon mesh, so you
can texture a model without creating a shared UV atlas. Samples use a
face ID and local coordinates, and filtering can blend across
neighbouring faces to reduce seams.

Use the package to create `.ptx` files from R arrays, inspect texture
and face information, and retrieve filtered texture values. It also
provides shared texture caches and a C interface so native renderers can
use the same texture service from C or C++.

Version 2.5.4-1 packages upstream Ptex 2.5.4 and links to the static
library provided by the CRAN package `libdeflate` (version 1.25-0 or
later). The suffix is the R packaging revision, following
glmheaders/openpbr.

Install from this directory:

``` r
install.packages("libdeflate")
install.packages(".", repos = NULL, type = "source")
```

Create a small texture, read it back, and sample its colour:

``` r
library(ptexr)
ptex_version()
```

    ## [1] "2.5.4"

``` r
# Write one quad face with a single RGB texel.
texture_file <- tempfile(fileext = ".ptx")
face <- array(c(0.9, 0.2, 0.05), dim = c(1, 1, 3))
ptex_write(texture_file, faces = list(face))

cache <- ptex_cache(max_memory = 256 * 1024^2)
texture <- ptex_open(texture_file, cache)
ptex_info(texture)
```

    ## $mesh_type
    ## [1] "quad"
    ## 
    ## $data_type
    ## [1] "float"
    ## 
    ## $faces
    ## [1] 1
    ## 
    ## $channels
    ## [1] 3
    ## 
    ## $alpha_channel
    ## [1] 0
    ## 
    ## $u_border
    ## [1] "clamp"
    ## 
    ## $v_border
    ## [1] "clamp"

``` r
ptex_face_info(texture, face = 1)
```

    ## $width
    ## [1] 1
    ## 
    ## $height
    ## [1] 1
    ## 
    ## $adjacent_faces
    ## [1] 0 0 0 0
    ## 
    ## $adjacent_edges
    ## [1] 1 1 1 1
    ## 
    ## $subface
    ## [1] FALSE

``` r
rgb <- ptex_sample(
  texture,
  face = 1,
  uv = c(.5, .5),
  footprint = c(.01, 0, 0, .01)
)
rgb
```

    ##      [,1] [,2] [,3]
    ## [1,]  0.9  0.2 0.05

``` r
ptex_close(texture)
ptex_close(cache)
unlink(texture_file)
```

`ptex_write()` creates real Ptex files from arrays and reciprocal
adjacency. Its help contains complete examples that need no external
assets.

## Runtime integration (ABI 1)

Ptex is compiled into one R package DLL using R’s toolchain. Compression
code is statically linked from the installed `libdeflate` R package,
which is needed when building `ptexr` from source. Building `libdeflate`
itself from source requires CMake. The resulting `ptexr` DLL contains
both implementations and does not require an external Ptex or libdeflate
DLL. `ptexr` does not build or install a static archive of its own.

The implementation lives in `ptexr.so` / `ptexr.dll`. Installed headers
expose a small C function table. No Ptex or libdeflate classes or
symbols are exposed across the binary boundary. Consumers need neither
libPtex nor libdeflate in `PKG_LIBS`, and no rpath is needed.

### Required dependency

Add these fields to your package’s `DESCRIPTION`:

``` text
Imports: ptexr
LinkingTo: ptexr
```

Obtain the API handle in R:

``` r
api <- ptexr::ptex_api()
```

Pass the handle to your registered native entry point. Include
`<ptex/ptex_r.h>` and call `ptex_api_from_R_v1(handle)` to access the
function table. `LinkingTo` supplies headers; consumers use the
implementation in the loaded `ptexr` DLL.

### Optional dependency

For an optional integration, such as rayimgui, add this field to
`DESCRIPTION`:

``` text
Suggests: ptexr
```

Copy the installed `ptex_api.h`, `ptex_r.h`, and their `LICENSE` from
`ptexr`’s `include/ptex/` directory into your package’s `src/ptex/`
directory. Your package can then build even when `ptexr` is absent. At
the R boundary, check availability before obtaining the handle:

``` r
if (!requireNamespace("ptexr", quietly = TRUE)) {
  stop("Install ptexr to use Ptex textures.")
}
api <- ptexr::ptex_api()
```

Pass the handle to your native code as above. The [consumer
fixture](dev/consumer) demonstrates this route in C and C++, including
concurrent sampling.

### Native code outline

The following outline assumes your native entry point receives `handle`
and the texture path and sampling coordinates. Check the status after
**every** fallible operation and handle errors before using its outputs
or continuing.

``` c
const ptex_api_v1* api = ptex_api_from_R_v1(handle);
ptex_cache* cache = NULL;
ptex_texture* texture = NULL;
ptex_error error;
int status = api->cache_create(100, 256ULL * 1024 * 1024, 1, &cache, &error);
// Check status after EVERY fallible operation.
status = api->texture_open(cache, absolute_path, &texture, &error);
ptex_filter_v1 filter = {PTEX_BSPLINE, 1, 0, 0};
float rgb[3];
status = api->sample(texture, &filter, face_id, u, v,
                     dudx, dvdx, dudy, dvdy, 0, 3, rgb, &error);
api->texture_destroy(texture);
api->cache_destroy(cache);
```

### Ownership and threading

Acquire and validate the API on R’s main thread. Retain the R handle for
the entire native session, for example as a protected field in a live
external pointer. All function-table operations are independent of the R
API. A cache and its textures may be shared by render workers. Sampling
uses Ptex 2.5’s reentrant static evaluator. Join workers before
destroying handles.

Each cache or texture handle is owned and destroyed exactly once; using
a destroyed raw pointer is invalid. `NULL` destruction is safe. Textures
internally retain the cache and filename, so releasing the caller’s
cache handle before its texture handles is safe. Each lookup acquires
and releases a file reference, permitting cache eviction even while
material handles live. Resource limits are soft targets; concurrent
lookups can temporarily pin data.

Exceptions are caught by the provider and reported as status codes plus
an optional caller-owned 512-byte error buffer. Worker errors never call
R, print to the console, or unwind into the consumer. Outputs are
invalid on failure. File contents must remain unchanged while cached.
Reopen through a new cache after a file has been rewritten. Read cache
statistics after workers join; upstream counters are not a synchronized
snapshot.

Do not explicitly call `dyn.unload()` on the provider while API tables,
textures, caches, or finalizers exist. The package intentionally has no
DLL unloading hook. Do not serialize native handles; reopen files in
each process. Namespace retention manages ordinary garbage-collection
lifetimes and does not protect against explicit `dyn.unload()` calls.

### Coordinates and renderer integration

Face, edge, and channel indices in the C API are **zero-based**. The R
wrappers use **one-based** indices and zero for missing neighbours or
alpha. The API expects native Ptex face identities and local
coordinates. A renderer must preserve source face IDs and
triangulation-to-face mappings. No sRGB decoding, gamma conversion, or
material interpretation is performed.

This package supplies the texture service. A renderer such as rayrender
must preserve Ptex face IDs and call the service from its texture
lookup.

### Alternative API lookup and versioning

Mandatory native consumers can also retrieve the function table through
R’s registered C-callable interface:

``` c
typedef const ptex_api_v1* (*ptex_api_getter)(uint32_t);
ptex_api_getter get_api = (ptex_api_getter)
    R_GetCCallable("ptexr", "ptex_get_api_v1");
const ptex_api_v1* api = get_api(1);
```

Call this on R’s main thread after loading the `ptexr` namespace. Pass
`1` to acquire ABI 1; any other version returns `NULL`. Check for
`NULL`, then verify `abi_version` and `struct_size` before using a
table. Future incompatible changes use a new ABI entry point and
external-pointer tag.

### Limits

The R writer supports float textures with up to 64 channels, full faces,
and reciprocal same-level adjacency. It does not author subfaces,
arbitrary metadata, or other pixel encodings. The upstream reader
supports existing files containing those features.

R samples are batched to avoid one `.Call()` per texel; native consumers
can sample directly in their render loop. Footprint components are
signed and bounded to `[-1, 1]`; coordinates must be local to the chosen
face. Wider renderer footprints must be reduced to a face-sized
footprint before calling this interface.

The runtime guide is also installed as `runtime-api.txt`. For background
on R’s native interface, see [Writing R Extensions: Linking to native
routines in other
packages](https://cran.r-project.org/doc/manuals/r-release/R-exts.html#Linking-to-native-routines-in-other-packages).
