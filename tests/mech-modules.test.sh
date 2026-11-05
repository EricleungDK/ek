# mech_review module layering: gitio and report at the bottom, the checks (r2, red, mutants) on them, engine on top.
# No import cycle, so no function-level imports, and every module imports first in a fresh interpreter.
source "$(dirname "$0")/lib.sh"
PKG="$ROOT/scripts/mech_review"

for m in gitio report r2 red mutants engine merge doctor comment cli; do
  out=$(python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import mech_review.$m" "$ROOT/scripts" 2>&1)
  eq "$out" "" "mech_review.$m imports first, alone"
done
eq "$(grep -n '^ \+\(from \.\|import \.\)' "$PKG"/*.py)" "" "no function-level imports in mech_review"
eq "$(grep -l 'from \.engine import\|from \. import.*\bengine\b' "$PKG"/{gitio,report,r2,red,mutants,merge}.py 2>&1)" "" \
   "checks and merge do not import the engine"
done_tests
