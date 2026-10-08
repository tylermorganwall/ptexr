#' Ptex Library Version
#'
#' @return The bundled upstream Ptex version as a character string.
#' @export
#' @examples
#' ptex_version()
ptex_version <- function() {
  .Call(C_ptex_version)
}

#' Acquire the Ptex Native Runtime Interface
#'
#' Returns the versioned C function table for downstream packages. See
#' `system.file("runtime-api.txt", package = "ptexr")` for integration details.
#' The table is obtained on R's main thread; its native operations can then
#' run on worker threads without invoking R. Keep the handle alive until all
#' native resources and workers using it have finished. Explicitly unloading
#' the package DLL while consumers exist is unsupported.
#'
#' @return An external pointer tagged `ptex.api.v1`. It cannot be serialized.
#' @export
#' @examples
#' api = ptex_api()
ptex_api <- function() {
  .Call(C_ptex_api, asNamespace("ptexr"))
}

#' Create a Shared Texture Cache
#'
#' Memory and open-file limits are soft limits on retained cache data, not hard
#' bounds on process memory. Concurrent lookups can temporarily exceed them.
#' File references are returned after each lookup, so live texture handles do
#' not prevent normal cache eviction.
#'
#' @param max_files Default `100L`. Positive maximum number of cached open files.
#' @param max_memory Default `256 * 1024^2`. Cache budget in bytes; zero means
#'   unlimited. A nonzero budget is recommended for rendering.
#' @param premultiply Default `TRUE`. Premultiply colour channels by alpha on
#'   input. Ptex's reduced resolutions always use premultiplied alpha.
#' @return An external pointer owning a cache. Use [ptex_close()] to release it.
#' @export
#' @examples
#' cache = ptex_cache(max_memory = 32 * 1024^2)
#' ptex_cache_info(cache)
#' ptex_close(cache)
ptex_cache <- function(
  max_files = 100L,
  max_memory = 256 * 1024^2,
  premultiply = TRUE
) {
  max_files <- ptex_integer(max_files, "max_files", 1L)
  stopifnot(
    is.numeric(max_memory),
    length(max_memory) == 1L,
    is.finite(max_memory),
    max_memory >= 0,
    max_memory <= 2^53 - 1,
    max_memory == floor(max_memory),
    is.logical(premultiply),
    length(premultiply) == 1L,
    !is.na(premultiply)
  )
  .Call(
    C_ptex_cache,
    max_files,
    as.double(max_memory),
    as.integer(premultiply),
    asNamespace("ptexr")
  )
}

#' @param x Numeric input.
#' @param name Argument name used in diagnostics.
#' @param minimum Default `0L`. Smallest accepted value.
#' @return A validated integer vector.
#' @keywords internal
#' @noRd
ptex_integer <- function(x, name, minimum = 0L) {
  if (
    !is.numeric(x) ||
      anyNA(x) ||
      any(!is.finite(x)) ||
      any(x < minimum | x > .Machine$integer.max | x != floor(x))
  ) {
    stop(
      name,
      " must contain integers from ",
      minimum,
      " to ",
      .Machine$integer.max,
      call. = FALSE
    )
  }
  as.integer(x)
}

#' Inspect Cache Usage
#' @param cache A cache from [ptex_cache()].
#' @return A named numeric vector of memory bytes, file counts and block reads.
#' @export
ptex_cache_info <- function(cache) {
  .Call(C_ptex_cache_stats, cache)
}

