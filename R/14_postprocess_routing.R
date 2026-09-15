# ------------------------------------------------------------------------
# 14_postprocess_routing.R
#
# Reads RVIC's routed streamflow at this AOI's pour point (13's output),
# writes a CSV, and plots it -- optionally overlaid with observed USGS
# discharge at the same gauge (config.yml's routing.observed_gauge_site_no,
# if set) as a sanity check.
#
# IMPORTANT: this VIC run is naturalized -- no irrigation diversions,
# trans-basin imports, or reservoir operations are modeled. Even when the
# pour point's drainage area is a near-exact match for the AOI's own area
# (i.e. it's essentially the AOI's own outlet, not an interior gauge --
# see config.yml's routing comment for how to check this), observed flow
# there still reflects all of those human alterations, so it will NOT
# match simulated flow 1:1. Treat the overlay as a check on timing/shape
# (does simulated flow rise and recede when observed flow does?), not a
# validation of absolute volume.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)
library(ncdf4)
library(dplyr)
library(purrr)
library(readr)
library(ggplot2)

# Must match 13_run_rvic_convolution.R's own caseid construction exactly
# (huc_id-keyed -- same AOI-caching bug pattern as 12/13's params caseid).
caseid <- glue("{tolower(gsub('[^A-Za-z0-9]+', '_', cfg$aoi$name))}_{cfg$aoi$huc_id}_convolution")
case_dir <- fs::path(cfg$paths$routing_dir, "cases", caseid)
marker_path <- fs::path(case_dir, "latest_hist_files.txt")

if (!fs::file_exists(marker_path)) {
  stop("Missing ", marker_path, " -- run 13_run_rvic_convolution.R first.")
}
hist_files <- readLines(marker_path)
hist_files <- hist_files[fs::file_exists(hist_files)]
if (length(hist_files) == 0) {
  stop("13_run_rvic_convolution.R's marker file lists no files that still ",
       "exist -- rerun 13_run_rvic_convolution.R.")
}

# RVIC's history variable is normally named "streamflow", but this isn't
# guaranteed across versions -- search rather than hardcode, and exclude
# the routing-grid variables (Flow_Direction/Flow_Distance) by name so a
# stray match there can't get picked up by mistake.
find_flow_var <- function(nc, f) {
  candidates <- names(nc$var)
  if ("streamflow" %in% candidates) return("streamflow")
  hit <- candidates[
    grepl("flow|discharge", candidates, ignore.case = TRUE) &
    !grepl("direction|distance", candidates, ignore.case = TRUE)
  ]
  if (length(hit) == 0) {
    stop("No flow-like variable found in ", f, ". Variables present: ",
         paste(candidates, collapse = ", "))
  }
  hit[1]
}

read_one <- function(f) {
  nc <- nc_open(f)
  on.exit(nc_close(nc), add = TRUE)

  flow_var <- find_flow_var(nc, f)
  message("Reading '", flow_var, "' from ", fs::path_file(f))

  time_vals <- as.vector(ncvar_get(nc, "time"))  # as.vector() strips a stray
                                                   # dim attribute -- same fix
                                                   # needed in 09_postprocess.
  time_units <- ncatt_get(nc, "time", "units")$value
  origin_str <- sub("^\\w+ since ", "", time_units)
  origin_str <- sub(" .*$", "", origin_str)
  unit_word <- tolower(strsplit(time_units, " ")[[1]][1])
  mult <- switch(unit_word,
                  seconds = 1 / 86400, minutes = 1 / 1440, hours = 1 / 24,
                  days = 1,
                  stop("Unrecognized time unit '", unit_word, "' in ", f))
  dates <- as.Date(time_vals * mult, origin = origin_str)

  arr <- ncvar_get(nc, flow_var)
  if (is.null(dim(arr)) || length(dim(arr)) == 1) {
    flow <- as.vector(arr)
  } else {
    # With one pour point, this is (time x outlets) or (outlets x time)
    # depending on ncdf4's read-order reversal -- match by LENGTH against
    # the time vector rather than assuming a fixed axis position.
    time_axis <- which(dim(arr) == length(dates))
    if (length(time_axis) == 0) {
      stop("Could not match '", flow_var, "' dims (",
           paste(dim(arr), collapse = "x"), ") to time length ",
           length(dates), " in ", f)
    }
    flow <- apply(arr, time_axis[1], function(x) x[1])
  }

  if (length(flow) != length(dates)) {
    stop("Length mismatch reading ", f, ": ", length(flow),
         " flow values vs ", length(dates), " time values.")
  }

  data.frame(date = dates, streamflow_cms = as.numeric(flow))
}

routed <- purrr::map_dfr(hist_files, read_one) |>
  dplyr::distinct(date, .keep_all = TRUE) |>
  dplyr::arrange(date)

