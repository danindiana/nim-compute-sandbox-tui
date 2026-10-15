#!/usr/bin/env bash
# Re-render every diagram (.dot -> .png @160dpi + .svg)
set -euo pipefail
cd "$(dirname "$0")/diagrams"
for f in *.dot; do b="${f%.dot}"; dot -Tpng -Gdpi=160 "$f" -o "$b.png"; dot -Tsvg "$f" -o "$b.svg"; done
echo "rendered $(ls *.dot | wc -l) diagrams"
