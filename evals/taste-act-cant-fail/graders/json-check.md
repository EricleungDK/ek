---
type: regex
target: {source: file, path: .ek/scenarios/json-output/run.sh}
pattern: 'json\.load|json\.loads|jq |isinstance|\[\s*\]|list'
arm: both
---
