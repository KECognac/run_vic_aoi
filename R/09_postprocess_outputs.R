# ------------------------------------------------------------------------
# 09_postprocess_outputs.R
#
# Reads VIC image-driver output NetCDF(s) from cfg$paths$output_dir,
# computes an AOI-average daily water balance (runoff, baseflow, total
# streamflow-equivalent), and saves a plot + CSV summary.
#
# Adjust `vars_to_read`/`snow_vars_to_read` below to add other variables.
# This run's global_param.txt doesn't list explicit OUTVAR lines, so VIC
# writes its full default output for each of the THREE output files it
# creates per run (RESULT_DIR, one time series each -- SNOW_BAND TRUE is
# what causes the snow/snowband split):
#   fluxes.<startdate>.nc  (this script's main input) --
#     OUT_PREC, OUT_EVAP, OUT_RUNOFF, OUT_BASEFLOW, OUT_WDEW, OUT_SWNET,
#     OUT_R_NET, OUT_EVAP_CANOP, OUT_TRANSP_VEG, OUT_EVAP_BARE,
#     OUT_SUB_CANOP, OUT_SUB_SNOW, OUT_AERO_RESIST, OUT_SURF_TEMP,
#     OUT_ALBEDO, OUT_REL_HUMID, OUT_IN_LONG, OUT_AIR_TEMP, OUT_WIND
#   snow.<startdate>.nc  (SWE/snowpack lives HERE, not in fluxes) --
#     OUT_SWE, OUT_SNOW_DEPTH, OUT_SNOW_CANOPY, OUT_SNOW_COVER
#   snowband.<startdate>.nc  (per-elevation-band snow/energy terms) --
#     OUT_SWE_BAND, OUT_SNOW_DEPTH_BAND, OUT_SNOW_CANOPY_BAND,
#     OUT_SWNET_BAND, OUT_LWNET_BAND, OUT_ALBEDO_BAND, OUT_LATENT_BAND,
#     OUT_SENSIBLE_BAND, OUT_GRND_FLUX_BAND -- NOT read by this script;
#     all of these are (time, snow_band, lat, lon), same extra-dimension
#     situation as OUT_SOIL_LIQ below.
# Everything in vars_to_read/snow_vars_to_read below is (time, lat, lon),
# so just adding a name from the fluxes or snow list is enough -- the
# pivot_longer() near the bottom picks up whatever's in either list
# automatically. The one exception among the vars actually read here is
# OUT_SOIL_LIQ, which is (time, nlayer, lat, lon) -- one extra dimension
# -- and needs its own read logic (see the note down by
# `arr <- ncvar_get(nc, v)` below) since the per-day mean() there assumes
# exactly 3 dims; the *_BAND vars above have the same issue if you want
# them (extra dim is snow_band instead of nlayer).
# `ncdump -h output/<stream>.<startdate>.nc` (or the python snippet in
# this chat) shows the full list plus units/long_name for any file.
#
# Reads with ncdf4 directly rather than tidync -- tidync::hyper_tibble()
# errored with "subscript out of bounds" on this file. Root cause looks
# like tidync's "active grid" detection getting confused: this fluxes
# file has THREE differently-shaped variable groups (most OUT_* vars are
# (time, lat, lon), OUT_SOIL_LIQ is (time, nlayer, lat, lon), and
# time_bnds is (time, nv)), and tidync only fully supports one active
# grid at a time. ncdf4 is already a proven dependency everywhere else in
# this pipeline, so we just read the two vars we need directly instead of
# fighting tidync's grid selection.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(ncdf4)
library(dplyr)
library(tidyr)
library(ggplot2)
library(readr)
library(fs)
library(glue)
library(purrr)

