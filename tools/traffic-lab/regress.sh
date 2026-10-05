#!/bin/bash
# Runs the scenario suite for one source tree; prints one line per scenario.
P="$1"
run() { local name="$1"; shift; local out; out=$(LAB_PATCH=$P timeout 1500 lune run "$@" 2>&1); echo "$out" | grep -E "^RESULT|COLLISIONS|^LOT|ERR" | tr '\n' ' ' | sed "s/^/[$name] /"; echo; }
run cross4   scen/roundabout.luau Roundabout1 NarrowRoad 0.12 300
run ra2      scen/roundabout.luau Roundabout CollectorRoad 0.2 300 60
run grid03   scen/grid.luau 5 0.03 300
run grid06   scen/grid.luau 5 0.06 300
run lot      scen/lot.luau 0.25 0.1 300 NarrowRoad
run lotS     scen/lot.luau 0.25 0.1 300 NarrowRoad single
