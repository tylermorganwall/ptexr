# CRAN pre-submission review

Reviewed 2026-11-07 on macOS arm64 with R 4.6.0.

## DESCRIPTION and scope

DESCRIPTION passes R's strict metadata validation. The upstream version and
packaging revision, contributor attribution, license notices, repository URLs,
and libdeflate build dependency match the implementation. No metadata change
was needed. This is a compiled texture service with R functions and a native
runtime API, rather than a header-only package. Rcpp is not a dependency.

## Native code

- No direct exit/abort calls or active console-output calls were found in the
  packaged Ptex/provider sources. The `std::cerr` example in
  `src/vendor/ptex/Ptexture.h` is inside a documentation comment.
- Upstream assertions are disabled in the clean R build by `-DNDEBUG`.
  The existing development DLL contained an assertion symbol, so the review
  used a fresh source build rather than that artifact.
- `#pragma pack(push, 1)` and its matching pop in `PtexIO.h` define the binary
  file layout. They do not suppress compiler diagnostics and were retained.
- The freshly installed DLL has no assertion, exit/abort, console-output, or
  system-RNG imports. R's error calls are recoverable R errors, not process exits.

## Validation

`R CMD check --as-cran --no-manual`: 0 errors, 0 warnings, 1 NOTE
("New submission"). Examples, texture round-trips, sampling tests, and compiled
code checks pass. This run does not establish Windows or Linux results.

Checked archive: `/tmp/native-cran-review-gX5rGQ/ptexr_2.5.4-1.tar.gz`.
Check log: `/tmp/native-cran-review-gX5rGQ/ptexr.Rcheck/00check.log`.

Reference: [Writing R Extensions: portable native code](https://cran.r-project.org/doc/manuals/r-release/R-exts.html#Writing-portable-packages).