# VIC's image driver writes fluxes.<startdate>.nc, snow.<startdate>.nc,
# and snowband.<startdate>.nc alongside each other in the same
# RESULT_DIR (SNOW_BAND TRUE is what produces the snow/snowband split) --
# named exactly, not globbed, and matched to the CURRENT
# cfg$run$start_date specifically. output_dir isn't cleared between runs
# (same fixed path across AOIs and reruns, like several other dirs in
# this pipeline), so old fluxes.<other-startdate>.nc files from an
# earlier run/AOI can still be sitting right next to the current one.
# VIC names its own output files after the run's actual start date, so
# filtering on that is both correct and AOI-agnostic (confirmed the hard
# way: an earlier version of this script glob-matched "*fluxes*.nc", and
# a stale fluxes.2009-10-01.nc from an earlier test was silently getting
# map_dfr()'d together with the current run's fluxes.2005-01-01.nc,
# corrupting aoi_daily_summary.csv with a second run's data).
start_str <- format(cfg$run$start_date, "%Y-%m-%d")
fluxes_file   <- fs::path(cfg$paths$output_dir, glue("fluxes.{start_str}.nc"))
snow_file     <- fs::path(cfg$paths$output_dir, glue("snow.{start_str}.nc"))
snowband_file <- fs::path(cfg$paths$output_dir, glue("snowband.{start_str}.nc"))
if (!fs::file_exists(fluxes_file)) {
  stop("No ", fluxes_file, " found -- did 08_run_vic.R succeed? (VIC names ",
       "its output files after RUN start_date -- if you changed ",
       "run$start_date in config.yml since the last VIC run, rerun ",
       "08_run_vic.R first.)")
}
message("Reading ", fluxes_file)

# EDIT ME: add any of the fluxes-file variables listed in the header
# comment above.
# OUT_EVAP = actual evapotranspiration (AET, total net evaporation, mm/day)
# and OUT_PET = potential evapotranspiration (Penman-Monteith, mm/day) --
# OUT_PET is NOT part of VIC's default output; it only exists in
# fluxes.nc once R/07_write_globalparam.R's explicit OUTVAR block
# (added alongside this line) has been used to actually rerun VIC (08).
# If you add OUT_PET here before rerunning 08 with that updated
# global_param.txt, read_vic_daily_means() below will fail loudly
# (missing variable) rather than silently skip it.
vars_to_read <- c("OUT_RUNOFF", "OUT_BASEFLOW", "OUT_EVAP", "OUT_PET")
# EDIT ME: add any of the snow-file variables listed in the header
# comment above (this is where SWE/snowpack lives -- OUT_SWE is mm of
# snow water equivalent, OUT_SNOW_DEPTH is cm of physical snow depth).
snow_vars_to_read <- c("OUT_SWE")
# EDIT ME: add any of the snowband-file variables listed in the header
# comment above (this is where PER-ELEVATION-BAND snow output lives --
# OUT_SWE_BAND is the per-band counterpart to OUT_SWE above, useful for
# telling whether snow behavior differs by elevation, e.g. a high band
# that never fully melts out each summer vs. lower bands that do).
band_vars_to_read <- c("OUT_SWE_BAND")

# Converts VIC's own raw time values into calendar dates by ANCHORING to
# cfg$run$start_date (the exact date this run's global_param.txt told
# VIC to start on -- see R/07_write_globalparam.R's RUN_STARTDATE-
# equivalent STARTYEAR/STARTMONTH/STARTDAY lines) and counting forward
# one day per record, rather than decoding the file's declared time
# units ("days since 0001-01-01 00:00:00") with as.Date(origin = ...).
# Confirmed empirically (staged real output from this AOI and
# cross-checked against Python's netCDF4/cftime -- same method used to
# find and fix the same issue in R/15_calibrate_routing.R) that R's
# as.Date() arithmetic disagrees with the file's own CF calendar meaning
# by a couple of days for an origin this ancient. Harmless for a casual
# look at a 30-year seasonal plot, but not worth carrying the same known
# bug into new code, or leaving in this file's own existing dates, now
# that it's been found and fixed elsewhere this session. Unlike RVIC's
# convolution output (which has small genuine gaps at flush boundaries --
# see 15_calibrate_routing.R's own comment on that), VIC's own direct
# daily output (this script's input) is a single regular, gap-free
# series for the exact run$start_date..end_date window, so a plain
# day-count from start_date is enough -- validated against the expected
# day count below rather than assumed blindly.
vic_output_dates <- function(n_records) {
  expected_n <- as.integer(cfg$run$end_date - cfg$run$start_date) + 1L
  if (n_records != expected_n) {
    stop("VIC output has ", n_records, " time records but ", expected_n,
         " were expected for ", cfg$run$start_date, "..", cfg$run$end_date,
         " -- this doesn't look like a clean single run over that exact ",
         "period, so dates derived from a plain day-count would be wrong. ",
         "Check the file (and whether run$start_date/end_date in ",
         "config.yml still match what 08_run_vic.R actually ran) before ",
         "trusting output built on this.")
  }
  cfg$run$start_date + seq_len(n_records) - 1L
}

