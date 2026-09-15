# ------------------------------------------------------------------------
# 06_run_metsim.R
#
# VIC5's image driver requires AIR_TEMP/PREC/PRESSURE/SWDOWN/LWDOWN/VP/WIND
# supplied directly -- confirmed from VIC's own 5.0.1 release notes, VIC5
# deliberately removed the old MTCLIM disaggregation that used to let it
# take Tmax/Tmin/Prec directly (both drivers, not just image). Livneh only
# gives us Prec/Tmax/Tmin/Wind, so those four have to be turned into the
# full set BEFORE VIC ever sees them. MetSim (github.com/UW-Hydro/MetSim)
# is UW-Hydro's own standalone replacement for the MTCLIM they removed --
# see setup/SETUP.md for how to install it.
#
# This also matters for driving VIC from LOCA2 later: LOCA2 (like most
# downscaled climate products) is Tmax/Tmin/Prec-only too, so this same
# MetSim step is the one you'd point at a different `forcing`/`domain`
# pair to switch sources, not something Livneh-specific.
#
# Two things confirmed empirically (not just from docs) while building
# this against the real AOI files, worth knowing if you're debugging:
#   1) MetSim's `state` file requirement of "90 days of t_min/t_max/prec
#      before start_date" is a hard assertion in metsim.py
#      (_aggregate_state(): `assert self.state.dims['time'] == 90`), not
#      a soft suggestion -- if 04_download_forcing.R hasn't grabbed enough
#      lead time, this script fails here, not silently produces bad data.
#   2) MetSim's `vapor_pressure` output is mislabeled with a "Pa" units
#      attribute, but the actual values are already kPa-scaled (checked
#      real magnitudes -- ~0.01-0.5 against VIC's required kPa, not
#      Pa-scale hundreds/thousands). We do NOT divide by 1000 -- doing so
#      would be WRONG despite what the attribute claims. We do overwrite
#      the attribute string itself below so it stops lying to the next
#      person who opens the file.
#
# MetSim also only ever writes ONE output file for the whole run period
# (despite what its docs say about `time_grouper` -- that option isn't
# actually wired up in metsim 2.4.4, confirmed by grepping its own
# source), never one-file-per-year like VIC's FORCING1 convention needs.
# So this script runs MetSim once for the full start_date..end_date
# window, then splits its single output into cfg$paths$metsim_forcing_dir/
# forcing.<YYYY>.nc files itself -- same per-calendar-year pattern as
# 04b, just one step later in the pipeline.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(ncdf4)
library(fs)
library(glue)
library(purrr)

forcing_glob <- fs::path(cfg$paths$raw_forcing_dir, "forcing.*.nc")
if (length(fs::dir_ls(cfg$paths$raw_forcing_dir, glob = "*forcing.*.nc")) == 0) {
  stop("No forcing.<YYYY>.nc files in ", cfg$paths$raw_forcing_dir, " -- run ",
       "04_download_forcing.R then 04b_build_forcing_netcdf.R first.")
}

domain_path <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")
if (!fs::file_exists(domain_path)) {
  stop("Missing ", domain_path, " -- run 05_build_domain.R first.")
}
# Sanity check domain has elev -- easy thing to have skipped if you're
# re-running 05 from before this script existed.
nc_dom <- nc_open(domain_path)
has_elev <- "elev" %in% names(nc_dom$var)
nc_close(nc_dom)
if (!has_elev) {
  stop(domain_path, " has no `elev` variable -- re-run 05_build_domain.R ",
       "(MetSim requires elevation for solar geometry calculations).")
}

python_bin <- cfg$paths$metsim_python
if (is.null(python_bin) || !fs::file_exists(python_bin)) {
  stop("config.yml's paths.metsim_python (", python_bin, ") doesn't exist. ",
       "Install MetSim first -- see setup/SETUP.md -- then point this at ",
       "the interpreter it's installed into.")
}
ms_bin <- fs::path(fs::path_dir(python_bin), "ms")   # `ms` CLI lives next to
                                                       # python in the same
                                                       # venv/env's bin/ dir
if (!fs::file_exists(ms_bin)) {
  stop("Expected MetSim's `ms` CLI at ", ms_bin, " (next to metsim_python) ",
       "but it's not there. Confirm MetSim installed cleanly: ",
       "`", python_bin, " -c 'import metsim; print(metsim.__version__)'`")
}

# Keyed on huc_id -- same AOI-caching bug pattern found and fixed
# elsewhere in this pipeline (04b's aoi_monthly subset dir, 11/12's
# routing_inputs_*.nc): a fixed "_metsim_raw_output" name here let the
# skip-check below (metsim_already_ran) match a DIFFERENT AOI's leftover
# MetSim output whenever the two AOIs happened to share the same
# run$start_date/end_date -- confirmed the hard way switching this repo's
# test AOI to gauge mode: 08_run_vic.R failed with a NetCDF
# "Start+count exceeds dimension bound" reading `temp`, because MetSim
# was silently skipped (this file already existed from an earlier,
# smaller-grid AOI) and the stale, wrong-grid forcing.<YYYY>.nc files got
# re-split from it, one grid size smaller than the AOI's actual
# domain.aoi.nc.
raw_out_dir <- fs::path(cfg$paths$metsim_forcing_dir,
                         glue("_metsim_raw_output_{cfg$aoi$huc_id}"))
