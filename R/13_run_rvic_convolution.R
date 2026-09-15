# ------------------------------------------------------------------------
# 13_run_rvic_convolution.R
#
# Runs RVIC's convolution step (`rvic convolution`): combines 12's unit
# hydrographs with VIC's actual OUT_RUNOFF/OUT_BASEFLOW output
# (output/fluxes.<start-date>.nc) to produce routed daily streamflow
# (m3/s) at the AOI's pour point.
#
# RUN_TYPE: drystart because we have no prior RVIC state to restart from
# (this is the first and only convolution run for this AOI) -- "drystart"
# is RVIC's term for "start clean, no initial state needed", not a typo
# for "startup".
#
# RVICHIST_OUTTYPE: array (not "grid") because we only care about the one
# pour point's time series, not a full spatial grid of it -- much smaller
# output, and simpler for 14_postprocess_routing.R to read.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

domain_path <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")
# Must match 12_run_rvic_parameters.R's own caseid construction exactly
# (see that script's comment for why it's huc_id-keyed).
params_case_dir <- fs::path(cfg$paths$routing_dir, "cases",
                             glue("{tolower(gsub('[^A-Za-z0-9]+', '_', cfg$aoi$name))}_{cfg$aoi$huc_id}_parameters"))
param_marker_path <- fs::path(params_case_dir, "latest_param_file.txt")

if (!fs::file_exists(domain_path)) {
  stop("Missing ", domain_path, " -- run 05_build_domain.R first.")
}
if (!fs::file_exists(param_marker_path)) {
  stop("Missing ", param_marker_path, " -- run 12_run_rvic_parameters.R first.")
}
param_file <- readLines(param_marker_path, n = 1)
if (!fs::file_exists(param_file)) {
  stop("12_run_rvic_parameters.R's marker file points at ", param_file,
       ", which no longer exists -- rerun 12_run_rvic_parameters.R.")
}

vic_flux_files <- fs::dir_ls(cfg$paths$output_dir, glob = "*fluxes*.nc")
if (length(vic_flux_files) == 0) {
  stop("No fluxes*.nc files found in ", cfg$paths$output_dir, " -- did ",
       "08_run_vic.R succeed?")
}

python_bin <- cfg$paths$rvic_python
if (is.null(python_bin) || !fs::file_exists(python_bin)) {
  stop("config.yml's paths.rvic_python (", python_bin, ") doesn't exist. ",
       "Install RVIC first -- see setup/SETUP.md section 7.")
}
rvic_bin <- fs::path(fs::path_dir(python_bin), "rvic")
if (!fs::file_exists(rvic_bin)) {
  stop("Expected RVIC's `rvic` CLI at ", rvic_bin, " but it's not there.")
}

# Keyed on huc_id too, matching 12_run_rvic_parameters.R's caseid fix --
# same AOI-caching bug pattern (see that script's comment).
caseid <- glue("{tolower(gsub('[^A-Za-z0-9]+', '_', cfg$aoi$name))}_{cfg$aoi$huc_id}_convolution")
case_dir <- fs::path(cfg$paths$routing_dir, "cases", caseid)

# Same staleness issue as 12_run_rvic_parameters.R's case_dir (see that
# script's comment) -- RVIC's convolution history tapes
# (<caseid>.rvic.h0a.<date>.nc) don't get purged across separate runs
# either, and unlike 12's "expect exactly 1 file" check, hist_files
# below just grabs EVERYTHING under hist/ -- so leftover tapes from an
# OLDER run wouldn't even error, they'd silently get mixed into
# read_one()'s combined time series (dplyr::distinct(date,
# .keep_all = TRUE) below keeps whichever file's value for a given date
# comes first in glob order, not necessarily from THIS run). That's a
# silent-wrong-answer risk, worse than 12's loud failure -- especially
# for 15_calibrate_routing.R, which reruns this script once per grid
# combination. Wipe case_dir fresh each run for the same reason as 12.
if (fs::dir_exists(case_dir)) {
  fs::dir_delete(case_dir)
}
fs::dir_create(case_dir)

