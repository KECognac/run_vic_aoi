#!/usr/bin/env python
"""
convert_params_to_netcdf.py

Thin CLI wrapper around Tonic (https://github.com/UW-Hydro/tonic) that
converts classic-driver VIC4 ASCII parameter files (soil, veg param, veg
library, snow band) into a single VIC 5 image-driver parameter NetCDF
file, as documented at:
https://vic.readthedocs.io/en/master/Documentation/Drivers/Image/Ascii_to_NetCDF_params/

There is no R equivalent of Tonic, so R/03_convert_params_to_netcdf.R
calls this script with system2() rather than reimplementing the
conversion. Requires a Python env with tonic installed -- see
setup/SETUP.md.

Usage:
    python convert_params_to_netcdf.py \
        --soil soil.txt --veg vegparam.txt --veglib veglib.txt \
        --snow snowband.txt --nlayers 3 --snow-bands 5 --veg-classes 11 \
        --out params.vic5.nc
"""
import argparse

from tonic.models.vic.grid_params import (
    soil, snow, veg, veg_class, calc_grid, grid_params, write_netcdf, Cols
)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--soil", required=True, help="classic-driver soil parameter file")
    p.add_argument("--veg", required=True, help="classic-driver vegetation parameter file")
    p.add_argument("--veglib", required=True, help="classic-driver vegetation library file")
    p.add_argument("--snow", required=True, help="classic-driver snow band file")
    p.add_argument("--nlayers", type=int, required=True, help="number of soil layers")
    p.add_argument("--snow-bands", type=int, required=True, dest="snow_bands",
                    help="number of elevation/snow bands")
    p.add_argument("--veg-classes", type=int, required=True, dest="veg_classes",
                    help="number of vegetation classes (rows in veglib, excl. bare soil)")
    p.add_argument("--root-zones", type=int, default=3, dest="root_zones",
                    help="number of root zones in the veg param file (VIC's ROOT_ZONES)")
    p.add_argument("--out", required=True, help="output NetCDF path")
    p.add_argument("--version", default="5.0.dev", help="VIC version tag written to the file")
    args = p.parse_args()

    print(f"Reading soil params from {args.soil}")
    soil_dict = soil(args.soil, c=Cols(nlayers=args.nlayers))

    print(f"Reading snow bands from {args.snow}")
    snow_dict = snow(args.snow, soil_dict, c=Cols(snow_bands=args.snow_bands))

    print(f"Reading veg params from {args.veg}")
    # vegparam_lai/lai_src match this dataset's original global param file
    # (VEGPARAM_LAI TRUE, LAI_SRC LAI_FROM_VEGLIB) -- NOT the `lai_index`
    # kwarg shown in VIC's own docs example, which doesn't exist in the
    # current tonic source (docs drifted from the code).
    veg_dict = veg(args.veg, soil_dict, veg_classes=args.veg_classes,
                   max_roots=args.root_zones,
                   vegparam_lai=True, lai_src="FROM_VEGLIB")

    print(f"Reading veg library from {args.veglib}")
    # No skiprows param on this tonic version -- it auto-skips lines
    # starting with "#" (confirmed: LDAS_veg_lib's header line is
    # "#Class\tOvrStry\t...", so this "just works").
    # veg_class() returns a (dict, lib_bare_idx) TUPLE, not just the dict --
    # unpacking it wrong is silent until something downstream indexes the
    # tuple with a string key and blows up several calls later.
    veg_lib, lib_bare_idx = veg_class(args.veglib)

    print("Building target grid from soil lat/lon...")
    target_grid, target_attrs = calc_grid(soil_dict["lats"], soil_dict["lons"])

    print("Assembling gridded parameter dict...")
    # version_in (not version), and vegparam_lai/lai_src again to match
    # veg()'s settings above -- both are further spots where the VIC docs
    # example doesn't match tonic's actual current signature.
    grid_dict = grid_params(
        soil_dict, target_grid, version_in=args.version,
        veg_dict=veg_dict, veglib_dict=veg_lib, snow_dict=snow_dict,
        lib_bare_idx=lib_bare_idx,
        vegparam_lai=True, lai_src="FROM_VEGLIB",
    )

    print(f"Writing {args.out}")
    # write_netcdf() has no veglib_dict parameter at all (only
    # soil_grid/snow_grid/veg_grid/lake_grid) -- veglib info is already
    # folded into veg_grid by grid_params() above.
    write_netcdf(
        args.out, target_attrs, target_grid=target_grid,
        soil_grid=grid_dict["soil_dict"], snow_grid=grid_dict["snow_dict"],
        veg_grid=grid_dict["veg_dict"], version_in=args.version,
        vegparam_lai=True, lai_src="FROM_VEGLIB",
    )
    print("Done.")


if __name__ == "__main__":
    main()
