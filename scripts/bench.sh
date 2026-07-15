#!/usr/bin/env bash
# Benchmark girard's inference over a fixed corpus of real hex packages, staged
# OFFLINE from the sweep cache (scripts/cache.sh). This is the number to track
# across performance work: the same corpus and cache fix the module/expression
# set, while repeated rounds help expose normal runtime noise.
#
#   scripts/bench.sh [listfile] [warmup-rounds] [measure-rounds]
#
# listfile defaults to scripts/bench_corpus.txt (one package name per line).
# Each package must be present in the cache (run scripts/cache.sh build-batch
# first). The package's dependency closure is reconstructed as symlinks into the
# cache pool — zero-copy, no hex, no oracle compile — exactly as cache.sh
# resweep does, then dev/girard/bench.gleam annotates every module of every
# package inside ONE VM process and reports throughput.
#
# Env overrides:
#   GIRARD_CACHE  cache root (default ~/.cache/girard-sweep)
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cache="${GIRARD_CACHE:-$HOME/.cache/girard-sweep}"
pool="$cache/pool"
manifest_dir="$cache/manifest"

list="${1:-$root/scripts/bench_corpus.txt}"
warmup="${2:-1}"
measure="${3:-3}"

if [ ! -f "$list" ]; then
  echo "corpus list not found: $list" >&2
  exit 1
fi
if [ ! -d "$pool" ]; then
  echo "no cache pool at $pool (run scripts/cache.sh build-batch first)" >&2
  exit 1
fi

stage="$(mktemp -d)"
spec="$stage/spec.tsv"
: >"$spec"
trap 'rm -rf "$stage"' EXIT

staged=0
missing=0
while IFS= read -r pkg; do
  pkg="$(printf '%s' "$pkg" | tr -d '[:space:]')"
  [ -z "$pkg" ] && continue
  case "$pkg" in \#*) continue ;; esac
  if [ ! -f "$manifest_dir/$pkg.txt" ]; then
    echo "  skip $pkg: not in cache"
    missing=$((missing + 1))
    continue
  fi
  # Reconstruct the closure: one symlink per closure member into the pool.
  pkgroot="$stage/$pkg"
  mkdir -p "$pkgroot"
  while IFS= read -r member; do
    [ -z "$member" ] && continue
    name="${member%@*}"
    [ -d "$pool/$member" ] && ln -sfn "$pool/$member" "$pkgroot/$name"
  done <"$manifest_dir/$pkg.txt"
  printf '%s\t%s\n' "$pkg" "$pkgroot" >>"$spec"
  staged=$((staged + 1))
done <"$list"

echo "staged $staged packages ($missing missing) -> running bench"
( cd "$root" && gleam run -m girard/bench "$spec" "$warmup" "$measure" )