fs::dir_create(raw_out_dir)
# Defined unconditionally (not just inside the !metsim_already_ran branch
# below) so it's always available -- including in error messages further
# down that reference it even on the skip-MetSim-run path.
log_path <- fs::path(cfg$paths$log_dir, glue("metsim_run_{format(Sys.time(), '%Y%m%dT%H%M%S')}.log"))
# MetSim names its output {prefix}_{startYYYYMMDD}-{stopYYYYMMDD}.nc -- if
# a file matching the CURRENT start/end dates is already there, skip
# re-running MetSim itself (the slow part) and go straight to splitting
# it into per-year files. Only clean out files that DON'T match (stale
# output from a previous, different date range).
expected_suffix <- glue("{format(cfg$run$start_date, '%Y%m%d')}-",
                         "{format(cfg$run$end_date, '%Y%m%d')}")
expected_out <- fs::path(raw_out_dir, glue("forcing_{expected_suffix}.nc"))
metsim_already_ran <- fs::file_exists(expected_out)

if (metsim_already_ran) {
  message("Already have MetSim output for this exact date range (",
          expected_out, ") -- skipping the MetSim run itself and going ",
          "straight to splitting it into per-year files. Delete that file ",
          "yourself first if you want to force a full MetSim re-run (e.g. ",
          "after changing metsim$time_step_min or metsim$prec_type in ",
          "config.yml, which this skip-check doesn't know to detect).")
  walk(setdiff(fs::dir_ls(raw_out_dir, glob = "*.nc"), expected_out), fs::file_delete)
} else {
  walk(fs::dir_ls(raw_out_dir, glob = "*.nc"), fs::file_delete)
}

