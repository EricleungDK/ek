# gate/stale-after-edit: misuse, edit after PASS

- story: As a user I pass scenarios, then keep editing; the gate blocks again until I re-run.
- covers: #9 misuse scenario; gate rejects a stale PASS
- steps: reuse parent flow: installed kit, fresh PASS, then edit a file; Stop hook; re-run; Stop hook.
- expected: block mentioning "stale" after the edit; allow after re-run.