#' Open a Per-Face Texture
#'
#' Reuse one cache for a collection of textures. The file is loaded lazily;
#' opening it does not decode every face. Textures keep their cache alive even
#' after its R handle is explicitly closed. File contents must remain unchanged
#' while cached; use a new cache after rewriting a file.
#'
#' @param path Path to a Ptex file.
#' @param cache Default `ptex_cache()`. Shared cache to use for this texture.
#' @return An external pointer owning a texture reference. Handles cannot be
#'   serialized; reopen files in a new R session.
#' @export
#' @examples
#' file = tempfile(fileext = ".ptx")
#' ptex_write(file, list(array(c(0.1, 0.7, 0.9), c(1, 1, 3))))
#' texture = ptex_open(file)
#' ptex_info(texture)
#' ptex_sample(texture, face = 1, uv = c(0.5, 0.5))
#' ptex_close(texture)
#' unlink(file)
ptex_open <- function(path, cache = ptex_cache()) {
  stopifnot(is.character(path), length(path) == 1L, !is.na(path))
  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  .Call(C_ptex_open, enc2utf8(path), cache)
}

#' Close a Texture or Cache
#' @param handle A texture or cache handle. Closing an already closed handle is safe.
#' @return Invisibly `NULL`.
#' @export
ptex_close <- function(handle) {
  .Call(C_ptex_close, handle)
  invisible(NULL)
}

#' Inspect a Ptex Texture
#' @param texture A texture from [ptex_open()].
#' @return A list with mesh and data types, face and channel counts, alpha channel
#'   (one-based, or zero for no alpha), and border modes.
#' @export
ptex_info <- function(texture) {
  info <- as.list(.Call(C_ptex_info, texture))
  info$mesh_type <- c("triangle", "quad")[[info$mesh_type + 1L]]
  info$data_type <- c("uint8", "uint16", "half", "float")[[info$data_type + 1L]]
  info$u_border <- c("clamp", "black", "periodic")[[info$u_border + 1L]]
  info$v_border <- c("clamp", "black", "periodic")[[info$v_border + 1L]]
  info
}

#' Inspect Face Resolution and Adjacency
#' @param texture A texture from [ptex_open()].
#' @param face One-based face index.
#' @return A list with width, height, adjacent face and edge indices (one-based;
#'   zero means a boundary face), and the subface flag. Triangles use three edges.
#' @export
ptex_face_info <- function(texture, face) {
  info <- .Call(C_ptex_face_info, texture, ptex_integer(face, "face", 1L))
  list(
    width = unname(info[[1L]]),
    height = unname(info[[2L]]),
    adjacent_faces = unname(info[3:6]),
    adjacent_edges = unname(info[7:10]),
    subface = as.logical(info[[11L]])
  )
}

