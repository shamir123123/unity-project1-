#!/usr/bin/env bash
# Run every offline check in this folder and print the last lines of each. Slow (Lune mocks the
# engine); each test has its own timeout. Usage: tools/harness/run_all.sh
cd "$(dirname "$0")"
LUNE=${LUNE:-/tmp/tools/lune}
run() {
  local t=$1; shift
  echo "=== $*"
  timeout "$t" "$LUNE" run "$@" 2>&1 | tail -n "${TAIL:-8}"
}
run 600 test_pieces_equiv.luau
run 1500 test_crossings_equiv.luau new 7 60
run 1800 test_gates_equiv.luau
run 3000 bench_server_place.luau 8
run 1800 bench_validate.luau new 12
run 600 test_meshview.luau
run 600 test_render_worker.luau
run 900 test_terrain_edit.luau
run 1500 test_terrain_lod.luau
run 600 test_streetnames.luau
run 600 test_streetnames_cache.luau
run 300 test_streetlights.luau
run 900 test_signplan_cache.luau
run 600 bench_trafficsigns.luau
run 600 test_trafficjam.luau
run 300 test_waterfoam.luau
run 300 test_windturbines.luau
run 300 test_solar.luau
run 300 test_pedestrians.luau
run 300 test_windowlights.luau
run 900 test_seasontint.luau
run 600 test_assetlod.luau
run 300 test_utilityboxes.luau
