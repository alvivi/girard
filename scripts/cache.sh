#!/usr/bin/env bash
# Build and consume an OFFLINE cache of the differential-sweep corpus, so a
# re-validation sweep (girard changed, packages + patched compiler unchanged)
# runs without touching hex and without re-exporting the oracle.
#
# A normal sweep (scripts/sweep.sh) pays three costs per package:
#   1. `gleam deps download`  — resolve + download the closure from hex
#      (rate-limited; the dominant cost of a cold sweep), then
#   2. oracle export          — the patched compiler compiles the package
#      into per-expression types (~1s), then
#   3. girard diff            — the only step that changes when girard changes.
# This cache eliminates 1 and 2: it stores every package's resolved dependency
# closure (deduplicated) plus its pre-computed oracle JSON, leaving only step 3
# (~1s/pkg, no network) for every future re-sweep.
#
# Usage:
#   scripts/cache.sh build <package>            populate the cache for one package
#   scripts/cache.sh build-batch <listfile>     populate for a list (resumable, paced)
#   scripts/cache.sh resweep [<listfile>|--all] [results.tsv]
#                                               offline diff from the cache
#   scripts/cache.sh pack [out.tar.gz]          pack the cache into one artifact
#   scripts/cache.sh unpack <in.tar.gz>         restore a packed cache
#   scripts/cache.sh stats                      summarize cache contents
#
# Layout ($GIRARD_CACHE, default ~/.cache/girard-sweep):
#   pool/<name>@<version>/   each unique package version's gleam.toml + src/, ONCE
#   manifest/<pkg>.txt       the package's closure: one "<name>@<version>" per line
#   oracle/<pkg>.json        the patched compiler's per-expression oracle
#   index.tsv                <pkg> <TAB> built|skip-build|skip-resolve <TAB> detail
#   meta.txt                 patched-compiler git rev the oracles were built with
#
# Env overrides:
#   GIRARD_CACHE  cache root (default ~/.cache/girard-sweep)
#   GLEAM         patched compiler for the oracle (default ../gleam/target/debug/gleam)
#   HEXGLEAM      stock gleam used to resolve/download/run (default first on PATH)
#   For build-batch pacing: SWEEP_DELAY / SWEEP_RETRIES / SWEEP_BACKOFF (see batch_sweep.sh)
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
gleam="${GLEAM:-$root/../gleam/target/debug/gleam}"
hexgleam="${HEXGLEAM:-$(command -v gleam)}"
cache="${GIRARD_CACHE:-$HOME/.cache/girard-sweep}"

pool="$cache/pool"
manifest_dir="$cache/manifest"
oracle_dir="$cache/oracle"
index="$cache/index.tsv"

