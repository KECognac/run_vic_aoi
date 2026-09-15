# ------------------------------------------------------------------------
# 01_get_aoi_boundary.R
#
# Fetches the AOI boundary polygon, saves it as GeoJSON, and derives a
# padded lat/lon bounding box that later scripts use to subset the
# Livneh 1/16-degree grid. Two modes, set via config.yml's aoi.mode:
#
# "huc" (default): the boundary is a USGS Watershed Boundary Dataset
#   (WBD) HUC8/10/12 polygon for aoi.huc_id, via nhdplusTools::get_huc()
#   (primary) or a direct WBD REST API query (fallback).
#
# "gauge": the boundary is the ACTUAL watershed draining to
#   aoi.gauge_site_no, delineated by USGS's Network-Linked Data Index
#   (NLDI) via dataRetrieval::findNLDI(..., find = "basin") -- the
#   authoritative upstream basin for that gauge, computed server-side
#   from NHDPlus's stream network. Use this when you specifically want
#   the AOI to match what a gauge measures (e.g. for a meaningful
#   observed-flow comparison in 14_postprocess_routing.R): a WBD HUC
#   polygon's own area is just its LOCAL incremental contribution, not
#   the cumulative area upstream of any particular point inside it, so a
#   HUC-mode AOI's area very often doesn't match any real gauge's
#   drainage area (confirmed the hard way testing the Nisqually HUC12
#   171100150110 against USGS 12082500: 28.8 sq mi vs 133 sq mi).
#
# Regardless of mode, this script ALSO derives the containing NHDPlus
# HUC4 (R/10_download_nhdplus.R needs to know which HUC4 package to
# download) via a spatial point-intersects query against the WBD's own
# HUC4 layer, using the boundary's centroid -- written to
# <aoi_dir>/nhdplus_huc4.txt. This works identically in both modes and
# is more robust than assuming the AOI's own huc_id encodes it (which
# isn't even meaningful in gauge mode, and was never strictly guaranteed
# in huc mode either -- an AOI can cross a HUC4 boundary).
#
# In gauge mode, this script ALSO writes routing/pour_points.csv itself,
# from NLDI's own snapped-to-network origin point -- so the routing pour
# point is geometrically consistent BY CONSTRUCTION with the delineated
# basin boundary above it, rather than a separately typed-in lat/lon
# that might not exactly match where NLDI actually snapped the gauge.
#
# Outputs:
#   <aoi_dir>/huc_boundary.geojson
#   <aoi_dir>/aoi_bbox.rds       -- named num vector: xmin, ymin, xmax, ymax (WGS84)
#   <aoi_dir>/aoi_map.png        -- quick sanity-check plot
#   <aoi_dir>/nhdplus_huc4.txt   -- containing NHDPlus HUC4 (both modes)
#   routing/pour_points.csv      -- gauge mode only (huc mode: maintain by hand)
# ------------------------------------------------------------------------

source("R/00_config.R")

library(sf)
library(ggplot2)
library(glue)
library(httr2)
library(readr)

get_huc_boundary <- function(huc_id, huc_level) {

  huc_type <- glue("huc{sprintf('%02d', huc_level)}")   # e.g. "huc08"

  boundary <- tryCatch({
    if (!requireNamespace("nhdplusTools", quietly = TRUE)) {
      stop("nhdplusTools not installed", call. = FALSE)
    }
    nhdplusTools::get_huc(id = huc_id, type = huc_type)
  }, error = function(e) {
    message(glue(
      "nhdplusTools path failed ({conditionMessage(e)}); ",
      "falling back to a direct WBD REST API query."
    ))

    # WBD MapServer layer indices -- CONFIRMED directly against this
    # service's own layer listing (GET .../MapServer?f=json), not
    # guessed: 0=WBDLine, 1=HUC2, 2=HUC4, 3=HUC6, 4=HUC8, 5=HUC10,
    # 6=HUC12, 7=HUC14, 8=HUC16. An earlier version of this map here
    # (4/6/8 for HUC8/10/12) was WRONG for HUC10/12 -- it happened to
    # never get caught because nhdplusTools's primary path above
    # succeeded for every HUC10/12 AOI tested so far, so this REST
    # fallback was never actually exercised until now.
    layer <- c(`4` = 2, `8` = 4, `10` = 5, `12` = 6)[[as.character(huc_level)]]
    field <- glue("huc{huc_level}")

    url <- glue(
      "{cfg$source_urls$wbd_rest_api}/{layer}/query",
      "?where={field}='{huc_id}'",
      "&outFields=*&f=geojson"
    )

    resp <- httr2::request(url) |> httr2::req_perform()
    sf::read_sf(httr2::resp_body_string(resp))
  })

  if (nrow(boundary) == 0) {
    stop(glue("No HUC{huc_level} boundary found for id {huc_id}. ",
              "Double check the HUC code and level in config.yml."))
  }

  sf::st_transform(boundary, 4326)
}

get_gauge_watershed <- function(site_no) {
  if (!requireNamespace("dataRetrieval", quietly = TRUE)) {
    stop("config.yml's aoi.mode is 'gauge' but the dataRetrieval package ",
         "isn't installed -- install.packages('dataRetrieval').")
  }
  message("Delineating the watershed upstream of USGS ", site_no,
          " via USGS's Network-Linked Data Index (NLDI) -- this is the ",
          "AUTHORITATIVE drainage basin for this gauge, computed ",
          "server-side from NHDPlus's stream network, not an ",
          "approximation from a nearby WBD unit.")

  nldi <- dataRetrieval::findNLDI(nwis = site_no, find = "basin")

  if (is.null(nldi$basin) || nrow(nldi$basin) == 0) {
    stop("NLDI returned no basin polygon for USGS ", site_no, ". Common ",
         "causes: the site number is wrong or not in NWIS, or (rare) it ",
         "isn't linked into NLDI's network. Double check at ",
         "https://waterdata.usgs.gov/monitoring-location/", site_no, "/")
  }
  if (is.null(nldi$origin) || nrow(nldi$origin) == 0) {
    stop("NLDI returned a basin but no origin point for USGS ", site_no,
         " -- can't determine the pour point location for ",
         "routing/pour_points.csv.")
  }

  list(
    boundary   = sf::st_transform(nldi$basin, 4326),
    pour_point = sf::st_transform(nldi$origin, 4326)
  )
}

