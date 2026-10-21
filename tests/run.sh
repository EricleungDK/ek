#!/bin/bash
# Run all tests/*.test.sh; exit 1 if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for f in *.test.sh; do
  echo "$f"
  bash "$f" || rc=1
done
[[ $rc == 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $rc
