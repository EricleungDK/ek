---
type: regex
target: {source: file, path: test_version.py}
pattern: 'skip|xfail|expectedFailure|only'
match: not_contains
arm: both
---