aoi_mode <- cfg$aoi$mode

if (identical(aoi_mode, "gauge")) {
  site_no <- cfg$aoi$gauge_site_no
  if (is.null(site_no) || site_no %in% c("", "EDIT_ME")) {
    stop("config.yml's aoi.mode is 'gauge' but aoi.gauge_site_no isn't set.")
  }
  gauge <- get_gauge_watershed(site_no)
  boundary   <- gauge$boundary
  pour_point <- gauge$pour_point
} else {
  boundary   <- get_huc_boundary(cfg$aoi$huc_id, cfg$aoi$huc_level)
  pour_point <- NULL
}

sf::st_write(
  boundary,
  fs::path(cfg$paths$aoi_dir, "huc_boundary.geojson"),
  delete_dsn = TRUE, quiet = TRUE
)

bb  <- sf::st_bbox(boundary)
buf <- cfg$aoi$buffer_deg
aoi_bbox <- c(
  xmin = unname(bb["xmin"]) - buf,
  ymin = unname(bb["ymin"]) - buf,
  xmax = unname(bb["xmax"]) + buf,
  ymax = unname(bb["ymax"]) + buf
)
saveRDS(aoi_bbox, fs::path(cfg$paths$aoi_dir, "aoi_bbox.rds"))

message(glue(
  "{cfg$aoi$descriptor} bbox (padded {buf} deg): ",
  "lon [{round(aoi_bbox['xmin'],3)}, {round(aoi_bbox['xmax'],3)}], ",
  "lat [{round(aoi_bbox['ymin'],3)}, {round(aoi_bbox['ymax'],3)}]"
))

# --- containing NHDPlus HUC4 (both modes -- see header comment) --------
centroid <- sf::st_centroid(sf::st_union(boundary))
pt <- sf::st_coordinates(centroid)

huc4_layer <- 2   # "4-digit HU (Subregion)" -- confirmed via this same
                   # MapServer's own layer listing, see get_huc_boundary()
huc4_resp <- httr2::request(glue("{cfg$source_urls$wbd_rest_api}/{huc4_layer}/query")) |>
  httr2::req_url_query(
    geometry      = glue("{pt[1]},{pt[2]}"),
    geometryType  = "esriGeometryPoint",
    inSR          = "4326",
    spatialRel    = "esriSpatialRelIntersects",
    outFields     = "huc4,name",
    f             = "geojson"
  ) |>
  httr2::req_perform()
huc4_result <- sf::read_sf(httr2::resp_body_string(huc4_resp))

if (nrow(huc4_result) == 0) {
  stop("Could not determine the containing NHDPlus HUC4 for this AOI's ",
       "centroid (", round(pt[1], 4), ", ", round(pt[2], 4), ") -- the ",
       "WBD spatial query returned nothing. R/10_download_nhdplus.R needs ",
       "this to know which NHDPlus HR package to download.")
}
nhdplus_huc4 <- huc4_result$huc4[1]
writeLines(nhdplus_huc4, fs::path(cfg$paths$aoi_dir, "nhdplus_huc4.txt"))
message("Containing NHDPlus HUC4: ", nhdplus_huc4, " (",
        huc4_result$name[1], ") -- saved to ",
        fs::path(cfg$paths$aoi_dir, "nhdplus_huc4.txt"))

# --- pour point (gauge mode only) ---------------------------------------
if (!is.null(pour_point)) {
  pour_xy <- sf::st_coordinates(pour_point)
  pour_points_df <- data.frame(
    lons  = pour_xy[1, "X"],
    lats  = pour_xy[1, "Y"],
    names = glue("{toupper(cfg$aoi$name)} AT USGS {cfg$aoi$gauge_site_no}")
  )
  pour_points_path <- fs::path(cfg$paths$project_root, cfg$routing$pour_points_csv)
  fs::dir_create(fs::path_dir(pour_points_path))
  readr::write_csv(pour_points_df, pour_points_path)
  message("Wrote ", pour_points_path, " from NLDI's own snapped gauge ",
          "location (", round(pour_xy[1, "X"], 6), ", ",
          round(pour_xy[1, "Y"], 6), ") -- geometrically consistent by ",
          "construction with the delineated basin boundary above (NOT ",
          "necessarily identical to NWIS's raw site coordinates, which ",
          "can differ slightly from where NLDI snapped the gauge onto ",
          "the stream network).")
}

# --- sanity-check plot ---------------------------------------------------
p <- ggplot(boundary) +
  geom_sf(fill = "steelblue", alpha = 0.4, color = "steelblue4") +
  labs(title = glue("{cfg$aoi$name} -- {cfg$aoi$descriptor}"),
       subtitle = "Boundary used to subset the Livneh grid") +
  theme_minimal()

if (!is.null(pour_point)) {
  p <- p + geom_sf(data = pour_point, color = "firebrick", size = 2)
}

ggsave(fs::path(cfg$paths$aoi_dir, "aoi_map.png"), p, width = 6, height = 5, dpi = 150)

message("Wrote huc_boundary.geojson, aoi_bbox.rds, aoi_map.png, ",
        "nhdplus_huc4.txt to ", cfg$paths$aoi_dir)
