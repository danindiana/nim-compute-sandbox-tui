#!/usr/bin/env bash
# Smoke test: builds nothing; expects ./src/sandbox_tui. Pipes snippets through every language.
set -euo pipefail
cd "$(dirname "$0")/../src"
rm -rf .runs
out=$(printf 'print(6*7)\n.\n:lang js\nconsole.log(1+2)\n.\n:lang sql\ncreate table t(a);\ninsert into t values (5);\n.\nselect * from t;\n.\n:lang python\nimport socket\nsocket.create_connection(("1.1.1.1",53),1)\n.\n:timeout 1\nimport time\ntime.sleep(5)\n.\n:quit\n' | timeout 60 ./sandbox_tui)
echo "$out"
fail=0
check() { echo "$out" | grep -qF -- "$1" || { echo "MISSING: $1"; fail=1; }; }
check "42"
check "3"
check "network disabled in sandbox"
check "TIMED OUT after 1s"
echo "$out" | grep -qE '^5$' || { echo "MISSING: sql row 5"; fail=1; }
exit $fail