#' Sample and Filter Per-Face Textures
#'
#' Filters use the file's face adjacency to blend across seams. The footprint
#' is a parallelogram with sides `(du1, dv1)` and `(du2, dv2)` in local face
#' coordinates, typically derived from ray differentials. A zero footprint
#' still permits reconstruction filtering. `filter = "point"` reads the nearest
#' texel without blending. No gamma, sRGB or other colour conversion is applied;
#' integer formats are normalized by Ptex to the range zero to one.
#'
#' @param texture A texture from [ptex_open()].
#' @param face One-based face indices, one per sample, or one index for all samples.
#' @param uv Two-column matrix of local `(u, v)` coordinates, or one length-two
#'   vector. Values must be in `[0, 1]`; triangle faces also require `u + v <= 1`.
#' @param footprint Default `c(0, 0, 0, 0)`. Length-four vector or one matrix row
#'   per sample, ordered `du1, dv1, du2, dv2`. Components must be in `[-1, 1]`.
#' @param filter Default `"bspline"`. One of `"point"`, `"bilinear"`, `"box"`,
#'   `"gaussian"`, `"bicubic"`, `"bspline"`, `"catmullrom"`, or `"mitchell"`.
#' @param first_channel Default `1L`. First channel, using one-based indexing.
#' @param channels Default `NULL`. Number of consecutive channels; `NULL` uses
#'   all channels from `first_channel` onward.
#' @param lerp Default `TRUE`. Blend between mipmap levels.
#' @param sharpness Default `0`. General bicubic sharpness in `[0, 1]`.
#' @param no_edge_blend Default `FALSE`. Disable blending across adjacent faces.
#' @return A numeric matrix with one row per sample and one column per channel.
#' @export
#' @examples
#' # A little two-tone flag, sampled at the centres of its four texels.
#' file = tempfile(fileext = ".ptx")
#' flag = array(c(1, 0, 1, 0, 0.1, 0.7, 0.1, 0.7, 0.2, 1, 0.2, 1), c(2, 2, 3))
#' ptex_write(file, list(flag))
#' texture = ptex_open(file)
#' ptex_sample(texture, 1, as.matrix(expand.grid(u = c(.25, .75), v = c(.25, .75))),
#'             filter = "point")
#' ptex_close(texture)
#' unlink(file)
ptex_sample <- function(
  texture,
  face,
  uv,
  footprint = c(0, 0, 0, 0),
  filter = "bspline",
  first_channel = 1L,
  channels = NULL,
  lerp = TRUE,
  sharpness = 0,
  no_edge_blend = FALSE
) {
  filters <- c(
    "point",
    "bilinear",
    "box",
    "gaussian",
    "bicubic",
    "bspline",
    "catmullrom",
    "mitchell"
  )
  filter <- match.arg(filter, filters)
  if (is.numeric(uv) && is.null(dim(uv))) {
    uv <- matrix(uv, nrow = 1L)
  }
  stopifnot(is.matrix(uv), is.numeric(uv), ncol(uv) == 2L, all(is.finite(uv)))
  n <- nrow(uv)
  face <- ptex_integer(face, "face", 1L)
  if (length(face) == 1L) {
    face <- rep(face, n)
  }
  stopifnot(length(face) == n)
  if (is.numeric(footprint) && is.null(dim(footprint))) {
    stopifnot(length(footprint) == 4L)
    footprint <- matrix(rep(footprint, each = n), ncol = 4L)
  }
  stopifnot(
    is.matrix(footprint),
    is.numeric(footprint),
    nrow(footprint) == n,
    ncol(footprint) == 4L,
    all(is.finite(footprint)),
    is.logical(lerp),
    length(lerp) == 1L,
    !is.na(lerp),
    is.logical(no_edge_blend),
    length(no_edge_blend) == 1L,
    !is.na(no_edge_blend),
    is.numeric(sharpness),
    length(sharpness) == 1L,
    is.finite(sharpness)
  )
  first_channel <- ptex_integer(first_channel, "first_channel", 1L)
  if (is.null(channels)) {
    channels <- ptex_info(texture)$channels - first_channel + 1L
  }
  channels <- ptex_integer(channels, "channels", 1L)
  .Call(
    C_ptex_sample,
    texture,
    face,
    as.double(uv),
    as.double(footprint),
    first_channel,
    channels,
    as.integer(match(filter, filters) - 1L),
    as.integer(lerp),
    as.double(sharpness),
    as.integer(no_edge_blend)
  )
}