# Shared by both files below -- same read logic works for any (time, lat,
# lon) VIC output variable, regardless of which output stream it's in.
read_vic_daily_means <- function(nc_path, vars) {
  nc <- nc_open(nc_path)
  on.exit(nc_close(nc), add = TRUE)

  # as.vector() strips a `dim` attribute that ncvar_get() leaves on this
  # 1-D coordinate variable (confirmed empirically) -- without it, that
  # dim attribute survives arithmetic into vic_output_dates() and
  # readr::write_csv() later rejects the result as a "list or matrix
  # column" even though it's functionally a plain Date vector.
  time_vals <- as.vector(ncvar_get(nc, "time"))
  dates <- vic_output_dates(length(time_vals))

  present_vars <- intersect(vars, names(nc$var))
  if (length(present_vars) == 0) {
    stop("None of ", paste(vars, collapse = ", "), " found in ", nc_path,
         " -- actual variables: ", paste(names(nc$var), collapse = ", "))
  }

  df <- data.frame(time = dates)
  for (v in present_vars) {
    # Confirmed empirically against the real output file: even on a FULL
    # read (no start/count at all), ncdf4 hands back the array with
    # dimensions REVERSED relative to the file's declared CDL order. This
    # var is declared (time, lat, lon) in the file, but ncvar_get(nc, v)
    # returns an R array shaped (lon, lat, time) -- so time is MARGIN 3,
    # not 1. (This appears to be ncdf4's general convention -- fastest
    # varying dim first in R -- not a one-off quirk of explicit
    # start/count like the ones hit earlier in this pipeline.)
    #
    # OUT_SOIL_LIQ (and any *_BAND var) is 4-D -- (time, nlayer-or-
    # snow_band, lat, lon) in the file, (lon, lat, that-dim, time) as read
    # here -- so `apply(arr, 3, mean)` below would average over lat
    # (wrong margin) and leave the extra dim dangling in df[[v]]. If you
    # add one of those to vars/snow_vars_to_read, handle it separately,
    # e.g. `apply(arr, c(3, 4), mean, na.rm = TRUE)` gives an
    # nlayer-or-band x time matrix -- pick one or average across it
    # first, and give it its own column name (df$OUT_SOIL_LIQ_L1 <- ...).
    arr <- ncvar_get(nc, v)
    df[[v]] <- apply(arr, 3, mean, na.rm = TRUE)   # simple AOI-mean per day;
                                                     # switch to area-weighted
                                                     # if cell areas vary a lot
  }
  df
}

