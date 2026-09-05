#!/usr/bin/env bash
# Regenerate the differential-testing oracle fixtures from the *real* Gleam
# compiler. For each fixtures/oracle/<name>.gleam it writes:
#   - fixtures/oracle/<name>.interface.json  (gleam export package-interface)
#   - fixtures/oracle/<name>.expr.json       (gleam export expression-types)
#
# `expression-types` requires the patched compiler built from the
# `expression-type-export` branch in ../gleam. Override its path with GLEAM=.
# Run from the project root: `bash scripts/gen-oracle.sh`.
#
# Each export runs in its own fresh project: `root_package.modules` only
# contains freshly-compiled modules, so the two exports must not share a build.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
oracle_dir="$root/fixtures/oracle"
toolversions="$root/.tool-versions"
gleam="${GLEAM:-$root/../gleam/target/debug/gleam}"

if [ ! -x "$gleam" ]; then
  echo "patched gleam compiler not found at $gleam" >&2
  echo "build it: (cd ../gleam && ASDF_RUST_VERSION=stable cargo build --bin gleam)" >&2
  exit 1
fi

# export <sample-name> <sample-src> <export-command> <output-file>
generate() {
  local name="$1" src="$2" command="$3" out="$4"
  local work
  work="$(mktemp -d)"
  cp "$toolversions" "$work/.tool-versions"
  ( cd "$work" && "$gleam" new proj >/dev/null 2>&1 )
  cp "$src" "$work/proj/src/$name.gleam"
  rm -f "$work/proj/src/proj.gleam"
  sed -i "s/^name = .*/name = \"$name\"/" "$work/proj/gleam.toml"
  ( cd "$work/proj" && "$gleam" export "$command" --out out.json >/dev/null 2>&1 )
  cp "$work/proj/out.json" "$out"
  rm -rf "$work"
}

for src in "$oracle_dir"/*.gleam; do
  name="$(basename "$src" .gleam)"
  generate "$name" "$src" package-interface "$oracle_dir/$name.interface.json"
  generate "$name" "$src" expression-types "$oracle_dir/$name.expr.json"
  echo "generated $name.{interface,expr}.json"
done
