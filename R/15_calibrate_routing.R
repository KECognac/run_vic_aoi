# ------------------------------------------------------------------------
# 15_calibrate_routing.R
#
# Grid-search calibration of RVIC's routing parameters (VELOCITY,
# DIFFUSION -- see config.yml's routing section) against observed
# discharge at the AOI's pour point gauge. Optional and separate from
# the main 01-14 pipeline on purpose: it reruns 12_run_rvic_parameters.R
# and 13_run_rvic_convolution.R once per (velocity, diffusion)
# combination below, which is comparatively cheap (routing-only, no VIC
# rerun) but still adds up -- skip this script entirely if you're happy
# with config.yml's current velocity/diffusion values; nothing else in
# the pipeline depends on it having been run.
#
# Scores each combination with Kling-Gupta Efficiency (KGE, Gupta et
# al. 2009) against observed daily discharge (config.yml's
# routing.observed_gauge_site_no), plus the day-lag that maximizes
# cross-correlation between simulated and observed flow -- KGE alone
# tells you HOW WELL a combination fits, the lag tells you WHICH WAY to
# move velocity to fix a timing mismatch (a POSITIVE lag means
# simulated flow is DELAYED relative to observed => RAISE velocity; a
# NEGATIVE lag means simulated flow arrives too EARLY => LOWER velocity
# -- confirmed empirically with a synthetic delayed series before
# writing this, not just derived from ccf()'s documentation). KGE's own
# three components (r, alpha, beta -- see kge() below) also separate
# correlation/timing (r, closest to what velocity controls) from
# variability/peak-sharpness (alpha, closest to what diffusion
# controls) and volume bias (beta, mostly a VIC land-surface question,
# not much affected by either routing parameter) -- worth looking at
# all three, not just the blended KGE score, when deciding which
# parameter to adjust next.
#
# CAVEAT (see 14_postprocess_routing.R's own header comment): VIC's
# simulation here is naturalized, no reservoir operations modeled, and
# Nisqually has real upstream regulation (Alder/La Grande dams). A
# perfect KGE against the full regulated record isn't achievable by
# routing parameters alone, and chasing one risks fitting reservoir
# operations rather than actual routing physics.
#
# EDIT ME: the grid to search. Runtime scales with
# length(velocity_grid) * length(diffusion_grid) -- each combination
# reruns rvic parameters + rvic convolution over the FULL run period
# (config.yml's run.start_date/end_date), so a 6x6 grid means 36 full
# reruns of those two steps. Start narrow/coarse, then refine around
# whatever comes out on top.
velocity_grid  <- c(0.5, 1, 2, 3, 4)              # m/s
diffusion_grid <- c(500, 1000, 2000, 3500, 5000)  # m^2/s
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)
library(ncdf4)
library(dplyr)
library(purrr)
library(readr)
library(tidyr)
library(ggplot2)

if (is.null(cfg$routing$observed_gauge_site_no) ||
    cfg$routing$observed_gauge_site_no %in% c("", "EDIT_ME")) {
  stop("config.yml's routing.observed_gauge_site_no must be set to score ",
       "calibration runs against observed discharge.")
}
if (!requireNamespace("dataRetrieval", quietly = TRUE)) {
  stop("dataRetrieval package required -- install.packages('dataRetrieval').")
}

CFS_PER_CMS <- 35.3147

# Cache observed discharge to disk, keyed on gauge + exact run start/end
# dates, so re-running this script (e.g. after widening the velocity/
# diffusion grid) doesn't have to re-hit USGS's NWIS web service every
# time -- that service is slow/flaky for long date ranges (see the retry
# loop below) and is slated for eventual decommission per dataRetrieval's
# own warning ("NWIS servers are slated for decommission. Please begin to
# migrate to read_waterdata_daily."). Keying on the exact dates (not just
# the gauge) means a config.yml run-period change invalidates the cache
# automatically instead of silently reusing a shorter/older range --
# confirmed this AOI already had a STALE output/observed_streamflow.csv
# sitting around from an earlier, shorter test run (2005-2010 only), which
# would have been exactly this kind of silent mismatch if reused blindly
# against the current, wider 1980-2010 config.
obs_cache_path <- fs::path(
  cfg$paths$routing_dir,
  glue("observed_discharge_cache_{cfg$routing$observed_gauge_site_no}_",
       "{format(cfg$run$start_date, '%Y%m%d')}_{format(cfg$run$end_date, '%Y%m%d')}.csv")
)

