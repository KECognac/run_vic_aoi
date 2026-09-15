# ------------------------------------------------------------------------
# 11_build_routing_inputs.R
#
# Builds data/routing/routing_inputs.nc -- the Flow_Direction/Flow_Distance/
# Basin_ID/Source_Area grid RVIC's parameter generation step needs,
# EXACTLY on domain.aoi.nc's grid -- by shelling out to
# python/build_routing_inputs.py.
#
# That script derives flow direction FRESH from NHDPlus HR's hydro-
# conditioned DEM (not by reprojecting NHDPlus's own pre-computed fdr.tif
# codes -- see its docstring for why that would be wrong) via
# pyflwdir.from_dem(), then upscales to our 1/16deg grid with pyflwdir's
# IHU method (built for exactly this macro-scale-routing-model use case).
# Tested end-to-end against a synthetic DEM in NHDPlus HR's actual CRS
# (EPSG:5070) before being handed to you -- alignment with domain.aoi.nc
# is asserted (not just hoped) inside the python script itself.
# ------------------------------------------------------------------------

source("R/00_config.R")

library(fs)
library(glue)

domain_path <- fs::path(cfg$paths$domain_dir, "domain.aoi.nc")
if (!fs::file_exists(domain_path)) {
  stop("Missing ", domain_path, " -- run 05_build_domain.R first.")
}

nhdplus_extract_dir <- fs::path(cfg$paths$nhdplus_dir,
                                 glue("HU4_{cfg$routing$nhdplus_huc4}_RASTER"))
if (!fs::dir_exists(nhdplus_extract_dir)) {
  stop("Missing ", nhdplus_extract_dir, " -- run 10_download_nhdplus.R first.")
}

# 10_download_nhdplus.R prints its DEM candidate(s) but doesn't persist a
# chosen path anywhere (deliberately -- see that script's comments), so
# this re-does the same search. If it picks the wrong file for your
# extracted layout, hardcode the right path here instead of using
# dem_candidates[1].
dem_candidates <- fs::dir_ls(nhdplus_extract_dir, recurse = TRUE, type = "file")
dem_candidates <- dem_candidates[
  grepl("hydrodem|dem|elev", fs::path_file(dem_candidates), ignore.case = TRUE) &
  grepl("\\.(tif|tiff|img)$", dem_candidates, ignore.case = TRUE) &
  !grepl("fdr|fac", fs::path_file(dem_candidates), ignore.case = TRUE)
]
if (length(dem_candidates) == 0) {
  stop("No hydro-conditioned DEM found under ", nhdplus_extract_dir,
       " -- see 10_download_nhdplus.R's output for what WAS extracted, ",
       "and hardcode the right path in this script if the search pattern ",
       "just doesn't match this release's naming.")
}
dem_path <- dem_candidates[1]
if (length(dem_candidates) > 1) {
  message("NOTE: multiple DEM candidates found, using the first: ", dem_path,
          "\nAll candidates:\n  ", paste(dem_candidates, collapse = "\n  "))
}

# Keyed on huc_id, NOT a fixed "routing_inputs.nc" -- same reasoning as
# 04b_build_forcing_netcdf.R's aoi_monthly_<huc_id> fix: routing_dir is
# shared across every AOI tested in this checkout, and an unkeyed
# filename here would let a second AOI's run 11 silently overwrite (or,
# worse, a stale copy get read by) the first AOI's flow-direction grid.
routing_inputs_out <- fs::path(cfg$paths$routing_dir,
                                glue("routing_inputs_{cfg$aoi$huc_id}.nc"))

python_bin <- cfg$paths$pyflwdir_python
if (is.null(python_bin) || !fs::file_exists(python_bin)) {
  stop("config.yml's paths.pyflwdir_python (", python_bin, ") doesn't ",
       "exist. Install pyflwdir/rasterio first -- see setup/SETUP.md ",
       "section 7 -- then point this at that env's python.")
}

message("Building routing inputs on domain.aoi.nc's grid (this can take a ",
        "few minutes -- reprojecting the DEM and deriving flow direction ",
        "are the slow parts)...")

status <- system2(python_bin, c(
  "python/build_routing_inputs.py",
  "--dem-tif", dem_path,
  "--domain-nc", domain_path,
  "--out", routing_inputs_out,
  "--fine-scale-factor", "32",
  "--pad-cells", "2"
))
if (status != 0) {
  stop("build_routing_inputs.py failed (status ", status, "). Common ",
       "causes: the DEM doesn't actually cover the AOI (check its extent ",
       "against data/aoi/huc_boundary.geojson), or the wrong file got ",
       "picked as dem_path above.")
}

message("Done: ", routing_inputs_out, ". Next: 12_run_rvic_parameters.R.")
