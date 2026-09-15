#!/usr/bin/env python
"""
align_params_to_forcing.py

Fixes a real grid-registration issue found by actually running this
pipeline: Tonic's calc_grid() builds the parameter NetCDF's lat/lon axes
with np.arange() using a step size derived from stats.mode(diff(coords))
on the ORIGINAL ASCII soil file's own stored coordinates. Those
coordinates carry tiny floating-point imprecision (observed: a step of
~0.062399... instead of exactly 0.0625), which accumulates across the
grid and adds ONE SPURIOUS, FULLY-MASKED extra row and column beyond
where real soil data exists.

The Livneh forcing NetCDF files, by contrast, have an exact, evenly
0.0625-spaced grid. VIC's image driver requires DOMAIN, PARAMS, and
FORCING to share identical lat/lon coordinates -- so this snaps every
parameter grid cell onto the forcing grid's precise coordinates (nearest
neighbor; observed residual ~0.003 deg, i.e. floating-point noise, not a
real spatial offset) and drops the spurious padding.

Usage:
    python align_params_to_forcing.py \
        --params-in params.vic5.nc --forcing-ref forcing.2009.nc \
        --out params.aligned.nc [--max-residual-deg 0.01]
"""
import argparse
import netCDF4 as nc
import numpy as np


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--params-in", required=True)
    p.add_argument("--forcing-ref", required=True,
                   help="any one forcing NetCDF with the target grid's exact lat/lon")
    p.add_argument("--out", required=True)
    p.add_argument("--max-residual-deg", type=float, default=0.01,
                   help="abort if nearest-neighbor snap distance exceeds this "
                        "(guards against silently mis-aligning a genuinely "
                        "different grid)")
    args = p.parse_args()

    src = nc.Dataset(args.params_in)
    ref = nc.Dataset(args.forcing_ref)

    plat, plon = src.variables["lat"][:], src.variables["lon"][:]
    tlat, tlon = ref.variables["lat"][:], ref.variables["lon"][:]

    iy_map = np.array([np.argmin(np.abs(plat - y)) for y in tlat])
    ix_map = np.array([np.argmin(np.abs(plon - x)) for x in tlon])
    resid = max(np.max(np.abs(plat[iy_map] - tlat)),
                np.max(np.abs(plon[ix_map] - tlon)))
    print(f"max residual after snapping to forcing grid: {resid:.5f} deg")
    if resid > args.max_residual_deg:
        raise SystemExit(
            f"Residual {resid:.5f} exceeds --max-residual-deg "
            f"{args.max_residual_deg} -- this looks like a real grid "
            f"mismatch, not floating-point noise. Refusing to snap blindly; "
            f"investigate params vs. forcing grid alignment before re-running."
        )

    out = nc.Dataset(args.out, "w")
    for name, dim in src.dimensions.items():
        if name == "lat":
            out.createDimension("lat", len(tlat))
        elif name == "lon":
            out.createDimension("lon", len(tlon))
        else:
            out.createDimension(name, len(dim))

    n_inactive = 0
    for name, var in src.variables.items():
        dims = var.dimensions
        data = var[:]
        if "lat" in dims and "lon" in dims:
            data = np.take(data, iy_map, axis=dims.index("lat"))
            data = np.take(data, ix_map, axis=dims.index("lon"))
        if name == "lat":
            data = tlat
        if name == "lon":
            data = tlon
        fill = getattr(var, "_FillValue", None)
        v = out.createVariable(name, var.dtype, dims, fill_value=fill)
        v.setncatts({k: var.getncattr(k) for k in var.ncattrs() if k != "_FillValue"})
        v[:] = data
        if name == "run_cell":
            n_inactive = int(np.sum(data == 0))

    out.close()
    src.close()
    ref.close()

    print(f"wrote {args.out} ({len(tlat)} x {len(tlon)} grid, "
          f"{n_inactive} inactive cells after snapping)")
    if n_inactive > 0:
        print("WARNING: some forcing grid cells landed on an inactive/masked "
              "params cell after snapping -- those cells will have no valid "
              "soil parameters. Inspect before trusting the run.")


if __name__ == "__main__":
    main()