if (fs::file_exists(obs_cache_path)) {
  message("Using cached observed discharge: ", obs_cache_path)
  obs <- readr::read_csv(obs_cache_path, show_col_types = FALSE)
} else {
  message("Fetching observed discharge for USGS ", cfg$routing$observed_gauge_site_no, "...")

  # A single 10-second httr2 timeout (dataRetrieval's default) is tight
  # for NWIS on a long date range or a slow day -- retry with backoff
  # rather than failing the whole calibration run over one flaky request.
  # This fetch only happens once total (cached above), so a little extra
  # time here is cheap.
  fetch_observed <- function(max_tries = 4) {
    for (attempt in seq_len(max_tries)) {
      result <- tryCatch(
        dataRetrieval::readNWISdv(
          siteNumbers = cfg$routing$observed_gauge_site_no, parameterCd = "00060",
          startDate = format(cfg$run$start_date, "%Y-%m-%d"),
          endDate = format(cfg$run$end_date, "%Y-%m-%d")
        ),
        error = function(e) e
      )
      if (!inherits(result, "error")) return(result)
      if (attempt < max_tries) {
        wait_s <- 5 * attempt
        message("  Attempt ", attempt, "/", max_tries, " failed (",
                conditionMessage(result), ") -- retrying in ", wait_s, "s...")
        Sys.sleep(wait_s)
      } else {
        stop("Failed to fetch observed discharge after ", max_tries,
             " attempts. Last error: ", conditionMessage(result), "\n",
             "This is usually USGS's NWIS servers being slow/unreachable for ",
             "a request this size (", as.integer(cfg$run$end_date - cfg$run$start_date),
             " days), not a bug here -- they're also slated for decommission ",
             "per dataRetrieval's own warning above. Try again in a few minutes.")
      }
    }
  }

  obs_raw <- fetch_observed()
  flow_col <- "X_00060_00003"
  if (nrow(obs_raw) == 0 || !flow_col %in% names(obs_raw)) {
    stop("No usable observed discharge returned for ", cfg$routing$observed_gauge_site_no)
  }
  obs <- obs_raw |>
    dplyr::transmute(date = Date, observed_cms = .data[[flow_col]] / CFS_PER_CMS)

  readr::write_csv(obs, obs_cache_path)
  message("Cached observed discharge to ", obs_cache_path, " for reuse next time.")
}
message("Got ", nrow(obs), " days of observed discharge.")

# Duplicated (not sourced) from 14_postprocess_routing.R's own
# find_flow_var()/read_one() -- deliberately not source()-ing 14 itself,
# since 14 also does its own (redundant, live-API) observed-discharge
# fetch and writes CSVs/PNGs we don't want repeated once per grid point.
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