# Per-band counterpart to read_vic_daily_means() above, for a 4-D
# (time, snow_band, lat, lon) variable -- keeps the snow_band dimension
# instead of collapsing it, returning one row per (date, band).
#
# Finding which array axis is "band" and which is "time" by NAME
# (nc$var[[v]]$dim) was tried first and gave the WRONG axis when tested
# against this AOI's own real params.aligned.nc -- ncdf4's actual
# returned-array axis order does not reliably match the file's declared
# dimension order reversed (or any other fixed rule assumed without
# checking). Matching by LENGTH against the known band count and time
# length -- the same pattern 13/14/15_*.R already use for a time axis --
# is what's actually reliable, so that's what this does; confirmed
# against a real staged subset of this AOI's own snowband.nc, cross-
# checked value-for-value against an independent Python/numpy
# computation, before trusting it here.
read_vic_band_means <- function(nc_path, vars, band_coord) {
  nc <- nc_open(nc_path)
  on.exit(nc_close(nc), add = TRUE)

  time_vals <- as.vector(ncvar_get(nc, "time"))
  dates <- vic_output_dates(length(time_vals))

  present_vars <- intersect(vars, names(nc$var))
  if (length(present_vars) == 0) {
    stop("None of ", paste(vars, collapse = ", "), " found in ", nc_path,
         " -- actual variables: ", paste(names(nc$var), collapse = ", "))
  }

  n_bands <- length(band_coord)
  out <- vector("list", length(present_vars))
  for (i in seq_along(present_vars)) {
    v <- present_vars[i]
    arr <- ncvar_get(nc, v)
    band_axis <- which(dim(arr) == n_bands)
    time_axis <- which(dim(arr) == length(dates))
    if (length(band_axis) != 1 || length(time_axis) != 1) {
      stop("Couldn't unambiguously match '", v, "' dims (",
           paste(dim(arr), collapse = "x"), ") to band count ", n_bands,
           " and time length ", length(dates), " in ", nc_path,
           " -- inspect this variable's actual shape before trusting it.")
    }
    # Mean over the two remaining (lat, lon) margins, keeping band x
    # time. apply() returns margins in the order requested -- band
    # varies fastest in the flattened result below, matching
    # expand.grid()'s own default (first argument varies fastest),
    # confirmed these line up correctly against real staged data before
    # trusting this rather than just assuming the margin order.
    band_time <- apply(arr, c(band_axis, time_axis), mean, na.rm = TRUE)
    df <- expand.grid(band = band_coord, time = dates)
    df$value <- as.vector(band_time)
    df$variable <- v
    out[[i]] <- df
  }
  dplyr::bind_rows(out)
}

# Area-weighted mean elevation per snow band, for labeling the per-band
# plot below -- otherwise "band 1..5" tells you nothing about what
# elevation range each band actually represents. Reads
# params.aligned.nc's own elevation/AreaFract/snow_band variables (same
# file 07/12's scripts already depend on), using the same length-matched
# axis approach as read_vic_band_means() above for the same reason.
# AreaFract is 0 for an unused band in a basin that doesn't reach that
# elevation range (confirmed this AOI has one such band), which the
# weighted average below naturally turns into NA rather than a
# misleading 0 m.
band_elevation_labels <- function(params_path) {
  nc <- nc_open(params_path)
  on.exit(nc_close(nc), add = TRUE)
  snow_band <- as.vector(ncvar_get(nc, "snow_band"))
  elev_arr <- ncvar_get(nc, "elevation")
  area_arr <- ncvar_get(nc, "AreaFract")
  n_bands <- length(snow_band)
  band_axis <- which(dim(elev_arr) == n_bands)
  if (length(band_axis) != 1) {
    stop("Couldn't unambiguously match 'elevation' dims (",
         paste(dim(elev_arr), collapse = "x"), ") to band count ",
         n_bands, " in ", params_path, ".")
  }
  elev_m <- vapply(seq_len(n_bands), function(b) {
    ix <- lapply(dim(elev_arr), seq_len)
    ix[[band_axis]] <- b
    e_b <- do.call("[", c(list(elev_arr), ix))
    w_b <- do.call("[", c(list(area_arr), ix))
    total_w <- sum(w_b, na.rm = TRUE)
    if (total_w > 0) sum(e_b * w_b, na.rm = TRUE) / total_w else NA_real_
  }, numeric(1))
  data.frame(band = snow_band, elev_m = elev_m)
}

fluxes_daily <- read_vic_daily_means(fluxes_file, vars_to_read)

