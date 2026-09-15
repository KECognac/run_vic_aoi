# ------------------------------------------------------------------------
# 09b_plot_gridded_maps.R
#
# Plots the PERIOD-OF-RECORD MEAN of one or more VIC output variables as
# a spatial map (one value per grid cell) -- the opposite aggregation
# from 09_postprocess_outputs.R's read_vic_daily_means(), which collapses
# (lat, lon) to one AOI-wide number per day and keeps time. This collapses
# time (mean over the whole run$start_date..end_date window) and keeps
# (lat, lon).
#
# Scope: any (time, lat, lon) variable from fluxes.<startdate>.nc or
# snow.<startdate>.nc -- see 09_postprocess_outputs.R's header comment for
# the full default variable list in each file. Does NOT support
# OUT_SOIL_LIQ or any *_BAND variable (both have an extra nlayer/snow_band
# dimension beyond time/lat/lon, which would need its own per-layer/
# per-band map, not a single grid -- see 09's own header comment for why
# those need separate handling; out of scope here).
#
# Grid cells outside domain.aoi.nc's own "mask" (1 = active VIC cell, 0 =
# inactive) are set to NA before plotting, so the map only colors real
# basin cells, not the padded bounding-box rectangle around them.
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
library(sf)

start_str <- format(cfg$run$start_date, "%Y-%m-%d")
fluxes_file   <- fs::path(cfg$paths$output_dir, glue("fluxes.{start_str}.nc"))
snow_file     <- fs::path(cfg$paths$output_dir, glue("snow.{start_str}.nc"))
domain_file   <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")
boundary_file <- fs::path(cfg$paths$aoi_dir, "huc_boundary.geojson")

if (!fs::file_exists(fluxes_file)) {
  stop("No ", fluxes_file, " found -- did 08_run_vic.R succeed? (VIC names ",
       "its output files after run$start_date -- rerun 08 if you changed ",
       "that in config.yml since the last VIC run.)")
}
if (!fs::file_exists(domain_file)) {
  stop("Missing ", domain_file, " -- run 05_build_domain.R first.")
}

# EDIT ME: any (time, lat, lon) variable from fluxes.<startdate>.nc or
# snow.<startdate>.nc (see this script's header comment above for scope).
vars_to_map <- c("OUT_RUNOFF", "OUT_BASEFLOW", "OUT_EVAP", "OUT_PET", "OUT_SWE")

message("Reading domain grid from ", domain_file)
nc_dom <- nc_open(domain_file)
lat <- as.vector(ncvar_get(nc_dom, "lat"))
lon <- as.vector(ncvar_get(nc_dom, "lon"))
mask_arr <- ncvar_get(nc_dom, "mask")   # 1 = active VIC cell, 0 = inactive
nc_close(nc_dom)

# ncdf4 returns this 2-D (lat, lon)-declared variable as an R array
# shaped (lon, lat) -- confirmed directly against this AOI's own real
# domain.aoi.nc (same "declared order reversed" convention already
# established for the 3-D fluxes/snow variables in
# 09_postprocess_outputs.R's read_vic_daily_means()) -- not assumed, and
# checked again below for every variable this script actually reads,
# since a silently wrong axis pick here would produce a plausible-looking
# but WRONG map, not an obvious crash.
if (!identical(dim(mask_arr), c(length(lon), length(lat)))) {
  stop("domain.aoi.nc's 'mask' came back with dims ",
       paste(dim(mask_arr), collapse = "x"), ", expected ",
       length(lon), "x", length(lat), " (lon x lat) -- inspect this ",
       "file's actual variable shapes before trusting this script.")
}

# Period-of-record mean per grid cell, for one (time, lat, lon) variable.
# Reads whichever of fluxes.nc/snow.nc actually has it (same two-file
# scope as 09_postprocess_outputs.R).
period_mean_grid <- function(v) {
  for (f in c(fluxes_file, snow_file)) {
    if (!fs::file_exists(f)) next
    nc <- nc_open(f)
    on.exit(nc_close(nc), add = TRUE)
    if (!(v %in% names(nc$var))) next

    arr <- ncvar_get(nc, v)
    n_time <- nc$dim[["time"]]$len
    if (!identical(dim(arr), c(length(lon), length(lat), n_time))) {
      stop("'", v, "' in ", f, " came back with dims ",
           paste(dim(arr), collapse = "x"), ", expected ",
           length(lon), "x", length(lat), "x", n_time,
           " (lon x lat x time) -- inspect this variable's actual shape ",
           "before trusting this script (this most likely means '", v,
           "' isn't a plain (time, lat, lon) variable -- see this ",
           "script's header comment on scope).")
    }
    return(apply(arr, c(1, 2), mean, na.rm = TRUE))   # (lon, lat)
  }
  stop("'", v, "' not found in ", fluxes_file,
       if (fs::file_exists(snow_file)) paste0(" or ", snow_file) else "",
       ".")
}

boundary <- NULL
if (fs::file_exists(boundary_file)) {
  message("Overlaying watershed boundary from ", boundary_file)
  boundary <- sf::read_sf(boundary_file)
} else {
  message("No ", boundary_file, " found -- plotting the grid without a ",
          "watershed outline (run 01_get_aoi_boundary.R if you expected ",
          "this file to exist).")
}

all_grids <- purrr::map_dfr(vars_to_map, function(v) {
  message("Computing period-of-record mean for ", v, "...")
  grid <- period_mean_grid(v)
  grid[mask_arr == 0] <- NA
  # expand.grid()'s first argument (lon) varies fastest, matching how
  # as.vector() flattens an R array (column-major, first dim fastest) --
  # same pairing already validated in 09_postprocess_outputs.R's
  # read_vic_band_means() for its own expand.grid()+as.vector() use.
  df <- expand.grid(lon = lon, lat = lat)
  df$value <- as.vector(grid)
  df$variable <- v
  df
})

readr::write_csv(all_grids, fs::path(cfg$paths$output_dir, "aoi_gridded_period_mean.csv"))
message("Wrote ", fs::path(cfg$paths$output_dir, "aoi_gridded_period_mean.csv"))

# One map per variable, not one faceted plot -- vars_to_map can mix very
# different units (mm/day water-balance terms vs mm SWE), and unlike
# facet_wrap's free y-axis scales, facet_wrap can't give each panel its
# own independent FILL color scale -- separate plots is the correct
# equivalent here (same reasoning as 09's free_y facets, different fix).
plot_one_var <- function(v) {
  d <- dplyr::filter(all_grids, variable == v)

  p <- ggplot(d, aes(lon, lat, fill = value)) +
    geom_raster() +
    scale_fill_viridis_c(na.value = "transparent") +
    coord_sf(crs = 4326) +
    labs(title = glue("{cfg$aoi$name} -- {v} (period-of-record mean, ",
                       "{format(cfg$run$start_date, '%Y')}-",
                       "{format(cfg$run$end_date, '%Y')})"),
         x = NULL, y = NULL, fill = v) +
    theme_minimal()

  if (!is.null(boundary)) {
    p <- p + geom_sf(data = boundary, fill = NA, color = "black",
                      linewidth = 0.6, inherit.aes = FALSE)
  }

  out_path <- fs::path(cfg$paths$output_dir,
                        glue("aoi_gridded_{tolower(v)}.png"))
  ggsave(out_path, p, width = 6, height = 5, dpi = 150)
  message("Wrote ", out_path)
}

purrr::walk(vars_to_map, plot_one_var)

message("Done. Period-of-record gridded mean map(s) + ",
        "aoi_gridded_period_mean.csv written to ", cfg$paths$output_dir)