# Deliberately does NOT decode "days since 0001-1-1" (RVIC's actual
# origin, confirmed by inspecting a real hist/*.nc file directly) into
# an R Date via as.Date(time_vals, origin = ...). Confirmed the hard way
# that this is unsafe: R's as.Date() arithmetic for an origin this
# ancient disagrees with the file's own CF "standard"-calendar meaning
# by a couple of days (verified against Python's netCDF4/cftime, which
# decoded the SAME raw value correctly and is what RVIC's own Python
# codebase relies on) -- e.g. raw day 730416.5 decoded to 2000-10-24 in
# R but 2000-10-22 via cftime. On its own that would just shift every
# date by a couple of days; combined with the raw values' ".5" (noon)
# fraction -- which as.Date() carries through into the Date's
# UNDERLYING numeric value, so it no longer compares equal to a clean
# integer-valued Date even though format() prints an ordinary-looking
# date -- every single join against `obs` below came back with ZERO
# overlapping rows for every combination in the grid.
#
# The robust fix: don't decode calendar dates from the file at all.
# Return the RAW time value (still in days, still relative to
# whatever origin the file declares) so rows from multiple files can
# be ordered and de-duplicated correctly relative to EACH OTHER, and
# let the caller re-derive actual calendar dates from cfg$run$start_date/
# end_date instead -- which we already know authoritatively, since
# that's the exact window 13_run_rvic_convolution.R told RVIC to run
# (RUN_STARTDATE/STOP_DATE in that script's config_text).
read_one <- function(f) {
  nc <- nc_open(f)
  on.exit(nc_close(nc), add = TRUE)
  flow_var <- find_flow_var(nc, f)
  time_vals <- as.vector(ncvar_get(nc, "time"))
  time_units <- ncatt_get(nc, "time", "units")$value
  unit_word <- tolower(strsplit(time_units, " ")[[1]][1])
  mult <- switch(unit_word,
                  seconds = 1 / 86400, minutes = 1 / 1440, hours = 1 / 24,
                  days = 1,
                  stop("Unrecognized time unit '", unit_word, "' in ", f))
  time_days <- time_vals * mult
  arr <- ncvar_get(nc, flow_var)
  if (is.null(dim(arr)) || length(dim(arr)) == 1) {
    flow <- as.vector(arr)
  } else {
    time_axis <- which(dim(arr) == length(time_days))
    if (length(time_axis) == 0) {
      stop("Could not match '", flow_var, "' dims to time length ", length(time_days), " in ", f)
    }
    flow <- apply(arr, time_axis[1], function(x) x[1])
  }
  data.frame(time_days = time_days, streamflow_cms = as.numeric(flow))
}

# Combines read_one()'s output across all of a run's hist/*.nc files into
# one clean daily series with real calendar dates -- ordering rows by
# their RAW time value (not filename: RVIC stamps history filenames with
# the CURRENT DATE it was writing on, e.g.
# <caseid>.rvic.h0a.1901-11-25.nc, NOT the calendar date of the data
# inside -- confirmed those two can differ by exactly 100 years for a
# flush written past year ~2000, a separate RVIC/library quirk from the
# as.Date() issue above, and why sorting by filename string is unsafe
# here).
#
# Calendar dates are assigned by ANCHORING to cfg$run$start_date (the one
# date we're actually certain of -- it's literally what
# 13_run_rvic_convolution.R told RVIC to start on via RUN_STARTDATE) and
# adding each row's raw time offset relative to the run's first record,
# rather than decoding the file's own ancient origin at all. Deliberately
# NOT asserting the combined row count must exactly equal
# end_date - start_date + 1: confirmed directly against this AOI's own
# real hist/*.nc files that RVIC's convolution output has small genuine
# gaps at RVICHIST_MFILT flush boundaries (a ~2-day gap between two
# consecutive tapes, confirmed from each file's own raw time values, not
# a decoding artifact) -- so a handful of missing days appears to be
# normal RVIC behavior, not a sign anything is wrong. Warn instead, and
# only error if there are MORE rows than expected (which would mean
# overlapping/duplicate time steps distinct() didn't catch -- an actual
# problem, unlike a small gap).
combine_sim <- function(files) {
  raw <- purrr::map_dfr(files, read_one) |>
    dplyr::distinct(time_days, .keep_all = TRUE) |>
    dplyr::arrange(time_days)
  first_time_days <- min(raw$time_days)
  raw$date <- cfg$run$start_date + as.integer(round(raw$time_days - first_time_days))

  expected_n <- as.integer(cfg$run$end_date - cfg$run$start_date) + 1L
  n_missing <- expected_n - nrow(raw)
  if (n_missing < 0) {
    stop("Got ", -n_missing, " MORE daily records than the ", expected_n,
         " expected for ", cfg$run$start_date, "..", cfg$run$end_date,
         " after combining hist/*.nc -- that suggests overlapping/",
         "duplicate time steps across files that distinct(time_days) ",
         "didn't catch. Check the hist/ files directly before trusting a ",
         "calibration score built on this.")
  } else if (n_missing > 0) {
    message("Note: rvic convolution's hist/*.nc output is missing ",
            n_missing, " of the ", expected_n, " expected daily records ",
            "for ", cfg$run$start_date, "..", cfg$run$end_date,
            " -- small gaps at flush boundaries appear to be normal RVIC ",
            "behavior (confirmed directly in this AOI's own raw hist ",
            "file time values), not a correctness problem here. Scoring ",
            "below only uses days present in both series, so this just ",
            "slightly reduces n_days.")
  }
  raw |>
    dplyr::distinct(date, .keep_all = TRUE) |>
    dplyr::select(date, streamflow_cms)
}