# NO COMMAS anywhere in CASESTR below (or any other single-value entry
# in the [OPTIONS] block) -- RVIC's own config parser
# (rvic/core/config.py, config_type()) treats ANY comma in a value as a
# separator for a multi-value list (that is how DATL_LIQ_FLDS elsewhere
# in this file accepts "OUT_RUNOFF, OUT_BASEFLOW" as two fields), with
# no way to escape or quote a literal comma. A comma here silently turns
# CASESTR into a Python list instead of a string at config-read time,
# which does not fail until much later, at the FIRST history-file flush
# (RVICHIST_MFILT timesteps into the run) -- deep inside RVIC's
# core/history.py, writing the file's global attributes, with
# AttributeError: list object has no attribute encode. Confirmed the
# hard way, then confirmed again by replicating config_type()'s actual
# comma-splitting logic against the exact string this line used to
# produce (it had a comma right before the year range). cfg$aoi$name
# and cfg$aoi$descriptor (see R/00_config.R) are both comma-free by
# construction in every mode this pipeline supports, so interpolating
# them here is currently safe -- just do not add a comma to this line.
config_path <- fs::path(cfg$paths$routing_dir, "rvic_convolution.cfg")
config_text <- glue('
[OPTIONS]
LOG_LEVEL: INFO
VERBOSE: True

CASE_DIR: {case_dir}
CASEID: {caseid}
CASESTR: {cfg$aoi$name} ({cfg$aoi$descriptor}) routed streamflow for {format(cfg$run$start_date, "%Y")}-{format(cfg$run$end_date, "%Y")}
CALENDAR: {cfg$run$calendar}

RUN_TYPE: drystart
RUN_STARTDATE: {format(cfg$run$start_date, "%Y-%m-%d")}-00

STOP_OPTION: date
STOP_N: -999
STOP_DATE: {format(cfg$run$end_date, "%Y-%m-%d")}

REST_OPTION: %(STOP_OPTION)s
REST_N: %(STOP_N)s
REST_DATE: %(STOP_DATE)s
REST_NCFORM: NETCDF4_CLASSIC

[HISTORY]
RVICHIST_NTAPES = 1
RVICHIST_MFILT = 400
RVICHIST_NDENS = 2
RVICHIST_NHTFRQ = 1
RVICHIST_AVGFLAG = A
RVICHIST_OUTTYPE: array
RVICHIST_NCFORM: NETCDF4_CLASSIC
RVICHIST_NETCDF_ZLIB: False
RVICHIST_NETCDF_COMPLEVEL: 4
RVICHIST_NETCDF_SIGFIGS: None
RVICHIST_UNITS: m3/s

[DOMAIN]
FILE_NAME: {domain_path}
LONGITUDE_VAR: lon
LATITUDE_VAR: lat
AREA_VAR: area
LAND_MASK_VAR: mask
FRACTION_VAR: frac

[INITIAL_STATE]
FILE_NAME: None

[PARAM_FILE]
FILE_NAME: {param_file}

[INPUT_FORCINGS]
DATL_PATH: {cfg$paths$output_dir}/
DATL_FILE: fluxes.{format(cfg$run$start_date, "%Y-%m-%d")}.nc
TIME_VAR: time
LATITUDE_VAR: lat
DATL_LIQ_FLDS: OUT_RUNOFF, OUT_BASEFLOW
START:
END:
')
# DATL_FILE above is the literal, single actual filename VIC wrote (same
# name 09_postprocess_outputs.R reads), NOT a $YYYY-$MM-$DD template --
# and START/END are deliberately left BLANK. Confirmed directly against
# RVIC's own source (rvic/core/read_forcing.py's DataModel.__init__):
# it decides how many forcing files to expect purely by counting
# dash-separated parts in START (1 part -> one file per YEAR, 2 ->
# per MONTH, 3 -> per DAY), independent of what placeholders DATL_FILE
# actually contains. A "%Y-%m-%d"-formatted START (3 parts) put RVIC
# into daily-file mode, so it looked for a separate fluxes.<date>.nc for
# EVERY DAY of the run (fluxes.2005-01-01.nc, fluxes.2005-01-02.nc, ...)
# and crashed with FileNotFoundError on day 2 -- but VIC's image driver
# writes ONE fluxes.<run-start-date>.nc file covering the WHOLE run, not
# one per day. Leaving START/END blank parses to Python None (see RVIC's
# core/config.py's config_type()), which sends DataModel down its
# "single file, no date substitution" branch instead -- confirmed
# against RVIC's own rasm sample config
# (samples/configs/rvic.convolution.rasm.cfg), which uses exactly this
# blank-START/END + literal-filename pattern. DataModel still reads the
# full run's actual date range from that one file's own time variable,
# so nothing about the convolution period is lost by leaving these
# blank -- confirmed they're not used anywhere else in RVIC's
# convolution code path.
writeLines(config_text, config_path)
message("Wrote ", config_path)

log_path <- fs::path(cfg$paths$log_dir, glue("rvic_convolution_{format(Sys.time(), '%Y%m%dT%H%M%S')}.log"))
message("Running `rvic convolution` (routes VIC's OUT_RUNOFF/OUT_BASEFLOW ",
        "through the unit hydrographs from 12 to produce streamflow at ",
        "the AOI's pour point)...")
message("  log: ", log_path)

start_time <- Sys.time()
status <- system2(rvic_bin, c("convolution", config_path),
                   stdout = log_path, stderr = log_path)
elapsed <- difftime(Sys.time(), start_time, units = "mins")

if (status != 0) {
  stop(glue("rvic convolution exited with status {status} after ",
            "{round(elapsed, 1)} min. Check the log: {log_path}\n",
            "Common causes: DATL_FILE (", "fluxes.",
            format(cfg$run$start_date, "%Y-%m-%d"), ".nc) not matching ",
            "an actual file in {cfg$paths$output_dir} (check with `ls ",
            "{cfg$paths$output_dir}`), or run$start_date in config.yml ",
            "not matching the date VIC actually used for 08_run_vic.R's ",
            "global_param.txt (rerun 08 if you changed it since)."))
}
message(glue("rvic convolution finished in {round(elapsed, 1)} min."))

# hist/ ONLY, not case_dir recursively -- rvic convolution also writes a
# restarts/ subdirectory alongside hist/ (its own end-of-run state file,
# e.g. <caseid>.r.<date>.nc, holding the convolution ring/timemgr state,
# not streamflow), and a case with multiple RVICHIST_MFILT-sized flushes
# writes one restart file per flush too. A recursive "*.nc" glob over
# case_dir swept that file in alongside the real hist/*.rvic.h0a.*.nc
# tapes, and 14_postprocess_routing.R's find_flow_var() then choked on
# it with "No flow-like variable found" (restart files hold
# unit_hydrograph_dt/timemgr_rst_*/locfnh/outlet_*_ind/LIQ_ring instead)
# -- confirmed by inspecting this case's actual directory structure.
hist_files <- fs::dir_ls(fs::path(case_dir, "hist"), glob = "*.nc")
if (length(hist_files) == 0) {
  stop("rvic convolution reported success but no .nc output found under ",
       fs::path(case_dir, "hist"), ". Check ", log_path, ".")
}
marker_path <- fs::path(case_dir, "latest_hist_files.txt")
writeLines(hist_files, marker_path)

message("Output file(s):\n  ", paste(hist_files, collapse = "\n  "))
message("(path(s) also saved to ", marker_path, " so ",
        "14_postprocess_routing.R can find them without you copying by hand)")
message("Done. Next: 14_postprocess_routing.R.")
