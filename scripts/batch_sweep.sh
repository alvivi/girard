#!/usr/bin/env bash
# Sweep a list of packages sequentially, recording a machine-readable result
# per package. Sweeps cannot run in parallel: each rewrites girard's
# build/packages and runs `gleam run` in the repo root.
#
#   bash scripts/batch_sweep.sh <listfile> [results.tsv]
#
# Output TSV columns: package <TAB> status <TAB> detail
#   clean         diff with 0 errored, 0 mismatches
#   discrepancy   diff with errored>0 or mismatches>0   (-> flagged)
#   crash         girard produced no diff summary line   (-> flagged)
#   skip-build    package/dep does not compile
#   skip-resolve  not found / could not download
# Already-recorded packages are skipped, so the run is resumable.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
list="${1:?usage: batch_sweep.sh <listfile> [results.tsv]}"
results="${2:-/tmp/sweep_results.tsv}"
flagged="${results%.tsv}.flagged.txt"
logdir="${results%.tsv}.logs"
mkdir -p "$logdir"
touch "$results"

while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  grep -q "^${pkg}	" "$results" && continue
  log="$logdir/$pkg.txt"
  bash "$root/scripts/sweep.sh" "$pkg" >"$log" 2>&1
  summary="$(grep -E '^diff ' "$log" | tail -1)"
  if [ -n "$summary" ]; then
    errored="$(echo "$summary" | grep -oE '[0-9]+ errored' | grep -oE '[0-9]+')"
    mism="$(echo "$summary" | grep -oE '[0-9]+ expression mismatches' | grep -oE '[0-9]+')"
    if [ "${errored:-0}" = "0" ] && [ "${mism:-0}" = "0" ]; then
      st=clean
    else
      st=discrepancy; echo "$pkg	$summary" >>"$flagged"
    fi
    detail="$summary"
  elif grep -q 'SKIP (oracle export failed' "$log"; then
    st=skip-build;   detail="$(grep SKIP "$log" | tail -1)"
  elif grep -q 'SKIP (' "$log"; then
    st=skip-resolve; detail="$(grep SKIP "$log" | tail -1)"
  else
    st=crash; detail="$(tail -1 "$log")"; echo "$pkg	crash	$detail" >>"$flagged"
  fi
  printf '%s\t%s\t%s\n' "$pkg" "$st" "$detail" >>"$results"
  printf '[%s] %s\n' "$st" "$pkg"
done <"$list"
echo "=== batch done ==="
