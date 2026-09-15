# ------------------------------------------------------------------------
# 02b_subset_params_to_aoi.R
#
# Subsets the downloaded CONUS+Mexico-extension ASCII parameter files
# (333,579 grid cells) down to just the AOI bounding box BEFORE handing
# them to Tonic in 03_convert_params_to_netcdf.R. Converting the full
# domain works but is extremely slow (Tonic's snow-band matching is an
# O(n^2) Python loop over 333,579 cells); this cuts that to a couple
# hundred cells and the conversion drops from many minutes to seconds.
#
# The three files are NOT in the same row order as each other, so this
# can't be a simple "keep matching line numbers" filter:
#   - soil: filtered directly by its own lat/lon columns.
#   - veg: ragged multi-line records, one per grid cell, keyed by the
#     gridcell id in each record's first line -- filtered by ID against
#     the set of gridcell ids soil kept.
#   - snow: ONE ROW PER CELL, but its own first column ("cellnum") is a
#     real gridcell id in a DIFFERENT row order than soil -- filtered by
#     ID, same as veg. (Naively assuming this file's row order matched
#     soil's row order is what broke this for me the first time around;
#     if you're adapting this script to a different Livneh directory,
#     verify this assumption still holds before trusting the output.)
#
# Outputs: data/raw/vic_params_aoi/{soil,veg,snow}.txt
# ------------------------------------------------------------------------

source("R/00_config.R")

library(readr)
library(dplyr)
library(purrr)
library(stringr)
library(fs)
library(glue)

# Keyed on huc_id -- same AOI-caching bug pattern found and fixed
# elsewhere in this pipeline (04b's aoi_monthly subset dir, 11/12's
# routing_inputs_*.nc, 06's _metsim_raw_output dir): a fixed
# "vic_params_aoi" name here would let 03_convert_params_to_netcdf.R
# silently reuse a PREVIOUS AOI's subset ASCII files if 03 is ever run
# without rerunning 02b first for the new AOI -- 03 only checks that
# files EXIST at this path, not that they belong to the current AOI.
aoi_subset_dir <- fs::path(cfg$paths$raw_params_dir, "..",
                            glue("vic_params_aoi_{cfg$aoi$huc_id}")) |> fs::path_norm()
fs::dir_create(aoi_subset_dir)

bbox <- readRDS(fs::path(cfg$paths$aoi_dir, "aoi_bbox.rds"))

# EDIT ME if 03's file_map ever points at different source file names.
soil_in <- fs::path(cfg$paths$raw_params_dir, "vic.nldas.mexico.soil.txt")
veg_in  <- fs::path(cfg$paths$raw_params_dir, "vic.nldas.mexico.veg.txt")
snow_in <- fs::path(cfg$paths$raw_params_dir, "vic.nldas.mexico.snow.txt.L13")

# --- soil: plain fixed-column file, filter by lat/lon (cols 3, 4) -------
soil_lines <- read_lines(soil_in)
soil_split <- str_split(soil_lines, "\\s+")
lat <- as.numeric(map_chr(soil_split, 3))
lon <- as.numeric(map_chr(soil_split, 4))
gridcell <- as.integer(map_chr(soil_split, 2))

keep <- lat >= bbox["ymin"] & lat <= bbox["ymax"] &
        lon >= bbox["xmin"] & lon <= bbox["xmax"]
kept_ids <- gridcell[keep]

write_lines(soil_lines[keep], fs::path(aoi_subset_dir, "soil.txt"))
message(glue("soil: kept {sum(keep)} of {length(soil_lines)} cells"))

# --- snow: plain fixed-column file, filter by ID (col 1), NOT position --
snow_lines <- read_lines(snow_in)
snow_ids <- as.integer(map_chr(str_split(snow_lines, "\\s+"), 1))
snow_keep <- snow_ids %in% kept_ids

write_lines(snow_lines[snow_keep], fs::path(aoi_subset_dir, "snow.txt"))
message(glue("snow: kept {sum(snow_keep)} of {length(kept_ids)} target cells (ID-matched)"))

# --- veg: ragged records, "<gridcell> <Nveg>" header + 2*Nveg data lines
# (2x because VEGPARAM_LAI TRUE means each veg class has a class line AND
# an LAI line -- see config.yml / global.param template notes). No clean
# tidyverse primitive for ragged multi-record parsing like this; plain
# readLines + a manual cursor is clearer than forcing it into a
# vectorized shape.
veg_lines_in <- read_lines(veg_in)
out <- vector("list", length(kept_ids))
n_written <- 0L
i <- 1L
n <- length(veg_lines_in)
while (i <= n) {
  header <- str_split(veg_lines_in[i], "\\s+")[[1]]
  gridcel <- as.integer(header[1])
  nveg <- as.integer(header[2])
  record_end <- i + 2L * nveg
  if (gridcel %in% kept_ids) {
    n_written <- n_written + 1L
    out[[n_written]] <- veg_lines_in[i:record_end]
  }
  i <- record_end + 1L
}
write_lines(unlist(out[seq_len(n_written)]), fs::path(aoi_subset_dir, "veg.txt"))
message(glue("veg: kept {n_written} of {length(kept_ids)} target cells"))

message("Done. Point 03_convert_params_to_netcdf.R's file_map at ", aoi_subset_dir)
