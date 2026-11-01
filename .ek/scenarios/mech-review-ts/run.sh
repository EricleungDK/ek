#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
MR="$EK_REPO/scripts/mech-review.py"
FX="$EK_REPO/tests/fixtures"
export MECH_FX="$FX"
# fake toolchain (argv[0] replaced via MECH_TEST_STUB): a Stryker run (--mutate) copies the real report fixture and
# prints its log; any other run is a vitest replay of the outcome named for the test's leaf name in ./outcomes
STUB="$PWD/fake-ts.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
if [[ "$1" == "--version" ]]; then echo "10.0.0"; exit 0; fi
if [[ " $* " == *" --mutate "* ]]; then
  mkdir -p reports/mutation; cp "$MECH_FX/stryker/missed/report.json" reports/mutation/mutation.json
  cat "$MECH_FX/stryker/missed/stdout.txt"; exit 0
fi
pat=""; prev=""; for a in "$@"; do [[ "$prev" == "-t" ]] && pat="$a"; prev="$a"; done
leaf="${pat#^}"; leaf="${leaf%\$}"; leaf="${leaf##* > }"
o=$(awk -v n="$leaf" '$1 == n { print $2 }' outcomes 2>/dev/null); o="${o:-pass}"
case "$o" in
  pass) cat "$MECH_FX/vitest/pass.txt"; exit 0 ;;
  fail) cat "$MECH_FX/vitest/fail.txt"; exit 1 ;;
esac
SH
chmod +x "$STUB"

ts_repo() {
  R="$PWD/repo"; rm -rf "$R"; mkdir -p "$R/src" "$R/tests" "$R/node_modules/.bin"; git -C "$R" init -q -b main
  printf 'node_modules/\n' > "$R/.gitignore"
  printf '{"name":"calc","devDependencies":{"vitest":"5.0.5"}}\n' > "$R/package.json"
  printf '#!/bin/bash\necho 5.0.5\n' > "$R/node_modules/.bin/vitest"; chmod +x "$R/node_modules/.bin/vitest"
  printf 'export function add(a: number, b: number): number {\n  return a+b;\n}\n\nexport function isPositive(n: number): boolean {\n  return n>0;\n}\n\nexport function mul(a: number, b: number): number {\n  return a * b;\n}\n\nexport function sub(a: number, b: number): number {\n  return a - b;\n}\n' > "$R/src/calc.ts"
  printf 'import { describe, it, expect } from "vitest";\nimport { add } from "../src/calc";\n\ndescribe("Calc", () => {\n  it("adds", () => {\n    expect(add(0, 0)).toBe(0);\n  });\n});\n' > "$R/tests/calc.test.ts"
  git -C "$R" add -A; git -C "$R" commit -qm base; BASE=$(git -C "$R" rev-parse HEAD)
}
# r2 <head>: r2 with the ts stack on the repo
r2() { python3 "$MR" r2 --repo "$R" --base "$BASE" --head "$1" --stack ts --test-paths 'tests/**'; }

# 1. cheat: it.skip the failing test
ts_repo
printf 'import { describe, it, expect } from "vitest";\nimport { add } from "../src/calc";\n\ndescribe("Calc", () => {\n  it.skip("adds", () => {\n    expect(add(0, 0)).toBe(0);\n  });\n});\n' > "$R/tests/calc.test.ts"
git -C "$R" commit -qam cheat; CHEAT=$(git -C "$R" rev-parse HEAD)
out=$(r2 "$CHEAT"); rc=$?
eq "skip exit" "$rc" 1
eq "skip check" "$(jq -r '.entries[0].check' <<<"$out")" R2
eq "skip class" "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable
eq "skip file" "$(jq -r '.entries[0].file' <<<"$out")" tests/calc.test.ts
has "$(jq -r '.entries[0].problem' <<<"$out")" "Calc > adds" "skip names the test"
eq "skip summary" "$(jq -r .summary <<<"$out")" "fail $CHEAT (1 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"

