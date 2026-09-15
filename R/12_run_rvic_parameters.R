# ------------------------------------------------------------------------
# 12_run_rvic_parameters.R
#
# Runs RVIC's parameter generation step (`rvic parameters`): combines
# routing_inputs.nc (11's output -- flow direction/distance/basin/source
# area, on domain.aoi.nc's exact grid), the pour point (this AOI's
# gauge, in routing/pour_points.csv), and the within-cell unit hydrograph
# (routing/uh_box.csv) into unit hydrographs routed to the outlet -- a
# one-time step, run before any VIC output is needed.
#
# REMAP=False and AGGREGATE=False below because: our [ROUTING] grid IS
# domain.aoi.nc's grid already (no CESM-style remap needed -- that's what
# REMAP handles), and we have exactly one pour point, not several sharing
# coastal cells (that's what AGGREGATE handles). Both are the RIGHT
# defaults for this setup, not just "leave it alone" -- see RVIC's own
# samples/configs/rvic.parameters.pnw.cfg vs .rasm.cfg for the contrast
# (the RASM sample sets both True, because it IS a CESM coastal setup).
#
# RVIC stamps its output parameter file with today's date
# (<CASEID>.rvic.prm.<GRIDID>.<YYYYMMDD>.nc), so 13_run_rvic_convolution.R
# can't just guess the filename if it's run on a different day than this
# script -- this script writes the exact path it produced into
# <CASE_DIR>/latest_param_file.txt for 13 to read.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

domain_path <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")
routing_inputs_path <- fs::path(cfg$paths$routing_dir,
                                 glue("routing_inputs_{cfg$aoi$huc_id}.nc"))
pour_points_path <- fs::path(cfg$paths$project_root, cfg$routing$pour_points_csv)
uh_box_path <- fs::path(cfg$paths$project_root, cfg$routing$uh_box_csv)

missing <- c(
  if (!fs::file_exists(domain_path)) "domain.aoi.nc (run 05_build_domain.R)",
  if (!fs::file_exists(routing_inputs_path)) glue("routing_inputs_{cfg$aoi$huc_id}.nc (run 11_build_routing_inputs.R): {routing_inputs_path}"),
  if (!fs::file_exists(pour_points_path)) glue("pour_points.csv ({pour_points_path})"),
  if (!fs::file_exists(uh_box_path)) glue("uh_box.csv ({uh_box_path})")
)
if (length(missing) > 0) {
  stop("Missing required input(s):\n  ", paste(missing, collapse = "\n  "))
}

python_bin <- cfg$paths$rvic_python
if (is.null(python_bin) || !fs::file_exists(python_bin)) {
  stop("config.yml's paths.rvic_python (", python_bin, ") doesn't exist. ",
       "Install RVIC first -- see setup/SETUP.md section 7 -- then point ",
       "this at that env's python.")
}
rvic_bin <- fs::path(fs::path_dir(python_bin), "rvic")  # same venv/conda-env
                                                          # bin/ dir as python,
                                                          # same pattern as
                                                          # MetSim's `ms`
if (!fs::file_exists(rvic_bin)) {
  stop("Expected RVIC's `rvic` CLI at ", rvic_bin, " (next to rvic_python) ",
       "but it's not there. Confirm RVIC installed cleanly: `", rvic_bin,
       " -h` or `", python_bin, " -c 'import rvic'`.")
}

# Keyed on huc_id, NOT just "<name>_parameters" -- same AOI-caching bug
# pattern found and fixed elsewhere in this pipeline (04b's aoi_monthly,
# 06's _metsim_raw_output, 02b/03's vic_params_aoi): cfg$aoi$name stays
# the same across a huc-mode <-> gauge-mode switch for the same physical
# area (e.g. "Nisqually" either way), so a name-only caseid lets this
# case's directory accumulate a DIFFERENT AOI's leftover files right
# next to the current run's (confirmed: routing_inputs_171100150110.nc
# from an earlier HUC12 run was still sitting in this case's inputs/ dir
# during the gauge-mode debugging session that found the flow-direction
# flip bug above -- CLEAN: True does not purge it). Didn't turn out to be
# the cause of that particular crash (the file RVIC actually opened was
# confirmed fresh/correct), but it's the same latent risk, closed the
# same way.
caseid <- glue("{tolower(gsub('[^A-Za-z0-9]+', '_', cfg$aoi$name))}_{cfg$aoi$huc_id}_parameters")
gridid <- glue("{tolower(gsub('[^A-Za-z0-9]+', '_', cfg$aoi$name))}_{cfg$aoi$huc_id}_1_16deg")
case_dir <- fs::path(cfg$paths$routing_dir, "cases", caseid)

