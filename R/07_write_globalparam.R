# ------------------------------------------------------------------------
# 07_write_globalparam.R
#
# Writes global_param.txt, pointing VIC at 06_run_metsim.R's output
# (temp/prec/shortwave/longwave/vapor_pressure/air_pressure/wind) instead
# of the raw Livneh Prec/Tmax/Tmin/Wind files -- see 06_run_metsim.R's
# header comment for why VIC can't use the raw files directly.
#
# Because MetSim's full variable set (SWDOWN/LWDOWN/VP/PRESSURE) is only
# available sub-daily (its daily-output mode is missing several of them --
# see 06's header), this run is sub-daily internally
# (MODEL_STEPS_PER_DAY/SNOW_STEPS_PER_DAY/RUNOFF_STEPS_PER_DAY driven by
# config.yml's metsim$time_step_min), even though it's still a
# water-balance-only run (FULL_ENERGY FALSE). AGGFREQ NDAYS 1 aggregates
# output back to daily, matching what 09_postprocess_outputs.R expects.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

params_aligned <- fs::path(cfg$paths$domain_dir, "params.aligned.nc")
if (!fs::file_exists(params_aligned)) {
  stop("Missing ", params_aligned, " -- run 05_build_domain.R first.")
}
domain_out <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")
if (!fs::file_exists(domain_out)) {
  stop("Missing ", domain_out, " -- run 05_build_domain.R first.")
}
metsim_files <- fs::dir_ls(cfg$paths$metsim_forcing_dir, glob = "*forcing.*.nc")
if (length(metsim_files) == 0) {
  stop("No forcing.<YYYY>.nc files in ", cfg$paths$metsim_forcing_dir,
       " -- run 06_run_metsim.R first.")
}

steps_per_day <- 1440 / cfg$metsim$time_step_min
if (steps_per_day != as.integer(steps_per_day)) {
  stop("metsim$time_step_min (", cfg$metsim$time_step_min, ") doesn't ",
       "divide 1440 evenly -- MetSim requires this (see config.yml).")
}
steps_per_day <- as.integer(steps_per_day)

forcing_prefix <- fs::path(cfg$paths$metsim_forcing_dir, "forcing.")

# Explicit OUTFILE/OUTVAR block, added to get OUT_PET (potential
# evapotranspiration) into the output -- VIC doesn't write it by default.
# Confirmed directly against VIC5's own docs (OutputFormatting.md) and a
# live inspection of this AOI's actual fluxes.nc: leaving OUTFILE/OUTVAR
# out entirely (as this script did before) makes VIC fall back to its
# built-in default file/variable set, but specifying ANY OUTFILE turns
# that default OFF ENTIRELY -- for every stream, not just the one you
# touched. So getting OUT_PET means re-listing everything the pipeline
# already depends on too, not just adding one line.
#
# The three streams/variable lists below reproduce EXACTLY what VIC was
# already writing by default before this change (confirmed against
# 09_postprocess_outputs.R's own header comment, itself written from a
# live inspection of real output files earlier in this project), so nothing
# already relied upon should change -- OUT_PET is the only net addition,
# in the fluxes stream.
#
# Each OUTVAR line below is bare (just the variable name, no trailing
# format/type/multiplier/aggtype fields) -- confirmed from VIC5's own
# docs this is the documented way to keep a variable's normal default
# type/multiplier/aggregation behavior, the same as when it was written
# implicitly before. AGGFREQ NDAYS 1 (daily aggregation from this run's
# sub-daily internal timestep -- see this script's own header comment)
# is set inside each OUTFILE block rather than once at top level, since
# that's how VIC5's own documented example scopes it per-stream.
#
# One thing this change can't fully guarantee without actually running
# it: VIC's default (implicit) output naming already stamps files as
# <prefix>.<run-start-date>.nc (e.g. fluxes.1980-01-01.nc), which is what
# 09_postprocess_outputs.R and 13_run_rvic_convolution.R both hardcode.
# The OUTFILE prefixes below ("fluxes"/"snow"/"snowband") are chosen to
# match those exactly, and nothing in VIC5's docs suggests explicit
# OUTFILE changes the date-stamping rule itself -- but this is the one
# part of this change that's worth double-checking against the actual
# filenames produced after 08_run_vic.R runs, before trusting 09/13 to
# find them.
outfile_blocks <- '
OUTFILE        fluxes
AGGFREQ        NDAYS   1
OUTVAR OUT_PREC
OUTVAR OUT_EVAP
OUTVAR OUT_PET
OUTVAR OUT_RUNOFF
OUTVAR OUT_BASEFLOW
OUTVAR OUT_WDEW
OUTVAR OUT_SOIL_LIQ
OUTVAR OUT_SWNET
OUTVAR OUT_R_NET
OUTVAR OUT_EVAP_CANOP
OUTVAR OUT_TRANSP_VEG
OUTVAR OUT_EVAP_BARE
OUTVAR OUT_SUB_CANOP
OUTVAR OUT_SUB_SNOW
OUTVAR OUT_AERO_RESIST
OUTVAR OUT_SURF_TEMP
OUTVAR OUT_ALBEDO
OUTVAR OUT_REL_HUMID
OUTVAR OUT_IN_LONG
OUTVAR OUT_AIR_TEMP
OUTVAR OUT_WIND

