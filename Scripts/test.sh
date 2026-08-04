#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"
swift test "$@"
