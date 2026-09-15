# ------------------------------------------------------------------------
# 04_download_forcing.R
#
# Downloads Livneh CONUS meteorological forcing for the months covering
# cfg$run$start_date through cfg$run$end_date.
#
# This directory (confirmed by actually listing it -- see config.yml's
# comment on livneh_forcing_base) distributes ONE NETCDF FILE PER MONTH,
# full-CONUS grid, named e.g.
#   Meteorology_Livneh_CONUSExt_v.1.2_2013.200910.nc
# or, for many months, the same but bz2-compressed:
#   Meteorology_Livneh_CONUSExt_v.1.2_2013.200910.nc.bz2
# NOT one file per grid cell -- there's no lat/lon in the filename to
# match against the AOI, we just need the right months. Spatial
# subsetting to the AOI happens later, in 04b, after download.
#
# Downloads state_days (config.yml's metsim$state_days) of EXTRA months
# before start_date too -- MetSim (06_run_metsim.R) requires that many
# days of prior Tmax/Tmin/Prec to spin up, and this is the simplest place
# to grab them (04b then builds them into the same per-calendar-year
# files as everything else -- no special-casing needed there).
#
# Outputs: raw (full-CONUS, NOT yet AOI-subset) monthly NetCDF files in
# cfg$paths$raw_forcing_dir, one per month in the extended window,
# decompressed if they arrived as .bz2.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(httr2)
library(rvest)
library(dplyr)
library(stringr)
library(purrr)
library(fs)
library(glue)

list_directory_files <- function(base_url) {
  resp <- httr2::request(base_url) |> httr2::req_perform()
  page <- rvest::read_html(httr2::resp_body_string(resp))
  hrefs <- rvest::html_elements(page, "a") |> rvest::html_attr("href")
  hrefs <- hrefs[!is.na(hrefs) & !hrefs %in% c("../", "/")]
  tibble::tibble(href = hrefs, url = url_absolute(hrefs, base_url))
}

if (cfg$source_urls$livneh_forcing_base %in% c("EDIT_ME", "", NA)) {
  stop("source_urls$livneh_forcing_base is not set in config.yml.")
}

message("Listing ", cfg$source_urls$livneh_forcing_base)
files_df <- list_directory_files(cfg$source_urls$livneh_forcing_base)
message(nrow(files_df), " files found")

state_start_date <- cfg$run$start_date - cfg$metsim$state_days

months_needed <- format(
  seq(as.Date(format(state_start_date, "%Y-%m-01")),
      as.Date(format(cfg$run$end_date, "%Y-%m-01")),
      by = "month"),
  "%Y%m"
)
message("Run window needs ", length(months_needed), " month(s): ",
        paste(range(months_needed), collapse = " - "),
        " (includes ", cfg$metsim$state_days, " day MetSim spin-up window ",
        "before ", cfg$run$start_date, ")")

pattern <- paste0("\\.(", paste(months_needed, collapse = "|"), ")\\.nc(\\.bz2)?$")
matched <- filter(files_df, str_detect(href, pattern))

if (nrow(matched) != length(months_needed)) {
  stop(glue(
    "Expected {length(months_needed)} monthly files, matched {nrow(matched)}. ",
    "Check `pattern` above against the real file names (run_vic_aoi's config ",
    "assumes 'Meteorology_Livneh_CONUSExt_v.1.2_2013.YYYYMM.nc[.bz2]' -- if ",
    "the directory listing looks different now, this regex needs updating)."
  ))
}

have_bunzip2 <- requireNamespace("R.utils", quietly = TRUE)

purrr::pwalk(matched, function(href, url) {
  is_bz2 <- str_ends(href, "\\.bz2")
  dest <- fs::path(cfg$paths$raw_forcing_dir, href)
  final_dest <- if (is_bz2) fs::path_ext_remove(dest) else dest

  if (fs::file_exists(final_dest)) {
    message("  already have ", fs::path_file(final_dest), " -- skipping")
    return(invisible())
  }

  message("  downloading ", href)
  httr2::request(url) |> httr2::req_perform(path = dest)

  if (is_bz2) {
    if (!have_bunzip2) {
      stop("Downloaded a .bz2 file but the R.utils package (for bunzip2()) ",
           "isn't installed. install.packages('R.utils') and re-run.")
    }
    message("  decompressing ", href)
    R.utils::bunzip2(dest, destname = final_dest, remove = TRUE, overwrite = TRUE)
  }
})

message("Done. Raw (full-CONUS, not yet AOI-subset) monthly forcing files ",
        "are in ", cfg$paths$raw_forcing_dir, ". Next: 04b subsets each to ",
        "the AOI and concatenates them into the file(s) VIC actually reads.")

