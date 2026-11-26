# Resolve the installed libdeflate archive before make reads the link flags.
archive = system.file(
  "lib",
  Sys.info()[["machine"]],
  "libdeflate.a",
  package = "libdeflate",
  mustWork = TRUE
)

# Keep libdeflate symbols private to ptexr, including when the archive exports them.
flags = if (Sys.info()[["sysname"]] == "Darwin") {
  c(archive, "-Wl,-exported_symbol,_R_init_ptexr")
} else {
  c(archive, "-Wl,--exclude-libs,libdeflate.a")
}
link_flags = paste(shQuote(flags, type = "sh"), collapse = " ")
# Escape make metacharacters without changing the shell quoting of paths.
link_flags = gsub("$", "$$", link_flags, fixed = TRUE)
link_flags = gsub("#", "\\#", link_flags, fixed = TRUE)
target = if (.Platform$OS.type == "windows") {
  "src/Makevars.win"
} else {
  "src/Makevars"
}
makevars = readLines(paste0(target, ".in"), warn = FALSE)
makevars = gsub("@LIBDEFLATE_LIBS@", link_flags, makevars, fixed = TRUE)
writeLines(makevars, target, useBytes = TRUE)
