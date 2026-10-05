#!/bin/bash
# regress_multi.sh OUTDIR PATCH -- every scenario on seeds 1-3, 4 in parallel; one line per run.
OUT=$1; P=$2; mkdir -p $OUT
jobs=()
for seed in 1 2 3; do
  jobs+=("cross4|$seed|scen/roundabout.luau Roundabout1 NarrowRoad 0.12 300")
  jobs+=("ra2|$seed|scen/roundabout.luau Roundabout CollectorRoad 0.2 300 60")
  jobs+=("grid03|$seed|scen/grid.luau 5 0.03 300")
  jobs+=("grid06|$seed|scen/grid.luau 5 0.06 300")
  jobs+=("lot|$seed|scen/lot.luau 0.25 0.1 300 NarrowRoad")
  jobs+=("lotS|$seed|scen/lot.luau 0.25 0.1 300 NarrowRoad single")
done
printf '%s\n' "${jobs[@]}" | xargs -P ${PAR:-4} -I{} bash -c '
  IFS="|" read -r name seed cmd <<< "{}"
  out=$(LAB_SEED=$seed LAB_PATCH='"$P"' timeout 1500 lune run $cmd 2>&1 | grep -E "^RESULT|COLLISIONS|^LOT" | tr "\n" " ")
  echo "[$name s$seed] $out" > '"$OUT"'/$name.$seed.txt'
cat $OUT/*.txt
