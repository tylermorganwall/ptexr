library(ptexr)

expect_error <- function(expr, pattern = NULL) {
  error <- tryCatch(
    {
      force(expr)
      NULL
    },
    error = identity
  )
  stopifnot(inherits(error, "error"))
  if (!is.null(pattern)) stopifnot(grepl(pattern, conditionMessage(error)))
}

local({
  directory <- tempfile("ptex-tests-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE))
  file <- file.path(directory, "colours.ptx")
  cache <- ptex_cache(max_memory = 1024^2)
  on.exit(ptex_close(cache), add = TRUE)
  # Nonconstant asymmetric data catches u/v, row/column and channel swaps.
  face <- array(seq_len(4 * 2 * 3) / 32, c(4, 2, 3))
  ptex_write(file, list(face))
  texture <- ptex_open(file, cache)
  on.exit(ptex_close(texture), add = TRUE)
  stopifnot(
    ptex_version() == "2.5.4",
    ptex_info(texture)$mesh_type == "quad",
    ptex_info(texture)$channels == 3,
    ptex_info(texture)$alpha_channel == 0,
    ptex_face_info(texture, 1)$width == 4,
    ptex_face_info(texture, 1)$height == 2
  )
  uv <- as.matrix(expand.grid(u = (0:3 + .5) / 4, v = (0:1 + .5) / 2))
  expected <- matrix(face, ncol = 3)
  stopifnot(isTRUE(all.equal(
    ptex_sample(texture, 1, uv, filter = "point"),
    expected
  )))
  stopifnot(isTRUE(all.equal(
    ptex_sample(
      texture,
      1,
      uv,
      filter = "point",
      first_channel = 2,
      channels = 1
    ),
    expected[, 2, drop = FALSE]
  )))
  stopifnot(identical(
    dim(ptex_sample(texture, integer(), matrix(numeric(), 0, 2))),
    c(0L, 3L)
  ))
  expect_error(ptex_sample(texture, 2, c(.5, .5)), "Face|face")
  expect_error(ptex_sample(texture, 1.5, c(.5, .5)))
  expect_error(ptex_sample(texture, NA_integer_, c(.5, .5)))
  expect_error(ptex_sample(texture, 1, c(Inf, .5)))
  expect_error(ptex_sample(texture, 1, c(-.1, .5)))
  expect_error(ptex_sample(texture, 1, c(.5, .5), channels = 4))
  expect_error(ptex_sample(texture, 1, c(.5, .5), footprint = c(2, 0, 0, 0)))
  expect_error(ptex_sample(texture, 1, c(.5, .5), sharpness = 2))
  expect_error(ptex_write(file, list(face)), "exists")
  expect_error(ptex_write(
    file.path(directory, "bad-size.ptx"),
    list(array(1, c(3, 2, 1)))
  ))
  expect_error(ptex_write(
    file.path(directory, "bad-data.ptx"),
    list(array(Inf, c(2, 2, 1)))
  ))
  # Explicitly release the cache first: an active texture still owns the native cache.
  ptex_close(cache)
  expect_error(ptex_cache_info(cache), "closed")
  stopifnot(isTRUE(all.equal(
    ptex_sample(texture, 1, uv, filter = "point"),
    expected
  )))
  ptex_close(texture)
  ptex_close(texture)
  expect_error(ptex_sample(texture, 1, c(.5, .5)), "closed")

  # Reciprocal edge connections must blend to the same value from either side.
  seam <- file.path(directory, "seam.ptx")
  colours <- list(array(c(1, 0, 0), c(1, 1, 3)), array(c(0, 0, 1), c(1, 1, 3)))
  neighbours <- matrix(0L, 2, 4)
  edges <- matrix(1L, 2, 4)
  neighbours[1, 2] <- 2L
  edges[1, 2] <- 4L
  neighbours[2, 4] <- 1L
  edges[2, 4] <- 2L
  ptex_write(seam, colours, adjacent_faces = neighbours, adjacent_edges = edges)
  texture2 <- ptex_open(seam)
  on.exit(ptex_close(texture2), add = TRUE)
  stopifnot(
    ptex_info(texture2)$faces == 2,
    ptex_face_info(texture2, 1)$adjacent_faces[2] == 2
  )
  for (filter in c(
    "bilinear",
    "box",
    "gaussian",
    "bicubic",
    "bspline",
    "catmullrom",
    "mitchell"
  )) {
    values <- ptex_sample(
      texture2,
      c(1, 2),
      rbind(c(1, .5), c(0, .5)),
      footprint = c(.25, 0, 0, .25),
      filter = filter
    )
    stopifnot(max(abs(values - matrix(c(.5, .5, 0, 0, .5, .5), 2))) < 1e-5)
  }
  isolated <- ptex_sample(
    texture2,
    c(1, 2),
    rbind(c(1, .5), c(0, .5)),
    no_edge_blend = TRUE
  )
  stopifnot(max(abs(isolated - rbind(c(1, 0, 0), c(0, 0, 1)))) < 1e-5)
  neighbours[2, 4] <- 0L
  expect_error(
    ptex_write(
      file.path(directory, "bad-seam.ptx"),
      colours,
      adjacent_faces = neighbours,
      adjacent_edges = edges
    ),
    "reciprocal"
  )

  # Alpha semantics differ between full-resolution authored data and rendering.
  alpha <- file.path(directory, "alpha.ptx")
  ptex_write(
    alpha,
    list(array(c(.8, .4, .2, .5), c(1, 1, 4))),
    alpha_channel = 4
  )
  raw_cache <- ptex_cache(premultiply = FALSE)
  premul_cache <- ptex_cache(premultiply = TRUE)
  on.exit(
    {
      ptex_close(raw_cache)
      ptex_close(premul_cache)
    },
    add = TRUE
  )
  raw <- ptex_open(alpha, raw_cache)
  premul <- ptex_open(alpha, premul_cache)
  on.exit(
    {
      ptex_close(raw)
      ptex_close(premul)
    },
    add = TRUE
  )
  stopifnot(
    max(abs(
      ptex_sample(raw, 1, c(.5, .5), filter = "point") - c(.8, .4, .2, .5)
    )) <
      1e-6
  )
  stopifnot(
    max(abs(
      ptex_sample(premul, 1, c(.5, .5), filter = "point") - c(.4, .2, .1, .5)
    )) <
      1e-6
  )
  stopifnot(ptex_info(premul)$alpha_channel == 4)

  tri <- file.path(directory, "triangle.ptx")
  ptex_write(tri, list(array(.375, c(4, 4, 1))), mesh_type = "triangle")
  triangle <- ptex_open(tri)
  on.exit(ptex_close(triangle), add = TRUE)
  stopifnot(
    ptex_info(triangle)$mesh_type == "triangle",
    abs(ptex_sample(triangle, 1, c(.2, .3))[1] - .375) < 1e-6
  )
  expect_error(ptex_sample(triangle, 1, c(.9, .9)), "Triangle")

  # Invalid files fail at the R boundary; they never abort the process.
  bad <- file.path(directory, "not-ptex.ptx")
  writeLines("This is not a texture", bad)
  expect_error(ptex_open(bad))
  truncated <- file.path(directory, "truncated.ptx")
  writeBin(readBin(file, "raw", n = 20), truncated)
  expect_error(ptex_open(truncated))
  expect_error(ptex_open(file.path(directory, "missing.ptx")))
  saved <- unserialize(serialize(triangle, NULL))
  expect_error(ptex_info(saved), "closed|serialized")
  expect_error(ptex_close(ptex_api()), "cache or texture")

  # Live material handles must not pin open files. Cycle through more than
  # upstream's 50-entry MRU batch while keeping every R texture handle alive.
  eviction_cache <- ptex_cache(max_files = 2L, max_memory = 1024^2)
  on.exit(ptex_close(eviction_cache), add = TRUE)
  paths <- file.path(directory, paste0("cached-", seq_len(64L), ".ptx"))
  stopifnot(all(file.copy(file, paths)))
  textures <- lapply(paths, ptex_open, cache = eviction_cache)
  on.exit(invisible(lapply(textures, ptex_close)), add = TRUE)
  for (pass in seq_len(3L)) {
    for (texture in textures) {
      value <- ptex_sample(texture, 1, c(.125, .25), filter = "point")
      stopifnot(max(abs(value - c(1, 9, 17) / 32)) < 1e-6)
    }
  }
  stopifnot(ptex_cache_info(eviction_cache)[["file_reopens"]] > 0)
})

cat(
  "Ptex file, filtering, adjacency, alpha, triangle, validation and lifetime checks passed.\n"
)

# Read a legacy-format fixture written by an independent Ptex 2.4 library.
local({
  texture <- ptex_open(system.file(
    "extdata",
    "legacy-quad.ptx",
    package = "ptexr"
  ))
  on.exit(ptex_close(texture))
  uv <- as.matrix(expand.grid(c(.25, .75), c(.25, .75)))
  expected <- rbind(c(1, 0, 0), c(0, 1, 0), c(0, 0, 1), c(.25, .5, .75))
  stopifnot(
    max(abs(ptex_sample(texture, 1, uv, filter = "point") - expected)) < 1e-6
  )
})
cat("Legacy Ptex 2.4 file compatibility passed.\n")
