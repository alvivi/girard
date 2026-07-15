#!/usr/bin/env bash
#
# Publish girard to Hex while the temporary glance-7 dev-dependency overrides
# are in place.
#
# glinter and birdie have no published glance-7-compatible release yet, so
# girard's [dev_dependencies] point at git forks (see gleam.toml). `gleam
# publish` builds the whole project — including test/ — and Hex rejects git
# dependencies, so this script:
#
#   1. comments out the glinter + birdie git dev-deps,
#   2. sets aside test/golden_test.gleam (the only module that imports birdie),
#   3. regenerates the manifest and sanity-builds with hex-only deps,
#   4. runs `gleam publish`,
#
# then restores the working tree — on success, failure, or interrupt.
#
# dev_dependencies are never part of the published tarball, so stripping them
# does not change what consumers receive; [dependencies] (glance >= 7) is
# unaffected.
#
# Usage:
#   scripts/publish.sh              # strip, build, then `gleam publish`
#   scripts/publish.sh --yes        # extra args are forwarded to `gleam publish`
#   scripts/publish.sh --dry-run    # do everything except publish (verify only)
#
# Delete this script once glinter and birdie publish glance-7-compatible
# releases: at that point the dev-deps become plain hex packages and `gleam
# publish` works directly.

set -euo pipefail

cd "$(dirname "$0")/.."

GOLDEN="test/golden_test.gleam"
BACKUP="$(mktemp -d)"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

restore() {
  # Runs on every exit path (EXIT trap) so the overrides are never left stripped.
  [ -f "$BACKUP/gleam.toml" ] && cp "$BACKUP/gleam.toml" gleam.toml
  [ -f "$BACKUP/manifest.toml" ] && cp "$BACKUP/manifest.toml" manifest.toml
  [ -f "$BACKUP/golden_test.gleam" ] && cp "$BACKUP/golden_test.gleam" "$GOLDEN"
  rm -rf "$BACKUP"
  echo "publish.sh: restored dev-dep overrides and ${GOLDEN}"
}
trap restore EXIT

# Portable in-place edit (avoids GNU/BSD `sed -i` differences).
replace_in_place() {
  local file="$1" script="$2" tmp
  tmp="$(mktemp)"
  sed "$script" "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Back up everything we touch before changing it.
cp gleam.toml "$BACKUP/gleam.toml"
cp manifest.toml "$BACKUP/manifest.toml"
cp "$GOLDEN" "$BACKUP/golden_test.gleam"

echo "publish.sh: commenting out glinter/birdie git dev-deps"
replace_in_place gleam.toml \
  's|^\(glinter = { git .*\)$|# \1  # temporarily disabled for publish|'
replace_in_place gleam.toml \
  's|^\(birdie = { git .*\)$|# \1  # temporarily disabled for publish|'

echo "publish.sh: setting aside ${GOLDEN} (imports birdie)"
rm -f "$GOLDEN"

echo "publish.sh: regenerating manifest without git deps"
rm -f manifest.toml
gleam deps download

if grep -q 'source = "git"' manifest.toml; then
  echo "publish.sh: ERROR — a git dependency is still in the manifest; aborting" >&2
  exit 1
fi

echo "publish.sh: sanity build (hex-only deps)"
gleam build

if [ "$DRY_RUN" -eq 1 ]; then
  echo "publish.sh: --dry-run — skipping 'gleam publish'. Build succeeded with hex-only deps."
  exit 0
fi

echo "publish.sh: gleam publish $*"
gleam publish "$@"
