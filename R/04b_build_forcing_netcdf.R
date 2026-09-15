# ------------------------------------------------------------------------
# 04b_build_forcing_netcdf.R
#
# Subsets each full-CONUS monthly forcing file from 04_download_forcing.R
# to the AOI bbox, then concatenates months into one NetCDF per calendar
# year (VIC's image driver FORCING1 convention: <prefix><YYYY>.nc).
#
# Variable names in the source files are "Prec"/"Tmax"/"Tmin"/"Wind"
# (confirmed by inspecting a downloaded file directly -- NOT "prcp" etc.
# as originally guessed). 06_run_metsim.R's [forcing_vars]/[state_vars]
# mappings must match this -- these files are MetSim's INPUT now, not
# read by VIC directly (see 06_run_metsim.R's header comment for why).
#
# Outputs: cfg$paths$raw_forcing_dir/forcing.<YYYY>.nc, one per calendar
# year touched by the run window. Since 04_download_forcing.R now also
# grabs metsim$state_days of extra months before start_date (for MetSim's
# spin-up window -- see 06_run_metsim.R), whichever year(s) that spin-up
# window falls in will have MORE days in it than just the run window.
# That's fine -- these files are MetSim's INPUT now, not VIC's directly;
# MetSim slices out exactly the days it needs itself.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(ncdf4)
library(fs)
library(glue)
library(purrr)
library(dplyr)
library(stringr)
library(lubridate)
# abind is used via abind::abind() below for stacking months along the
# time axis -- install.packages("abind") if you don't have it.

bbox <- readRDS(fs::path(cfg$paths$aoi_dir, "aoi_bbox.rds"))

monthly_files <- fs::dir_ls(cfg$paths$raw_forcing_dir, glob = "*Meteorology_Livneh*.nc")
if (length(monthly_files) == 0) {
  stop("No monthly forcing files found in ", cfg$paths$raw_forcing_dir,
       " -- run 04_download_forcing.R first.")
}

# Keyed on huc_id, NOT just "aoi_monthly" -- raw_forcing_dir's raw
# monthly downloads are legitimately shared across AOIs (full-CONUS,
# not yet subset), but the AOI-SUBSET files most definitely are not.
# Found this the hard way: testing a second (smaller) AOI in the same
# checkout silently reused stale subset files left over from the first
# AOI's bbox for any calendar month the two runs' windows happened to
# overlap, because the cache directory used to be shared across AOIs.
# Keying it on huc_id makes that collision impossible instead of just
# remembering to clear a shared cache by hand.
subset_dir <- fs::path(cfg$paths$raw_forcing_dir,
                        glue("aoi_monthly_{cfg$aoi$huc_id}"))
fs::dir_create(subset_dir)

vars <- c("Prec", "Tmax", "Tmin", "Wind")

# --- subset each month to the AOI bbox -----------------------------------
subset_one <- function(path) {
  out_path <- fs::path(subset_dir, fs::path_file(path))
  if (fs::file_exists(out_path)) {
    message("  already subset: ", fs::path_file(path))
    return(out_path)
  }

  nc_in <- nc_open(path)
  lat <- ncvar_get(nc_in, "lat")
  lon <- ncvar_get(nc_in, "lon")
  lat_idx <- which(lat >= bbox["ymin"] & lat <= bbox["ymax"])
  lon_idx <- which(lon >= bbox["xmin"] & lon <= bbox["xmax"])
  stopifnot(length(lat_idx) > 0, length(lon_idx) > 0)

  sub_lat <- lat[lat_idx]
  sub_lon <- lon[lon_idx]
  time_vals <- ncvar_get(nc_in, "time")
  time_units <- ncatt_get(nc_in, "time", "units")$value

  dim_lon  <- ncdim_def("lon", "degrees_east", sub_lon)
  dim_lat  <- ncdim_def("lat", "degrees_north", sub_lat)
  dim_time <- ncdim_def("time", time_units, time_vals, unlim = FALSE)

  ncvars <- map(vars, function(v) {
    units <- ncatt_get(nc_in, v, "units")$value
    longname <- ncatt_get(nc_in, v, "long_name")$value
    ncvar_def(v, units, list(dim_lon, dim_lat, dim_time), 1e20,
              longname = longname, prec = "float")
  })
  names(ncvars) <- vars

  nc_out <- nc_create(out_path, ncvars)
  for (v in vars) {
    data <- ncvar_get(nc_in, v,
                       start = c(min(lon_idx), min(lat_idx), 1),
                       count = c(length(lon_idx), length(lat_idx), -1))
    ncvar_put(nc_out, ncvars[[v]], data)
  }
  nc_close(nc_out)
  nc_close(nc_in)
  message("  subset: ", fs::path_file(path), " -> ",
          length(sub_lat), " x ", length(sub_lon))
  out_path
}

