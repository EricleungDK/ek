# mech-review-doctor/broken-mutation-tool: a mutation tool that does not run is not "present"

- story: As a user whose mutation tool is installed but broken, doctor's trial says so, so R3 does not surprise me later.
- covers: A2 trial-runs the mutation tool and reports the verdict; a toolchain failure is a reported entry; A4 exit 1
- steps: Good caller, tests pass, mutation tool exits 1 on every call (`mutants --version` included). `doctor`.
- expected: exit 1, `trial.mutation_tool` not `present`, an entry names the mutation tool.
