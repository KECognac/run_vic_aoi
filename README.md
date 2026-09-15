---

editor_options: 
  markdown: 
    wrap: 79
---

# run_vic_aoi

Runs the VIC hydrologic model (image driver) for an area of interest, using Livneh's precompiled CONUS parameter set as the starting point for soil/vegetation/snow-band parameters, orchestrated from R.

**Current test AOI:** the watershed draining to USGS gauge `12082500` (Nisqually River, WA), delineated via `aoi.mode: "gauge"` in `config.yml`. The original test AOI was the Cache la Poudre River, HUC8 `10190007` (CO), via `aoi.mode: "huc"`.

`config.yml`'s `aoi:` block supports two ways to define the AOI:

- `mode: "gauge"` -- the AOI is the actual watershed upstream of `aoi.gauge_site_no`, delineated by USGS's NLDI. Recommended when you want the AOI to correspond exactly to what a real gauge measures (see `routing/README.md` and `R/01_get_aoi_boundary.R`'s header comment for why -- a WBD HUC's own area is not the same thing as a gauge's cumulative drainage area).
- `mode: "huc"` (the original design) -- the AOI is a WBD HUC8/10/12 polygon named by `aoi.huc_id`/`aoi.huc_level`.

## Quick start

1.  First, install [Homebrew](https://brew.sh) and [conda](https://docs.conda.io/en/latest/miniconda.html) (Miniconda or Miniforge) if you don't already have them -- neither this repo nor `setup/setup_macos.sh` installs either one for you, and everything below assumes both are already on your machine. Then read `setup/SETUP.md` (its own "Prerequisites" section has the details) and do the one-time installs (R packages, Homebrew compilers/NetCDF, build VIC, install Tonic, install MetSim) -- or run `setup/setup_macos.sh` to automate all of it (and RVIC's install, section 7) in one script, safe to re-run if it fails partway through.

2.  Open `config.yml` and edit the `paths:` block for your machine -- `vic_source_dir`, `vic_image_exe`, and anything else that isn't a relative path inside this repo.

3.  Run the scripts in `R/` in order (00 is sourced automatically by each of the others, you don't run it directly):

    ```         
    01_get_aoi_boundary.R          fetch HUC boundary + bbox
    02_download_vic_params.R       download Livneh ASCII VIC4 params
    02b_subset_params_to_aoi.R     trim to AOI bbox (makes 03 fast -- run before it)
    03_convert_params_to_netcdf.R  ASCII -> image-driver NetCDF (via Tonic)
    04_download_forcing.R          download Livneh forcing (monthly, full-CONUS,
                                    plus MetSim's 90-day spin-up window)
    04b_build_forcing_netcdf.R     subset to AOI, concat months -> forcing.<YYYY>.nc
    05_build_domain.R              align params to forcing grid, write domain.nc (+elev)
    06_run_metsim.R                derive AIR_TEMP/SWDOWN/LWDOWN/VP/PRESSURE from
                                    Tmax/Tmin/Prec/Wind (VIC5 needs all 7, see below)
    07_write_globalparam.R         write global_param.txt, pointing at 06's output
    08_run_vic.R                   run the compiled VIC binary
    09_postprocess_outputs.R       AOI-mean daily water balance, plot + CSV
    09b_plot_gridded_maps.R        period-of-record mean maps (any variable), gridded --
                                    not AOI-averaged like 09, keeps (lat, lon) and collapses time
    ```

    Routing (phase 2, adds routed streamflow at a real gauge -- see `setup/SETUP.md` sections 6-7 for the 7z/RVIC/pyflwdir installs these need first, and `routing/README.md` for the full picture):

    ```         
    10_download_nhdplus.R          download NHDPlus HR raster package (flow direction source)
    11_build_routing_inputs.R      derive flow direction/distance/basin/source-area on domain's grid
    12_run_rvic_parameters.R       RVIC: build unit hydrographs routed to the AOI's pour point (one-time)
    13_run_rvic_convolution.R      RVIC: route VIC's OUT_RUNOFF/OUT_BASEFLOW into streamflow
    14_postprocess_routing.R       plot routed streamflow, optionally vs. observed USGS discharge
    15_calibrate_routing.R         optional: grid-search RVIC's velocity/diffusion against
                                    observed discharge (KGE-scored) -- see its own header comment
    ```

    To run everything above end to end in one go and see every plot together, knit `run_full_pipeline.Rmd` from RStudio instead of running scripts one at a time -- see its own header comment for exactly what it reruns automatically (everything) and what's opt-in (15's calibration grid search, off by default since it's far slower than the rest of the pipeline combined).

## Reproducibility / editing for your own setup

Every path is centralized in `config.yml` and resolved in `R/00_config.R` -- no script hardcodes a path. If you're running this on a different machine or for a different AOI, `config.yml` is the only file you should need to touch (aside from `R/03`'s `file_map`, which has to point at whatever the Livneh directory actually contains -- see the comments at the top of that script).

## Why R AND Python?

This repo is orchestrated from R -- config, NetCDF assembly, and postprocessing all happen in `R/` -- but four steps shell out to Python, because the actual tool needed at each of those steps only exists there, not because R can't handle NetCDF or scientific computing (it does that fine, via `ncdf4`, throughout this pipeline):

- **Tonic** (`03_convert_params_to_netcdf.R`) -- converts the Livneh ASCII VIC4 parameter files into the NetCDF format VIC5's image driver requires. No R equivalent exists.
- **MetSim** (`06_run_metsim.R`) -- VIC5 dropped the old MTCLIM disaggregation that let VIC4 take Tmax/Tmin/Prec directly, so something has to derive the full set of variables VIC5 needs (air temp, shortwave/longwave radiation, vapor pressure, air pressure, wind) from Livneh's raw Tmax/Tmin/Prec/Wind. MetSim is UW-Hydro's standalone replacement for that -- Python-only.
- **pyflwdir** (`python/build_routing_inputs.py`, called from `11_build_routing_inputs.R`) -- derives D8 flow direction from the NHDPlus DEM and upscales it to VIC's grid with the IHU algorithm, purpose-built for exactly this "prepare a routing model's flow grid" problem. A Deltares library, Python-only.
- **RVIC** itself (`12_run_rvic_parameters.R`, `13_run_rvic_convolution.R`) -- the routing model that turns VIC's gridded runoff/baseflow into a routed hydrograph at the pour point. Also UW-Hydro, also Python (with one small C extension).

All four come out of the University of Washington hydrology group's VIC tooling, which has always been Python, not R. That's also why `config.yml` has separate `tonic_python`/`metsim_python`/`rvic_python`/ `pyflwdir_python` entries rather than one shared interpreter: these tools have very different, sometimes conflicting, dependency pins (MetSim and RVIC especially, given their age) -- see `setup/SETUP.md` for the per-tool environment instructions.

## What's been confirmed (both the original Poudre test AOI, phase 1 only, and the current Nisqually AOI, phases 1 and 2 including routing + calibration, running end to end)

- `livneh_params_base` = the Livneh 2015 NAmer-extension VIC4 ASCII params (soil/veg/veglib/snow -- see comments in `R/03`'s `file_map` for exactly which file is which; despite the "mexico" naming, these cover CONUS fine).
- `livneh_forcing_base` = the Livneh 2013 CONUS-only meteorology, one NetCDF file per MONTH (not per grid cell), variables named `Prec`/`Tmax`/`Tmin`/`Wind` (see `R/04`/`R/04b`).
- `vic_params` block (nlayers=3, snow_bands=5, veg_classes=11, root_zones=3): confirmed against the original VIC4 global param template shipped alongside the params files, and independently against `LDAS_veg_lib`'s row count.
- Tonic (the ASCII-\>NetCDF conversion library, no R equivalent exists) needed three compatibility patches for a modern Python/NumPy/SciPy -- see `setup/SETUP.md`'s tonic section.
- **Grid alignment**: Tonic's own grid-building step leaves tiny floating-point drift in the params NetCDF's lat/lon spacing (an extra, fully-masked row/column vs. the forcing grid's exact spacing). VIC requires DOMAIN/PARAMS/FORCING to share identical coordinates, so `05_build_domain.R` snaps params onto the forcing grid's precise coordinates before writing domain.nc (see `python/align_params_to_forcing.py`) -- confirmed empirically that every forcing cell lands on a valid params cell after snapping, with \~0.003 deg residual (floating-point noise, not a real offset).
- **Building VIC on macOS/Homebrew hits five separate errors in sequence** (missing `mpicc`, Apple clang not supporting `-fopenmp`, missing SDK headers/libs, duplicate-symbol link errors from GCC 10+'s `-fno-common` default) -- all found and fixed getting this repo's test run compiled; see `setup/SETUP.md` section 3 for the exact fixes, in the order they actually came up.
- **VIC5 dropped MTCLIM** (confirmed from VIC's own 5.0.1 release notes): neither driver can take Tmax/Tmin/Prec directly anymore, the way VIC4 used to. VIC5's image driver requires AIR_TEMP/PREC/PRESSURE/SWDOWN/ LWDOWN/VP/WIND supplied directly, so `06_run_metsim.R` runs MetSim (UW-Hydro's own standalone MTCLIM replacement) to derive the full set from Livneh's Prec/Tmax/Tmin/Wind before VIC ever sees it. This also means the run is sub-daily internally (3-hourly by default -- MetSim's daily-output mode doesn't include everything VIC needs), with output aggregated back to daily via `AGGFREQ NDAYS 1`. Two non-obvious things confirmed empirically building this: MetSim's 90-day state/spin-up requirement is a hard assertion, not a soft one, and its `vapor_pressure` output is mislabeled with a "Pa" units attribute when the actual values are already kPa-scaled (see `06_run_metsim.R`'s header comment). This same MetSim step is also what you'd reuse to drive VIC from LOCA2 or another Tmax/Tmin/Prec-only source later.
- **VIC5 doesn't write `OUT_PET` (potential evapotranspiration) by default** -- getting it (or any variable beyond VIC's default set) means `07_write_globalparam.R` writing an explicit `OUTFILE`/`OUTVAR` block, which turns OFF VIC's default output entirely for every stream it touches, not just the one variable you wanted -- confirmed against VIC5's own docs and a live rerun that everything previously relied upon (fluxes/snow/snowband) still comes out the same, with `OUT_PET` now added alongside it.
- **RVIC needed seven compatibility patches** for a modern Python/NumPy/pandas/netCDF4-python (removed `.ix`/`np.float` APIs, three separate `netCDF4.stringtochar()` incompatibilities, a `cftime`/`date2index()` calendar-mismatch bug, and a NumPy 2.x silent int64 upcast that breaks RVIC's one C-extension call) -- each found by actually reproducing the failure against this pipeline's real data, not guessed; see `setup/SETUP.md` section 7 (all seven are applied automatically by `setup/setup_macos.sh`).
- **R's `as.Date()` disagrees with the file's own CF calendar for an ancient NetCDF time origin** ("days since 0001-01-01", the origin RVIC/VIC both use) -- confirmed by cross-checking against Python's `netCDF4`/`cftime` decoding of the same raw values: R's `as.Date(x, origin = "0001-1-1")` is self-consistent but lands a couple of days off from what the file's `calendar` attribute actually means. `15_calibrate_routing.R` and `09_postprocess_outputs.R` both work around this by anchoring dates to `config.yml`'s own `run$start_date` and counting forward one day per record instead of decoding the file's declared origin -- worth knowing if you add a new script that reads time from one of these NetCDFs.

## Known gaps / things to verify before trusting results

- **Routing (scripts 10-14) has been run end-to-end** for the Nisqually AOI against the real NHDPlus HR download and the real RVIC binary -- not just synthetic-data/config checks. `15_calibrate_routing.R`'s velocity/diffusion grid search has also completed successfully against real observed USGS discharge at gauge `12082500` (KGE \~0.45 at RVIC's PNW-sample default parameters, `velocity: 0.5`/`diffusion: 500`, over the full 1980-2010 run). Routes to whichever gauge `config.yml`'s `routing:` block points at -- see `routing/README.md` for how that pour point is chosen (auto, in gauge mode; by hand, in huc mode) and why. **The VIC run is naturalized** (no irrigation diversions, trans-basin imports, or reservoir operations modeled), so routed flow will NOT necessarily match observed discharge at that gauge 1:1 -- this is a real, permanent limitation of the simulation itself, not a testing gap -- `14_postprocess_routing.R`'s optional USGS overlay (and `15`'s KGE score) are a timing/shape sanity check and calibration target, not a validation of absolute streamflow volume.
- **MetSim's radiation/humidity estimates** are a real physical model (not the crude approximations that would've been used without it), but they're still statistically estimated from Tmax/Tmin/Prec, not observed -- keep that in mind before treating shortwave/longwave/VP- sensitive outputs (like snowmelt timing) as highly precise.
- **Cite the data** -- see `CITATION.md` for the full required + optional citation list -- in anything produced from this pipeline. If you use MetSim, cite it too (see MetSim's GitHub repo / relevant papers).