#' Write Floating-Point Per-Face Textures
#'
#' Writes an entire file with mipmaps. Each face is an array indexed by
#' `[u, v, channel]` with power-of-two spatial dimensions. All faces use the
#' same number of channels. Triangle textures use Ptex's square texel layout;
#' sampling coordinates occupy `u >= 0, v >= 0, u + v <= 1`.
#'
#' Adjacent face and edge matrices must describe reciprocal connections.
#' Quad edges run counterclockwise from the bottom edge: bottom, right, top,
#' left. Triangle edges follow Ptex's native order. This writer does not author
#' subfaces or arbitrary metadata; existing files containing them can be read.
#' Values are stored as floats with no colour conversion and should contain
#' unassociated colour when an alpha channel is specified.
#'
#' @param path Destination file path.
#' @param faces Nonempty list of numeric `[u, v, channel]` arrays. Dimensions
#'   must be powers of two no larger than 32768; triangles require square arrays.
#' @param mesh_type Default `"quad"`. Either `"quad"` or `"triangle"`.
#' @param adjacent_faces Default `NULL`. Matrix with one row per face and four
#'   columns (three for triangles). One-based neighbouring face indices, or
#'   zero for a boundary. `NULL` makes all edges boundaries.
#' @param adjacent_edges Default `NULL`. Corresponding one-based neighbour
#'   edge indices. Required when any adjacent face is nonzero.
#' @param alpha_channel Default `0L`. One-based alpha channel, or zero for none.
#' @param overwrite Default `FALSE`. Allow replacing an existing file. Close
#'   existing readers and create a fresh cache before reading a replacement.
#' @return Invisibly the normalized output path.
#' @export
#' @examples
#' # A warm face and a cool face, joined along their shared edge.
#' file = tempfile(fileext = ".ptx")
#' faces = list(array(c(.9, .2, .05), c(1, 1, 3)),
#'              array(c(.05, .3, .9), c(1, 1, 3)))
#' neighbours = matrix(0L, 2, 4)
#' edges = matrix(1L, 2, 4)
#' neighbours[1, 2] = 2L; edges[1, 2] = 4L
#' neighbours[2, 4] = 1L; edges[2, 4] = 2L
#' ptex_write(file, faces, adjacent_faces = neighbours, adjacent_edges = edges)
#' texture = ptex_open(file)
#' ptex_sample(texture, c(1, 2), rbind(c(1, .5), c(0, .5)), footprint = c(.2, 0, 0, .2))
#' ptex_close(texture)
#' unlink(file)
ptex_write <- function(
  path,
  faces,
  mesh_type = "quad",
  adjacent_faces = NULL,
  adjacent_edges = NULL,
  alpha_channel = 0L,
  overwrite = FALSE
) {
  mesh_type <- match.arg(mesh_type, c("quad", "triangle"))
  stopifnot(
    is.character(path),
    length(path) == 1L,
    !is.na(path),
    nzchar(path),
    is.list(faces),
    length(faces) > 0L,
    is.logical(overwrite),
    length(overwrite) == 1L,
    !is.na(overwrite)
  )
  n <- length(faces)
  faces <- lapply(faces, function(face) {
    stopifnot(is.numeric(face), length(dim(face)) == 3L)
    storage.mode(face) <- "double"
    face
  })
  edge_count <- if (mesh_type == "quad") 4L else 3L
  if (is.null(adjacent_faces)) {
    adjacent_faces <- matrix(0L, n, edge_count)
  }
  if (is.null(adjacent_edges)) {
    if (any(adjacent_faces != 0L)) {
      stop("adjacent_edges is required for connected faces")
    }
    adjacent_edges <- matrix(1L, n, edge_count)
  }
  stopifnot(
    is.matrix(adjacent_faces),
    is.matrix(adjacent_edges),
    identical(dim(adjacent_faces), c(n, edge_count)),
    identical(dim(adjacent_edges), c(n, edge_count))
  )
  neighbours <- matrix(ptex_integer(adjacent_faces, "adjacent_faces"), n)
  edges <- matrix(ptex_integer(adjacent_edges, "adjacent_edges", 1L), n)
  if (edge_count == 3L) {
    neighbours <- cbind(neighbours, 0L)
    edges <- cbind(edges, 1L)
  }
  alpha_channel <- ptex_integer(alpha_channel, "alpha_channel")
  directory <- normalizePath(dirname(path), winslash = "/", mustWork = TRUE)
  path <- file.path(directory, basename(path))
  if (file.exists(path) && !overwrite) {
    stop("File already exists: ", path)
  }
  # Write alongside the destination so a failed write leaves the original intact.
  temporary <- tempfile("ptex-", tmpdir = directory, fileext = ".ptx")
  on.exit(unlink(temporary), add = TRUE)
  .Call(
    C_ptex_write,
    enc2utf8(temporary),
    faces,
    if (mesh_type == "quad") 1L else 0L,
    alpha_channel,
    neighbours,
    edges
  )
  if (!file.rename(temporary, path)) {
    stop("Could not move the completed Ptex file to ", path)
  }
  invisible(path)
}

#' @useDynLib ptexr, .registration = TRUE
NULL
