runtime_test = function(path) {
  if (!requireNamespace("ptexr", quietly = TRUE)) {
    stop("Install ptexr to run the runtime test")
  }
  .Call(C_runtime_test, ptexr::ptex_api(), normalizePath(path, winslash = "/"))
}
