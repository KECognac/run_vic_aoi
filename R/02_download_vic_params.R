# ------------------------------------------------------------------------
# 02_download_vic_params.R
#
# Reproducibly downloads the Livneh CONUS VIC parameter files from
#   cfg$source_urls$livneh_params_base
# (the directory you pointed to: .../Livneh.2015.NAmer.Dataset/nldas.vic.params/)
#
# NOTE ON WHAT'S IN THAT DIRECTORY: this is the original Livneh et al.
# (2013) parameter set, built for the VIC 4 *classic* driver -- i.e. plain
# ASCII soil/veg/snow-band tables, not the NetCDF domain+params the image
# driver expects. 03_convert_params_to_netcdf.R converts them. This is a
# one-time discovery-and-download step: it lists whatever is actually in
# the directory (via its Apache index page) rather than assuming fixed
# file names, so it keeps working if the layout changes.
#
# I was not able to browse this directory myself from this session (it's
# on a non-standard port that my network sandbox doesn't reach), so the
# very first time you run this, READ THE PRINTED FILE LIST before moving
# on to 03_convert_params_to_netcdf.R -- you may need to adjust the
# `keep_pattern` filter below to match what's actually there (e.g. if
# params are split into multiple regional tiles rather than one
# CONUS-wide soil/veg/vegetation-library/snowband set).
#
# Outputs: raw files copied into cfg$paths$raw_params_dir
# ------------------------------------------------------------------------

source("R/00_config.R")

library(httr2)
library(rvest)
library(purrr)
library(stringr)
library(fs)
library(glue)

list_directory_files <- function(base_url) {
  resp <- httr2::request(base_url) |>
    httr2::req_perform()

  page <- rvest::read_html(httr2::resp_body_string(resp))
  hrefs <- rvest::html_elements(page, "a") |> rvest::html_attr("href")

  # Apache-style indexes: drop parent-dir links and anything that's
  # clearly a subdirectory (trailing "/"), keep everything else.
  hrefs <- hrefs[!is.na(hrefs)]
  hrefs <- hrefs[!hrefs %in% c("../", "/")]
  tibble::tibble(
    href = hrefs,
    is_dir = str_ends(hrefs, "/"),
    url = url_absolute(hrefs, base_url)
  )
}

download_file_list <- function(files_df, dest_dir, keep_pattern = NULL) {
  if (!is.null(keep_pattern)) {
    files_df <- dplyr::filter(files_df, str_detect(href, keep_pattern))
  }

  purrr::pwalk(files_df, function(href, is_dir, url) {
    if (is_dir) return(invisible())
    dest <- fs::path(dest_dir, href)
    if (fs::file_exists(dest)) {
      message("  already have ", href, " -- skipping")
      return(invisible())
    }
    message("  downloading ", href)
    httr2::request(url) |>
      httr2::req_progress() |>
      httr2::req_perform(path = dest)
  })
}

message("Listing ", cfg$source_urls$livneh_params_base)
files_df <- list_directory_files(cfg$source_urls$livneh_params_base)

message(nrow(files_df), " entries found:")
print(files_df[, c("href", "is_dir")])

# EDIT ME once you've looked at the printed listing above. NULL keeps
# everything (fine for a first pass at a small AOI; adjust if the
# directory turns out to contain a lot of unrelated data).
keep_pattern <- NULL

download_file_list(files_df, cfg$paths$raw_params_dir, keep_pattern)

message("Done. Files are in ", cfg$paths$raw_params_dir)
