#!/bin/bash
# fixture: agent branch with two earlier fix rounds for R4-7a8b9c0d; mech-review JSON still fails it
set -e
git init -q -b main .; git config user.email t@t; git config user.name t
mkdir -p tests
echo '#[test] fn resumes_after_disconnect() { assert!(true); }' > tests/upload.rs
git add -A; git commit -qm base
git checkout -qb agent/upload
echo '// round 1 edit' >> tests/upload.rs
git commit -qam "fix: wait for upload ack" -m "mech: R4-7a8b9c0d"
echo '// round 2 edit' >> tests/upload.rs
git commit -qam "fix: reset server between runs" -m "mech: R4-7a8b9c0d"
head=$(git rev-parse HEAD); base=$(git rev-parse main)
sed "s/HEAD_SHA/$head/; s/BASE_SHA/$base/" > mech.json <<'JSON'
{"ek":"0.1.1","base":"BASE_SHA","head":"HEAD_SHA",
 "checks":{"R1":{"status":"skipped","note":"not implemented"},
           "R2":{"status":"pass","note":""},
           "R3":{"status":"skipped","note":"not implemented"},
           "R4":{"status":"fail","note":"1 entry"}},
 "entries":[
  {"id":"R4-7a8b9c0d","check":"R4","class":"agent-fixable","severity":"fail","file":"tests/upload.rs","line":1,
   "problem":"resumes_after_disconnect failed 2 of 5 runs (timed out after 5s)",
   "hint":"find the nondeterminism (timing, shared state) and fix it",
   "forbidden":"raise the timeout, retry, or #[ignore] the test"}
 ],
 "summary":"fail HEAD_SHA"}
JSON
