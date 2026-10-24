#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp "${TMPDIR:-/tmp}/runbar-process.XXXXXX")"
trap 'rm -f "$BIN"' EXIT
cc -std=c11 -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  -I Sources/RunbarProcess/include Sources/RunbarProcess/process.c scripts/process-tests.c -o "$BIN"
"$BIN"