# CLEAN: True below does NOT actually purge this case's own directory
# from a PREVIOUS run -- already confirmed for inputs/ (see this
# script's caseid comment above), and now confirmed again for params/:
# RVIC stamps its output parameter file with TODAY's date
# (<CASEID>.rvic.prm.<GRIDID>.<YYYYMMDD>.nc), so any rerun of this
# script on a DIFFERENT calendar day than a previous run -- a plain
# rerun days later, or any grid-search iteration from
# 15_calibrate_routing.R -- leaves that OLD dated file sitting next to
# the new one, and the "expect exactly 1 parameter file" check below
# then fails every time, for the same reason. Confirmed the hard way:
# every single combination in a 15_calibrate_routing.R grid search
# failed identically, each citing this AOI's very first successful
# params file (days old) alongside that run's fresh one. Nothing
# downstream needs an old case_dir to survive --
# 13_run_rvic_convolution.R always re-reads whichever path THIS
# script's own marker file below points at, written fresh every run --
# so wipe it ourselves before each run, actually enforcing what
# CLEAN: True already claims to do.
if (fs::dir_exists(case_dir)) {
  fs::dir_delete(case_dir)
}
fs::dir_create(case_dir)

config_path <- fs::path(cfg$paths$routing_dir, "rvic_parameters.cfg")
config_text <- glue('
[OPTIONS]
LOG_LEVEL: INFO
VERBOSE: True
CLEAN: True
CASEID: {caseid}
GRIDID: {gridid}
CASE_DIR: {case_dir}
TEMP_DIR: %(CASE_DIR)s/temp/
REMAP: False
AGGREGATE: False
AGG_PAD: 25
NETCDF_FORMAT: NETCDF4_CLASSIC
NETCDF_ZLIB: False
NETCDF_COMPLEVEL: 4
NETCDF_SIGFIGS: None
SUBSET_DAYS: {cfg$routing$subset_days}
CONSTRAIN_FRACTIONS: False
SEARCH_FOR_CHANNEL: True

[POUR_POINTS]
FILE_NAME: {pour_points_path}

[UH_BOX]
FILE_NAME: {uh_box_path}
HEADER_LINES = {cfg$routing$uh_box_header_lines}

[ROUTING]
FILE_NAME: {routing_inputs_path}
LONGITUDE_VAR: lon
LATITUDE_VAR: lat
FLOW_DISTANCE_VAR: Flow_Distance
FLOW_DIRECTION_VAR: Flow_Direction
BASIN_ID_VAR: Basin_ID
SOURCE_AREA_VAR: Source_Area
VELOCITY: {cfg$routing$velocity}
DIFFUSION: {cfg$routing$diffusion}
OUTPUT_INTERVAL: {cfg$routing$output_interval_sec}
BASIN_FLOWDAYS: {cfg$routing$basin_flowdays}
CELL_FLOWDAYS: {cfg$routing$cell_flowdays}

[DOMAIN]
FILE_NAME: {domain_path}
LONGITUDE_VAR: lon
LATITUDE_VAR: lat
LAND_MASK_VAR: mask
FRACTION_VAR: frac
AREA_VAR: area
')
writeLines(config_text, config_path)
message("Wrote ", config_path)

log_path <- fs::path(cfg$paths$log_dir, glue("rvic_parameters_{format(Sys.time(), '%Y%m%dT%H%M%S')}.log"))
message("Running `rvic parameters` (this searches for the channel network ",
        "and builds unit hydrographs to the pour point -- can take a ",
        "while)...")
message("  log: ", log_path)

start_time <- Sys.time()
status <- system2(rvic_bin, c("parameters", config_path),
                   stdout = log_path, stderr = log_path)
elapsed <- difftime(Sys.time(), start_time, units = "mins")

if (status != 0) {
  stop(glue("rvic parameters exited with status {status} after ",
            "{round(elapsed, 1)} min. Check the log: {log_path}\n",
            "Common causes: the pour point didn't snap to a channel cell ",
            "(SEARCH_FOR_CHANNEL should handle this, but a badly-formed ",
            "routing_inputs.nc can still defeat it), or a routing_inputs.nc/",
            "domain.aoi.nc coordinate mismatch (11_build_routing_inputs.R ",
            "asserts these match at build time, so this would mean ",
            "domain.aoi.nc changed since 11 last ran -- rerun 11 if so)."))
}
message(glue("rvic parameters finished in {round(elapsed, 1)} min."))

# --- locate the actual output (RVIC stamps it with today's date, so this
#     can't be predicted in advance) and record it for 13 to find later --
params_dir <- fs::path(case_dir, "params")
param_files <- fs::dir_ls(params_dir, glob = glue("*{caseid}.rvic.prm.*.nc"))
if (length(param_files) != 1) {
  stop("Expected exactly 1 parameter file in ", params_dir, " matching ",
       "*", caseid, ".rvic.prm.*.nc, found ", length(param_files), ": ",
       paste(param_files, collapse = ", "), ". Check ", log_path,
       " for what went wrong.")
}
param_file <- param_files[1]
marker_path <- fs::path(case_dir, "latest_param_file.txt")
writeLines(param_file, marker_path)

message("Parameter file: ", param_file)
message("(path also saved to ", marker_path, " so 13_run_rvic_convolution.R ",
        "can find it without you copying it by hand)")
message("Done. Next: 13_run_rvic_convolution.R.")