# Extract `version = "x.y.z"` from a gleam.toml; "0.0.0" if absent.
toml_version() {
  local v
  v="$(grep -m1 '^[[:space:]]*version[[:space:]]*=' "$1" 2>/dev/null \
        | sed -E 's/.*"([^"]*)".*/\1/')"
  printf '%s' "${v:-0.0.0}"
}

# ---------------------------------------------------------------------------
# build: resolve a package's closure, dedup its members into the pool, write
# its manifest, and export its oracle. Idempotent and resumable: a package
# already recorded in index.tsv is skipped.
# ---------------------------------------------------------------------------
cmd_build() {
  local pkg="${1:?usage: cache.sh build <package>}"
  mkdir -p "$pool" "$manifest_dir" "$oracle_dir"
  touch "$index"
  if grep -q "^${pkg}	" "$index"; then
    echo "cache build $pkg: already recorded (skip)"
    return 0
  fi
  if [ ! -x "$gleam" ]; then
    echo "patched compiler not found at $gleam (set GLEAM=)" >&2
    return 1
  fi

  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  cp "$root/.tool-versions" "$work/.tool-versions"

  # 1. Resolve + download the full transitive closure into a probe project.
  #    Permissive stdlib range so the resolver picks whatever the closure needs.
  local proj="$work/probe"
  mkdir -p "$proj/src"
  cp "$root/.tool-versions" "$proj/.tool-versions"
  cat > "$proj/gleam.toml" <<EOF
name = "probe"
version = "1.0.0"
[dependencies]
gleam_stdlib = ">= 0.34.0 and < 2.0.0"
$pkg = ">= 0.0.0"
[dev-dependencies]
EOF
  echo "pub const probe = 0" > "$proj/src/probe.gleam"
  if ! ( cd "$proj" && timeout 240 "$hexgleam" deps download >/dev/null 2>&1 ); then
    printf '%s\tskip-resolve\tcould not resolve/download\n' "$pkg" >>"$index"
    echo "cache build $pkg: skip-resolve"
    return 0
  fi

  local deps="$proj/build/packages"
  if [ ! -d "$deps/$pkg/src" ]; then
    printf '%s\tskip-resolve\tpackage source not downloaded\n' "$pkg" >>"$index"
    echo "cache build $pkg: skip-resolve (no source)"
    return 0
  fi

  # 2. Oracle: build the package as the root against the resolved deps.
  local oroot="$work/oracle"
  mkdir -p "$oroot/build/packages"
  cp -r "$deps/$pkg/src" "$oroot/src"
  cp "$deps/$pkg/gleam.toml" "$oroot/gleam.toml"
  cp "$root/.tool-versions" "$oroot/.tool-versions"
  sed -i "s/^name = .*/name = \"$pkg\"/" "$oroot/gleam.toml"
  local d name
  for d in "$deps"/*/; do
    name="$(basename "$d")"
    [ "$name" = "$pkg" ] && continue
    cp -r "$d" "$oroot/build/packages/$name"
  done
  if ! ( cd "$oroot" && "$gleam" export expression-types --out out.json >/dev/null 2>&1 ); then
    printf '%s\tskip-build\toracle export failed (package or dep does not compile)\n' "$pkg" >>"$index"
    echo "cache build $pkg: skip-build"
    return 0
  fi

  # 3. Dedup every closure member (incl. the root) into the pool by name@version,
  #    storing only gleam.toml + src/ (all girard's resolver and the diff need).
  local tmp_manifest="$work/manifest.txt"
  : >"$tmp_manifest"
  local ver dest
  for d in "$deps"/*/; do
    name="$(basename "$d")"
    [ -d "$d/src" ] || continue
    ver="$(toml_version "$d/gleam.toml")"
    dest="$pool/$name@$ver"
    if [ ! -d "$dest" ]; then
      mkdir -p "$dest"
      cp "$d/gleam.toml" "$dest/gleam.toml" 2>/dev/null || true
      cp -r "$d/src" "$dest/src"
    fi
    printf '%s@%s\n' "$name" "$ver" >>"$tmp_manifest"
  done

  # 4. Commit the oracle + manifest only once everything succeeded.
  cp "$oroot/out.json" "$oracle_dir/$pkg.json"
  cp "$tmp_manifest" "$manifest_dir/$pkg.txt"
  printf '%s\tbuilt\t%s members\n' "$pkg" "$(wc -l <"$tmp_manifest" | tr -d ' ')" >>"$index"
  echo "cache build $pkg: built ($(wc -l <"$tmp_manifest" | tr -d ' ') members)"
}

# ---------------------------------------------------------------------------
# build-batch: populate for every package in a list, resumable and paced.
# ---------------------------------------------------------------------------
cmd_build_batch() {
  local list="${1:?usage: cache.sh build-batch <listfile>}"
  local delay="${SWEEP_DELAY:-0}"
  local retries="${SWEEP_RETRIES:-0}"
  local backoff="${SWEEP_BACKOFF:-30}"
  mkdir -p "$pool" "$manifest_dir" "$oracle_dir"
  touch "$index"
  [ -f "$cache/meta.txt" ] || record_meta

  local pkg attempt
  while IFS= read -r pkg; do
    pkg="$(printf '%s' "$pkg" | tr -d '[:space:]')"
    [ -z "$pkg" ] && continue
    grep -q "^${pkg}	" "$index" && continue
    attempt=0
    while :; do
      cmd_build "$pkg"
      # Retry only resolve failures (transient hex throttling).
      if grep -q "^${pkg}	skip-resolve" "$index" && [ "$attempt" -lt "$retries" ]; then
        sed -i "\#^${pkg}	skip-resolve#d" "$index"
        attempt=$((attempt + 1))
        printf '  retry %d/%d (resolve) %s after %ss\n' "$attempt" "$retries" "$pkg" "$backoff"
        sleep "$backoff"
        continue
      fi
      break
    done
    [ "$delay" != "0" ] && sleep "$delay"
  done <"$list"
  echo "=== build-batch done ==="
  cmd_stats
}

# ---------------------------------------------------------------------------
# resweep: reconstruct each cached package's closure (symlinks into the pool)
# and run girard's diff against the cached oracle. No hex, no oracle compile.
# ---------------------------------------------------------------------------
cmd_resweep() {
  local sel="${1:---all}"
  local results="${2:-$cache/resweep.tsv}"
  local flagged="${results%.tsv}.flagged.txt"
  : >"$results"
  : >"$flagged"

  local pkgs
  if [ "$sel" = "--all" ]; then
    pkgs="$(ls "$manifest_dir" 2>/dev/null | sed 's/\.txt$//')"
  else
    pkgs="$(cat "$sel")"
  fi

  local stage
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN

  local pkg member name ver pkgroot summary errored mism st detail
  for pkg in $pkgs; do
    pkg="$(printf '%s' "$pkg" | tr -d '[:space:]')"
    [ -z "$pkg" ] && continue
    if [ ! -f "$manifest_dir/$pkg.txt" ] || [ ! -f "$oracle_dir/$pkg.json" ]; then
      printf '%s\tmissing\tnot in cache\n' "$pkg" >>"$results"
      continue
    fi
    # Reconstruct the packages-root with symlinks into the pool (zero-copy).
    pkgroot="$stage/$pkg"
    rm -rf "$pkgroot"
    mkdir -p "$pkgroot"
    while IFS= read -r member; do
      [ -z "$member" ] && continue
      name="${member%@*}"
      [ -d "$pool/$member" ] && ln -sfn "$pool/$member" "$pkgroot/$name"
    done <"$manifest_dir/$pkg.txt"

    summary="$( cd "$root" && gleam run -m girard/diff "$pkg" "$oracle_dir/$pkg.json" "$pkgroot" 2>/dev/null | grep -E '^diff ' | tail -1 )"
    if [ -n "$summary" ]; then
      errored="$(echo "$summary" | grep -oE '[0-9]+ errored' | grep -oE '[0-9]+')"
      mism="$(echo "$summary" | grep -oE '[0-9]+ expression mismatches' | grep -oE '[0-9]+')"
      if [ "${errored:-0}" = "0" ] && [ "${mism:-0}" = "0" ]; then
        st=clean
      else
        st=discrepancy; echo "$pkg	$summary" >>"$flagged"
      fi
      detail="$summary"
    else
      st=crash; detail="no diff summary"; echo "$pkg	crash" >>"$flagged"
    fi
    printf '%s\t%s\t%s\n' "$pkg" "$st" "$detail" >>"$results"
    printf '[%s] %s\n' "$st" "$pkg"
  done
  echo "=== resweep done -> $results (flagged: $flagged) ==="
}

record_meta() {
  mkdir -p "$cache"
  {
    printf 'compiler_rev\t%s\n' "$(git -C "$root/../gleam" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'compiler_branch\t%s\n' "$(git -C "$root/../gleam" branch --show-current 2>/dev/null || echo unknown)"
  } >"$cache/meta.txt"
}

cmd_pack() {
  local out="${1:-$root/girard-sweep-cache.tar.gz}"
  [ -d "$cache" ] || { echo "no cache at $cache" >&2; return 1; }
  # Store members relative to the cache root (no embedded top dir) so the
  # artifact restores into any $GIRARD_CACHE regardless of its name.
  tar -C "$cache" -czf "$out" .
  echo "packed $cache -> $out ($(du -h "$out" | cut -f1))"
}

cmd_unpack() {
  local in="${1:?usage: cache.sh unpack <in.tar.gz>}"
  mkdir -p "$cache"
  tar -C "$cache" -xzf "$in"
  echo "unpacked $in -> $cache"
  cmd_stats
}

cmd_stats() {
  [ -d "$cache" ] || { echo "no cache at $cache"; return 0; }
  echo "cache: $cache"
  [ -f "$cache/meta.txt" ] && sed 's/^/  /' "$cache/meta.txt"
  printf '  pool versions : %s\n' "$(ls "$pool" 2>/dev/null | wc -l | tr -d ' ')"
  printf '  manifests     : %s\n' "$(ls "$manifest_dir" 2>/dev/null | wc -l | tr -d ' ')"
  printf '  oracles       : %s\n' "$(ls "$oracle_dir" 2>/dev/null | wc -l | tr -d ' ')"
  printf '  disk          : %s\n' "$(du -sh "$cache" 2>/dev/null | cut -f1)"
  if [ -f "$index" ]; then
    printf '  index: built=%s skip-build=%s skip-resolve=%s\n' \
      "$(grep -c '	built	' "$index")" \
      "$(grep -c '	skip-build	' "$index")" \
      "$(grep -c '	skip-resolve	' "$index")"
  fi
}

case "${1:-}" in
  build)        shift; cmd_build "$@" ;;
  build-batch)  shift; cmd_build_batch "$@" ;;
  resweep)      shift; cmd_resweep "$@" ;;
  pack)         shift; cmd_pack "$@" ;;
  unpack)       shift; cmd_unpack "$@" ;;
  stats)        shift; cmd_stats "$@" ;;
  *)
    sed -n '2,40p' "$0"
    exit 1
    ;;
esac
