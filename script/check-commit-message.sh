#!/usr/bin/env bash
set -euo pipefail

message_file=${1:-}
if [[ -z "$message_file" || ! -r "$message_file" ]]; then
  echo "Usage: $0 <commit-message-file>" >&2
  exit 2
fi

IFS= read -r subject < "$message_file" || true
pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9][a-z0-9-]*\))?(!)?: [^[:space:]].*$'

if [[ ! "$subject" =~ $pattern || "$subject" =~ [[:space:]]$ || ${#subject} -gt 72 ]]; then
  echo "Invalid commit subject: $subject" >&2
  echo "Expected: type(scope)!: concise description (up to 72 characters)." >&2
  echo "Allowed types: feat fix docs style refactor perf test build ci chore revert" >&2
  exit 1
fi
