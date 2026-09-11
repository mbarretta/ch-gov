#!/usr/bin/env bash
# Shared helpers for the ClickHouse Private on EKS setup scripts.
# Source this, don't execute it:   source "$(dirname "$0")/lib/common.sh"

# Homebrew's bin must be on PATH even under non-login shells (cron, CI, agents).
[[ ":$PATH:" == *":/opt/homebrew/bin:"* ]] || export PATH="/opt/homebrew/bin:$PATH"
# krew installs kubectl plugins (we use `kubectl preflight`, Step 10) under
# ~/.krew/bin, which nothing adds to PATH for you.
[[ ":$PATH:" == *":$HOME/.krew/bin:"* ]] || export PATH="$HOME/.krew/bin:$PATH"

# This project keeps its AWS config in-repo rather than in ~/.aws, so the whole
# setup is portable. Point the CLI at it unless the caller already chose a file.
CH_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -z "${AWS_CONFIG_FILE:-}" && -f "$CH_PROJECT_ROOT/.aws/config" ]]; then
  export AWS_CONFIG_FILE="$CH_PROJECT_ROOT/.aws/config"
fi

# ---- output helpers -------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLU" "$*" "$C_RESET"; }
ok()    { printf '  %s[ ok ]%s %s\n'   "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '  %s[warn]%s %s\n'   "$C_YEL" "$C_RESET" "$*"; }
fail()  { printf '  %s[fail]%s %s\n'   "$C_RED" "$C_RESET" "$*"; }
info()  { printf '  %s%s%s\n'          "$C_DIM" "$*" "$C_RESET"; }
die()   { fail "$*"; exit 1; }

# Tracks non-fatal problems so the script can exit non-zero at the very end
# instead of stopping at the first issue -- you want the whole report.
PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# ---- python floor ---------------------------------------------------------
# 3.12 is the floor, and it is not an arbitrary choice: ansible-core 2.21
# declares Requires-Python >=3.12, so anything older cannot run the playbook at
# all. It also happens to be the oldest line with real life left -- 3.9 went EOL
# in Oct 2025 and 3.10 goes EOL in Oct 2026, while 3.12 is supported to Oct 2028.
readonly PY_MIN_MAJOR=3
readonly PY_MIN_MINOR=12
readonly PY_MIN="${PY_MIN_MAJOR}.${PY_MIN_MINOR}"

# Succeeds if the given interpreter (default: python3 on PATH) is >= PY_MIN.
py_at_least() {
  "${1:-python3}" -c \
    "import sys; sys.exit(0 if sys.version_info[:2] >= ($PY_MIN_MAJOR, $PY_MIN_MINOR) else 1)" \
    2>/dev/null
}

# Prints e.g. 3.14.7, or nothing if the interpreter is missing/unrunnable.
py_version() { "${1:-python3}" -c 'import platform; print(platform.python_version())' 2>/dev/null; }

# ---- constants (from the ClickHouse Private training guide) ---------------
# Where ClickHouse publishes its images. You never deploy into this account;
# you only read from it, then copy images into your own ECR.
readonly SOURCE_ECR_ACCOUNT="<SOURCE_ECR_ACCOUNT_ID>"
readonly SOURCE_ECR_REGION="us-east-1"
readonly SOURCE_ECR_PROFILE="private-us"

# Your account, where everything actually gets built.
readonly TARGET_PROFILE="sa"

# The three images that make up a ClickHouse Private deployment.
readonly CH_REPOS=(clickhouse-server clickhouse-keeper clickhouse-operator)