if (!metsim_already_ran) {
  # [chunks] wants the domain's real lat/lon sizes -- chunking the WHOLE
  # domain in one go is fine at this AOI's size, not a knob worth exposing
  # for a single-HUC test run.
  nc_dom <- nc_open(domain_path)
  n_lat <- nc_dom$dim$lat$len
  n_lon <- nc_dom$dim$lon$len
  nc_close(nc_dom)

  config_path <- fs::path(cfg$paths$metsim_forcing_dir, "metsim_config.conf")
  config_text <- glue('
[MetSim]
out_vars = [\'temp\', \'prec\', \'shortwave\', \'longwave\', \'vapor_pressure\', \'air_pressure\', \'wind\']
time_step = {cfg$metsim$time_step_min}
start = {format(cfg$run$start_date, "%Y/%m/%d")}
stop = {format(cfg$run$end_date, "%Y/%m/%d")}

forcing = {forcing_glob}
domain  = {domain_path}
state   = {forcing_glob}
forcing_fmt = netcdf
in_format = netcdf

out_dir = {raw_out_dir}
out_prefix = forcing
prec_type = {cfg$metsim$prec_type}
utc_offset = False
calendar = {cfg$run$calendar}
method = mtclim

[chunks]
lat = {n_lat}
lon = {n_lon}

[forcing_vars]
prec  = Prec
t_max = Tmax
t_min = Tmin
wind  = Wind

[state_vars]
prec  = Prec
t_max = Tmax
t_min = Tmin

[domain_vars]
lat  = lat
lon  = lon
mask = mask
elev = elev
')

  writeLines(config_text, config_path)
  message("Wrote ", config_path)

  message("Running MetSim (this derives AIR_TEMP/SWDOWN/LWDOWN/VP/PRESSURE from ",
          "Tmax/Tmin/Prec/Wind -- can take a while for a full water year)...")
  message("  log: ", log_path)

  start_time <- Sys.time()
  status <- system2(
    ms_bin, c(config_path, "-s", "synchronous"),
    stdout = log_path, stderr = log_path
  )
  elapsed <- difftime(Sys.time(), start_time, units = "mins")

  if (status != 0) {
    stop(glue("MetSim exited with status {status} after {round(elapsed, 1)} min. ",
              "Check the log: {log_path}\n",
              "Common cause: fewer than metsim$state_days ({cfg$metsim$state_days}) ",
              "days of Tmax/Tmin/Prec available before start_date -- MetSim's ",
              "spin-up window requirement is a hard assertion, not a soft one. ",
              "Re-check 04_download_forcing.R actually pulled the extra months."))
  }
  message(glue("MetSim finished in {round(elapsed, 1)} min."))
}

# --- split MetSim's single combined output into one file per calendar year,
#     matching VIC's FORCING1 <prefix><YYYY>.nc convention (same pattern as
#     04b, just for MetSim's output instead of the raw Livneh files) ------
combined_files <- fs::dir_ls(raw_out_dir, glob = "*forcing_*.nc")
if (length(combined_files) != 1) {
  stop("Expected exactly 1 MetSim output file in ", raw_out_dir, ", found ",
       length(combined_files), ". Check ", log_path, " for what went wrong.")
}
combined_path <- combined_files[1]
message("MetSim output: ", combined_path)

nc_in <- nc_open(combined_path)
lat <- ncvar_get(nc_in, "lat")
lon <- ncvar_get(nc_in, "lon")
time_vals <- ncvar_get(nc_in, "time")
time_units <- ncatt_get(nc_in, "time", "units")$value
# MetSim writes "minutes since 2000-01-01 00:00:00.0" -- parse generically
# rather than assuming that exact string.
origin_str <- sub("^\\w+ since ", "", time_units)
origin_str <- sub("\\.\\d+$", "", origin_str)   # strip trailing fractional
                                              # seconds (e.g. "...00.0"),
                                              # which R's default POSIXct
                                              # parsing isn't guaranteed to
                                              # handle
unit_word <- tolower(strsplit(time_units, " ")[[1]][1])
origin <- as.POSIXct(origin_str, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
if (is.na(origin)) {
  stop("Couldn't parse MetSim output's time units (\"", time_units, "\") -- ",
       "expected something like \"minutes since 2000-01-01 00:00:00\".")
}
mult <- switch(unit_word, seconds = 1, minutes = 60, hours = 3600, days = 86400,
               stop("Unrecognized time unit in MetSim output: ", time_units))
time_posix <- origin + time_vals * mult
years <- format(time_posix, "%Y")

out_vars <- c("temp", "prec", "shortwave", "longwave", "vapor_pressure", "air_pressure", "wind")
var_units <- map_chr(out_vars, function(v) ncatt_get(nc_in, v, "units")$value)
names(var_units) <- out_vars
# Fix MetSim's mislabeled vapor_pressure attribute -- values are already
# kPa (confirmed empirically), the attribute just wrongly says "Pa".
var_units["vapor_pressure"] <- "kPa"

for (yr in unique(years)) {
  idx <- which(years == yr)
  out_path <- fs::path(cfg$paths$metsim_forcing_dir, glue("forcing.{yr}.nc"))

  dim_lon  <- ncdim_def("lon", "degrees_east", lon)
  dim_lat  <- ncdim_def("lat", "degrees_north", lat)
  yr_origin <- glue("seconds since {yr}-01-01 00:00:00")
  yr_time_secs <- as.numeric(difftime(time_posix[idx],
                                       as.POSIXct(glue("{yr}-01-01 00:00:00"), tz = "UTC"),
                                       units = "secs"))
  dim_time <- ncdim_def("time", yr_origin, yr_time_secs)

  ncvars <- map(out_vars, function(v) {
    ncvar_def(v, var_units[[v]], list(dim_lon, dim_lat, dim_time), 1e20, prec = "float")
  })
  names(ncvars) <- out_vars

  nc_out <- nc_create(out_path, ncvars)
  # VIC's image driver hard-requires a `calendar` attribute on the time
  # variable (get_nc_var_attr.c errors with "Attribute not found" if it's
  # missing) -- ncdim_def() only sets `units`, not `calendar`, so this has
  # to be added explicitly. Use the same calendar declared in config.yml
  # (also what we told MetSim to use for this same run).
  ncatt_put(nc_out, "time", "calendar", cfg$run$calendar)
  for (v in out_vars) {
    # MetSim's on-disk (CDL) declared dim order is (time, lat, lon), but
    # ncdf4's ncvar_get() with explicit start/count returns the array in
    # the SAME order as the start/count VECTOR you pass in -- confirmed
    # empirically from the actual error this produced (the reported "got"
    # shape exactly matched the (lon, lat, time) count vector below, not
    # the file's declared (time, lat, lon) order). So: no aperm() needed --
    # requesting start/count as (lon, lat, time) hands back an array
    # already in (lon, lat, time) order, which is exactly what ncvar_put()
    # wants given ncvar_def()'s dim list of (dim_lon, dim_lat, dim_time).
    arr <- ncvar_get(nc_in, v, start = c(1, 1, min(idx)),
                      count = c(length(lon), length(lat), length(idx)))
    if (!identical(dim(arr), c(length(lon), length(lat), length(idx)))) {
      stop("Read back the wrong shape for ", v, " (year ", yr, "): got ",
           paste(dim(arr), collapse = "x"), ", expected ",
           length(lon), "x", length(lat), "x", length(idx), " (lon x lat x ",
           "time). ncdf4's start/count ordering quirk again -- check this ",
           "against a fresh `ncvar_get(nc_in, \"", v, "\")` with no start/",
           "count to see what order it actually comes back in.")
    }
    ncvar_put(nc_out, ncvars[[v]], arr)
  }
  nc_close(nc_out)
  message("  wrote ", out_path, " (", length(idx), " timesteps)")
}
nc_close(nc_in)

message("Done. VIC-ready forcing is in ", cfg$paths$metsim_forcing_dir,
        ". Next: 07_write_globalparam.R.")
