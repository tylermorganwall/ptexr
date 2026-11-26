# rwasm runs configure with host R, whose installed archives are native.
wasm = identical(R.version$os, "emscripten") ||
  "--host=wasm32-unknown-emscripten" %in% commandArgs(trailingOnly = TRUE)
windows = .Platform$OS.type == "windows"

wasm_libdeflate_archive = function() {
  host = find.package("libdeflate")
  desc = read.dcf(
    file.path(host, "DESCRIPTION"),
    fields = c("Version", "Built")
  )
  version = desc[[1]]
  target_library = Sys.getenv("PTEXR_WASM_RLIB")
  if (nzchar(target_library)) {
    root = file.path(target_library, "libdeflate")
  } else if (
    isTRUE(grepl("; wasm32-unknown-emscripten;", desc[[2]], fixed = TRUE))
  ) {
    root = host
  } else {
    series = paste(
      R.version$major,
      sub("[.].*", "", R.version$minor),
      sep = "."
    )
    url = sprintf(
      "https://tylermorganwall.r-universe.dev/bin/emscripten/contrib/%s/libdeflate_%s.tgz",
      series,
      version
    )
    tarball = tempfile(fileext = ".tgz")
    on.exit(unlink(tarball))
    utils::download.file(url, tarball, mode = "wb")
    members = utils::untar(tarball, list = TRUE)
    archive = grep(
      "^libdeflate/lib/[^/]+/libdeflate[.]a$",
      members,
      value = TRUE
    )
    if (length(archive) != 1L) {
      stop("Expected one libdeflate.a in ", url)
    }
    destination = "src/wasm-libdeflate"
    dir.create(destination, showWarnings = FALSE)
    status = utils::untar(
      tarball,
      files = c("libdeflate/DESCRIPTION", archive),
      exdir = destination
    )
    if (isTRUE(status != 0L)) {
      stop("Could not extract ", url)
    }
    root = file.path(destination, "libdeflate")
  }

  desc = read.dcf(
    file.path(root, "DESCRIPTION"),
    fields = c("Package", "Version", "Built")
  )
  if (
    desc[[1]] != "libdeflate" ||
      desc[[2]] != version ||
      !isTRUE(grepl("; wasm32-unknown-emscripten;", desc[[3]], fixed = TRUE))
  ) {
    stop("Expected the wasm32 build of libdeflate ", version, " at ", root)
  }
  # The binary package may store the archive under the build machine's name.
  archive = Sys.glob(file.path(root, "lib", "*", "libdeflate.a"))
  if (length(archive) != 1L) {
    stop("Expected one libdeflate.a under ", root)
  }
  normalizePath(archive, mustWork = TRUE)
}

archive = if (wasm) {
  wasm_libdeflate_archive()
} else {
  system.file(
    "lib",
    Sys.info()[["machine"]],
    "libdeflate.a",
    package = "libdeflate",
    mustWork = TRUE
  )
}

# R uses ptexr-win.def for DLL exports on both Windows architectures.
flags = if (windows || wasm) {
  archive
} else if (Sys.info()[["sysname"]] == "Darwin") {
  c(archive, "-Wl,-exported_symbol,_R_init_ptexr")
} else {
  c(archive, "-Wl,--exclude-libs,libdeflate.a")
}
# webR loads single-threaded side modules and supplies pthread stubs.
if (!windows && !wasm) {
  flags = c(flags, "-pthread")
}
link_flags = paste(shQuote(flags, type = "sh"), collapse = " ")
# Escape make metacharacters without changing the shell quoting of paths.
link_flags = gsub("$", "$$", link_flags, fixed = TRUE)
link_flags = gsub("#", "\\#", link_flags, fixed = TRUE)
target = if (windows) {
  "src/Makevars.win"
} else {
  "src/Makevars"
}
makevars = readLines(paste0(target, ".in"), warn = FALSE)
makevars = gsub("@PTEX_LIBS@", link_flags, makevars, fixed = TRUE)
writeLines(makevars, target, useBytes = TRUE)