# Kling-Gupta Efficiency (Gupta et al. 2009): r = timing/shape
# correlation (closest to what velocity controls), alpha = variability
# ratio (closest to what diffusion controls, since diffusion smooths/
# sharpens peaks), beta = volume/mean-flow bias (mostly a VIC
# land-surface question -- routing parameters barely touch it).
kge <- function(sim, obs) {
  r     <- cor(sim, obs)
  alpha <- sd(sim) / sd(obs)
  beta  <- mean(sim) / mean(obs)
  list(kge = 1 - sqrt((r - 1)^2 + (alpha - 1)^2 + (beta - 1)^2),
       r = r, alpha = alpha, beta = beta)
}

# Day-lag that maximizes cross-correlation between simulated and
# observed flow, via base R's ccf(sim, obs) -- per ccf()'s own
# documented convention, "the lag k value returned by ccf(x, y)
# estimates the correlation between x[t+k] and y[t]", i.e. how many
# days simulated flow has to be shifted EARLIER to line up with
# observed. Empirically verified (not just derived from the docs)
# with a synthetic test before writing this: built `obs` as a sine
# wave and `sim` as `obs` delayed by 5 days (i.e. simulated velocity
# too LOW), and ccf(sim, obs)'s peak lag came back as exactly +5. So:
# POSITIVE lag => simulated flow arrives too LATE => RAISE velocity.
# NEGATIVE lag => simulated flow arrives too EARLY => LOWER velocity.
best_lag <- function(sim, obs, max_lag = 15) {
  cc <- ccf(sim, obs, lag.max = max_lag, plot = FALSE)
  cc$lag[which.max(cc$acf)]
}

grid <- tidyr::expand_grid(velocity = velocity_grid, diffusion = diffusion_grid)
message("Calibration grid: ", nrow(grid), " combination(s).")

results <- vector("list", nrow(grid))

for (i in seq_len(nrow(grid))) {
  v <- grid$velocity[i]
  d <- grid$diffusion[i]
  message("")
  message(glue("=== [{i}/{nrow(grid)}] velocity = {v} m/s, diffusion = {d} m^2/s ==="))

  # Picked up by R/00_config.R's cfg <- modifyList(cfg, ...) hook the
  # NEXT time it's source()'d (by 12 and 13 below) -- overrides only
  # cfg$routing$velocity/diffusion, leaves the rest of cfg untouched,
  # and never writes to config.yml on disk (which would strip its
  # comments -- see config.yml's own header).
  .calibration_override <- list(routing = list(velocity = v, diffusion = d))

  result <- tryCatch({
    source("R/12_run_rvic_parameters.R")
    source("R/13_run_rvic_convolution.R")
    # hist_files is left in the global environment by 13 itself
    # (already scoped to hist/*.nc only, not restarts/ -- see 13's own
    # comment on that fix).
    if (!exists("hist_files") || length(hist_files) == 0) {
      stop("No hist/*.nc output produced by 13_run_rvic_convolution.R.")
    }
    sim <- combine_sim(hist_files)
    joined <- dplyr::inner_join(sim, obs, by = "date") |>
      tidyr::drop_na(streamflow_cms, observed_cms)
    if (nrow(joined) < 30) {
      stop("Only ", nrow(joined), " overlapping simulated/observed days.")
    }
    score <- kge(joined$streamflow_cms, joined$observed_cms)
    lag   <- best_lag(joined$streamflow_cms, joined$observed_cms)
    message(glue("KGE = {round(score$kge, 3)} (r = {round(score$r, 3)}, ",
                 "alpha = {round(score$alpha, 3)}, beta = {round(score$beta, 3)}), ",
                 "best-fit lag = {lag} day(s), n = {nrow(joined)}"))
    tibble::tibble(velocity = v, diffusion = d, kge = score$kge,
                    r = score$r, alpha = score$alpha, beta = score$beta,
                    lag_days = lag, n_days = nrow(joined), status = "ok")
  }, error = function(e) {
    message("FAILED: ", conditionMessage(e))
    tibble::tibble(velocity = v, diffusion = d, kge = NA_real_,
                    r = NA_real_, alpha = NA_real_, beta = NA_real_,
                    lag_days = NA_integer_, n_days = NA_integer_,
                    status = paste("error:", conditionMessage(e)))
  })
  results[[i]] <- result
}

