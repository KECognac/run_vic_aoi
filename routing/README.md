# Routing (phase 2)

Scripts 10-14 in `R/` add RVIC (https://github.com/UW-Hydro/RVIC) routing
on top of the grid-cell water balance from scripts 01-09, producing
routed daily streamflow (m3/s) at a real USGS gauge. `15_calibrate_routing.R`
is an optional sixth step on top of that: a velocity/diffusion grid
search against observed discharge, scored by KGE.

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
   package (HUC4 1019 for the original Poudre AOI; whichever HUC4
   contains your AOI otherwise -- see that script's header) that has the
   DEM.
2. `11_build_routing_inputs.R` -- finds that DEM, shells out to
   `python/build_routing_inputs.py` to build `routing_inputs.nc`.
3. `12_run_rvic_parameters.R` -- runs `rvic parameters`: combines
   `routing_inputs.nc`, `routing/pour_points.csv`, and
   `routing/uh_box.csv` into unit hydrographs routed to the AOI's pour
   point (see "Pour point" above for how that's chosen). One-time step --
   doesn't need any VIC output.
4. `13_run_rvic_convolution.R` -- runs `rvic convolution`: combines
   12's unit hydrographs with VIC's actual `output/fluxes.*.nc`
   (OUT_RUNOFF/OUT_BASEFLOW) to produce a routed streamflow time series.
5. `14_postprocess_routing.R` -- reads that time series, writes a CSV,
   and plots it -- optionally overlaid with observed USGS discharge at
   whichever gauge `config.yml`'s `routing.observed_gauge_site_no` names
   (via the `dataRetrieval` package, if installed) as a sanity check.
6. `15_calibrate_routing.R` (optional) -- grid-searches RVIC's
   `velocity`/`diffusion` parameters (reruns steps 3-5 once per
   combination), scoring each against observed discharge with KGE, and
   prints the best combination found -- does NOT update `config.yml`
   itself, see that script's own header comment.

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

Run end-to-end against the real NHDPlus HR download and the real RVIC
binary -- not just the synthetic-data/unit-test passes this section used
to describe. Confirmed for the current Nisqually AOI (USGS gauge
`12082500`): `10`-`14` produce real routed streamflow for the full
1980-2010 run, and `15_calibrate_routing.R`'s grid search completes
successfully against real observed discharge (KGE \~0.45 at RVIC's
PNW-sample default parameters, `velocity: 0.5`/`diffusion: 500`).

Two real bugs were found and fixed getting this far, both worth knowing
if you're extending this pipeline:

- **RVIC's case directories aren't purged across separate runs** --
  `CLEAN: True` in RVIC's own config doesn't do this, and RVIC stamps
  output filenames with the current date, so rerunning `12`/`13` on a
  different day (or, for `15`, once per grid-search combination) used to
  leave old dated files sitting next to new ones, causing anything from a
  loud "expected exactly 1 parameter file, found 2" failure to a silent
  wrong-answer risk. Both scripts now wipe their own case directory
  before every run.
- **R's `as.Date()` disagrees with RVIC/VIC's shared NetCDF time origin**
  ("days since 0001-01-01") by a couple of days relative to what the
  file's own CF `calendar` attribute actually means (confirmed by
  cross-checking against Python's `netCDF4`/`cftime` decoding of the same
  raw values) -- this silently produced "0 overlapping simulated/observed
  days" in `15_calibrate_routing.R`. Both `15` and `09_postprocess_outputs.R`
  now anchor dates to `config.yml`'s `run$start_date` and count forward
  one day per record instead of decoding the file's declared origin.
