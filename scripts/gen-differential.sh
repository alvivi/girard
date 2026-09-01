#!/usr/bin/env bash
# Regenerate the resolution differential manifest from the *real* Gleam
# compiler. For every case under `differential/cases/` it compiles the fixture,
# and whichever forced-branch companions the case has, with **gleam 1.18.0**,
# then hands the results to `girard/differential` to write
# `differential/expected.json`.
#
# Run from the project root: `bash scripts/gen-differential.sh`.
#
# Unlike `gen-oracle.sh` this needs no patched compiler — `package-interface` is
# a stock export — but it does need the pinned 1.18.0 toolchain, which is why it
# is manual rather than a CI gate. Override the binary with GLEAM=.
#
# Three things it does differently from `gen-oracle.sh`, each of which would
# silently corrupt the evidence if it did not:
#
#   - it copies `differential/.tool-versions`, *not* the repo root's, which pins
#     1.18.1 — copying the wrong one runs the whole corpus on the wrong compiler;
#   - it copies `gleam.toml` byte for byte instead of patching `name =`, so the
#     committed template is exactly the compiled configuration and `inputs_hash`
#     covers bytes the compiler actually saw;
#   - it stages **one module per project**, because some companions are required
#     not to compile and `package-interface` is package-wide: a project holding a
#     base and its expected-failure companion exports nothing at all.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
differential="$root/differential"
gleam="${GLEAM:-$HOME/.asdf/installs/gleam/1.18.0/bin/gleam}"
staging="${STAGING:-$(mktemp -d)}"

if [ ! -x "$gleam" ]; then
  echo "gleam 1.18.0 not found at $gleam" >&2
  echo "install it (asdf install gleam 1.18.0) or set GLEAM=" >&2
  exit 1
fi

# The version check has to run where the pin is in force and has to interrogate
# the binary that will actually run: from the repo root `gleam --version` reports
# the root's 1.18.1, and bare `gleam` is not necessarily what GLEAM= selected.
( cd "$differential" && test "$("$gleam" --version)" = "gleam 1.18.0" ) || {
  echo "expected gleam 1.18.0 from $gleam" >&2
  exit 1
}

# The pinned template resolves one hex dependency. Download it once, into a
# prototype the pinned compiles copy, rather than per compile.
pinned_proto="$staging/.pinned-proto"
prepare_pinned() {
  [ -d "$pinned_proto" ] && return 0
  mkdir -p "$pinned_proto/src"
  cp "$differential/.tool-versions" "$pinned_proto/.tool-versions"
  cp "$differential/pinned/gleam.toml" "$pinned_proto/gleam.toml"
  cp "$differential/pinned/manifest.toml" "$pinned_proto/manifest.toml"
  ( cd "$pinned_proto" && "$gleam" deps download >/dev/null 2>&1 )
}

# compile <fixture> <variant> <source> <template> <support-csv>
compile() {
  local fixture="$1" variant="$2" src="$3" template="$4" support="$5"
  local work out
  out="$staging/$fixture"
  mkdir -p "$out"
  work="$(mktemp -d)"

  if [ "$template" = "pinned" ]; then
    prepare_pinned
    cp -R "$pinned_proto/." "$work/"
    rm -rf "$work/src"
    mkdir -p "$work/src"
  else
    mkdir -p "$work/src"
    cp "$differential/.tool-versions" "$work/.tool-versions"
    cp "$differential/gleam.toml" "$work/gleam.toml"
  fi

  cp "$root/$src" "$work/src/differential_case.gleam"
  if [ -n "$support" ]; then
    local module
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      mkdir -p "$work/src/$(dirname "${module#differential/support/}")"
      cp "$root/$module" "$work/src/${module#differential/support/}"
    done <<< "${support//,/$'\n'}"
  fi

  if ( cd "$work" && "$gleam" export package-interface --out out.json ) \
      >"$out/$variant.log" 2>&1; then
    cp "$work/out.json" "$out/$variant.json"
    printf 'ok\n' > "$out/$variant.status"
  else
    cp "$out/$variant.log" "$out/$variant.err"
    printf 'error\n' > "$out/$variant.status"
  fi
  rm -f "$out/$variant.log"
  rm -rf "$work"
}

mkdir -p "$staging"
echo "staging in $staging"

# `plan` writes any missing companion and prints one line per compile.
plan="$staging/plan.tsv"
( cd "$root" && gleam run -m girard/differential plan ) > "$plan"

while IFS=$'\t' read -r fixture variant src template support; do
  [ -z "${fixture:-}" ] && continue
  compile "$fixture" "$variant" "$src" "$template" "${support:-}"
  printf '%s %s\n' "$fixture" "$variant"
done < "$plan"

( cd "$root" && gleam run -m girard/differential build "$staging" "$(date +%F)" )
