#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

UDID="${UDID:-}"
ITERATIONS="${ITERATIONS:-10}"
SIM_USE_PATH="${SIM_USE_PATH:-.build/debug/sim-use}"
WRAPPER_PATH="${WRAPPER_PATH:-Examples/SimUseMacOSClient/.build/debug/SimUseMacOSClient}"

usage() {
  cat <<EOF
Usage: $0 --udid <booted-simulator-udid> [options]

Compare the same describe-ui operation through:
  1. CLI + existing daemon
  2. CLI + in-process backend
  3. SimUseKit macOS wrapper

Options:
  --iterations N       Number of calls per measurement (default: ${ITERATIONS})
  --sim-use-path PATH  sim-use executable (default: ${SIM_USE_PATH})
  --wrapper-path PATH  macOS sample executable (default: ${WRAPPER_PATH})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --sim-use-path) SIM_USE_PATH="$2"; shift 2 ;;
    --wrapper-path) WRAPPER_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$UDID" ]]; then
  echo "Missing required --udid" >&2
  usage
  exit 1
fi
if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--iterations must be a positive integer" >&2
  exit 1
fi
for executable in "$SIM_USE_PATH" "$WRAPPER_PATH"; do
  if [[ ! -x "$executable" ]]; then
    echo "Executable not found or not executable: $executable" >&2
    exit 1
  fi
done

measure() {
  local label="$1"
  shift
  python3 - "$label" "$ITERATIONS" "$@" <<'PY'
import subprocess
import sys
import time

label = sys.argv[1]
iterations = int(sys.argv[2])
command = sys.argv[3:]
start = time.perf_counter()
for _ in range(iterations):
    subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
elapsed = time.perf_counter() - start
print(f"{label}: total={elapsed:.4f}s per_call={elapsed / iterations * 1000:.2f}ms")
PY
}

measure daemon "$SIM_USE_PATH" describe-ui --device "$UDID"
measure in_process env SIM_USE_NO_DAEMON=1 "$SIM_USE_PATH" describe-ui --device "$UDID"
measure swift_wrapper "$WRAPPER_PATH" "$UDID" --describe-only
