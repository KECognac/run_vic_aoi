#!/usr/bin/env bash
# ------------------------------------------------------------------------
# setup/setup_macos.sh
#
# Automates setup/SETUP.md sections 1-7 (R packages, compilers, VIC,
# Tonic, MetSim, 7z, RVIC) so you don't have to copy commands out of that
# file one at a time. Every command below is copied verbatim from
# SETUP.md, which documents exactly how/why each one was found -- read
# that file if something here fails and you want the full story, not
# just the fix.
#
# macOS + Homebrew ONLY. Every fix in Section 3 (VIC) and the sed/python
# patches in Sections 4 and 7 were found by actually hitting the
# corresponding error on a real macOS/Homebrew machine -- see SETUP.md's
# own text for each one. This has NOT been run/tested on Linux or under
# WSL, and would very likely hit different platform-specific issues that
# haven't been found or fixed yet (Homebrew's OMPI_CC/Xcode-SDK problems
# in particular are macOS-specific -- a native Linux gcc doesn't need
# either workaround).
#
# SAFE TO RE-RUN. Every step below checks whether it's already done
# before doing it, so if this script fails partway through (a real
# install failure, a network hiccup, an error SETUP.md doesn't cover
# yet), fix the problem and re-run the whole script -- it picks up from
# wherever it left off rather than redoing already-finished work (this
# matters most for `make`-ing VIC and creating the conda envs, both slow).
#
# REQUIRES Homebrew (https://brew.sh) and conda/Miniconda/Miniforge
# (https://docs.conda.io/en/latest/miniconda.html) ALREADY INSTALLED --
# this script checks for both and stops with a clear message if either
# is missing, rather than trying to install them itself (both are
# consequential, sometimes-interactive installs better done by hand once,
# outside this script).
#
# Does NOT edit config.yml -- that file is specific to a given AOI/run
# and is version-controlled, so it's left to you. The very last thing
# this script prints is the exact paths.* block to paste into it.
# ------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIC_SRC="${VIC_SRC:-$HOME/src/VIC}"
TONIC_SRC="${TONIC_SRC:-$HOME/src/tonic}"
RVIC_SRC="${RVIC_SRC:-$HOME/src/RVIC}"
METSIM_VENV="${METSIM_VENV:-$HOME/metsim-venv}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$1" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "This script is macOS-only (Homebrew + Xcode-toolchain-specific fixes) -- see setup/SETUP.md's \"Does this work on a PC?\" section."
command -v brew >/dev/null 2>&1 || die "Homebrew not found -- install it first: https://brew.sh"
command -v conda >/dev/null 2>&1 || die "conda not found -- install Miniconda or Miniforge first: https://docs.conda.io/en/latest/miniconda.html"

# ------------------------------------------------------------------------
# 1. R packages (SETUP.md section 1)
# ------------------------------------------------------------------------
log "1/7: R packages"
if command -v Rscript >/dev/null 2>&1; then
  Rscript -e '
    pkgs <- c(
      "yaml", "fs", "glue", "purrr", "dplyr", "tidyr", "stringr", "readr",
      "lubridate", "sf", "ggplot2", "httr2", "rvest", "ncdf4", "tidync",
      "abind", "R.utils", "nhdplusTools", "dataRetrieval"
    )
    missing <- pkgs[!pkgs %in% rownames(installed.packages())]
    if (length(missing) > 0) {
      message("Installing: ", paste(missing, collapse = ", "))
      install.packages(missing)
    } else {
      message("All R packages already installed.")
    }
  '
else
  warn "Rscript not found on PATH -- skipping R package install. Install R (and/or RStudio) first, then either re-run this script or install the packages listed in setup/SETUP.md section 1 by hand."
fi

# ------------------------------------------------------------------------
# 2. Compilers + NetCDF + MPI + 7z (SETUP.md sections 2, 6, and the
#    open-mpi fix from section 3)
# ------------------------------------------------------------------------
log "2/7: Homebrew packages (compilers, NetCDF, MPI, 7z)"
BREW_PKGS=(gcc netcdf netcdf-fortran automake libtool open-mpi)
for pkg in "${BREW_PKGS[@]}"; do
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    echo "  already installed: $pkg"
  else
    echo "  installing: $pkg"
    brew install "$pkg"
  fi
done

