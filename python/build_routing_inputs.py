"""
build_routing_inputs.py

Builds RVIC's "routing input" NetCDF (Flow_Direction, Flow_Distance,
Basin_ID, Source_Area) EXACTLY on domain.aoi.nc's grid, from NHDPlus HR's
hydro-conditioned DEM.

Why derive flow direction fresh from the DEM instead of reprojecting
NHDPlus's own pre-computed fdr.tif directly: flow direction codes are
DIRECTIONAL, encoded relative to the source raster's own coordinate axes.
Reprojecting those codes into a different CRS (NHDPlus HR's raster
component is in a projected CRS, our target is geographic lat/lon) can
silently rotate what a code means -- nearest-neighbor resampling carries
the CODE VALUE across unchanged, but the axis it was encoded against has
rotated. Elevation has no such problem (it's a continuous scalar field,
reprojects/resamples cleanly with ordinary bilinear interpolation), and
NHDPlus's "hydrodem" is pre-conditioned (sinks filled, streams burned)
specifically so that running an ordinary D8-from-DEM algorithm on it
reproduces the real mapped channels. So: reproject the DEM (safe), then
derive D8 fresh on our own aligned grid (pyflwdir.from_dem), then upscale
to domain.aoi.nc's resolution (pyflwdir's IHU method -- built for exactly
this macro-scale-routing-model use case).

Alignment is the part that actually matters for RVIC: with REMAP=False in
rvic.parameters.cfg (our setup -- routing grid == domain grid, no CESM-
style remapping needed), the routing input file's lon/lat MUST match
domain.aoi.nc's exactly. This script never trusts floating-point transform
arithmetic to guarantee that on its own -- it always writes domain.aoi.nc's
OWN lon/lat arrays verbatim into the output, and separately asserts (not
just hopes) that the upscaled grid's computed transform matches the
intended one before doing so.
"""
import argparse
import math
import sys

import numpy as np
import netCDF4 as nc
import rasterio
from rasterio.warp import reproject, Resampling, calculate_default_transform
from rasterio.transform import Affine
import pyflwdir

D8_NODATA = 247  # pyflwdir's own d8 nodata code (used by to_array("d8"))
EARTH_M_PER_DEG_LAT = 111_320.0  # standard approximation, matches the rest
                                   # of this pipeline's flow-distance-style
                                   # calculations elsewhere


def read_domain_grid(domain_nc_path):
    ds = nc.Dataset(domain_nc_path)
    lon = np.array(ds.variables["lon"][:], dtype="float64")
    lat = np.array(ds.variables["lat"][:], dtype="float64")
    mask = np.array(ds.variables["mask"][:], dtype="int32")  # (lat, lon)
    ds.close()

    lon_steps = np.diff(lon)
    lat_steps = np.diff(lat)
    if not np.allclose(lon_steps, lon_steps[0], atol=1e-9) or \
       not np.allclose(lat_steps, lat_steps[0], atol=1e-9):
        raise ValueError("domain.aoi.nc's lon/lat are not evenly spaced -- "
                          "this script assumes a regular grid.")
    res_lon = float(lon_steps[0])
    res_lat = float(lat_steps[0])
    if abs(res_lon) - abs(res_lat) > 1e-9:
        raise ValueError(f"domain grid isn't square (lon step {res_lon}, "
                          f"lat step {res_lat}) -- this script assumes it is.")
    res = abs(res_lon)

    # lon/lat are CELL CENTERS -- edges are +/- half a cell.
    west = lon.min() - res / 2
    north = lat.max() + res / 2
    return {
        "lon": lon, "lat": lat, "mask": mask,
        "res": res, "west": west, "north": north,
        "w": len(lon), "h": len(lat),
    }