subset_paths <- map_chr(monthly_files, subset_one)

# --- concatenate months into one file per calendar year -------------------
# No NCO (ncrcat) dependency -- read+recombine directly with ncdf4/base R,
# same approach validated against a real download before this script was
# written (see chat history / commit message for the residual check).
month_years <- str_extract(fs::path_file(subset_paths), "\\d{6}") |> substr(1, 4)

walk(unique(month_years), function(yr) {
  out_path <- fs::path(cfg$paths$raw_forcing_dir, glue("forcing.{yr}.nc"))
  # NOTE: always rebuilds, even if out_path already exists -- deliberately
  # NOT skip-if-exists. This bit us in practice: after extending
  # 04_download_forcing.R's window (metsim$state_days), a stale
  # forcing.<YYYY>.nc from an earlier, narrower download would otherwise
  # silently stick around forever, missing the new months, since the set
  # of source months feeding a given year's file can change between runs
  # even though the year itself hasn't. Rebuilding from the current
  # aoi_monthly/ files is cheap, so there's no real cost to always doing it.
  if (fs::file_exists(out_path)) fs::file_delete(out_path)

  yr_paths <- sort(subset_paths[month_years == yr])
  first <- nc_open(yr_paths[1])
  lat <- ncvar_get(first, "lat")
  lon <- ncvar_get(first, "lon")
  nc_close(first)

  all_time <- c()
  time_units_base <- NULL
  data_by_var <- setNames(vector("list", length(vars)), vars)

  for (p in yr_paths) {
    nc_in <- nc_open(p)
    t <- ncvar_get(nc_in, "time")
    tu <- ncatt_get(nc_in, "time", "units")$value
    if (is.null(time_units_base)) time_units_base <- tu
    # times are "seconds since <that month's 1st>" per file -- convert to a
    # single consistent axis, seconds since the year's Jan 1.
    origin <- as.POSIXct(sub("seconds since ", "", tu, fixed = TRUE), tz = "UTC")
    year_origin <- as.POSIXct(glue("{yr}-01-01 00:00:00"), tz = "UTC")
    offset <- as.numeric(difftime(origin, year_origin, units = "secs"))
    all_time <- c(all_time, t + offset)
    for (v in vars) {
      arr <- ncvar_get(nc_in, v)  # (lon, lat, time)
      data_by_var[[v]] <- if (is.null(data_by_var[[v]])) arr else
        abind::abind(data_by_var[[v]], arr, along = 3)
    }
    nc_close(nc_in)
  }

  dim_lon  <- ncdim_def("lon", "degrees_east", lon)
  dim_lat  <- ncdim_def("lat", "degrees_north", lat)
  dim_time <- ncdim_def("time", glue("seconds since {yr}-01-01 00:00:00"), all_time)

  ncvars <- map(vars, ~ ncvar_def(.x, "1", list(dim_lon, dim_lat, dim_time), 1e20, prec = "float"))
  names(ncvars) <- vars
  nc_out <- nc_create(out_path, ncvars)
  for (v in vars) ncvar_put(nc_out, ncvars[[v]], data_by_var[[v]])
  nc_close(nc_out)
  message("wrote ", out_path, " (", length(yr_paths), " months, ",
          length(all_time), " days)")
})

message("Done. Forcing files matching global_param.txt's FORCING1 prefix ",
        "are in ", cfg$paths$raw_forcing_dir)