# sevenzip installs as 7zz (not 7z -- deliberately renamed by the
# formula so it doesn't collide with the older p7zip formula's 7z); the
# fallback p7zip DOES install as 7z/7za. R/10_download_nhdplus.R looks
# for 7zz, 7z, and 7za, so either is fine.
if command -v 7zz >/dev/null 2>&1 || command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1; then
  echo "  already have a 7z-family binary (7zz/7z/7za)"
elif brew install sevenzip; then
  echo "  installed sevenzip (7zz)"
else
  warn "brew install sevenzip failed -- trying p7zip instead"
  brew install p7zip
fi

# Homebrew's gcc binary is named gcc-<N> (N = the formula's major
# version) -- picking the highest N with a plain numeric comparison
# (not GNU's `sort -V`, which macOS's built-in sort doesn't support, and
# not `ls | grep`, whose lexical order would rank gcc-9 above gcc-14).
# Globbing instead of `ls | grep` so an unusual filename can't confuse
# the match.
GCC_PREFIX_BIN="$(brew --prefix gcc)/bin"
GCC_BIN=""
GCC_BIN_N=-1
for f in "$GCC_PREFIX_BIN"/gcc-[0-9]*; do
  [[ -e "$f" ]] || continue
  b="$(basename "$f")"
  if [[ "$b" =~ ^gcc-([0-9]+)$ ]]; then
    n="${BASH_REMATCH[1]}"
    if (( n > GCC_BIN_N )); then
      GCC_BIN_N="$n"
      GCC_BIN="$b"
    fi
  fi
done
[[ -n "$GCC_BIN" ]] || die "Could not find a gcc-<N> binary under $GCC_PREFIX_BIN after 'brew install gcc' -- inspect that directory by hand."
echo "  Homebrew gcc binary: $GCC_BIN"

# ------------------------------------------------------------------------
# 3. Build VIC image driver (SETUP.md section 3)
# ------------------------------------------------------------------------
log "3/7: VIC image driver"
VIC_EXE="$VIC_SRC/vic/drivers/image/vic_image.exe"
if [[ -x "$VIC_EXE" ]]; then
  echo "  already built: $VIC_EXE"
else
  if [[ ! -d "$VIC_SRC" ]]; then
    git clone https://github.com/UW-Hydro/VIC.git "$VIC_SRC"
  else
    echo "  $VIC_SRC already exists, not re-cloning"
  fi

  # Fix 2 (mpicc wraps Apple clang, which doesn't support -fopenmp) --
  # point Open MPI's wrapper compiler at Homebrew's gcc instead.
  export OMPI_CC="$GCC_BIN"
  # Fix 3 + 4 (math.h / -lSystem not found -- Homebrew gcc losing track
  # of the active Xcode SDK's headers/libs). Declared separately from
  # `export` so a failing `xcrun` (unlikely, but possible on an unusual
  # Xcode Command Line Tools setup) isn't masked by export's own always-
  # zero exit status under `set -e`.
  SDK_PATH="$(xcrun --show-sdk-path)"
  export CPATH="$SDK_PATH/usr/include"
  export LIBRARY_PATH="$SDK_PATH/usr/lib"

  cd "$VIC_SRC/vic/drivers/image"
  # Fix 5 (GCC 10+'s -fno-common default breaks VIC's un-`extern`'d
  # header globals -- hundreds of "duplicate symbol" link errors).
  # Patching the Makefile directly (not `make CFLAGS=...` on the command
  # line, which would REPLACE the whole CFLAGS instead of adding to it).
  sed -i.bak 's/-std=c99/-std=c99 -fcommon/' Makefile

  echo "  running make (this can take a few minutes)..."
  make NETCDFHOME="$(brew --prefix netcdf)"
  cd "$REPO_ROOT"
fi
[[ -x "$VIC_EXE" ]] || die "VIC build finished but $VIC_EXE isn't there -- check the make output above."
echo "  vic_image.exe: $VIC_EXE"
"$VIC_EXE" -v || true

# ------------------------------------------------------------------------
# 4. Tonic (SETUP.md section 4)
# ------------------------------------------------------------------------
log "4/7: Tonic (ASCII -> NetCDF parameter conversion)"
if conda env list | grep -qE '^tonic[[:space:]]'; then
  echo "  conda env 'tonic' already exists"
else
  conda create -n tonic python=3.9 netcdf4 pandas "numpy<1.24" scipy -y
fi
TONIC_PYTHON="$(conda run -n tonic which python)"
conda run -n tonic pip show configobj >/dev/null 2>&1 || conda run -n tonic pip install configobj