def build_fine_grid(domain, scale_factor, pad_cells):
    """Fine grid transform/shape: an exact integer subdivision of the
    (padded) coarse domain grid, so alignment after upscaling is exact by
    construction, not by luck."""
    res = domain["res"]
    fine_res = res / scale_factor
    padded_w = domain["w"] + 2 * pad_cells
    padded_h = domain["h"] + 2 * pad_cells
    fine_w = padded_w * scale_factor
    fine_h = padded_h * scale_factor
    fine_west = domain["west"] - pad_cells * res
    fine_north = domain["north"] + pad_cells * res
    fine_transform = Affine(fine_res, 0, fine_west, 0, -fine_res, fine_north)
    return fine_transform, fine_w, fine_h


def reproject_dem_to_fine_grid(dem_path, fine_transform, fine_w, fine_h):
    with rasterio.open(dem_path) as src:
        src_nodata = src.nodata if src.nodata is not None else -9999.0
        # NHDPlus HR's native DEM is 10m; our fine grid is typically
        # 100-350m (domain_res / fine_scale_factor). That's a big
        # downsampling ratio, where Resampling.average is the safer
        # default for a continuous field like elevation than bilinear
        # (which just interpolates a handful of nearby source pixels and
        # can alias/miss narrow valleys when the ratio is this large).
        dst = np.full((fine_h, fine_w), np.nan, dtype="float64")
        reproject(
            source=rasterio.band(src, 1),
            destination=dst,
            src_transform=src.transform,
            src_crs=src.crs,
            dst_transform=fine_transform,
            dst_crs="EPSG:4326",
            dst_nodata=np.nan,
            src_nodata=src_nodata,
            resampling=Resampling.average,
        )
    return dst


