#!/bin/bash
# R3 baseline with a project dir: --relative is a git diff flag; cargo-mutants rejects it, and did on every Alfredo PR (v0.2.2).
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

R="$T/repo"; mkdir -p "$R/sub/src"; git -C "$R" init -q -b main
printf '[package]\nname = "sub"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n' > "$R/sub/Cargo.toml"
printf 'pub fn add(a: i32, b: i32) -> i32 {\n    0\n}\n#[test]\nfn adds() {\n    add(1, 2);\n}\n' > "$R/sub/src/lib.rs"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
printf 'pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n#[test]\nfn adds() {\n    add(1, 2);\n}\n' > "$R/sub/src/lib.rs"
git -C "$R" -c user.name=t -c user.email=t@t commit -qam change
base() { python3 -I "$MR" baseline --repo "$R" --base HEAD~1 --head HEAD --stack rust --test-paths 'sub/tests/**' --project-dir sub "$@"; }

# a stub as strict as cargo-mutants 27.1.0 about this flag
STUB="$T/mutants.sh"
cat > "$STUB" <<SH
#!/bin/bash
echo "\$*" >> "$T/calls"
case "\$*" in *--relative*) echo "error: unexpected argument '--relative' found" >&2; exit 2 ;; esac
case "\$*" in
  *--version*) echo "cargo-mutants 27.1.0" ;;
  *--list*) cat "$ROOT/tests/fixtures/mutants/list-15.json" ;;
esac
SH
chmod +x "$STUB"
out="$(base --mutants-cmd "$STUB")"
lacks "$out" "unexpected argument" "stub: baseline gets past --list"
lacks "$(cat "$T/calls")" "--relative" "stub: no git flag reaches cargo-mutants"

# the real tool, end to end, on a crate in a subdir
if command -v cargo-mutants >/dev/null; then
  out="$(base --mutation-budget 3)"
  run="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["run"], d["count"], d["checks"]["R3"]["status"])' <<<"$out")"
  has "$run" "True" "real: baseline runs the shards"
  t="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["timeout"])' <<<"$out")"
  out="$(python3 -I "$MR" mutants --repo "$R" --base HEAD~1 --head HEAD --stack rust --test-paths 'sub/tests/**' --project-dir sub --mutant-timeout "$t" --mutation-budget 3 --shard 0/1)"
  has "$out" "MISSED" "real: a shard reports the surviving mutant"
else
  ok "skip real run: cargo-mutants not installed"
fi

done_tests
