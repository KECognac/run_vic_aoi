# ------------------------------------------------------------------------
# 03_convert_params_to_netcdf.R
#
# Converts the classic-driver ASCII files downloaded in
# 02_download_vic_params.R into a single VIC 5 image-driver parameter
# NetCDF file, by shelling out to python/convert_params_to_netcdf.py
# (which wraps Tonic -- there is no R package that does this conversion).
#
# This script does NOT try to guess which downloaded file is the soil
# file vs. veg param file vs. veglib vs. snowband -- naming conventions
# vary. Fill in `file_map` below after looking at what
# 02_download_vic_params.R printed / what's in cfg$paths$raw_params_dir.
#
# Requires: a Python environment with tonic installed and on PATH (or
# point `python_bin` at it directly). See setup/SETUP.md.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

# CONFIRMED against global.param.4.1.2.c.flux.template.nldas -- the
# original VIC4 classic global param file these exact parameters were
# distributed with (see VEGLIB/VEGPARAM/SOIL/SNOW_BAND lines in that
# file). The "mexico" naming on the soil/veg files is misleading -- they
# are the full NLDAS-domain-plus-Mexico-extension grid, which covers
# CONUS (and so the Poudre) fine. Despite covering CONUS, the matching
# snow-band file is the one ALSO named "mexico", not either CONUS-named
# file -- soil/veg/snow have to come from the same matched triplet, and
# the template confirms this is it (this was wrong in an earlier version
# of this script -- if you downloaded before this comment existed and
# hit a ValueError inside tonic's snow(), this was why).
#   LDAS_veg_lib                          -> veglib
#   vic.nldas.mexico.soil.txt             -> soil
#   vic.nldas.mexico.veg.txt              -> veg
#   vic.nldas.mexico.snow.txt.L13         -> snow (NOT vic.CONUS.L13/L14 -- those are a
#                                            different, incompatible triplet)
# Not used by this conversion but worth having read: readme.txt (citation
# info, now in CITATION.md) and the global param template itself, which
# is also where NLAYER=3, SNOW_BAND=5, and ROOT_ZONES=3 below were
# confirmed (vic_params in config.yml, --root-zones in this script).
# Points at 02b_subset_params_to_aoi.R's output, NOT the raw downloads --
# converting the full 333,579-cell continent works but is extremely slow
# (many minutes; Tonic's snow-band matching is an O(n^2) Python loop).
# Run 02b first. veglib isn't subset (it's not per-cell -- same file for
# every cell in the domain, so there's nothing to trim).
# Keyed on huc_id -- must match 02b_subset_params_to_aoi.R's own
# aoi_subset_dir naming (see that script's comment for why).
aoi_params_dir <- fs::path(cfg$paths$raw_params_dir, "..",
                            glue("vic_params_aoi_{cfg$aoi$huc_id}")) |> fs::path_norm()
file_map <- list(
  soil    = fs::path(aoi_params_dir, "soil.txt"),
  veg     = fs::path(aoi_params_dir, "veg.txt"),
  veglib  = fs::path(cfg$paths$raw_params_dir, "LDAS_veg_lib"),
  snow    = fs::path(aoi_params_dir, "snow.txt")
)

missing <- file_map[!file.exists(unlist(file_map))]
if (length(missing) > 0) {
  missing_aoi <- intersect(names(missing), c("soil", "veg", "snow"))
  hint <- if (length(missing_aoi) > 0) {
    glue(
      "\n\n{paste(missing_aoi, collapse = '/')} come from ",
      "02b_subset_params_to_aoi.R's AOI-keyed output dir ({aoi_params_dir}) -- ",
      "most likely you just need to (re)run 02b_subset_params_to_aoi.R for ",
      "the CURRENT aoi.huc_id/aoi.mode in config.yml (this dir is keyed on ",
      "huc_id, so switching AOIs always needs a fresh 02b run, even if ",
      "you've run it before for a different AOI)."
    )
  } else ""
  stop(glue(
    "file_map in R/03_convert_params_to_netcdf.R points at files that ",
    "don't exist:\n",
    paste(glue("  {names(missing)}: {unlist(missing)}"), collapse = "\n"),
    "\n\nIf veglib is missing, run 02_download_vic_params.R first and look ",
    "at what it downloaded into {cfg$paths$raw_params_dir}, then edit ",
    "file_map above to match.",
    hint
  ))
}

# Prefer an explicit tonic_python from config.yml -- RStudio does not
# inherit shell conda-env activation, so Sys.which() here almost always
# resolves to your SYSTEM python (which won't have tonic installed) even
# after you've correctly set up the "tonic" conda env in a terminal.
python_bin <- cfg$paths$tonic_python
if (is.null(python_bin) || !fs::file_exists(python_bin)) {
  python_bin <- Sys.which("python3")
  if (python_bin == "") python_bin <- Sys.which("python")
}
if (python_bin == "" || is.null(python_bin)) {
  stop("No usable python found. Set paths$tonic_python in config.yml to ",
       "the tonic conda env's python (see the comment next to it), or ",
       "install python and put it on PATH.")
}
message("Using python: ", python_bin)

# Bypass `pip install tonic` entirely if a source checkout is configured --
# tonic's old setup.py is prone to build failures (commonly a
# numpy.distutils issue) on modern toolchains, and none of that is needed
# if we just point PYTHONPATH at the cloned source. See config.yml's
# comment next to tonic_source_dir for the one-time `git clone`.
if (!is.null(cfg$paths$tonic_source_dir) && fs::dir_exists(cfg$paths$tonic_source_dir)) {
  existing <- Sys.getenv("PYTHONPATH")
  Sys.setenv(PYTHONPATH = paste(
    cfg$paths$tonic_source_dir,
    existing,
    sep = if (nzchar(existing)) .Platform$path.sep else ""
  ))
  message("Using tonic from source: ", cfg$paths$tonic_source_dir,
          " (PYTHONPATH bypass, not pip-installed)")
}

out_nc <- fs::path(cfg$paths$params_nc_dir, "params.vic5.nc")

args <- c(
  "python/convert_params_to_netcdf.py",
  "--soil",   file_map$soil,
  "--veg",    file_map$veg,
  "--veglib", file_map$veglib,
  "--snow",   file_map$snow,
  "--nlayers",    cfg$vic_params$nlayers,
  "--snow-bands", cfg$vic_params$snow_bands,
  "--veg-classes", cfg$vic_params$veg_classes,
  "--root-zones", cfg$vic_params$root_zones,
  "--out", out_nc
)
# (veg-classes = 11 is independently confirmed: LDAS_veg_lib has exactly
# 11 data rows below its "#Class..." header line)

message("Running: ", python_bin, " ", paste(args, collapse = " "))
status <- system2(python_bin, args)

if (status != 0) {
  stop(
    "convert_params_to_netcdf.py exited with status ", status, ". ",
    "If the error was ModuleNotFoundError: No module named 'tonic', this ",
    "python (", python_bin, ") isn't the one tonic is installed in -- set ",
    "paths$tonic_python in config.yml to the tonic conda env's python ",
    "(run `conda activate tonic && which python` in a terminal to find it), ",
    "not just PATH, since RStudio doesn't inherit conda activation. ",
    "See setup/SETUP.md."
  )
}

message("Wrote ", out_nc)
message("NOTE: this file is already AOI-sized (02b subset the ASCII inputs ",
        "before conversion), but its grid may have tiny floating-point ",
        "drift vs. the forcing grid -- 05_build_domain.R snaps it onto the ",
        "forcing grid's exact coordinates before it's usable by VIC.")

