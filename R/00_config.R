# ------------------------------------------------------------------------
# 00_config.R
#
# Loads config.yml and resolves every path in it to an absolute path,
# creating any output directories that don't exist yet. Every other
# script starts with:
#
#   source("R/00_config.R")
#
# and then uses `cfg$paths$...` / `cfg$aoi$...` / `cfg$run$...` instead of
# any hardcoded path. If you're adapting this repo to your own machine,
# this is the ONLY file where you should ever need to edit a path -- and
# even that just means editing config.yml, not this script.
# ------------------------------------------------------------------------

library(yaml)
library(fs)
library(purrr)

read_vic_config <- function(config_path = "config.yml") {

  stopifnot(file.exists(config_path))
  cfg <- yaml::read_yaml(config_path)

  root <- fs::path_abs(cfg$paths$project_root)

  # Resolve every entry under paths (except project_root itself) relative
  # to project_root, UNLESS it's already absolute (e.g. "~/src/VIC").
  resolve <- function(p) {
    p <- fs::path_expand(p)          # handles "~"
    if (fs::is_absolute_path(p)) p else fs::path_abs(fs::path(root, p))
  }

  cfg$paths <- purrr::imap(cfg$paths, function(p, name) {
    if (name == "project_root") return(root)
    resolve(p)
  })

  # Directories this pipeline WRITES to -- create them if missing.
  # (vic_source_dir / vic_image_exe / tonic_vic_utils_bin are things you
  # install yourself per setup/SETUP.md, so we don't touch those here.)
  writable_dirs <- c("aoi_dir", "raw_params_dir", "raw_forcing_dir",
                      "params_nc_dir", "domain_dir", "output_dir", "log_dir",
                      "metsim_forcing_dir", "nhdplus_dir", "routing_dir")
  purrr::walk(cfg$paths[writable_dirs], fs::dir_create)

  cfg$run$start_date <- as.Date(cfg$run$start_date)
  cfg$run$end_date   <- as.Date(cfg$run$end_date)

  # aoi.mode: "huc" (a WBD HUC8/10/12 polygon, the original design) or
  # "gauge" (the watershed draining to a specific USGS gauge, delineated
  # via NLDI -- see R/01_get_aoi_boundary.R). Defaults to "huc" so older
  # config.yml files without this field still work unchanged.
  if (is.null(cfg$aoi$mode)) cfg$aoi$mode <- "huc"

  # A short, mode-aware description of the AOI for messages/titles/NetCDF
  # attributes -- computed ONCE here instead of every script re-deriving
  # its own "HUC{level} {id}" text (which broke silently for gauge mode,
  # since huc_level isn't meaningful there).
  cfg$aoi$descriptor <- if (identical(cfg$aoi$mode, "gauge")) {
    glue::glue("watershed at USGS {cfg$aoi$gauge_site_no}")
  } else {
    glue::glue("HUC{cfg$aoi$huc_level} {cfg$aoi$huc_id}")
  }

  # NHDPlus HUC4 (used to build the NHDPlus HR download URL in
  # R/10_download_nhdplus.R) is derived from the AOI boundary ITSELF --
  # via a spatial point-intersects query R/01_get_aoi_boundary.R runs
  # against the WBD's own HUC4 layer, written to
  # <aoi_dir>/nhdplus_huc4.txt -- rather than a manually-edited
  # config.yml field (which went stale switching AOIs before: this repo
  # briefly derived it from huc_id's first 4 digits instead, which
  # breaks for a gauge-delineated AOI where huc_id isn't a real WBD code
  # at all, and was never actually guaranteed even in huc mode -- an AOI
  # can cross a HUC4 boundary). Not present until 01 has run once --
  # that's fine, nothing before 10_download_nhdplus.R needs it.
  if (!is.null(cfg$routing)) {
    huc4_file <- fs::path(cfg$paths$aoi_dir, "nhdplus_huc4.txt")
    if (fs::file_exists(huc4_file)) {
      cfg$routing$nhdplus_huc4 <- readLines(huc4_file, n = 1)
    }
  }

  cfg
}

cfg <- read_vic_config()

# Calibration hook: R/15_calibrate_routing.R sets a `.calibration_override`
# list in the global environment before source()-ing 12_run_rvic_parameters.R
# and 13_run_rvic_convolution.R (which both start with source("R/00_config.R")
# same as every other script), so a grid-search iteration's velocity/
# diffusion survive each script's own fresh re-read of config.yml, without
# 15 ever writing to config.yml itself on disk (which would strip its
# extensive hand-written comments -- see this file's own header for why
# that matters). modifyList() merges recursively, so this only overrides
# the specific leaf keys present in the override list (routing$velocity/
# routing$diffusion), leaving every other cfg$routing$* field (e.g.
# pour_points_csv, uh_box_csv) untouched. Not present unless
# 15_calibrate_routing.R is running -- every other script's cfg is
# unaffected.
if (exists(".calibration_override", envir = .GlobalEnv)) {
  cfg <- modifyList(cfg, get(".calibration_override", envir = .GlobalEnv))
}

message(glue::glue(
  "Loaded config for {cfg$aoi$descriptor} ",
  "({cfg$aoi$name}). Project root: {cfg$paths$project_root}"
))