if (length(snow_vars_to_read) > 0) {
  if (fs::file_exists(snow_file)) {
    message("Reading ", snow_file)
    snow_daily <- read_vic_daily_means(snow_file, snow_vars_to_read)
    # full_join, not cbind -- both files cover the same run so their time
    # columns should already match exactly, but joining by time (rather
    # than assuming identical row order/count) fails loudly instead of
    # silently misaligning dates if they ever don't.
    daily <- dplyr::full_join(fluxes_daily, snow_daily, by = "time")
  } else {
    message("No ", snow_file, " found -- skipping snow_vars_to_read (",
            paste(snow_vars_to_read, collapse = ", "), "). SNOW_BAND TRUE ",
            "in global_param.txt should always produce this file, so this ",
            "is worth investigating if you expected it.")
    daily <- fluxes_daily
  }
} else {
  daily <- fluxes_daily
}

if (!"time" %in% names(daily)) {
  stop("No 'time' column after reading output -- inspect the .nc structure ",
       "with `nc_open(fluxes_file)` interactively and adjust this script.")
}

all_vars <- c(vars_to_read, snow_vars_to_read)

basin_daily <- daily %>%
  # any_of(all_vars), NOT a hardcoded c("OUT_RUNOFF", "OUT_BASEFLOW") --
  # so adding a variable to vars_to_read/snow_vars_to_read above is the
  # ONLY edit needed to get it into the CSV/plot too (this used to
  # silently drop anything you added but forgot to also add here).
  pivot_longer(cols = any_of(all_vars),
               names_to = "variable", values_to = "value") %>%
  group_by(time, variable) %>%
  summarise(value = mean(value, na.rm = TRUE), .groups = "drop")

readr::write_csv(basin_daily, fs::path(cfg$paths$output_dir, "aoi_daily_summary.csv"))

# Faceted with free y scales, not one shared axis -- vars_to_read can mix
# very different units (mm/day water-balance terms, W/m^2 radiation,
# degC temperature, m/s wind, etc.), which would be unreadable/misleading
# on one shared "mm/day" axis the moment you add anything beyond
# OUT_RUNOFF/OUT_BASEFLOW. Check aoi_daily_summary.csv or the header
# comment's variable list above for each variable's actual units.
p <- ggplot(basin_daily, aes(time, value, color = variable)) +
  geom_line() +
  facet_wrap(~variable, scales = "free_y", ncol = 1) +
  labs(title = glue("{cfg$aoi$name} -- AOI-mean daily output"),
       x = NULL, y = NULL, color = NULL) +
  theme_minimal() +
  theme(legend.position = "none")

p

ggsave(fs::path(cfg$paths$output_dir, "aoi_daily_summary.png"), p, width = 8, height = 4.5, dpi = 150)

message("Wrote aoi_daily_summary.csv and aoi_daily_summary.png to ", cfg$paths$output_dir)

