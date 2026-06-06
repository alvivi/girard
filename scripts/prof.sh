#!/usr/bin/env bash
# Profile girard's inference over one cached package with eprof or fprof.
#
#   scripts/prof.sh [eprof|fprof] <package>
#
# Stages the package's dependency closure from the sweep cache (symlinks into
# the pool, as scripts/bench.sh does), compiles scripts/girard_prof.erl against
# girard's compiled beams, and runs the profiler over every module of the
# package. eprof prints a per-function time table to stdout; fprof writes a
# call-graph analysis to /tmp/girard_fprof.txt.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cache="${GIRARD_CACHE:-$HOME/.cache/girard-sweep}"
pool="$cache/pool"
manifest_dir="$cache/manifest"

mode="${1:-eprof}"
pkg="${2:?usage: prof.sh [eprof|fprof] <package>}"

[ -f "$manifest_dir/$pkg.txt" ] || { echo "$pkg not in cache" >&2; exit 1; }

# Ensure girard's beams are current.
( cd "$root" && gleam build >/dev/null 2>&1 ) || { echo "gleam build failed" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
pkgroot="$stage/$pkg"
mkdir -p "$pkgroot"
while IFS= read -r member; do
  [ -z "$member" ] && continue
  name="${member%@*}"
  [ -d "$pool/$member" ] && ln -sfn "$pool/$member" "$pkgroot/$name"
done <"$manifest_dir/$pkg.txt"

# Compile the profiler helper next to the staged work.
erlc -o "$stage" "$root/scripts/girard_prof.erl" || { echo "erlc failed" >&2; exit 1; }

erl -noshell \
    -pa "$stage" \
    -pa "$root"/build/dev/erlang/*/ebin \
    -run girard_prof main "$mode" "$pkgroot" "$pkg"
