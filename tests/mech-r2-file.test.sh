# R2 per-file rules through the internal seam r2.r2_file: text in, entries out, no git repo.
source "$(dirname "$0")/lib.sh"
python3 -I - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review.r2 import r2_file
from mech_review.stack import PythonAdapter, RustAdapter

R, P = RustAdapter(), PythonAdapter()
TG = ["tests/**"]
FAILS = 0


def check(label, got, want):
    global FAILS
    if got == want:
        print(f"  ok   {label}")
    else:
        FAILS += 1
        print(f"  FAIL {label}\n       want: {want!r}\n       got:  {got!r}")


def keys(ents):
    return sorted((e["_key"], e["severity"]) for e in ents)


A = "#[test]\nfn a() {\n    assert_eq!(1, 1);\n}\n"
B = "\n#[test]\nfn b() {\n    assert_eq!(2, 2);\n}\n"

ents = r2_file(R, TG, "tests/a.rs", "tests/a.rs", A + B, A)
check("removed fn: one fail keyed by fn", keys(ents), [("b", "fail")])
check("removed fn: base line", ents[0]["line"], 7)
check("removed fn: problem", ents[0]["problem"], "test fn `b` removed")

renamed = A + B.replace("fn b()", "fn b2()")
check("rename with same asserts is not a removal", keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", A + B, renamed)), [])

check("new file: nothing removed", keys(r2_file(R, TG, None, "tests/a.rs", None, A + B)), [])
check("unchanged file: no entries", keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", A, A)), [])

ign = A.replace("#[test]\n", "#[test]\n#[ignore]\n")
check("ignore added: fail", keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", A, ign)), [("ignore:a", "fail")])
check("ignore kept: no entry", keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", ign, ign)), [])

two = "#[test]\nfn a() {\n    assert_eq!(1, 1);\n    assert!(true);\n}\n"
check("assert dropped in surviving fn", keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", two, A)),
      [("assert-count:a", "fail")])

helper = "fn h() {\n    assert!(true);\n}\n\n#[test]\nfn a() {\n    assert_eq!(1, 1);\n    h();\n}\n"
check("assert moved to a called helper is not a drop", keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", two, helper)), [])

changed = A.replace("assert_eq!(1, 1)", "assert_eq!(1, 2)")
ents = r2_file(R, TG, "tests/a.rs", "tests/a.rs", A, changed)
check("expected value changed: confirm", keys(ents), [("expected:a|1", "confirm")])
check("expected value changed: problem", ents[0]["problem"], "expected value changed in `a`: was 1, now 2")

PROD = "pub fn f() -> i32 { 1 }\n"
sup = "#[allow(dead_code)]\n" + PROD
check("suppression on an added line: fail", keys(r2_file(R, TG, "src/lib.rs", "src/lib.rs", PROD, sup, added={1})),
      [("dead_code", "fail")])
check("suppression on an unchanged line: no entry", keys(r2_file(R, TG, "src/lib.rs", "src/lib.rs", sup, sup)), [])

skip = "#[mutants::skip]\n" + PROD
check("mutation skip added in prod: needs-human", [(e["_key"], e["class"]) for e in
      r2_file(R, TG, "src/lib.rs", "src/lib.rs", PROD, skip, added={1})], [("mutation-skip", "needs-human")])
check("mutation skip in a test file: no entry",
      keys(r2_file(R, TG, "tests/a.rs", "tests/a.rs", A, "#[mutants::skip]\n" + A, added={1})), [])

PY_OK = "def test_a():\n    assert 1 == 1\n"
ents = r2_file(P, ["tests/**"], "tests/test_a.py", "tests/test_a.py", PY_OK, "def test_a(:\n")
check("head does not parse: one fail, no other rule runs", keys(ents), [("unparseable:head", "fail")])

sys.exit(1 if FAILS else 0)
PY
