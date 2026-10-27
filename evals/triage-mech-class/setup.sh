#!/bin/bash
# fixture: PR branch at HEAD + mech-review JSON with one entry per class path
set -e
git init -q -b main .; git config user.email t@t; git config user.name t
mkdir -p src tests .github/workflows
echo 'pub fn add(a: i32, b: i32) -> i32 { a + b }' > src/lib.rs
echo '#[test] fn adds() { assert_eq!(add(1, 1), 2); }' > tests/a.rs
echo 'name: mech-review' > .github/workflows/mech-review.yml
git add -A; git commit -qm base
git checkout -qb agent/upload
echo 'pub fn up() -> u8 { 1 }' >> src/lib.rs
echo '#[allow(dead_code)] fn unused() {}' > src/net.rs
echo '#[test] fn resumes_after_disconnect() { assert!(true); }' > tests/upload.rs
git add -A; git commit -qm "feat: upload"
head=$(git rev-parse HEAD); base=$(git rev-parse HEAD~1)
sed "s/HEAD_SHA/$head/; s/BASE_SHA/$base/" > mech.json <<'JSON'
{"ek":"0.1.1","base":"BASE_SHA","head":"HEAD_SHA",
 "checks":{"R1":{"status":"skipped","note":"not implemented"},
           "R2":{"status":"fail","note":"3 entries"},
           "R3":{"status":"skipped","note":"not implemented"},
           "R4":{"status":"fail","note":"1 entry"}},
 "entries":[
  {"id":"CI-9e8d7c6b","check":"CI","class":"env","severity":"fail","file":"","line":0,
   "problem":"bubblewrap (bwrap) not installed on runner; tests cannot sandbox",
   "hint":"install bubblewrap in the caller workflow setup step",
   "forbidden":"mark the tests skipped or run them unsandboxed in code"},
  {"id":"R2-2b3c4d5e","check":"R2","class":"agent-fixable","severity":"fail","file":"src/net.rs","line":1,
   "problem":"#[allow(dead_code)] without reason",
   "hint":"remove the allow, or add reason = \"...\" if it must stay",
   "forbidden":"add an allow with no reason"},
  {"id":"R4-7a8b9c0d","check":"R4","class":"agent-fixable","severity":"fail","file":"tests/upload.rs","line":1,
   "problem":"resumes_after_disconnect failed 2 of 5 runs (timed out after 5s)",
   "hint":"find the nondeterminism (timing, shared state) and fix it",
   "forbidden":"raise the timeout, retry, or #[ignore] the test"},
  {"id":"R2-c0ffee12","check":"R2","class":"needs-human","severity":"fail","file":".github/workflows/mech-review.yml","line":1,
   "problem":"edit to protected path .github/workflows/mech-review.yml",
   "hint":"stop; a human decides",
   "forbidden":"edit the gate to pass"},
  {"id":"R2-deadbeef","check":"R2","class":"agent-fixable","severity":"confirm","file":"tests/a.rs","line":1,
   "problem":"expected value changed in assert_eq! of adds (old 3, new 2)",
   "hint":"the spec sets the value; check it",
   "forbidden":"change the expectation to match the output"}
 ],
 "summary":"fail HEAD_SHA"}
JSON
git add -A; git commit -qm "chore: mech fixture"