OUTFILE        snow
AGGFREQ        NDAYS   1
OUTVAR OUT_SWE
OUTVAR OUT_SNOW_DEPTH
OUTVAR OUT_SNOW_CANOPY
OUTVAR OUT_SNOW_COVER

OUTFILE        snowband
AGGFREQ        NDAYS   1
OUTVAR OUT_SWE_BAND
OUTVAR OUT_SNOW_DEPTH_BAND
OUTVAR OUT_SNOW_CANOPY_BAND
OUTVAR OUT_SWNET_BAND
OUTVAR OUT_LWNET_BAND
OUTVAR OUT_ALBEDO_BAND
OUTVAR OUT_LATENT_BAND
OUTVAR OUT_SENSIBLE_BAND
OUTVAR OUT_GRND_FLUX_BAND
'

global_param <- glue('
MODEL_STEPS_PER_DAY    {steps_per_day}
SNOW_STEPS_PER_DAY     {steps_per_day}
RUNOFF_STEPS_PER_DAY   {steps_per_day}

STARTYEAR   {format(cfg$run$start_date, "%Y")}
STARTMONTH  {format(cfg$run$start_date, "%m")}
STARTDAY    {format(cfg$run$start_date, "%d")}
ENDYEAR     {format(cfg$run$end_date, "%Y")}
ENDMONTH    {format(cfg$run$end_date, "%m")}
ENDDAY      {format(cfg$run$end_date, "%d")}
CALENDAR    {toupper(cfg$run$calendar)}

FULL_ENERGY    FALSE
FROZEN_SOIL    FALSE

DOMAIN         {domain_out}
DOMAIN_TYPE    LAT     lat
DOMAIN_TYPE    LON     lon
DOMAIN_TYPE    MASK    mask
DOMAIN_TYPE    AREA    area
DOMAIN_TYPE    FRAC    frac
DOMAIN_TYPE    YDIM    lat
DOMAIN_TYPE    XDIM    lon

FORCING1       {forcing_prefix}
FORCE_TYPE     AIR_TEMP   temp
FORCE_TYPE     PREC       prec
FORCE_TYPE     PRESSURE   air_pressure
FORCE_TYPE     SWDOWN     shortwave
FORCE_TYPE     LWDOWN     longwave
FORCE_TYPE     VP         vapor_pressure
FORCE_TYPE     WIND       wind

PARAMETERS     {params_aligned}
SNOW_BAND      TRUE
BASEFLOW       ARNO
NODES          3

{outfile_blocks}
RESULT_DIR     {cfg$paths$output_dir}/
LOG_DIR        {cfg$paths$log_dir}/
')
# NOTE the trailing "/" on RESULT_DIR/LOG_DIR above -- VIC concatenates
# these directly onto its own output/log filenames (no separator added),
# so without it you get files literally named e.g.
# "<project_root>/logsvic.log.<pid>.<usec>.txt" sitting in project_root
# itself instead of inside logs/ -- confirmed by hitting this for real
# (cfg$paths$log_dir/output_dir are resolved via fs::path_abs() in
# R/00_config.R, which never keeps a trailing slash).

global_param_path <- fs::path(cfg$paths$domain_dir, "global_param.txt")
writeLines(global_param, global_param_path)
message("Wrote ", global_param_path)
message("Next: 08_run_vic.R.")