out_csv <- fs::path(cfg$paths$output_dir, "routed_streamflow.csv")
readr::write_csv(routed, out_csv)
readr::write_csv(routed, "/Users/kcognac/Library/CloudStorage/OneDrive-SharedLibraries-Colostate/WCNR NPS-CSU-DRI - Documents/Water for People (WFP)/data/park/MORA/vic/routed_streamflow.csv")
message("Wrote ", out_csv, " (", nrow(routed), " days)")

# --- optional observed-discharge overlay (sanity check only -- see the
#     naturalized-flow caveat at the top of this file) ---
site_no <- cfg$routing$observed_gauge_site_no
CFS_PER_CMS <- 35.3147

obs <- NULL
if (is.null(site_no) || site_no %in% c("", "EDIT_ME")) {
  message("config.yml's routing.observed_gauge_site_no is not set -- ",
          "skipping the observed-flow overlay (set it to the USGS site ",
          "number matching routing/pour_points.csv's gauge to enable it).")
} else if (requireNamespace("dataRetrieval", quietly = TRUE)) {
  message("Fetching observed discharge for USGS ", site_no,
          " via dataRetrieval...")
  obs_raw <- tryCatch(
    dataRetrieval::readNWISdv(
      siteNumbers = site_no, parameterCd = "00060",
      startDate = format(cfg$run$start_date, "%Y-%m-%d"),
      endDate = format(cfg$run$end_date, "%Y-%m-%d")
    ),
    error = function(e) {
      message("Could not fetch observed USGS data (", conditionMessage(e),
              ") -- continuing with simulated-only plot.")
      NULL
    }
  )
  flow_col <- "X_00060_00003"
  if (!is.null(obs_raw) && nrow(obs_raw) > 0 && flow_col %in% names(obs_raw)) {
    obs <- obs_raw |>
      dplyr::transmute(date = Date, observed_cms = .data[[flow_col]] / CFS_PER_CMS)
  } else if (!is.null(obs_raw)) {
    message("dataRetrieval returned data but not the expected column '",
            flow_col, "' -- columns present: ",
            paste(names(obs_raw), collapse = ", "),
            ". Skipping observed overlay.")
  } else {
    message("No observed data returned for ", site_no, " over the run period.")
  }
} else {
  message("dataRetrieval package not installed -- skipping observed-flow ",
          "overlay (install.packages('dataRetrieval') to enable it).")
}

plot_df <- routed |>
  dplyr::rename(time = date) |>
  dplyr::mutate(series = "VIC/RVIC simulated (naturalized)")

if (!is.null(obs)) {
  obs_df <- obs |>
    dplyr::rename(time = date, streamflow_cms = observed_cms) |>
    dplyr::mutate(series = glue("USGS observed ({site_no})"))
  plot_df <- dplyr::bind_rows(plot_df, obs_df)

  out_csv_obs <- fs::path(cfg$paths$output_dir, "observed_streamflow.csv")
  readr::write_csv(obs, out_csv_obs)
  message("Wrote ", out_csv_obs, " (", nrow(obs), " days)")
}

p <- ggplot2::ggplot(plot_df, ggplot2::aes(time, streamflow_cms, color = series)) +
  ggplot2::geom_line(linewidth = 0.7) +
  ggplot2::labs(
    title = if (!is.null(site_no) && !site_no %in% c("", "EDIT_ME")) {
      glue("Routed streamflow near {cfg$aoi$name} (vs. USGS {site_no})")
    } else {
      glue("Routed streamflow near {cfg$aoi$name}")
    },
    subtitle = paste(
      "Simulated flow is NATURALIZED (no irrigation diversions, trans-basin",
      "imports, or reservoir ops modeled) -- it will not match observed 1:1"
    ),
    x = NULL, y = "Streamflow (m³/s)", color = NULL
  ) +
  ggplot2::theme_minimal() +
  ggplot2::theme(legend.position = "bottom")

out_png <- fs::path(cfg$paths$output_dir, "routed_streamflow.png")
ggplot2::ggsave(out_png, p, width = 9, height = 5, dpi = 150)
message("Wrote ", out_png)

message("")
message("CAVEAT: this VIC run is naturalized -- it does not model irrigation ",
        "diversions, trans-basin imports, or reservoir operations that may ",
        "affect this basin. Observed flow at this gauge reflects all of ",
        "those (if present here), so don't expect the two lines to match ",
        "day-to-day, or even in overall magnitude -- use this comparison ",
        "to check timing/shape (does simulated flow rise and recede when ",
        "observed flow does?), not absolute volume.")
message("Done. Routing pipeline (scripts 01-14) complete for this AOI.")
