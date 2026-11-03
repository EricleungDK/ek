#!/bin/bash
# R2: a change that hides code from mutation testing (R3) is a needs-human fail, as a protected path is.
# Covers added skip markers (rust #[mutants::skip], python `# pragma: no mutate`, ts `// Stryker disable`)
# and edits to the mutation tool's config (cargo-mutants mutants.toml, [tool.mutmut], stryker config).
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }
mr() { local r="$1" b="$2" h="$3" s="$4"; shift 4; python3 -I "$MR" r2 --repo "$r" --base "$b" --head "$h" --stack "$s" --test-paths 'tests/**' "$@"; }
first() { jq -r --arg k "$2" '[.entries[] | select(.problem | contains($k))][0] // {} | '"$3" <<<"$1"; }

# rust: #[mutants::skip] added on a production fn
R=$(mkrepo rs)
put "$R" src/lib.rs <<'X'
pub fn f(a: i32) -> i32 { a + 1 }
X
B=$(commit "$R" base)
put "$R" src/lib.rs <<'X'
#[mutants::skip]
pub fn f(a: i32) -> i32 { a + 1 }
X
H=$(commit "$R" skip)
out=$(mr "$R" "$B" "$H" rust); rc=$?
eq "$rc" 1 "rust skip: exit 1"
eq "$(first "$out" "mutation skip" .severity)" fail "rust skip: fail"
eq "$(first "$out" "mutation skip" .class)" needs-human "rust skip: needs-human"
eq "$(first "$out" "mutation skip" .line)" 1 "rust skip: line of the attribute"
has "$(first "$out" "mutation skip" .problem)" "mutants::skip" "rust skip: problem names the marker"

# rust: inside cfg_attr, too
put "$R" src/lib.rs <<'X'
#[cfg_attr(test, mutants::skip)]
pub fn f(a: i32) -> i32 { a + 1 }
X
H2=$(commit "$R" cfg-skip)
out=$(mr "$R" "$B" "$H2" rust); rc=$?
eq "$rc" 1 "rust cfg_attr skip: exit 1"
eq "$(first "$out" "mutation skip" .severity)" fail "rust cfg_attr skip: fail"

# rust: a skip already on base, unrelated edit: clean; one in a comment or string: clean
R=$(mkrepo rs-pre)
put "$R" src/lib.rs <<'X'
#[mutants::skip]
pub fn f(a: i32) -> i32 { a + 1 }
X
B=$(commit "$R" base)
put "$R" src/lib.rs <<'X'
#[mutants::skip]
pub fn f(a: i32) -> i32 { a + 1 }
// never #[mutants::skip] here
pub const S: &str = "#[mutants::skip]";
X
H=$(commit "$R" unrelated)
out=$(mr "$R" "$B" "$H" rust); rc=$?
eq "$rc" 0 "rust skip on base, comment and string: clean"

# rust: mutants.toml added or changed (exclude_globs hides files from R3), in any dir
R=$(mkrepo rs-cfg)
put "$R" crate/src/lib.rs <<'X'
pub fn f() {}
X
B=$(commit "$R" base)
put "$R" crate/.cargo/mutants.toml <<'X'
exclude_globs = ["src/main.rs"]
X
H=$(commit "$R" cfg)
out=$(mr "$R" "$B" "$H" rust); rc=$?
eq "$rc" 1 "mutants.toml added: exit 1"
eq "$(first "$out" "mutation config" .class)" needs-human "mutants.toml added: needs-human"
eq "$(first "$out" "mutation config" .file)" crate/.cargo/mutants.toml "mutants.toml added: names the file"

# python: `# pragma: no mutate` added; [tool.mutmut] changed; other pyproject edits clean
R=$(mkrepo py)
put "$R" src/calc.py <<'X'
def f(a):
    return a + 1
X
put "$R" pyproject.toml <<'X'
[project]
name = "calc"
version = "0.1.0"
X
B=$(commit "$R" base)
put "$R" src/calc.py <<'X'
def f(a):
    return a + 1  # pragma: no mutate
X
H=$(commit "$R" pragma)
out=$(mr "$R" "$B" "$H" python); rc=$?
eq "$rc" 1 "python pragma: exit 1"
eq "$(first "$out" "mutation skip" .line)" 2 "python pragma: line"
git -C "$R" checkout -q "$B"
put "$R" pyproject.toml <<'X'
[project]
name = "calc"
version = "0.2.0"
X
H2=$(commit "$R" bump)
out=$(mr "$R" "$B" "$H2" python); rc=$?
eq "$rc" 0 "python pyproject edit outside [tool.mutmut]: clean"
put "$R" pyproject.toml <<'X'
[project]
name = "calc"
version = "0.2.0"

[tool.mutmut]
do_not_mutate = ["src/calc.py"]
X
H3=$(commit "$R" mutmut)
out=$(mr "$R" "$B" "$H3" python); rc=$?
eq "$rc" 1 "python [tool.mutmut] added: exit 1"
eq "$(first "$out" "mutation config" .file)" pyproject.toml "python [tool.mutmut]: names pyproject.toml"

# ts: `// Stryker disable` added; stryker config added
R=$(mkrepo ts)
put "$R" package.json <<'X'
{"name": "t"}
X
put "$R" src/a.ts <<'X'
export const f = (a: number) => a + 1;
X
B=$(commit "$R" base)
put "$R" src/a.ts <<'X'
// Stryker disable next-line all
export const f = (a: number) => a + 1;
X
H=$(commit "$R" disable)
out=$(mr "$R" "$B" "$H" ts); rc=$?
eq "$rc" 1 "ts Stryker disable: exit 1"
eq "$(first "$out" "mutation skip" .line)" 1 "ts Stryker disable: line"
git -C "$R" checkout -q "$B"
put "$R" stryker.config.json <<'X'
{"mutate": ["src/b.ts"]}
X
H2=$(commit "$R" stryker-cfg)
out=$(mr "$R" "$B" "$H2" ts); rc=$?
eq "$rc" 1 "ts stryker config added: exit 1"
eq "$(first "$out" "mutation config" .class)" needs-human "ts stryker config: needs-human"

done_tests
