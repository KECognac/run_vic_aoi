# Routing (phase 2)

Scripts 10-14 in `R/` add RVIC (https://github.com/UW-Hydro/RVIC) routing
on top of the grid-cell water balance from scripts 01-09, producing
routed daily streamflow (m3/s) at a real USGS gauge.

**Pour point:** where this comes from depends on `config.yml`'s
`aoi.mode` (see `R/01_get_aoi_boundary.R`'s header comment for the full
rationale):

- **`mode: "gauge"`** (recommended when you specifically want a
  meaningful observed-flow comparison): the AOI itself IS the watershed
  draining to `aoi.gauge_site_no`, delineated by USGS's Network-Linked
  Data Index (NLDI). `01_get_aoi_boundary.R` auto-writes
  `routing/pour_points.csv` from NLDI's own snapped gauge location, so
  the pour point is geometrically consistent with the AOI boundary by
  construction -- nothing to hand-maintain.
- **`mode: "huc"`** (the original design): the AOI is a WBD HUC8/10/12
  polygon, and you pick a pour point gauge by hand in
  `routing/pour_points.csv`, choosing one whose drainage area is a
  near-exact match for the HUC's own total area (so it's essentially the
  HUC's own outlet, not a partial-basin gauge). The original Poudre test
  AOI (HUC8 `10190007`) used USGS 06752500 (Cache la Poudre at Greeley,
  CO) this way -- drainage area 1879 sq mi vs. the HUC8's own 1891 sq mi.
  **Caution:** a HUC12 (or often HUC10)'s own area is usually much
  smaller than any real gauge's cumulative drainage area upstream of it
  (a HUC's `areasqkm` is just its local incremental contribution, not
  everything draining through it) -- this is exactly why gauge mode
  exists, and why huc mode is really only a good match at the HUC8 level
  or coarser.

**Flow direction source:** derived fresh from NHDPlus HR's hydro-
conditioned DEM (not by reprojecting NHDPlus's own precomputed flow-
direction codes -- those are directional and don't reproject cleanly;
elevation is a continuous scalar and does). `python/build_routing_inputs.py`
reprojects the DEM onto a fine subdivision of the VIC domain grid, derives
D8 flow direction with `pyflwdir.from_dem()`, then upscales to the
domain's actual 1/16-deg grid with pyflwdir's IHU algorithm (purpose-built
for macro-scale routing model grids) -- producing Flow_Direction,
Flow_Distance, Basin_ID, and Source_Area, EXACTLY aligned to
`domain.aoi.nc` (asserted at build time, not just assumed).

## Scripts (run after 01-09, in order)

1. `10_download_nhdplus.R` -- downloads/extracts the NHDPlus HR raster
   package (HUC4 1019) that has the DEM.
2. `11_build_routing_inputs.R` -- finds that DEM, shells out to
   `python/build_routing_inputs.py` to build `routing_inputs.nc`.
3. `12_run_rvic_parameters.R` -- runs `rvic parameters`: combines
   `routing_inputs.nc`, `routing/pour_points.csv`, and
   `routing/uh_box.csv` into unit hydrographs routed to the Greeley
   gauge. One-time step -- doesn't need any VIC output.
4. `13_run_rvic_convolution.R` -- runs `rvic convolution`: combines
   12's unit hydrographs with VIC's actual `output/fluxes.*.nc`
   (OUT_RUNOFF/OUT_BASEFLOW) to produce a routed streamflow time series.
5. `14_postprocess_routing.R` -- reads that time series, writes a CSV,
   and plots it -- optionally overlaid with observed USGS discharge at
   06752500 (via the `dataRetrieval` package, if installed) as a sanity
   check.

## Setup

RVIC and pyflwdir need their own Python environment (recommended:
`python=3.10`, separate from MetSim's) -- see `setup/SETUP.md` sections
6 (7z, for extracting the NHDPlus download) and 7 (RVIC + pyflwdir
install). Point `config.yml`'s `paths.rvic_python` and
`paths.pyflwdir_python` at that environment.

## Important caveat: naturalized flow

This VIC run does not model irrigation diversions, trans-basin imports,
or reservoir operations -- all of which can affect observed discharge at
a real gauge. Simulated streamflow will NOT necessarily match observed
discharge 1:1, even in gauge mode where the drainage areas match exactly
by construction. Use the observed overlay in `14_postprocess_routing.R`
to sanity-check timing and shape (does simulated flow rise and recede
when observed flow does?), not absolute volume -- unless you've
separately confirmed the specific basin you're running has minimal
regulation/diversion (as was true for the original Poudre-at-Greeley
test AOI).

## Status

Written and unit/syntax-tested (including a synthetic-data pass through
the flow-direction derivation and the NetCDF-reading logic in
`14_postprocess_routing.R`), but not yet run end-to-end against the real
NHDPlus download and real RVIC binary -- that's the next step once
setup/SETUP.md sections 6-7 are installed.
