# taste-it/model: Claude discovers the installed skill

- story: As a user, with ek installed in my repo, Claude knows to use taste-it when asked how to verify a deliverable as a user.
- covers: #9 taste-it skill (model behaviour, smoke)
- steps: reuse parent install; `claude -p` (30-90s, uses account quota) asking which skill verifies a deliverable via black-box user scenarios.
- expected: reply names `taste-it`. Missing or unauthenticated `claude` FAILS with a reason (never a silent pass).