# 2. clean: from base, add a passing test
git -C "$R" checkout -q -b clean "$BASE"
printf 'import { describe, it, expect } from "vitest";\nimport { add, sub } from "../src/calc";\n\ndescribe("Calc", () => {\n  it("adds", () => {\n    expect(add(0, 0)).toBe(0);\n  });\n  it("subtracts", () => {\n    expect(sub(3, 1)).toBe(2);\n  });\n});\n' > "$R/tests/calc.test.ts"
git -C "$R" commit -qam clean; CLEAN=$(git -C "$R" rev-parse HEAD)
out=$(r2 "$CLEAN"); rc=$?
eq "clean exit" "$rc" 0
eq "clean summary" "$(jq -r .summary <<<"$out")" "pass $CLEAN (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"

# 3. red-first: a red commit adds Calc > fresh; the replayed vitest run decides its outcome at red and at head
git -C "$R" checkout -q -b agent/x "$BASE"
printf 'import { describe, it, expect } from "vitest";\nimport { add } from "../src/calc";\n\ndescribe("Calc", () => {\n  it("adds", () => {\n    expect(add(0, 0)).toBe(0);\n  });\n  it("fresh", () => {\n    expect(add(1, 2)).toBe(3);\n  });\n});\n' > "$R/tests/calc.test.ts"
printf 'fresh fail\nadds pass\n' > "$R/outcomes"; git -C "$R" add -A; git -C "$R" commit -qm "test(red): fresh"; RED=$(git -C "$R" rev-parse HEAD)
printf 'fresh pass\nadds pass\n' > "$R/outcomes"; git -C "$R" commit -qam "feat: fresh" --allow-empty; HEADR=$(git -C "$R" rev-parse HEAD)
out=$(MECH_TEST_STUB="$STUB" python3 "$MR" red --repo "$R" --base "$BASE" --head "$HEADR" --stack ts --test-paths 'tests/**' --head-branch agent/x); rc=$?
eq "red-first exit" "$rc" 0
eq "red-first R1" "$(jq -r .checks.R1.status <<<"$out")" pass
eq "red-first summary" "$(jq -r .summary <<<"$out")" "pass $HEADR (0 fail, 0 confirm; ran: R1 R4; skipped: R2 R3)"
printf 'fresh pass\nadds pass\n' > "$R/outcomes"; git -C "$R" checkout -q -b agent/y "$BASE"
git -C "$R" checkout -q agent/x -- tests/calc.test.ts; printf 'fresh pass\nadds pass\n' > "$R/outcomes"; git -C "$R" add -A; git -C "$R" commit -qm "test(red): fresh passes"; RED2=$(git -C "$R" rev-parse HEAD)
out=$(MECH_TEST_STUB="$STUB" python3 "$MR" red --repo "$R" --base "$BASE" --head "$RED2" --stack ts --test-paths 'tests/**' --head-branch agent/y); rc=$?
eq "red passes at red exit" "$rc" 1
eq "red passes at red names the test" "$(jq -r '.entries[0].problem' <<<"$out")" "new test \`Calc > fresh\` passes at the red commit"

# 4. mutation: head changes add and isPositive (the real Stryker fixture head); Stryker is replayed from the missed fixture
git -C "$R" checkout -q -b mut "$BASE"
cp "$FX/stryker/missed/head/src/calc.ts" "$R/src/calc.ts"; git -C "$R" commit -qam mut; MUT=$(git -C "$R" rev-parse HEAD)
out=$(MECH_TEST_STUB="$STUB" python3 "$MR" mutants --repo "$R" --base "$BASE" --head "$MUT" --stack ts --test-paths 'tests/**' --mutants-cmd node_modules/.bin/stryker); rc=$?
eq "stryker exit" "$rc" 1
eq "stryker entries" "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 5
eq "stryker lines" "$(jq -r '[.entries[].line] | unique | map(tostring) | join(",")' <<<"$out")" "2,6"
hasnt "sub outside diff" "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "src/calc.ts:14"
eq "stryker summary" "$(jq -r .summary <<<"$out")" "fail $MUT (5 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)"

# 5. plan: a ts production change runs the mutants job over 4 shards
out=$(python3 "$MR" plan --repo "$R" --base "$BASE" --head "$MUT" --stack ts --test-paths 'tests/**' --shards 4)
eq "plan" "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":true,"count":4,"shards":[0,1,2,3]}'
echo "mech-review ts ok"