# --- second plot: per-elevation-band snow output ---
#
# Separate from basin_daily/aoi_daily_summary above on purpose: an
# AOI-wide mean (like the OUT_SWE line in the first plot) blends every
# elevation band into one number, which can't distinguish "the whole
# basin is slowly accumulating snow" from "one small high band never
# fully melts out and drags the basin mean up while everything else
# behaves normally" -- exactly the question raised looking at this AOI's
# own OUT_SWE trend. Faceted per band with free y scales (same reasoning
# as the first plot's facets) so a deep, mostly-permanent high-elevation
# snowpack doesn't visually swamp a thin, fully-ablating low-elevation
# one on a shared axis.
if (length(band_vars_to_read) > 0) {
  if (fs::file_exists(snowband_file)) {
    message("Reading ", snowband_file)
    params_aligned_path <- fs::path(cfg$paths$domain_dir, "params.aligned.nc")

    # Band coordinate: NOT read from the snowband file itself -- confirmed
    # by direct inspection of this AOI's own real snowband.<startdate>.nc
    # that VIC's image driver writes "snow_band" only as a bare DIMENSION
    # there (used to shape OUT_SWE_BAND etc.), with no matching coordinate
    # VARIABLE to read values from -- ncvar_get(nc, "snow_band") errors
    # ("variable not found") on that file. params.aligned.nc (the file
    # 07/12 already depend on) has a real "snow_band" coordinate variable
    # (values 1..n, confirmed against this AOI's own file), so read it
    # from there instead, falling back to a plain 1..n sequence (using the
    # snowband file's own "snow_band" DIMENSION length, which unlike a
    # variable's array-axis order is unambiguous to read by name) if
    # params.aligned.nc isn't available for some reason.
    nc_sb <- nc_open(snowband_file)
    n_bands_dim <- nc_sb$dim[["snow_band"]]$len
    nc_close(nc_sb)

    if (fs::file_exists(params_aligned_path)) {
      nc_p <- nc_open(params_aligned_path)
      band_coord <- as.vector(ncvar_get(nc_p, "snow_band"))
      nc_close(nc_p)
      if (length(band_coord) != n_bands_dim) {
        stop(params_aligned_path, "'s snow_band coordinate has ",
             length(band_coord), " bands but ", snowband_file, " has ",
             n_bands_dim, " -- these should match (same AOI/run). Rerun ",
             "05_build_domain.R and/or 08_run_vic.R if config.yml's snow ",
             "band settings changed since either was last run.")
      }
    } else {
      message("No ", params_aligned_path, " found -- using plain band ",
              "numbers 1..", n_bands_dim, " (run 05_build_domain.R if you ",
              "expected this file to exist).")
      band_coord <- seq_len(n_bands_dim)
    }

    band_daily <- read_vic_band_means(snowband_file, band_vars_to_read, band_coord)

    if (fs::file_exists(params_aligned_path)) {
      band_labels <- band_elevation_labels(params_aligned_path)
      band_daily <- band_daily %>%
        dplyr::left_join(band_labels, by = "band") %>%
        dplyr::mutate(band_label = ifelse(
          is.na(elev_m),
          glue("Band {band} (unused -- 0 area in this AOI)"),
          glue("Band {band} (~{round(elev_m)} m)")
        ))
    } else {
      message("No ", params_aligned_path, " found -- labeling bands by ",
              "number only, without elevation (run 05_build_domain.R if ",
              "you expected this file to exist).")
      band_daily <- band_daily %>% dplyr::mutate(band_label = glue("Band {band}"))
    }

    readr::write_csv(
      dplyr::select(band_daily, time, band, band_label, variable, value),
      fs::path(cfg$paths$output_dir, "aoi_snowband_daily.csv")
    )

    # band_label as a FACTOR ordered by band number (not alphabetical on
    # the "Band N (~X m)" string, which would sort "Band 10" before
    # "Band 2") -- matters once there are more than 9 bands; harmless
    # here with 5, but no reason to leave a latent sorting bug for a
    # bigger AOI later.
    band_daily <- band_daily %>%
      dplyr::mutate(band_label = factor(
        band_label, levels = unique(band_label[order(band)])
      ))

    p_band <- ggplot(band_daily, aes(time, value, color = band_label)) +
      geom_line() +
      facet_wrap(~band_label, scales = "free_y", ncol = 1) +
      labs(title = glue("{cfg$aoi$name} -- SWE by elevation band"),
           x = NULL, y = "SWE (mm)", color = NULL) +
      theme_minimal() +
      theme(legend.position = "none")

    p_band

    ggsave(fs::path(cfg$paths$output_dir, "aoi_snowband_daily.png"), p_band,
           width = 8, height = 4.5, dpi = 150)

    message("Wrote aoi_snowband_daily.csv and aoi_snowband_daily.png to ",
            cfg$paths$output_dir)
  } else {
    message("No ", snowband_file, " found -- skipping band_vars_to_read (",
            paste(band_vars_to_read, collapse = ", "), "). This requires ",
            "R/07_write_globalparam.R's explicit OUTVAR block (added ",
            "alongside OUT_PET) and a rerun of 08_run_vic.R -- if you ",
            "haven't done that yet since updating 07, that's why this is ",
            "being skipped rather than erroring.")
  }
}

