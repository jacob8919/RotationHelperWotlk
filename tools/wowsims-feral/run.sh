#!/usr/bin/env bash
# Generates the rotation variants and compares them (10,000 fights each).
# Extra arguments go to feralcmp, e.g. ./run.sh -gear ui/feral_druid/gear_sets/p3.gear.json -dur 90
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
C=${WOWSIMS_CACHE:-$HOME/.cache/rotationhelper-wowsims}
rm -rf "$C/apls" && mkdir -p "$C/apls"
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
