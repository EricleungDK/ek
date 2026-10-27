---
type: regex
target: {source: file, path: test_version.py}
pattern: 'parse_version\("1\.2"\), \(1, 2, 0\)\)'
match: contains
arm: both
---
