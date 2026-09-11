#!/usr/bin/env bash
#
# Run the deployment playbook with this project's environment already set up.
#
#   scripts/play.sh --tags nodes                        # a step
#   scripts/play.sh --tags nodes -e nodegroups_state=absent
#   scripts/play.sh --check --tags storage              # dry run
#   scripts/play.sh other.yml --tags foo                # a different playbook
#
# Equivalent to `source scripts/env.sh && cd ansible && ansible-playbook
# deploy.yml ...`, minus three things that are easy to get wrong:
#
#   1. AWS_CONFIG_FILE / KUBECONFIG must point into the repo, not ~/.aws and
#      ~/.kube. Forget them and you either get "profile could not be found"
#      or, worse, act on whatever cluster your personal kubeconfig names.
#   2. ansible-playbook has to run from ansible/, because ansible.cfg (and
#      therefore the inventory and roles_path) is resolved from the cwd.
#   3. Ansible refuses to start if stdin/stdout/stderr are non-blocking:
#         ERROR: Ansible requires blocking IO on stdin/stdout/stderr.
#      Some parent processes -- CI runners, editor terminals, agent harnesses
#      -- hand over non-blocking pipes. See the fix below.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

export AWS_CONFIG_FILE="$CH_ROOT/.aws/config"     # common.sh sets this too; explicit here
export AWS_PROFILE="${AWS_PROFILE:-$TARGET_PROFILE}"
export KUBECONFIG="$CH_ROOT/state/kubeconfig"

# --- credentials -----------------------------------------------------------
# SSO tokens last hours, not days. Without this check an expired token surfaces
# partway into a run as an unrelated-looking module failure, sometimes after
# something has already been created.
if ! aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1; then
  die "not authenticated -- run: AWS_CONFIG_FILE=$AWS_CONFIG_FILE aws sso login --profile $AWS_PROFILE"
fi

# --- playbook selection ----------------------------------------------------
# Accept an explicit playbook as the first argument; otherwise assume
# deploy.yml, since that is the only one so far.
PLAYBOOK="deploy.yml"
if [[ $# -gt 0 && "$1" != -* && ( "$1" == *.yml || "$1" == *.yaml ) ]]; then
  PLAYBOOK="$1"; shift
fi

cd "$CH_ROOT/ansible"
[[ -f "$PLAYBOOK" ]] || die "no such playbook: ansible/$PLAYBOOK"

# --- blocking IO -----------------------------------------------------------
# Clear O_NONBLOCK on the three standard descriptors and then exec, rather
# than piping through `cat`. Piping would also satisfy Ansible, but it costs
# the TTY -- and with it coloured output and correct terminal width. This
# fixes the actual flag and leaves the terminal attached.
#
# Falls back to the pipe if no Python is available.
PY="$CH_ROOT/.venv/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3 || true)"

if [[ -n "$PY" ]]; then
  exec "$PY" -c '
import fcntl, os, sys
for fd in (0, 1, 2):
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        if flags & os.O_NONBLOCK:
            fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except OSError:
        pass          # closed or not a real file; ansible will say so
os.execvp(sys.argv[1], sys.argv[1:])
' ansible-playbook "$PLAYBOOK" "$@"
else
  warn "no python3 found; falling back to a pipe (output will not be coloured)"
  ansible-playbook "$PLAYBOOK" "$@" </dev/null 2>&1 | cat
  exit "${PIPESTATUS[0]}"
fi
