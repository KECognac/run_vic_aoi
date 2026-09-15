# ------------------------------------------------------------------------
# 05_build_domain.R
#
# 1) Aligns the converted params NetCDF (03's output, already AOI-sized --
#    02b subset the ASCII inputs before conversion, so there's no
#    CONUS-wide file left to subset here) onto the forcing grid's EXACT
#    coordinates, by shelling out to python/align_params_to_forcing.py.
#    This matters: Tonic's own grid-building step (calc_grid(), inside
#    03) introduces tiny floating-point drift in the params grid's
#    lat/lon spacing, which left one spurious fully-masked row/column that
#    don't exist in the forcing grid. VIC's image driver requires DOMAIN,
#    PARAMS, and FORCING to share identical coordinates, so this has to be
#    reconciled before writing domain.nc -- confirmed empirically (not
#    guessed): every forcing grid cell lands on an active params cell
#    after snapping, with ~0.003 deg residual (floating-point noise, not a
#    real spatial offset). See align_params_to_forcing.py's docstring.
# 2) Builds domain.nc (lat, lon, mask, area, frac, elev) from the
#    now-aligned params grid. `elev` is here for MetSim (06_run_metsim.R),
#    not VIC itself -- MetSim's domain file requires it for solar geometry
#    calculations ("It is important to ensure that all valid locations in
#    mask have data in elev" -- MetSim's own docs). Harmless extra
#    variable as far as VIC's own DOMAIN_TYPE lines are concerned, since
#    those only reference lat/lon/mask/area/frac.
#
# global_param.txt is NOT written here -- see 07_write_globalparam.R. It
# has to come after 06_run_metsim.R, because its FORCING1/FORCE_TYPE lines
# point at MetSim's output, not the raw Prec/Tmax/Tmin/Wind files.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(ncdf4)
library(fs)
library(glue)

params_in <- fs::path(cfg$paths$params_nc_dir, "params.vic5.nc")
if (!fs::file_exists(params_in)) {
  stop("Missing ", params_in, " -- run 03_convert_params_to_netcdf.R first.")
}

# Any one forcing file works as the alignment reference -- they all share
# the same lat/lon grid, only time differs.
forcing_files <- fs::dir_ls(cfg$paths$raw_forcing_dir, glob = "*forcing.*.nc")
if (length(forcing_files) == 0) {
  stop("No forcing.<YYYY>.nc files in ", cfg$paths$raw_forcing_dir,
       " -- run 04_download_forcing.R then 04b_build_forcing_netcdf.R first.")
}
forcing_ref <- forcing_files[1]

params_aligned <- fs::path(cfg$paths$domain_dir, "params.aligned.nc")
domain_out <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")

python_bin <- cfg$paths$tonic_python
if (is.null(python_bin) || !fs::file_exists(python_bin)) {
  python_bin <- Sys.which("python3")
}
status <- system2(python_bin, c(
  "python/align_params_to_forcing.py",
  "--params-in", params_in,
  "--forcing-ref", forcing_ref,
  "--out", params_aligned
))
if (status != 0) stop("align_params_to_forcing.py failed (status ", status, ")")

# --- build domain.nc from the now-aligned params ---------------------------
nc_p <- nc_open(params_aligned)
lat <- ncvar_get(nc_p, "lat")
lon <- ncvar_get(nc_p, "lon")
run_cell <- ncvar_get(nc_p, "run_cell")
elev <- ncvar_get(nc_p, "elev")
nc_close(nc_p)

mask <- run_cell
mask[is.na(mask)] <- 0
mask[mask != 0] <- 1
storage.mode(mask) <- "integer"

if (any(mask == 0)) {
  warning(sum(mask == 0), " of ", length(mask), " AOI grid cells have no ",
          "valid soil parameters after aligning to the forcing grid -- ",
          "those cells will be excluded from the run. Expected to be 0 for ",
          "the Poudre test AOI (confirmed when this script was written); if ",
          "you're running a different AOI and see a nonzero count here, ",
          "it's worth understanding why before trusting results.")
}

# Approximate cell area on a lat/lon grid -- good enough for a test run;
# revisit with a proper equal-area calc before using this for anything
# published.
res_deg <- abs(diff(lat))[1]
m_per_deg_lat <- 111320
area <- outer(rep(1, length(lon)), cos(lat * pi / 180)) *
  (res_deg * m_per_deg_lat) * (res_deg * m_per_deg_lat)

dim_lon <- ncdim_def("lon", "degrees_east", lon)
dim_lat <- ncdim_def("lat", "degrees_north", lat)

# Integer NetCDF variables can't use NA/NaN as a _FillValue (that's only
# defined for double/float types in netCDF4) -- ncdf4::ncvar_def() will
# error trying to write it. mask has a value (0 or 1) at every grid cell
# with no missing entries, so it doesn't need a fill value at all.
v_mask <- ncvar_def("mask", "1", list(dim_lon, dim_lat), missval = NULL,
                     prec = "integer", longname = "domain mask")
v_area <- ncvar_def("area", "m2", list(dim_lon, dim_lat), NA, prec = "double",
                     longname = "area of grid cell")
v_frac <- ncvar_def("frac", "1", list(dim_lon, dim_lat), NA, prec = "double",
                     longname = "fraction of grid cell that is land")
v_elev <- ncvar_def("elev", "m", list(dim_lon, dim_lat), NA, prec = "double",
                     longname = "elevation (for MetSim solar geometry -- not read by VIC)")

nc_out <- nc_create(domain_out, list(v_mask, v_area, v_frac, v_elev))
ncvar_put(nc_out, v_mask, t(mask))
ncvar_put(nc_out, v_area, t(area))
ncvar_put(nc_out, v_frac, t(mask))
ncvar_put(nc_out, v_elev, t(elev))
ncatt_put(nc_out, 0, "title", glue("VIC domain file -- {cfg$aoi$name} ({cfg$aoi$descriptor})"))
ncatt_put(nc_out, 0, "Conventions", "CF-1.6")
nc_close(nc_out)
message("Wrote ", domain_out)
message("Next: 06_run_metsim.R (derives full VIC forcing from Tmax/Tmin/Prec/Wind), ",
        "then 07_write_globalparam.R.")