if (exists(".calibration_override", envir = .GlobalEnv)) {
  rm(.calibration_override, envir = .GlobalEnv)
}

results_df <- dplyr::bind_rows(results) |> dplyr::arrange(dplyr::desc(kge))
out_csv <- fs::path(cfg$paths$routing_dir, "calibration_grid_search.csv")
readr::write_csv(results_df, out_csv)
message("")
message("Wrote ", out_csv)

n_failed <- sum(results_df$status != "ok")
if (n_failed > 0) message(n_failed, " combination(s) failed -- see status column.")

best <- results_df |> dplyr::filter(status == "ok") |> dplyr::slice(1)

if (length(velocity_grid) > 1 && length(diffusion_grid) > 1 && nrow(best) == 1) {
  p <- ggplot(results_df, aes(factor(velocity), factor(diffusion), fill = kge)) +
    geom_tile() +
    geom_text(aes(label = ifelse(is.na(kge), "x", round(kge, 2))), size = 3) +
    scale_fill_viridis_c(na.value = "grey85") +
    labs(title = glue("{cfg$aoi$name} routing calibration -- KGE grid"),
         x = "velocity (m/s)", y = "diffusion (m^2/s)", fill = "KGE") +
    theme_minimal()
  ggsave(fs::path(cfg$paths$routing_dir, "calibration_grid_search.png"),
         p, width = 7, height = 5, dpi = 150)
  message("Wrote ", fs::path(cfg$paths$routing_dir, "calibration_grid_search.png"))
}

message("")
message("Done. This script did not modify config.yml or leave a ",
        "particular velocity/diffusion combination as the pipeline's ",
        "'current' state -- 12_run_rvic_parameters.R's case directory ",
        "now reflects whichever combination ran LAST in the grid above, ",
        "not necessarily the best one.")

# Printed LAST, on purpose, so it's the final thing in the console
# regardless of how long the grid search's own per-combination output
# scrolled above it.
message("")
message(strrep("=", 70))
if (nrow(best) == 1) {
  message(glue(
    "BEST PARAMETERS FOUND:\n",
    "  velocity  = {best$velocity} m/s\n",
    "  diffusion = {best$diffusion} m^2/s\n",
    "  KGE = {round(best$kge, 3)}  (r = {round(best$r, 3)}, ",
    "alpha = {round(best$alpha, 3)}, beta = {round(best$beta, 3)})\n",
    "  best-fit lag = {best$lag_days} day(s), n = {best$n_days} overlapping days\n",
    "\n",
    "This did NOT change config.yml. To use these parameters, set\n",
    "routing.velocity: {best$velocity} and routing.diffusion: {best$diffusion}\n",
    "in config.yml yourself, then rerun 12_run_rvic_parameters.R,\n",
    "13_run_rvic_convolution.R, and 14_postprocess_routing.R once more."
  ))
} else {
  message("BEST PARAMETERS: none -- every combination failed. See ",
          out_csv, " for details.")
}
message(strrep("=", 70))
