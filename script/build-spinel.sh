#!/bin/sh
# Builds Spinel at the commit in .spinel-version, in place in DIR (default ~/spinel-build).
# Use it as DIR/bin/spinel. CI caches DIR keyed on .spinel-version, so this runs only when the
# version changes. Spinel's own Windows CI builds and uses the tree the same way, without
# `make install`.
# Needs git, make, a C compiler, curl, and a Ruby that can require "prism" (Ruby 3.3+ ships it):
# the build runs Ruby scripts that parse Ruby. On Windows, run it in an MSYS2 UCRT64 shell with
# the packages in Spinel's docs/windows.md.
#
#   script/build-spinel.sh [DIR]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-"$HOME/spinel-build"}
sha=$(tr -d '[:space:]' < "$root/.spinel-version")

rm -rf "$dir"
git clone --quiet --filter=blob:none https://github.com/matz/spinel "$dir"
cd "$dir"
git -c advice.detachedHead=false checkout --quiet "$sha"
make deps
# Only what herdr-slack-inbox needs: the compiler, the runtimes, json and tmpdir. lib/libspinel_rt.a is built
# too: bin/spinel finds its own tree by it. `make` alone also
# builds every bundled package, and some need what a runner lacks (sqlite3's headers; pty on Windows)
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)" \
  bin/spinel lib/libspinel_rt.a lib/libspinel_rt_mt.a packages/json/sp_json_mt.o packages/tmpdir/sp_tmpdir_mt.o \
  lib/spinel_rt_responds_generated.h
bin/spinel --version
