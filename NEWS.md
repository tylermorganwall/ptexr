# ptexr 2.5.4-1.9000

## Bugfixes

- Overall: Fixes package checks after removal of the legacy texture fixture by removing the test that depended on it.

## Documentation

- Overall: Includes the runtime integration guide in the README, covering dependency setup, native API access, ownership, threading, and ABI requirements.

## Other

- Overall: Uses the static library supplied by CRAN package `libdeflate` (>= 1.25-0) for compression, replacing the bundled libdeflate sources. The dependency is required when building `ptexr` from source.
- Overall: Renames the R package to `ptexr`. Load it with `library(ptexr)` and use `ptexr` in package dependencies and native runtime lookup; existing `ptex_*()` function names remain unchanged.

# ptex 2.5.4-1

## New features

- Overall: Provides Ptex 2.5.4 through one package DLL and a versioned runtime C interface.
- `ptex_open()` Reads per-face textures through a shared cache with configurable memory and file limits.
- `ptex_sample()` Filters across adjacent faces using point, bilinear, box, Gaussian and cubic filters, with explicit texture footprints.
- `ptex_write()` Writes floating-point quad or triangle textures, including face adjacency and alpha information.
