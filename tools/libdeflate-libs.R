# Called by Makevars and Makevars.win to link the installed static archive.
archive <- system.file(
  "lib",
  Sys.info()[["machine"]],
  "libdeflate.a",
  package = "libdeflate",
  mustWork = TRUE
)

# Keep libdeflate symbols private to ptexr, including when the archive exports them.
flags <- if (Sys.info()[["sysname"]] == "Darwin") {
  c(archive, "-Wl,-exported_symbol,_R_init_ptexr")
} else {
  c(archive, "-Wl,--exclude-libs,libdeflate.a")
}
cat(paste(shQuote(flags, type = "sh"), collapse = " "))