def flow_distance_from_d8(d8, res_deg, lat_centers):
    """Straight-line distance (m) from each cell center to its downstream
    neighbor's center, per RVIC's definition ("the distance in the
    direction of the flow direction -- zonal, meridional, or diagonal").
    ESRI/pyflwdir D8 codes: 1=E,2=SE,4=S,8=SW,16=W,32=NW,64=N,128=NE."""
    h, w = d8.shape
    dy = res_deg * EARTH_M_PER_DEG_LAT
    # zonal (E-W) distance shrinks with latitude -- broadcast per row.
    dx_row = res_deg * EARTH_M_PER_DEG_LAT * np.cos(np.deg2rad(lat_centers))
    dx = np.broadcast_to(dx_row[:, None], (h, w))
    diag = np.sqrt(dx ** 2 + dy ** 2)

    dist = np.full((h, w), dy, dtype="float64")  # fallback for pits/nodata
    ew = np.isin(d8, [1, 16])
    ns = np.isin(d8, [4, 64])
    dg = np.isin(d8, [2, 8, 32, 128])
    dist[ew] = dx[ew]
    dist[ns] = dy
    dist[dg] = diag[dg]
    return dist


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dem-tif", required=True)
    p.add_argument("--domain-nc", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--fine-scale-factor", type=int, default=32,
                    help="Fine-grid cells per coarse (domain) cell. Higher "
                         "= more faithful to real channel geometry, slower. "
                         "32 -> ~170m fine cells for a 1/16deg domain.")
    p.add_argument("--pad-cells", type=int, default=2,
                    help="Extra coarse-grid cells of padding around the "
                         "domain before deriving flow direction, so edge "
                         "cells aren't artificially treated as basin pits.")
    args = p.parse_args()

    print(f"Reading domain grid from {args.domain_nc}...", flush=True)
    domain = read_domain_grid(args.domain_nc)
    print(f"  {domain['w']}x{domain['h']} @ {domain['res']} deg, "
          f"west={domain['west']:.5f} north={domain['north']:.5f}")

    fine_transform, fine_w, fine_h = build_fine_grid(
        domain, args.fine_scale_factor, args.pad_cells)
    print(f"Fine grid: {fine_w}x{fine_h} @ {fine_transform.a:.7f} deg "
          f"(scale_factor={args.fine_scale_factor}, pad={args.pad_cells} "
          f"coarse cells)")

    print(f"Reprojecting {args.dem_tif} onto the fine grid...", flush=True)
    dem = reproject_dem_to_fine_grid(args.dem_tif, fine_transform, fine_w, fine_h)
    n_valid = np.isfinite(dem).sum()
    print(f"  {n_valid}/{dem.size} fine cells have valid elevation "
          f"({100 * n_valid / dem.size:.1f}%)")
    if n_valid < 0.5 * dem.size:
        print("WARNING: less than half the fine grid has valid elevation "
              "after reprojection -- the DEM likely doesn't fully cover "
              "the (padded) AOI, or the reprojection went wrong. Flow "
              "direction near the gaps will be unreliable. Inspect before "
              "trusting the output.", file=sys.stderr)

    dem_filled = np.where(np.isfinite(dem), dem, -9999.0)

    print("Deriving D8 flow direction from the DEM (pyflwdir.from_dem)...",
          flush=True)
    flw = pyflwdir.from_dem(
        data=dem_filled,
        nodata=-9999.0,
        transform=fine_transform,
        latlon=True,
        outlets="min",
    )

    print("Computing upstream area + upscaling to the domain grid "
          "(IHU method)...", flush=True)
    uparea = flw.upstream_area(unit="km2")
    flw1, idxs_out = flw.upscale(
        scale_factor=args.fine_scale_factor, uparea=uparea, method="ihu")

    padded_w = domain["w"] + 2 * args.pad_cells
    padded_h = domain["h"] + 2 * args.pad_cells
    if flw1.shape != (padded_h, padded_w):
        raise RuntimeError(
            f"Upscaled grid shape {flw1.shape} != expected padded domain "
            f"shape {(padded_h, padded_w)} -- scale_factor/pad_cells "
            f"arithmetic is wrong somewhere, this should be impossible "
            f"by construction. Do not trust the output.")

    expected_padded_transform = Affine(
        domain["res"], 0, domain["west"] - args.pad_cells * domain["res"],
        0, -domain["res"], domain["north"] + args.pad_cells * domain["res"])
    actual = tuple(flw1.transform)
    expected = tuple(expected_padded_transform)
    if not all(abs(a - b) < 1e-9 for a, b in zip(actual, expected)):
        raise RuntimeError(
            f"Upscaled grid transform {actual} != expected {expected} -- "
            f"alignment with domain.aoi.nc is NOT guaranteed. Do not trust "
            f"the output. (This should be impossible given the fine grid "
            f"was built as an exact integer subdivision of the padded "
            f"domain grid -- if you see this, something upstream changed.)")
    print("  alignment check passed: upscaled grid transform matches the "
          "padded domain grid exactly.")

    # Crop the padding back off -- pad_cells was only there so edge cells
    # of the ACTUAL domain aren't treated as artificial basin pits.
    pc = args.pad_cells
    d8_full = flw1.to_array("d8")
    d8 = d8_full[pc: pc + domain["h"], pc: pc + domain["w"]]

    subareas_km2 = flw.ucat_area(idxs_out=idxs_out, unit="km2")[1]
    uparea1_full = flw1.accuflux(subareas_km2)
    source_area_m2 = (uparea1_full[pc: pc + domain["h"], pc: pc + domain["w"]]
                       * 1e6)  # km2 -> m2, per RVIC's SOURCE_AREA_VAR doc

    # FLIP VERTICALLY (row 0 <-> last row) before doing anything else with
    # these arrays. flw1 (and therefore d8/uparea1_full above) is in
    # north-up raster row order -- row 0 = the NORTH edge -- inherited
    # from fine_transform's negative y pixel size (build_fine_grid()
    # above), which is the standard GIS/pyflwdir raster convention.
    # domain["lat"] (read straight from domain.aoi.nc, same array this
    # output's own "lat" coordinate gets set to below) is ASCENDING --
    # row 0 = SOUTH -- matching CF/netCDF convention and every other grid
    # in this pipeline (ultimately inherited from the Livneh forcing
    # grid). Writing d8/source_area_m2 in north-up order under an
    # ascending lat coordinate, without this flip, mislabels every row's
    # data against its own declared latitude.
    #
    # This isn't just a latitude-label cosmetic issue: RVIC's own
    # parameters.py explicitly detects an ascending lat array
    # ("fdr_data[fdr_lat][-1] > fdr_data[fdr_lat][0]") and responds by
    # flipping EVERY variable (np.flipud) to convert to its own internal
    # north-up convention. Fed our (already north-up, but ascending-
    # labeled) data, that flip runs anyway and flips it a SECOND time,
    # landing RVIC's internal working array back in south-up order where
    # it expects north-up -- silently scrambling the local D8
    # neighbor-to-neighbor topology. Confirmed as the actual root cause
    # of `rvic parameters` crashing with
    # "IndexError: index N is out of bounds ... pathy[cells] = yy" deep in
    # search_catchment() (rvic/core/make_uh.py): a topology scrambled this
    # way isn't the real drainage network, and can and did create D8
    # cycles a real network can't -- confirmed by reproducing RVIC's exact
    # read-then-flip behavior against this file's actual data in a
    # standalone simulation of search_catchment's cell-walking logic
    # before writing this fix. Flipping HERE, before writing, means
    # RVIC's own flip cancels it out and its internal array ends up
    # exactly matching pyflwdir's native (correct, cycle-free by
    # construction) north-up D8 output -- verified the same way, with no
    # cycles found.
    d8 = d8[::-1, :]
    source_area_m2 = source_area_m2[::-1, :]

    flow_distance = flow_distance_from_d8(d8, domain["res"], domain["lat"])

    # Basin_ID: uniform 1 wherever domain.aoi.nc's own mask says land --
    # this IS a single-basin routing setup (one pour point), and tying it
    # directly to the domain's own mask (rather than recomputing a "valid
    # DEM" mask separately) guarantees the two can never disagree.
    basin_id = np.where(domain["mask"] != 0, 1, 0).astype("int32")

    d8 = np.where(domain["mask"] != 0, d8, D8_NODATA).astype("int32")
    flow_distance = np.where(domain["mask"] != 0, flow_distance, 0.0)
    source_area_m2 = np.where(domain["mask"] != 0, source_area_m2, 0.0)

    print(f"Writing {args.out}...", flush=True)
    out = nc.Dataset(args.out, "w", format="NETCDF4_CLASSIC")
    out.createDimension("lon", domain["w"])
    out.createDimension("lat", domain["h"])
    v_lon = out.createVariable("lon", "f8", ("lon",))
    v_lat = out.createVariable("lat", "f8", ("lat",))
    v_lon.units = "degrees_east"
    v_lat.units = "degrees_north"
    v_lon[:] = domain["lon"]
    v_lat[:] = domain["lat"]

    v_fdir = out.createVariable("Flow_Direction", "i4", ("lat", "lon"),
                                 fill_value=D8_NODATA)
    v_fdir.long_name = "D8 flow direction (ESRI convention: 1=E,2=SE,4=S,8=SW,16=W,32=NW,64=N,128=NE)"
    v_fdir[:, :] = d8

    v_fdist = out.createVariable("Flow_Distance", "f8", ("lat", "lon"),
                                  fill_value=0.0)
    v_fdist.units = "m"
    v_fdist.long_name = "distance to downstream cell center along flow direction"
    v_fdist[:, :] = flow_distance

    v_basin = out.createVariable("Basin_ID", "i4", ("lat", "lon"),
                                  fill_value=0)
    v_basin.long_name = "basin ID (uniform 1 within domain.aoi.nc's land mask)"
    v_basin[:, :] = basin_id

    v_area = out.createVariable("Source_Area", "f8", ("lat", "lon"),
                                 fill_value=0.0)
    v_area.units = "m2"
    v_area.long_name = "upstream contributing area (aggregated from the fine-resolution DEM)"
    v_area[:, :] = source_area_m2

    out.title = "RVIC routing inputs derived from NHDPlus HR (build_routing_inputs.py)"
    out.close()
    print("Done.")


if __name__ == "__main__":
    main()
