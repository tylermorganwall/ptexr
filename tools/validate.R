# Run from the package root: Rscript --vanilla tools/validate.R [output-directory]
# R orchestrates builds and tests. All installed packages go to an isolated library.
args = commandArgs(trailingOnly = TRUE)
root = normalizePath(".", mustWork = TRUE)
stopifnot(
  read.dcf(file.path(root, "DESCRIPTION"), fields = "Package")[[1L]] == "ptexr"
)
output = if (length(args)) args[[1L]] else tempfile("ptexr-validation-")
dir.create(output, recursive = TRUE, showWarnings = FALSE)
output = normalizePath(output, mustWork = TRUE)
library = file.path(output, "library")
dir.create(library, showWarnings = FALSE)
r = file.path(R.home("bin"), "R")

run = function(command, arguments, log) {
  log = file.path(output, log)
  status = system2(command, shQuote(arguments), stdout = log, stderr = log)
  if (status != 0L) stop("Command failed; see ", log, call. = FALSE)
}

# Build the optional consumer before installing ptexr into the isolated library.
consumer = file.path(root, "tools", "consumer")
headers = list.files(
  file.path(root, "inst", "include", "ptex"),
  full.names = TRUE
)
stopifnot(all(file.copy(
  headers,
  file.path(consumer, "src", "ptex"),
  overwrite = TRUE
)))
run(
  r,
  c("CMD", "INSTALL", "--preclean", "-l", library, consumer),
  "consumer-install.log"
)
run(r, c("CMD", "INSTALL", "--preclean", "-l", library, root), "install.log")
.libPaths(c(library, .libPaths()))
source(file.path(root, "tests", "ptex.R"), chdir = TRUE)

local({
  file = file.path(output, "seam.ptx")
  faces = list(array(c(1, 0, 0), c(1, 1, 3)), array(c(0, 0, 1), c(1, 1, 3)))
  neighbours = matrix(0L, 2, 4)
  edges = matrix(1L, 2, 4)
  neighbours[1, 2] = 2L
  edges[1, 2] = 4L
  neighbours[2, 4] = 1L
  edges[2, 4] = 2L
  ptexr::ptex_write(
    file,
    faces,
    adjacent_faces = neighbours,
    adjacent_edges = edges,
    overwrite = TRUE
  )
  stopifnot(ptexconsumer::runtime_test(file) == 60000L)
})
cat("C and C++ runtime consumers: 60,000 concurrent samples passed.\n")

# Compile upstream CLI tests with R's configured compiler. This executable-only
# test uses the Ptex objects from installation and libdeflate's static archive.
compiler = system2(r, c("CMD", "config", "CXX"), stdout = TRUE)
objects = list.files(
  file.path(root, "src", "vendor", "ptex"),
  pattern = "[.]o$",
  recursive = TRUE,
  full.names = TRUE
)
stopifnot(length(objects) == 10L)
deflate_include = system.file(
  "include",
  package = "libdeflate",
  mustWork = TRUE
)
deflate_archive = system.file(
  "lib",
  Sys.info()[["machine"]],
  "libdeflate.a",
  package = "libdeflate",
  mustWork = TRUE
)
setwd(output)
for (name in c("wtest", "rtest", "ftest", "halftest")) {
  executable = file.path(
    output,
    paste0(name, if (.Platform$OS.type == "windows") ".exe" else "")
  )
  arguments = c(
    "-DPTEX_STATIC",
    "-DPTEX_VENDOR=rpackage",
    paste0("-I", file.path(root, "src", "vendor", "ptex")),
    paste0("-I", deflate_include),
    file.path(root, "tools", "upstream-tests", paste0(name, ".cpp")),
    objects,
    deflate_archive,
    "-pthread",
    "-o",
    executable
  )
  log = file.path(output, paste0(name, "-build.log"))
  # R's compiler string may include architecture/standard flags. It is trusted
  # toolchain configuration; quote all source, object and output arguments.
  command = paste(
    compiler,
    paste(shQuote(arguments), collapse = " "),
    ">",
    shQuote(log),
    "2>&1"
  )
  stopifnot(system(command) == 0L)
  run(executable, character(), paste0(name, ".out"))
  if (name %in% c("rtest", "ftest")) {
    expected = readLines(file.path(
      root,
      "tools",
      "upstream-tests",
      paste0(name, "ok.dat")
    ))
    stopifnot(identical(readLines(paste0(name, ".out")), expected))
  }
  cat(name, "passed\n")
}
run(r, c("CMD", "build", root), "build.log")
version = read.dcf(file.path(root, "DESCRIPTION"), fields = "Version")[[1L]]
archive = file.path(output, paste0("ptexr_", version, ".tar.gz"))
run(r, c("CMD", "check", "--no-manual", archive), "check.log")
cat("Validation output:", output, "\n")
