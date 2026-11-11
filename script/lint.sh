#!/usr/bin/env bash
# Mechanical checks on the Swift sources, independent of the compiler version: no tabs, no trailing whitespace, no
# lines over 220 characters, no leftover merge-conflict markers. Run from anywhere; prints each problem and exits 1.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
MAX_LINE=220
status=0

files=$(git ls-files '*.swift')
[[ -n "$files" ]] || { echo "No Swift files found." >&2; exit 2; }

report() {
  if [[ -n "$2" ]]; then
    echo "$1:"
    echo "$2" | sed 's/^/  /'
    status=1
  fi
}

# shellcheck disable=SC2086
report "Tab characters" "$(grep -n "$(printf '\t')" $files | cut -c1-160)"
# shellcheck disable=SC2086
report "Trailing whitespace" "$(grep -nE '[[:space:]]+$' $files | cut -c1-160)"
# shellcheck disable=SC2086
report "Lines over $MAX_LINE characters" "$(awk -v max=$MAX_LINE 'length($0) > max { printf "%s:%d: %d characters\n", FILENAME, FNR, length($0) }' $files)"
# shellcheck disable=SC2086
report "Merge-conflict markers" "$(grep -nE '^(<<<<<<<|>>>>>>>) ' $files | cut -c1-160)"

[[ $status -eq 0 ]] && echo "Lint passed ($(echo "$files" | wc -l | tr -d ' ') Swift files)."
exit $status
