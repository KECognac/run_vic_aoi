# ------------------------------------------------------------------------
# 10_download_nhdplus.R
#
# Routing (phase 2) starts here. RVIC needs a flow-direction grid to know
# how water moves between VIC grid cells -- we get that from NHDPlus HR's
# raster component (10m flow direction/accumulation, hydrologically
# corrected against actual mapped stream channels), then upscale it to
# our 1/16deg domain grid in 11_build_routing_inputs.R.
#
# This script just downloads + extracts the raw NHDPlus HR raster package
# for the HUC4 that contains our AOI (cfg$routing$nhdplus_huc4 -- "1019"
# for South Platte, confirmed via EPA's NHDPlus VPU listing: South Platte
# is inside VPU 10U "Upper Missouri").
#
# CONFIRMED (via a direct S3 bucket listing, not guessed): the download
# URL below exists for HUC4 1019. NOT independently confirmed: the exact
# internal folder/file naming inside the .7z once extracted -- USGS
# doesn't publish that as a fixed spec anywhere I could find, and it can
# vary by release. So rather than hardcoding an expected path, the
# extraction step below searches recursively for files that look like
# flow direction / flow accumulation rasters and fails with a clear
# listing of what it DID find if nothing matches -- same "don't assume,
# verify and fail loud" approach as 04_download_forcing.R's staged
# listing step.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

huc4 <- cfg$routing$nhdplus_huc4
if (is.null(huc4)) {
  stop("cfg$routing$nhdplus_huc4 isn't set -- it's derived from the AOI ",
       "boundary by R/01_get_aoi_boundary.R (written to ",
       fs::path(cfg$paths$aoi_dir, "nhdplus_huc4.txt"), "). Run ",
       "01_get_aoi_boundary.R first.")
}
archive_name <- glue("NHDPLUS_H_{huc4}_HU4_RASTER.7z")
archive_url  <- glue("{cfg$source_urls$nhdplus_hr_raster_base}{archive_name}")
archive_path <- fs::path(cfg$paths$nhdplus_dir, archive_name)
extract_dir  <- fs::path(cfg$paths$nhdplus_dir, glue("HU4_{huc4}_RASTER"))

# --- Stage A: download via curl, NOT base R's download.file() ----------
# download.file() has a hardcoded ~60 SECOND timeout (getOption("timeout")),
# and no resume support -- confirmed the hard way: it silently kills the
# transfer of this multi-GB archive partway through (550 MB in, reporting
# the full size as ~3.8 GB), and the old code here then deleted that
# partial file and would have restarted from zero on every retry. curl
# has no such ceiling and, given -C - below, resumes an existing partial
# file instead of restarting -- so we always invoke it and let IT decide
# whether there's anything left to fetch (rather than an R-side "already
# downloaded" existence check, which can't tell partial from complete).
curl_bin <- Sys.which("curl")
if (curl_bin == "") {
  stop("No `curl` found on PATH -- needed to download this multi-GB file ",
       "reliably (with resume support). curl ships with macOS by default; ",
       "if it's somehow missing, `brew install curl`.")
}

message("Downloading (or resuming) ", archive_url, " via curl -- this is a ",
        "multi-GB file, expect this to take a while. Safe to re-run this ",
        "script if it gets interrupted: curl will pick up where ",
        archive_path, " left off rather than starting over.")

status <- system2(curl_bin, c(
  "-L",                 # follow redirects (S3 sometimes issues one)
  "-C", "-",             # resume from archive_path's current size, if any
  "--retry", "5",
  "--retry-delay", "10",
  "--connect-timeout", "30",  # only for establishing the connection --
                               # deliberately NOT --max-time, which would
                               # reintroduce the same problem we're fixing
  "-f",                  # fail loudly (nonzero exit) on an HTTP error
                          # response instead of saving an error page as
                          # if it were the archive
  "-o", archive_path,
  archive_url
))

if (status != 0 || !fs::file_exists(archive_path) || fs::file_size(archive_path) == 0) {
  stop("Download failed for ", archive_url, " (curl exit status ", status,
       "). The partial file at ", archive_path, " was left in place --  ",
       "just rerun this script to resume rather than deleting it and ",
       "starting over. If curl reports a 404 (rather than a network/",
       "timeout error), the NHDPlus HR raster package naming/hosting may ",
       "have changed -- check ",
       "https://www.usgs.gov/national-hydrography/access-national-hydrography-products ",
       "or https://apps.nationalmap.gov/downloader/ for HUC4 ", huc4,
       " manually and update source_urls.nhdplus_hr_raster_base / this ",
       "script if the path has moved.")
}
message("Downloaded ", round(fs::file_size(archive_path) / 1e6, 1), " MB.")

