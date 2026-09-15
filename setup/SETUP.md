---

editor_options: 
  markdown: 
    wrap: 79
---

# Setup

One-time setup, done on your own machine (not something the R scripts do for you -- compiling VIC and installing Tonic/RVIC both need tools this repo can't install on its own).

## Prerequisites -- install these yourself first

Neither this file nor `setup/setup_macos.sh` installs these -- both assume they're already on your machine before you start:

- **Homebrew** (macOS's package manager) -- <https://brew.sh> -- installs the compilers, NetCDF, MPI, and 7z that sections 2, 3, and 6 below need. If `brew --version` in a terminal doesn't print a version, you don't have it yet.
- **conda** (Miniconda or Miniforge -- either works) -- <https://docs.conda.io/en/latest/miniconda.html> -- creates the isolated Python environments sections 4 and 7 (Tonic, RVIC) need. Both tools have old, sometimes-conflicting dependency pins that don't coexist with each other or with a normal system Python, which is the whole reason this repo uses conda envs instead of just `pip install`ing everything. If `conda --version` doesn't print a version, you don't have it yet.
- **R and RStudio** -- <https://posit.co/download/rstudio-desktop/> -- runs everything in `R/`, `run_full_pipeline.Rmd`, and section 1 below.

`setup/setup_macos.sh` checks for Homebrew and conda specifically and stops with a clear message if either is missing, rather than failing partway through some other step because one of them silently wasn't there.

## Shortcut: run it as one script

Everything below (sections 1-7) is also written up as `setup/setup_macos.sh`, which runs the exact same commands documented in this file, safe to re-run if it fails partway through (it checks what's already done before redoing it). It still needs the Prerequisites above already installed, and it prints the exact `config.yml` paths to paste in when it finishes:

``` sh
cd /path/to/run_vic_aoi
bash setup/setup_macos.sh
```

If it fails on something not covered here, share the exact error -- every fix in this file was found the same way, by actually reproducing the failure and patching it, not guessed in advance.

## Does this work on a PC?

Not directly, no. Everything below (Homebrew, `mpicc`/`gcc` via Open MPI, Xcode Command Line Tools' SDK headers, conda) is macOS/Unix-oriented, and `setup_macos.sh` in particular hardcodes several macOS-specific fixes (the `OMPI_CC`/`CPATH`/`LIBRARY_PATH` workarounds in section 3 are all about Homebrew's compilers losing track of Apple's Xcode SDK -- a problem that doesn't exist on Linux). Plain Windows (cmd/PowerShell) can't run a bash script at all without something like Git Bash or Cygwin, and neither of those gets you a working MPI+NetCDF C build toolchain equivalent to Homebrew's.

The realistic path on a PC is **WSL2** (Windows Subsystem for Linux) running Ubuntu (or another Linux distro) -- that gives VIC a real Linux environment to compile in, with `apt` in place of `brew` and no Xcode-SDK-specific issues to work around. That said, **this has not been tried or tested** as part of this project -- every fix in this file (and in `setup_macos.sh`) was found by actually hitting the error on a real macOS/Homebrew machine, and a Linux/WSL2 build would very likely hit its OWN set of platform-specific issues (different compiler defaults, different package names/versions, possibly different NetCDF/MPI linking quirks) that haven't been found or fixed yet. Budget time for a similar debugging pass, the same way this file's macOS instructions came together -- not a guaranteed drop-in.

## 1. R packages

``` r
install.packages(c(
  "yaml", "fs", "glue", "purrr", "dplyr", "tidyr", "stringr", "readr",
  "lubridate", "sf", "ggplot2", "httr2", "rvest", "ncdf4", "tidync",
  "abind", "R.utils"
))
install.packages("nhdplusTools")   # USGS WBD access for 01_get_aoi_boundary.R ("huc" mode)
install.packages("dataRetrieval")  # USGS NWIS/NLDI access -- required for 01_get_aoi_boundary.R's
                                    # "gauge" mode (delineates the AOI from a gauge's actual
                                    # watershed via findNLDI() instead of a WBD HUC polygon), and
                                    # used optionally by 14_postprocess_routing.R either way to
                                    # fetch an observed-discharge overlay.
```

## 2. Compilers + NetCDF (for building VIC itself)

macOS via Homebrew:

``` sh
brew install gcc netcdf netcdf-fortran automake libtool
```

(NCO/`ncks` is NOT needed -- an earlier version of this pipeline used it to subset the CONUS-wide params file, but 02b now subsets the ASCII inputs before conversion instead, so 03's output is already AOI-sized.)

## 3. Build VIC (image driver)

``` sh
git clone https://github.com/UW-Hydro/VIC.git ~/src/VIC
cd ~/src/VIC/vic/drivers/image
make
```

On a clean Homebrew-based macOS setup this will fail several times in a row before it succeeds -- every failure below was actually hit and fixed getting this repo's test run working, in this order:

**1. `mpicc: command not found`.** VIC's Makefile always compiles through an MPI compiler wrapper, even for a single-process run -- there's no serial-only fallback. Install Open MPI:

``` sh
brew install open-mpi
```

A binary built against `mpicc` still runs as a normal single-process program afterwards (`./vic_image.exe -g ...` works directly, no `mpirun` needed) -- this doesn't change how `08_run_vic.R` calls it.

**2. `clang: error: unsupported option '-fopenmp'`.** Homebrew's Open MPI wraps Apple's system `clang` by default, which doesn't support OpenMP. Point it at Homebrew's own gcc instead (Open MPI's wrapper compilers read `OMPI_CC` at invocation time, no reconfiguration needed):

``` sh
ls $(brew --prefix gcc)/bin | grep -E '^gcc-[0-9]+$'   # find the exact name/version
export OMPI_CC=gcc-16        # use whatever the line above printed
mpicc -show                  # sanity check -- should show gcc-16, not clang
```

`export OMPI_CC=...` only lasts for the current terminal session -- if you close it, set it again before rebuilding (you shouldn't need to rebuild again once the steps below all succeed once).

**3. `fatal error: math.h: No such file or directory`.** `math.h` comes from the macOS SDK, not GCC itself -- if Homebrew's gcc was built or last linked against an SDK path that's since changed (an Xcode Command Line Tools update, a macOS upgrade), it stops finding system headers entirely. Try pointing it at the current SDK first:

``` sh
xcrun --show-sdk-path        # confirm this prints a real path
export CPATH="$(xcrun --show-sdk-path)/usr/include"
```

If that's not enough, reinstall gcc, which regenerates its default SDK path against whatever Xcode CLT is currently active:

``` sh
brew reinstall gcc
```

**4. `ld: library not found for -lSystem`.** Same root cause as #3, at the link stage instead of compile. Point the linker at the SDK's lib dir the same way:

``` sh
export LIBRARY_PATH="$(xcrun --show-sdk-path)/usr/lib"
```

**5. `duplicate symbol '_LOG_DEST'` (and similar, \~400 of them).** GCC 10+ changed its default from `-fcommon` to `-fno-common`. VIC's C code declares some globals (e.g. `funcd` in `vic_run.h`) as plain variables in header files with no `extern` -- under the old default these got merged across translation units at link time ("common symbols"); under the new default each `.c` file that includes the header gets its own copy, so the linker sees hundreds of duplicates. This is a compiler-flag fix, not a real bug in VIC -- common when rebuilding older scientific C codebases. `CFLAGS` in VIC's Makefile is a plain `=` assignment (no `override`), so `make CFLAGS="-fcommon"` on the command line would silently replace the whole thing (including the include paths and NetCDF flags it needs) instead of adding to it. Patch the Makefile itself instead:

``` sh
cd ~/src/VIC/vic/drivers/image
sed -i.bak 's/-std=c99/-std=c99 -fcommon/' Makefile
```

With all five of the above in place (`OMPI_CC`, `CPATH`, `LIBRARY_PATH` still exported in the same terminal session, plus the `-fcommon` Makefile patch), `make` should succeed -- warnings are expected and harmless (mostly `-Wformat-overflow` from GCC being stricter than Apple's clang about `sprintf` buffer sizes in \~2018-era code). If NetCDF still isn't found automatically, add:

``` sh
make NETCDFHOME=$(brew --prefix netcdf)
```

Once it builds, confirm it runs and note the exact path to `vic_image.exe`:

``` sh
~/src/VIC/vic/drivers/image/vic_image.exe -v
```

Put that path in `config.yml` as `paths.vic_image_exe`. Also update `paths.vic_source_dir` if you cloned somewhere other than `~/src/VIC`.

## 4. Tonic (ASCII -\> NetCDF parameter conversion)

Tonic is a separate Python package, not on PyPI. Its `pip install` from git commonly FAILS to build on modern toolchains (an old `setup.py`, commonly tripping over `numpy.distutils` having been removed from recent numpy) -- if that happens to you, skip the pip step and use a source checkout instead, which is what this repo defaults to:

``` sh
conda create -n tonic python=3.9 netcdf4 pandas "numpy<1.24" scipy -y
conda activate tonic
pip install configobj   # tonic's setup.py doesn't declare its own deps -- this one's needed
which python   # -> config.yml's paths.tonic_python

git clone https://github.com/UW-Hydro/tonic.git ~/src/tonic
# -> config.yml's paths.tonic_source_dir (default already matches ~/src/tonic)
```

**Then patch tonic itself** -- it hasn't been updated since \~2018 and has three real incompatibilities with current Python/numpy/scipy (found by actually running the full conversion end-to-end, not guessed). Run this once, from anywhere:

``` sh
cd ~/src/tonic
sed -i.bak \
  -e 's/from collections import Sequence/from collections.abc import Sequence/' \
  tonic/io.py
sed -i.bak -E \
  -e 's/\bnp\.int\b/int/g; s/\bnp\.float\b/float/g; s/\bnp\.str\b/str/g' \
  tonic/models/vic/grid_params.py
sed -i.bak \
  -e 's/lon_step, lon_count = stats.mode(np.diff(ulons))/lon_step, lon_count = stats.mode(np.diff(ulons), keepdims=True)/' \
  -e 's/lat_step, lat_count = stats.mode(np.diff(ulats))/lat_step, lat_count = stats.mode(np.diff(ulats), keepdims=True)/' \
  tonic/models/vic/grid_params.py
```

What each fixes: `collections.Sequence` was removed in Python 3.10 (moved to `collections.abc`); `np.int`/`np.float`/`np.str` were removed in NumPy 1.24 (tonic used the bare builtin names, which are fine -- `int`/`float`/ `str` -- once the `np.` prefix is dropped); `scipy.stats.mode()` changed its default return shape in a later SciPy than tonic targeted (`keepdims=True` restores the old array-returning behavior tonic's code expects). `.bak` files are left next to each patched file if you want to diff or revert.

Separately, `python/convert_params_to_netcdf.py` in this repo had its own bugs (a handful of keyword arguments that don't match tonic's actual current function signatures -- `version` vs `version_in`, an unpacked tuple treated as a plain dict, etc.) -- those are already fixed in this repo, nothing to do on your end for those.

**Use `python=3.9`, not 3.10+, and `numpy<1.24`.** Tonic (last updated \~2018) uses APIs later Python/numpy releases removed: `from collections import Sequence` (removed in Python 3.10 -- 3.9 still has it, deprecated-but-working) and `np.int` (removed in NumPy 1.24 -- same deal). If you already have the env without these pins and hit `ImportError: cannot import name 'Sequence' from 'collections'` or `AttributeError: module 'numpy' has no attribute 'int'`, fix in place rather than recreating: `conda install "numpy<1.24" -y`, and if the Python version is also wrong, `conda env remove -n tonic` then the command above.

`R/03_convert_params_to_netcdf.R` sets `PYTHONPATH` to `tonic_source_dir` before calling python, so tonic never needs to be pip-installed at all -- just importable from the clone, using whatever numpy/pandas/netcdf4/scipy are already in the `tonic` conda env. If you'd still rather pip-install it properly (e.g. to get any compiled extensions, if it has any), try:

``` sh
pip install --no-build-isolation git+https://github.com/UW-Hydro/tonic.git
```

which often succeeds where the default (isolated-build) install fails, since it reuses your env's already-installed numpy instead of fetching a fresh one that may be too new for tonic's setup.py.

`R/03_convert_params_to_netcdf.R` shells out to python. **RStudio does not inherit your shell's conda env activation**, so if you just `conda activate tonic` in a terminal and then launch RStudio normally (e.g. from Finder/Dock), R will still find your system python -- and you'll hit `ModuleNotFoundError: No module named 'tonic'` even though installation worked fine. Avoid this by setting `paths$tonic_python` in `config.yml` to the tonic env's python directly:

``` sh
conda activate tonic
which python   # copy this path into config.yml's paths.tonic_python
```

## 5. MetSim (derives full VIC forcing from Tmax/Tmin/Prec/Wind)

VIC5's image driver requires AIR_TEMP/PREC/PRESSURE/SWDOWN/LWDOWN/VP/WIND supplied directly -- confirmed from VIC's own 5.0.1 release notes, VIC5 deliberately removed the MTCLIM disaggregation that used to let it take Tmax/Tmin/Prec directly (both classic and image drivers, not just image). Livneh only gives us Prec/Tmax/Tmin/Wind, so MetSim (UW-Hydro's own standalone MTCLIM replacement) has to derive the rest before VIC ever sees the data -- see `06_run_metsim.R`'s header comment for the full explanation, including two non-obvious things confirmed empirically while building this pipeline (a hard 90-day spin-up requirement, and a mislabeled units attribute on one output variable).

A plain venv is simpler than conda here -- MetSim installs cleanly via pip with no dependency conflicts, unlike tonic:

``` sh
python3 -m venv ~/metsim-venv
~/metsim-venv/bin/pip install --upgrade pip
~/metsim-venv/bin/pip install metsim
```

Then point `config.yml`'s `paths.metsim_python` at `~/metsim-venv/bin/python` (same RStudio-doesn't-inherit-your-shell gotcha as `tonic_python` -- `06_run_metsim.R` needs the real path, not just `python3`).

## 6. 7z (to extract the NHDPlus HR raster download)

NHDPlus HR's raster component ships as a `.7z` archive, which macOS can't open natively:

``` sh
brew install sevenzip
```

Confirmed directly from Homebrew's own formula source: this installs the binary as **`7zz`, not `7z`** -- deliberately renamed so it doesn't collide with the older `p7zip` formula's `7z`. That's not a typo above and not an error if `which 7z` comes up empty afterward -- check `which 7zz` instead.

If that formula isn't available on your Homebrew version, `brew install p7zip` is the older alternative, which DOES install as `7z`/`7za`. `R/10_download_nhdplus.R` looks for `7zz`, `7z`, and `7za`, so either install path works -- it doesn't hardcode one.

## 7. RVIC (routing) + pyflwdir (flow-direction upscaling)

RVIC (<https://github.com/UW-Hydro/RVIC>) routes VIC's gridded OUT_RUNOFF/OUT_BASEFLOW to a streamflow hydrograph at a pour point (see `routing/README.md` for the full picture). Two things worth knowing before you install it:

**It's an old, effectively unmaintained package** (last PyPI release 2015/2017) -- `pip install rvic` will try to build from a source tarball with no modern wheel available. The good news, checked directly against RVIC's own source: its one C extension (`rvic/clib/rvic_convolution.c`) is \~40 lines, includes only `stdlib.h`, and doesn't touch the NumPy C API at all -- about as low-risk a native build as this pipeline has needed (nothing like VIC's MPI/NetCDF/Fortran chain). `setup.py` also falls back to `setuptools` cleanly, so a modern `pip install .` should handle Python 3.12+'s removal of `distutils` from the standard library fine on its own.

**Still, pin an older Python for this env anyway**, since RVIC's actual *runtime* code (not just its build) is from the same \~2015-2017 era as MetSim's, and MetSim's pandas API breaks on a very new interpreter were the majority of the debugging in section 5 above. Starting from `python=3.10` instead of whatever's newest just reduces how many of those you're likely to hit -- if you still hit one, it'll get fixed the same way MetSim's were (tell me the error and I'll patch it).

``` sh
conda create -n rvic python=3.10 numpy scipy pandas netcdf4 matplotlib -y
conda activate rvic
which python   # -> config.yml's paths.rvic_python AND paths.pyflwdir_python
               # (same env works for both -- see config.yml's comment)

git clone https://github.com/UW-Hydro/RVIC.git ~/src/RVIC
cd ~/src/RVIC
pip install .

pip install pyflwdir rasterio   # for R/11_build_routing_inputs.R's
                                 # flow-direction upscaling step -- not
                                 # an RVIC dependency, just installed
                                 # into the same env for convenience
```

**Then patch RVIC itself** -- confirmed directly against RVIC's actual source on GitHub (not guessed): `rvic/parameters.py` uses the pandas `.ix` indexer, which pandas removed entirely years ago (same era-of-code problem as MetSim/Tonic above). One occurrence, and the DataFrame's index is still a plain freshly-read `0,1,2...` range at that point (no filtering happens beforehand), so `i` from `enumerate()` still matches the row label exactly -- `.loc` is the correct, safe drop-in replacement (NOT `.iloc`, which can't take `'names'` as a column label).

``` sh
RVIC_DIR=$(python -c "import rvic, os; print(os.path.dirname(rvic.__file__))")
sed -i.bak "s/pour_points.ix\[i, 'names'\] = strip_invalid_char(name)/pour_points.loc[i, 'names'] = strip_invalid_char(name)/" \
  "$RVIC_DIR/parameters.py"
sed -i.bak "s/np.finfo(np.float).resolution/np.finfo(float).resolution/" \
  "$RVIC_DIR/parameters.py"
sed -i.bak "s/char_names = stringtochar(outlet_name)/char_names = stringtochar(outlet_name.astype('U'), n_strlen=outlet_name.dtype.itemsize)/" \
  "$RVIC_DIR/core/write.py"
sed -i.bak "s/locfnh\[i, :\] = stringtochar(np.array(b_string.ljust(MAX_NC_CHARS)))/locfnh[i, :] = stringtochar(np.array(b_string.ljust(MAX_NC_CHARS)), encoding='bytes')/g" \
  "$RVIC_DIR/core/variables.py"
```

(`$RVIC_DIR` is found via `python` itself rather than hardcoding a conda path, so this works regardless of exactly where conda put the `rvic` env. If you already ran an earlier version of this section's commands by hand and they didn't seem to take effect, double check you ran them against the SAME python as `config.yml`'s `paths.rvic_python` -- a mismatched `$RVIC_DIR` silently patches an unused copy of the package and leaves the one `rvic` actually imports untouched.)

The second patch fixes `AttributeError: module 'numpy' has no attribute 'float'` in `gen_uh_run()` (hit further into `rvic parameters` than the `.ix` bug above -- past pour-point setup, into the actual per-outlet routing search) -- `np.float` was a deprecated alias for the builtin `float`, removed in NumPy 1.24 (same class of break as tonic's `np.int` in section 4 above; unlike tonic, the `rvic` env above isn't pinned to an older numpy, so this is the one place it still surfaces).

The third and fourth patches (`core/write.py`, `core/variables.py`) fix `AttributeError: 'numpy.bytes_' object has no attribute 'encode'` from `netCDF4.stringtochar()` -- confirmed directly against netCDF4-python 1.7.4's own source: `stringtochar(a, encoding='utf-8', ...)` defaults to `encoding='utf-8'`, which calls `.encode()` on each array element assuming plain Python `str` input, but RVIC builds `outlet_name` (and the history-restart filename arrays in `core/variables.py`) as raw BYTES arrays (`dtype='S...'`, or an explicit `.encode()` right before the call) -- older netCDF4-python releases were apparently more forgiving of this. `write.py` is hit by `rvic parameters` (script 12); `variables.py`'s copy is in `Rvar.write()`, used when `rvic convolution` (script 13) writes its restart file, so both are patched together rather than one-at-a-time.

These two call sites need DIFFERENT fixes, not the same one -- confirmed by actually running both against a real netCDF4 1.7.4 install, not just reading source. The obvious fix is `stringtochar(a, encoding='bytes')`, and that's exactly right for `variables.py` (one name at a time, a 0-d/scalar input). But netCDF4-python 1.7.4's `stringtochar()` has its own bug in that `encoding='bytes'` branch: unlike its other two branches, it never reshapes its output to `a.shape + (n_strlen,)` -- so for `write.py`, where `outlet_name` is a real `(numoutlets,)` array, `encoding='bytes'` silently returns a flat 1-D array instead of the 2-D `(numoutlets, n_strlen)` array the rest of `write_param_file()` expects, which then fails one line later at `f.createDimension(nocoords[1], char_names.shape[1])` with `IndexError: tuple index out of range`. The working fix there instead decodes to a unicode array first (`outlet_name.astype('U')`) so `stringtochar()` takes its default (correctly-reshaping) code path -- but that path derives the padded string length from `a.dtype.itemsize`, and a `'U'`-dtype array reports 4 bytes/character (numpy's internal UCS4 storage) instead of 1, which would silently 4x-inflate the `nc_chars` dimension -- so `n_strlen=outlet_name.dtype.itemsize` is passed explicitly, using the ORIGINAL bytes-dtype array's itemsize (1 byte/char) to get the correct length back.

`rvic/core/history.py` has a THIRD `stringtochar()` call (on `self._outlet_name`, read back from the parameter file) that looked suspicious on inspection but wasn't patched speculatively at the time -- its input's dtype depended on how netCDF4 reads back an `NC_CHAR` variable with no `_Encoding` attribute set, which wasn't fully pinned down by reading the source alone, and guessing wrong there risked silently corrupting output instead of just crashing. It DID fail, once `rvic convolution` actually reached it -- not on the first history-file flush but the SECOND (`RVICHIST_MFILT: 400` in this pipeline's convolution config buffers 400 daily timesteps before writing a history file, so this code path isn't exercised until day 400 of the run) -- with `AttributeError: 'MaskedArray' object has no attribute 'encode'`. Confirmed directly against this run's real parameter file: reading its `outlet_name` variable (a plain `NC_CHAR` with no `_Encoding` attribute, same as `core/write.py` produces) returns the RAW, already character-split array -- shape `(num_outlets, nc_chars)`, dtype `'S1'` -- not a string array. `stringtochar()` expects a STRING array (`'SN'`/`'U N'` dtype) as INPUT and converts it TO a char array; calling it on data that's already a char array made it iterate over ROWS (each one a `(nc_chars,)` sub-array) and call `.encode()` on each, which is exactly the observed crash. Since `self._outlet_name` is already precisely the `(num_outlets, nc_chars)` `'S1'` array the output variable needs, the fix drops the `stringtochar()` call entirely:

``` sh
python3 - "$RVIC_DIR/core/history.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
old = "        char_names = stringtochar(self._outlet_name)"
new = "        char_names = self._outlet_name"
n = content.count(old)
if n == 0:
    print("Nothing to patch (already patched, or RVIC's source has changed).")
else:
    with open(path, "w") as f:
        f.write(content.replace(old, new))
    print(f"Patched {n} occurrence(s).")
PYEOF
```

Verified via a full write/read round-trip against real data (not just that it doesn't crash) before applying it to the installed package.

Checked directly against RVIC's full source tree on GitHub (parameters.py, convolution.py, core/make_uh.py, core/history.py, core/variables.py, and everything else under core/) -- these patches now cover every deprecated numpy/pandas API use in the whole package.

A fifth patch, for `rvic convolution` (script 13) specifically -- not another deprecated-API break, a real calendar bug, confirmed by actually reproducing it against a real file with the exact installed netCDF4 (1.7.4) and cftime (1.6.5) versions before touching anything:

``` sh
python3 - "$RVIC_DIR/core/read_forcing.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
old = "date2index(\n                timestamp, self.current_fhdl.variables[self.time_fld])"
new = "date2index(\n                timestamp, self.current_fhdl.variables[self.time_fld],\n                calendar=self.calendar)"
n = content.count(old)
if n == 0:
    print("Nothing to patch (already patched, or RVIC's source has changed).")
else:
    with open(path, "w") as f:
        f.write(content.replace(old, new))
    print(f"Patched {n} occurrence(s).")
PYEOF
```

`rvic/core/read_forcing.py`'s `DataModel.start()` calls `date2index(timestamp, ...)` with NO explicit `calendar=` argument. `timestamp` here is always a plain Python `datetime.datetime` (RVIC's own `Dtime` class builds it via `datetime.strptime()`, never a cftime object) -- and cftime's `date2index()`, when given a plain `datetime.datetime` and no explicit `calendar`, silently assumes `calendar='proleptic_gregorian'` REGARDLESS of the actual forcing file's own `calendar` attribute (confirmed directly in cftime 1.6.5's source: it only reads `nctime.calendar` when the input is a cftime object, not a plain `datetime`). Our forcing files use `calendar: standard` throughout (matches `config.yml`'s `run.calendar`). For a reference date as early as `0001-01-01` (VIC/RVIC's shared "days since" epoch), `standard` and `proleptic_gregorian` disagree by 2 days as of 2005 (confirmed empirically: `date2num(datetime(2005,1,1), "days since 0001-01-01", calendar='standard')` gives `731948`, exactly the forcing file's actual first time value; the same call with `calendar='proleptic_gregorian'` -- what `date2index()` silently used -- gives `731946`) -- just enough to push the requested start date "before" the file's own first timestamp, throwing `ValueError: Some of the times given are before the first time in **nctime**` even though the requested date and the file's actual first date are the exact same calendar day. Passing `calendar=self.calendar` explicitly (that attribute is already set correctly from the forcing file's own `calendar` attribute earlier in `DataModel.__init__`) fixes both the call in `start()` (the one `rvic convolution` hits, script 13's normal first-timestep lookup) and an identical second call further down in `advance()` (a fallback path for switching between yearly/monthly/daily input files mid-run -- not normally exercised by this pipeline's single-file forcing setup, but the same bug, patched the same way, in case a future AOI/config combination hits it). Checked: `date2index` is the ONLY function in RVIC's entire source tree used this way (no other file calls it), so this is a complete fix, not a partial one.

A sixth patch, also for `rvic convolution` -- one more numpy 2.x silent-type-promotion bug, same investigative approach (reproduced against this run's own real parameter/domain files with the exact installed numpy version before touching anything):

``` sh
python3 - "$RVIC_DIR/core/variables.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
old = "        self.source_y_ind = self.ysize - self.source_y_ind - 1\n        self.outlet_y_ind = self.ysize - self.outlet_y_ind - 1"
new = "        self.source_y_ind = (self.ysize - self.source_y_ind - 1).astype(np.int32)\n        self.outlet_y_ind = (self.ysize - self.outlet_y_ind - 1).astype(np.int32)"
n = content.count(old)
if n == 0:
    print("Nothing to patch (already patched, or RVIC's source has changed).")
else:
    with open(path, "w") as f:
        f.write(content.replace(old, new))
    print(f"Patched {n} occurrence(s).")
PYEOF
```

`rvic/core/variables.py`'s `Rvar._flip_y_inds()` does `self.source_y_ind = self.ysize - self.source_y_ind - 1` (and the same for `outlet_y_ind`) when the parameter file's Y-orientation doesn't match the domain file's (`set_domain()` calls this whenever `lat0_is_min` is True -- logged as "Flipping Parameter File Y inds...", which this pipeline's AOIs always hit, since RVIC's own ascending-lat detection is exactly what section 8's flow-direction fix above is about). `source_y_ind`/`outlet_y_ind` are read from the parameter file as `numpy.ma.MaskedArray` with dtype `int32` (netCDF4-python's normal return type for these variables) -- confirmed directly against this run's own parameter file. Under NumPy 2.x, `python_int - int32_array` correctly stays `int32` for a PLAIN `ndarray` (confirmed empirically), but the SAME arithmetic on a `MaskedArray(int32)` silently upcasts the result to `int64` (confirmed empirically against the real arrays from this run -- not a hypothetical). That matters because `rvic_convolve()` -- the one ctypes call into RVIC's C extension in the entire package (`core/convolution_wrapper.py`) -- declares `source_y_ind` (and 3 other arguments) with `np.ctypeslib.ndpointer(np.int32)`, which strictly rejects anything that isn't actually `int32`, raising `ctypes.ArgumentError: argument 6: TypeError: array must have data type int32` the moment `Rvar.convolve()` is called (`rvic convolution`'s very first timestep -- confirmed by matching "argument 6" against `convolution_wrapper.py`'s declared argument order). `.astype(np.int32)` after the flip forces the dtype back to what the C extension requires, without changing any of the actual index values (checked: identical values before/after, only the dtype differs). The other three `ndpointer(np.int32)` arguments (`source2outlet_ind`, `source_x_ind`, `source_time_offset`) are read from the same parameter file but never go through any arithmetic like this, so they were confirmed to stay `int32` throughout and don't need the same fix.

If `rvic parameters` or `rvic convolution` fails with a DIFFERENT error than these, it's the same story as MetSim's pandas breaks in section 5 -- tell me the error and I'll find and patch it the same way.

Verify:

``` sh
rvic -h
python -c "import rvic, pyflwdir, rasterio; print('ok')"
```

Same RStudio-doesn't-inherit-your-shell-env gotcha as `tonic_python`/ `metsim_python` -- point `config.yml`'s `paths.rvic_python` / `paths.pyflwdir_python` at the conda env's actual python path from `which python` above, not just `"python3"`.

## Order of operations

```         
R/01_get_aoi_boundary.R
R/02_download_vic_params.R
R/03_convert_params_to_netcdf.R   # edit file_map first!
R/04_download_forcing.R           # two-stage; edit config.yml between stages
R/04b_build_forcing_netcdf.R
R/05_build_domain.R
R/06_run_metsim.R                 # needs setup section 5 done first
R/07_write_globalparam.R
R/08_run_vic.R
R/09_postprocess_outputs.R
# -- grid-cell water balance ends here; everything below is routing (phase 2) --
R/10_download_nhdplus.R           # needs setup sections 6+7 done first
R/11_build_routing_inputs.R
R/12_run_rvic_parameters.R
R/13_run_rvic_convolution.R
R/14_postprocess_routing.R
```

Every script starts with `source("R/00_config.R")`, which reads `config.yml` -- edit that file, not the scripts, to point at your own machine's paths.