if [[ ! -d "$TONIC_SRC" ]]; then
  git clone https://github.com/UW-Hydro/tonic.git "$TONIC_SRC"
else
  echo "  $TONIC_SRC already exists, not re-cloning"
fi

echo "  patching tonic at $TONIC_SRC (safe to re-run -- a no-op if already patched)"
( cd "$TONIC_SRC" && \
  sed -i.bak \
    -e 's/from collections import Sequence/from collections.abc import Sequence/' \
    tonic/io.py && \
  sed -i.bak -E \
    -e 's/\bnp\.int\b/int/g; s/\bnp\.float\b/float/g; s/\bnp\.str\b/str/g' \
    tonic/models/vic/grid_params.py && \
  sed -i.bak \
    -e 's/lon_step, lon_count = stats.mode(np.diff(ulons))/lon_step, lon_count = stats.mode(np.diff(ulons), keepdims=True)/' \
    -e 's/lat_step, lat_count = stats.mode(np.diff(ulats))/lat_step, lat_count = stats.mode(np.diff(ulats), keepdims=True)/' \
    tonic/models/vic/grid_params.py )
echo "  tonic_python: $TONIC_PYTHON"
echo "  tonic_source_dir: $TONIC_SRC"

# ------------------------------------------------------------------------
# 5. MetSim (SETUP.md section 5)
# ------------------------------------------------------------------------
log "5/7: MetSim"
if [[ -x "$METSIM_VENV/bin/python" ]]; then
  echo "  venv already exists: $METSIM_VENV"
else
  python3 -m venv "$METSIM_VENV"
fi
"$METSIM_VENV/bin/pip" install --upgrade pip >/dev/null
if "$METSIM_VENV/bin/python" -c "import metsim" >/dev/null 2>&1; then
  echo "  metsim already installed"
else
  "$METSIM_VENV/bin/pip" install metsim
fi
echo "  metsim_python: $METSIM_VENV/bin/python"

# ------------------------------------------------------------------------
# 6. RVIC + pyflwdir (SETUP.md section 7)
# ------------------------------------------------------------------------
log "6/7: RVIC + pyflwdir"
if conda env list | grep -qE '^rvic[[:space:]]'; then
  echo "  conda env 'rvic' already exists"
else
  conda create -n rvic python=3.10 numpy scipy pandas netcdf4 matplotlib -y
fi
RVIC_PYTHON="$(conda run -n rvic which python)"

if conda run -n rvic python -c "import rvic" >/dev/null 2>&1; then
  echo "  rvic already importable"
else
  if [[ ! -d "$RVIC_SRC" ]]; then
    git clone https://github.com/UW-Hydro/RVIC.git "$RVIC_SRC"
  else
    echo "  $RVIC_SRC already exists, not re-cloning"
  fi
  ( cd "$RVIC_SRC" && conda run -n rvic pip install . )
fi

conda run -n rvic python -c "import pyflwdir, rasterio" >/dev/null 2>&1 || \
  conda run -n rvic pip install pyflwdir rasterio

# RVIC_DIR found via python itself (not a hardcoded conda path), so this
# patches whichever copy `rvic`/R/12/R/13 actually import, regardless of
# exactly where conda put the rvic env.
RVIC_DIR="$(conda run -n rvic python -c "import rvic, os; print(os.path.dirname(rvic.__file__))")"
echo "  patching RVIC install at $RVIC_DIR (safe to re-run -- a no-op if already patched)"

# Patches 1-2: parameters.py (.ix -> .loc; np.float -> float, both
# removed/deprecated APIs from RVIC's ~2015-2017-era code).
sed -i.bak "s/pour_points.ix\[i, 'names'\] = strip_invalid_char(name)/pour_points.loc[i, 'names'] = strip_invalid_char(name)/" \
  "$RVIC_DIR/parameters.py"
sed -i.bak "s/np.finfo(np.float).resolution/np.finfo(float).resolution/" \
  "$RVIC_DIR/parameters.py"
# Patch 3: core/write.py -- stringtochar()'s encoding='bytes' path
# doesn't reshape its output for an array input (netCDF4-python 1.7.4
# bug); decoding to unicode first takes stringtochar()'s other, correctly
# -reshaping code path instead, with n_strlen passed explicitly since a
# 'U'-dtype array's itemsize (4 bytes/char) isn't the real string length.
sed -i.bak "s/char_names = stringtochar(outlet_name)/char_names = stringtochar(outlet_name.astype('U'), n_strlen=outlet_name.dtype.itemsize)/" \
  "$RVIC_DIR/core/write.py"
