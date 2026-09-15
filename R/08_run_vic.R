# ------------------------------------------------------------------------
# 08_run_vic.R
#
# Runs the compiled VIC 5 image-driver binary against the global
# parameter file written by 07_write_globalparam.R.
#
# Requires cfg$paths$vic_image_exe (config.yml) to point at a binary
# you've already built -- see setup/SETUP.md for the compile step. This
# script does not compile VIC; it just runs it.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

if (!fs::file_exists(cfg$paths$vic_image_exe)) {
  stop(glue(
    "vic_image_exe ({cfg$paths$vic_image_exe}) doesn't exist. Build VIC's ",
    "image driver first (setup/SETUP.md), then point config.yml's ",
    "paths.vic_image_exe at the resulting binary."
  ))
}

global_param_path <- fs::path(cfg$paths$domain_dir, "global_param.txt")
if (!fs::file_exists(global_param_path)) {
  stop("Missing ", global_param_path, " -- run 05_build_domain.R, ",
       "06_run_metsim.R, and 07_write_globalparam.R first.")
}

log_path <- fs::path(cfg$paths$log_dir, glue("vic_run_{format(Sys.time(), '%Y%m%dT%H%M%S')}.log"))

message("Running VIC image driver...")
message("  exe:    ", cfg$paths$vic_image_exe)
message("  global: ", global_param_path)
message("  log:    ", log_path)

start_time <- Sys.time()
status <- system2(
  cfg$paths$vic_image_exe,
  args = c("-g", global_param_path),
  stdout = log_path, stderr = log_path
)
elapsed <- difftime(Sys.time(), start_time, units = "mins")

if (status != 0) {
  stop(glue(
    "VIC exited with status {status} after {round(elapsed, 1)} min. ",
    "Check the log: {log_path}"
  ))
}

message(glue("VIC finished successfully in {round(elapsed, 1)} min. ",
             "Outputs in {cfg$paths$output_dir}, log at {log_path}"))
