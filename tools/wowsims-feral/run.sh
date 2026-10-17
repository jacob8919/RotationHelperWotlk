#!/usr/bin/env bash
# Generates the rotation variants and compares them (10,000 fights each).
#   ./run.sh [feralcmp options]          cat: WoWSims vs the addon before/after tuning
#   ./run.sh bear [feralcmp options]     bear tank, 1 and 3 targets, Whitemane threat
# e.g. ./run.sh -gear ui/feral_druid/gear_sets/p3.gear.json -dur 90
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
C=${WOWSIMS_CACHE:-$HOME/.cache/rotationhelper-wowsims}
rm -rf "$C/apls" && mkdir -p "$C/apls"
if [ "${1:-}" = bear ]; then
    shift
    python3 aplgen.py --bear "$C/apls" '{
      "bear_tuned": {"mangle_wait": 1.0, "ff_wait": 1.5, "maul_rage": 25, "aoe_maul_rage": 40,
                     "aoe": ["swipe", "demo", "mangle", "ff", "lacerate"]}
    }'
    cp "$C/wowsims/ui/feral_tank_druid/apls/default.apl.json" "$C/apls/wowsims_tank.apl.json"
    cd "$C/wowsims"
    for n in 1 3; do
        echo "== $n target(s)"
        "$C/feralcmp" -spec tank -targets $n -iters 10000 "$@" "$C"/apls/wowsims_tank.apl.json \
            "$C"/apls/bear_original.apl.json "$C"/apls/bear_tuned.apl.json 2>&1 | grep -v iterations
    done
    exit 0
fi
if [ "${1:-}" = tf ]; then
    # Tiger's Fury: when to use it (2026-10-17). "tuned" is the rotation as shipped before.
    shift
    T='"bite_rip": 5, "bite_roar": 5, "rake_refresh": 0.1, "pool_shred": 70, "ff_energy": 87, "wait_ff": 0.5, "roar_clip": [3, 10]'
    python3 aplgen.py "$C/apls" "{
      \"tuned_tf30\": {$T},
      \"tf_never\": {$T, \"tf_energy\": null},
      \"tf20\": {$T, \"tf_energy\": 20},
      \"tf40\": {$T, \"tf_energy\": 40},
      \"tf40_cc30\": {$T, \"tf_energy\": 40, \"tf_cc\": 10},
      \"tf40_cc25\": {$T, \"tf_energy\": 40, \"tf_cc\": 15},
      \"tf30_cc15\": {$T, \"tf_energy\": 30, \"tf_cc\": 15},
      \"tf50\": {$T, \"tf_energy\": 50}
    }"
    cd "$C/wowsims"
    "$C/feralcmp" -iters 10000 "$@" "$C"/apls/tuned_tf30.apl.json "$C"/apls/tf_never.apl.json "$C"/apls/tf20.apl.json \
        "$C"/apls/tf40.apl.json "$C"/apls/tf40_cc30.apl.json "$C"/apls/tf40_cc25.apl.json "$C"/apls/tf30_cc15.apl.json \
        "$C"/apls/tf50.apl.json 2>&1 | grep -v iterations
    exit 0
fi
python3 aplgen.py "$C/apls" '{
  "addon_tuned": {"bite_rip": 5, "bite_roar": 5, "rake_refresh": 0.1, "pool_shred": 70, "ff_energy": 87,
                  "wait_ff": 0.5, "roar_clip": [3, 10]}
}'
python3 - "$C" <<'PY'
import json, sys
c = sys.argv[1]
d = json.load(open(c + "/wowsims/ui/feral_druid/apls/default.apl.json"))
d["prepullActions"] = []  # no pre-pull Clearcasting/Berserk: a fair comparison
json.dump(d, open(c + "/apls/wowsims_optimal.apl.json", "w"))
PY
cd "$C/wowsims"
"$C/feralcmp" -iters 10000 "$@" "$C"/apls/wowsims_optimal.apl.json "$C"/apls/addon_original.apl.json "$C"/apls/addon_tuned.apl.json 2>&1 | grep -v iterations
