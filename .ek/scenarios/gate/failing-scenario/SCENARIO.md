# gate/failing-scenario: misuse, red scenario

- story: As a user whose scenario fails, the gate keeps blocking, and a repo with no scenarios dir is not forced into taste-it.
- covers: #9 misuse scenario; gate blocks on FAIL
- steps: installed kit, scenario exits 1, edit file, run runner (FAIL), Stop hook.
- expected: block "last run FAIL". Separately, a plain repo (no .ek/scenarios) with an edit gets the old finish-report block, not "Scenarios not green".
