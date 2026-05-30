#!/usr/bin/env bash
# Differentially test a hex package against girard with a *consistent*,
# hex-resolved dependency closure.
#
#   bash scripts/sweep.sh <package>
#
# Steps:
#   1. Create a throwaway project and let hex resolve the package's full
#      transitive dependency tree (`gleam add` + `gleam deps download`).
#   2. Export the per-expression oracle with the patched compiler, building the
#      package *as the root* (the export only emits the root package's modules)
#      against those resolved dependencies. Skip the package if it does not
#      compile — then neither the compiler nor girard can type it.
#   3. Sync the exact resolved dependency versions into girard's build/packages
#      so girard resolves imports identically (no version skew → no false
#      discrepancies).
#   4. Run girard/diff against the oracle.
#
# Env overrides:
#   GLEAM     patched compiler for the oracle (default ../gleam/target/debug/gleam)
#   HEXGLEAM  stock gleam used to resolve/download/run (default asdf 1.16.0)
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
gleam="${GLEAM:-$root/../gleam/target/debug/gleam}"
hexgleam="${HEXGLEAM:-$(command -v gleam)}"
pkg="${1:?usage: sweep.sh <package>}"
out="/tmp/sweep_${pkg}.json"

if [ ! -x "$gleam" ]; then
  echo "patched compiler not found at $gleam (set GLEAM=)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The gleam shim needs a pinned toolchain in scope for every invocation.
cp "$root/.tool-versions" "$work/.tool-versions"

# 1. Resolve + download the package and its full transitive closure.
( cd "$work" && "$hexgleam" new probe >/dev/null 2>&1 )
proj="$work/probe"
cp "$root/.tool-versions" "$proj/.tool-versions"
if ! ( cd "$proj" && timeout 120 "$hexgleam" add "$pkg" >/dev/null 2>&1 ); then
  echo "sweep $pkg: SKIP (could not add — not found or resolution failed)"
  exit 2
fi
( cd "$proj" && timeout 240 "$hexgleam" deps download >/dev/null 2>&1 )

deps="$proj/build/packages"
if [ ! -d "$deps/$pkg/src" ]; then
  echo "sweep $pkg: SKIP (package source not downloaded)"
  exit 2
fi

# 2. Oracle: build the package as the root against the resolved deps.
oroot="$work/oracle"
mkdir -p "$oroot/build/packages"
cp -r "$deps/$pkg/src" "$oroot/src"
cp "$deps/$pkg/gleam.toml" "$oroot/gleam.toml"
cp "$root/.tool-versions" "$oroot/.tool-versions"
sed -i "s/^name = .*/name = \"$pkg\"/" "$oroot/gleam.toml"
for d in "$deps"/*/; do
  name="$(basename "$d")"
  [ "$name" = "$pkg" ] && continue
  cp -r "$d" "$oroot/build/packages/$name"
done
if ! ( cd "$oroot" && "$gleam" export expression-types --out out.json >/dev/null 2>&1 ); then
  echo "sweep $pkg: SKIP (oracle export failed — package or a dependency does not compile)"
  exit 3
fi
cp "$oroot/out.json" "$out"

# 3. Sync the resolved closure into girard's build/packages (matching versions).
mkdir -p "$root/build/packages"
for d in "$deps"/*/; do
  name="$(basename "$d")"
  rm -rf "$root/build/packages/$name"
  cp -r "$d" "$root/build/packages/$name"
done

# 4. Diff girard against the oracle.
( cd "$root" && gleam run -m girard/diff "$pkg" "$out" 2>/dev/null | grep -E "^diff |ERROR" )
