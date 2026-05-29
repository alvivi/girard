#!/usr/bin/env bash
# Regenerate the differential-testing oracle fixtures: for each
# test/oracle/<name>.gleam, run the *real* Gleam compiler's
# `gleam export package-interface` and store the JSON as
# test/oracle/<name>.interface.json.
#
# This is the ground truth girard's inferred signatures are compared against
# (see test/oracle_test.gleam). Run from the project root: `bash scripts/gen-oracle.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
oracle_dir="$root/test/oracle"
toolversions="$root/.tool-versions"

for src in "$oracle_dir"/*.gleam; do
  name="$(basename "$src" .gleam)"
  work="$(mktemp -d)"
  cp "$toolversions" "$work/.tool-versions"
  ( cd "$work" && gleam new proj >/dev/null 2>&1 )
  cp "$src" "$work/proj/src/$name.gleam"
  rm -f "$work/proj/src/proj.gleam"
  # Rename project module to the sample's name so it appears in the interface.
  sed -i "s/^name = .*/name = \"$name\"/" "$work/proj/gleam.toml"
  ( cd "$work/proj" && gleam export package-interface --out interface.json >/dev/null 2>&1 )
  cp "$work/proj/interface.json" "$oracle_dir/$name.interface.json"
  echo "generated $name.interface.json"
  rm -rf "$work"
done