# --- Stage B: extract with 7z (not built into macOS -- see setup/SETUP.md) --
find_7z <- function() {
  # `7zz`, NOT a typo -- confirmed directly from Homebrew's own formula
  # source: the `sevenzip` formula (setup/SETUP.md's first-choice install)
  # names its binary `7zz`, specifically so it doesn't collide with the
  # older `p7zip` formula's `7z`. Both are checked here since either
  # install path in setup/SETUP.md's section 6 needs to work.
  candidates <- c(Sys.which("7zz"), Sys.which("7z"), Sys.which("7za"),
                   "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                   "/opt/homebrew/bin/7z", "/usr/local/bin/7z")
  candidates <- candidates[candidates != "" & fs::file_exists(candidates)]
  if (length(candidates) == 0) {
    stop("No `7zz`/`7z`/`7za` found on PATH. Install one -- see ",
         "setup/SETUP.md section 6 (`brew install sevenzip` -- installs ",
         "as `7zz` -- or `brew install p7zip` -- installs as `7z`).")
  }
  candidates[1]
}

already_extracted <- fs::dir_exists(extract_dir) &&
  length(fs::dir_ls(extract_dir, recurse = TRUE, type = "file")) > 0

if (already_extracted) {
  message("Already extracted to ", extract_dir, " -- skipping. Delete that ",
          "directory yourself first to force re-extraction.")
} else {
  sevenzip_bin <- find_7z()
  fs::dir_create(extract_dir)
  message("Extracting with ", sevenzip_bin, " (this can take a few minutes ",
          "for a package this size)...")
  status <- system2(sevenzip_bin, c("x", archive_path,
                                     glue("-o{extract_dir}"), "-y"))
  if (status != 0) {
    stop("7z extraction exited with status ", status, ". ", archive_path,
         " may be corrupt/incomplete -- delete it and rerun this script to ",
         "re-download.")
  }
}

# --- Stage C: locate the flow direction / flow accumulation rasters ----
all_files <- fs::dir_ls(extract_dir, recurse = TRUE, type = "file")
message("Extracted ", length(all_files), " files under ", extract_dir)

# NHDPlus HR raster naming has historically used short names like
# "fdr.tif"/"fac.tif" inside a per-HUC4 subfolder, but this isn't a
# documented guarantee -- search case-insensitively for anything that
# LOOKS like flow direction / flow accumulation, then let a human
# (11_build_routing_inputs.R's caller, i.e. you) confirm before it's used
# for anything.
fdr_candidates <- all_files[grepl("fdr", fs::path_file(all_files), ignore.case = TRUE) &
                             grepl("\\.(tif|tiff|img)$", all_files, ignore.case = TRUE)]
fac_candidates <- all_files[grepl("fac", fs::path_file(all_files), ignore.case = TRUE) &
                             grepl("\\.(tif|tiff|img)$", all_files, ignore.case = TRUE)]
# R/11_build_routing_inputs.R derives flow direction FRESH from this
# hydro-conditioned DEM (pyflwdir's from_dem()) rather than reprojecting
# NHDPlus's own pre-computed fdr.tif codes -- reprojecting already-encoded
# D8 direction codes across coordinate systems can rotate what each code
# means (a code meaning "flow east" in the source CRS's axes doesn't
# necessarily mean "flow east" after reprojecting to lat/lon), whereas
# elevation is a continuous field that reprojects cleanly and NHDPlus's
# "hydrodem" is pre-conditioned (sinks filled/streams burned) specifically
# so a fresh D8-from-DEM run reproduces the real mapped channels. fdr/fac
# above are kept only as an optional sanity-check comparison, not fed
# directly into 11.
dem_candidates <- all_files[grepl("hydrodem|dem|elev", fs::path_file(all_files), ignore.case = TRUE) &
                             grepl("\\.(tif|tiff|img)$", all_files, ignore.case = TRUE) &
                             !grepl("fdr|fac", fs::path_file(all_files), ignore.case = TRUE)]

if (length(fdr_candidates) == 0 || length(fac_candidates) == 0) {
  message(
    "NOTE: couldn't find flow direction (fdr) and/or flow accumulation ",
    "(fac) rasters by name pattern -- not fatal (11 doesn't need them, ",
    "they're only used there as an optional QA comparison), but means ",
    "that comparison will be skipped unless you point 11 at the right ",
    "path(s) yourself."
  )
}
if (length(dem_candidates) == 0) {
  stop(
    "Couldn't find a hydro-conditioned DEM ('hydrodem'/'dem'/'elev' in ",
    "the filename) among the extracted files -- R/11_build_routing_inputs.R ",
    "needs this one, it's not optional. NHDPlus HR's internal naming for ",
    "this release doesn't match what this script expected -- inspect the ",
    "listing below yourself and set the right path directly in ",
    "R/11_build_routing_inputs.R:\n",
    paste(all_files, collapse = "\n")
  )
}
if (length(fdr_candidates) > 1 || length(fac_candidates) > 1 || length(dem_candidates) > 1) {
  message("NOTE: found more than one candidate for at least one raster type ",
          "-- listing all of them below so you can pick the right one for ",
          "R/11 if the first guess is wrong:")
}

message("Hydro-conditioned DEM candidate(s) (used by R/11):\n  ",
        paste(dem_candidates, collapse = "\n  "))
message("Flow direction raster candidate(s) (optional QA only):\n  ",
        paste(fdr_candidates, collapse = "\n  "))
message("Flow accumulation raster candidate(s) (optional QA only):\n  ",
        paste(fac_candidates, collapse = "\n  "))
message("Done. Next: 11_build_routing_inputs.R (uses the first DEM ",
        "candidate above by default -- override there if that's wrong ",
        "for your extracted layout).")