# Patch 4: core/variables.py -- same netCDF4-python stringtochar()
# issue, one name at a time (scalar input), where encoding='bytes' IS the
# right fix (no reshape needed for a scalar).
sed -i.bak "s/locfnh\[i, :\] = stringtochar(np.array(b_string.ljust(MAX_NC_CHARS)))/locfnh[i, :] = stringtochar(np.array(b_string.ljust(MAX_NC_CHARS)), encoding='bytes')/g" \
  "$RVIC_DIR/core/variables.py"

# Patch 5: core/history.py -- self._outlet_name is already the raw
# (num_outlets, nc_chars) 'S1' char array the output variable needs;
# calling stringtochar() on it (which expects a STRING array as input)
# makes it iterate over rows and call .encode() on each, crashing on the
# first history-file flush past timestep RVICHIST_MFILT.
python3 - "$RVIC_DIR/core/history.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
old = "        char_names = stringtochar(self._outlet_name)"
new = "        char_names = self._outlet_name"
n = content.count(old)
if n == 0:
    print("  core/history.py: nothing to patch (already patched, or RVIC's source has changed).")
else:
    with open(path, "w") as f:
        f.write(content.replace(old, new))
    print(f"  core/history.py: patched {n} occurrence(s).")
PYEOF

# Patch 6: core/read_forcing.py -- date2index() with no explicit
# calendar= silently assumes proleptic_gregorian even when the forcing
# file's own calendar is "standard"; for a "days since 0001-01-01" origin
# the two disagree by 2 days by ~2005, which can push the requested start
# date "before" the file's own first timestamp.
python3 - "$RVIC_DIR/core/read_forcing.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
old = "date2index(\n                timestamp, self.current_fhdl.variables[self.time_fld])"
new = "date2index(\n                timestamp, self.current_fhdl.variables[self.time_fld],\n                calendar=self.calendar)"
n = content.count(old)
if n == 0:
    print("  core/read_forcing.py: nothing to patch (already patched, or RVIC's source has changed).")
else:
    with open(path, "w") as f:
        f.write(content.replace(old, new))
    print(f"  core/read_forcing.py: patched {n} occurrence(s).")
PYEOF

# Patch 7: core/variables.py -- under NumPy 2.x, python_int - int32
# MaskedArray silently upcasts to int64, but the one ctypes call into
# RVIC's C extension strictly requires int32 for these two arrays.
python3 - "$RVIC_DIR/core/variables.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
old = "        self.source_y_ind = self.ysize - self.source_y_ind - 1\n        self.outlet_y_ind = self.ysize - self.outlet_y_ind - 1"
new = "        self.source_y_ind = (self.ysize - self.source_y_ind - 1).astype(np.int32)\n        self.outlet_y_ind = (self.ysize - self.outlet_y_ind - 1).astype(np.int32)"
n = content.count(old)
if n == 0:
    print("  core/variables.py (_flip_y_inds): nothing to patch (already patched, or RVIC's source has changed).")
else:
    with open(path, "w") as f:
        f.write(content.replace(old, new))
    print(f"  core/variables.py (_flip_y_inds): patched {n} occurrence(s).")
PYEOF

echo "  rvic_python / pyflwdir_python: $RVIC_PYTHON"

# ------------------------------------------------------------------------
# 7. Done -- config.yml paths to paste in
# ------------------------------------------------------------------------
log "7/7: Done"
cat <<SUMMARY

Paste these into config.yml's paths: block (replacing whatever's there
now -- these are YOUR machine's actual paths, not the repo's defaults):

  vic_source_dir: "$VIC_SRC"
  vic_image_exe: "$VIC_EXE"
  tonic_python: "$TONIC_PYTHON"
  tonic_source_dir: "$TONIC_SRC"
  metsim_python: "$METSIM_VENV/bin/python"
  rvic_python: "$RVIC_PYTHON"
  pyflwdir_python: "$RVIC_PYTHON"

Everything above is idempotent -- if 08_run_vic.R, R/03, R/06, R/12, or
R/13 still fail after this, it's most likely a NEW error this script (and
SETUP.md) doesn't cover yet, not something re-running this script again
will fix. Share the exact error and it can be added here the same way
every fix above was found: by actually reproducing and patching it.
SUMMARY
