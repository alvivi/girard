#!/usr/bin/env bash
# Generate the per-expression oracle for an installed package using the patched
# compiler, by building a throwaway project from the package's own gleam.toml +
# src (as found under build/packages/<pkg>).
#
#   bash scripts/oracle-package.sh <package> [out.json]
#
# Pair with: gleam run -m girard/diff <package> <out.json>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
gleam="${GLEAM:-$root/../gleam/target/debug/gleam}"
pkg="$1"
out="${2:-/tmp/$pkg.expr.json}"
src="$root/build/packages/$pkg"

if [ ! -d "$src/src" ]; then
  echo "no package at $src" >&2
  exit 1
fi

work="$(mktemp -d)"
cp -r "$src/src" "$work/src"
cp "$src/gleam.toml" "$work/gleam.toml"
printf 'gleam 1.16.0\nerlang 28.4.2\n' > "$work/.tool-versions"
( cd "$work" && "$gleam" export expression-types --out out.json >/dev/null 2>&1 )
cp "$work/out.json" "$out"
rm -rf "$work"
echo "wrote $out"
