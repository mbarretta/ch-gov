#!/usr/bin/env bash
#
# Bring the whole stack up, Steps 1-12, in order.
#
#   scripts/up.sh                 # everything
#   scripts/up.sh --skip-images   # skip the Step 2 image hop (already mirrored)
#   scripts/up.sh --from nodes    # start at a step: images|vpc|eks|nodes|storage|
#                                 #   prereqs|operator|cluster|preflight|verify|lb
#   scripts/up.sh --yes           # no confirmation prompt
#
# Every step is idempotent, so running the whole thing over an existing stack
# is safe and changes nothing that already matches. The playbook already
# encodes the order; this script adds the cost warning, the confirmation, and
# a summary of what to do next. Pair with scripts/down.sh, which reverses it.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

# Deployment order. Each entry is a playbook tag; deploy.yml runs them in
# this order when no tags are given, so the list here only serves --from.
STEPS=(images vpc eks nodes storage prereqs operator cluster preflight verify lb)

YES=0; SKIP_IMAGES=0; FROM=""
while (($#)); do
  case "$1" in
    --yes|-y)       YES=1 ;;
    --skip-images)  SKIP_IMAGES=1 ;;
    --from)         FROM="${2:-}"; shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac; shift
done

TAGS=("${STEPS[@]}")
if [[ -n "$FROM" ]]; then
  for i in "${!STEPS[@]}"; do [[ "${STEPS[$i]}" == "$FROM" ]] && { TAGS=("${STEPS[@]:$i}"); FROM=found; break; }; done
  [[ "$FROM" == found ]] || die "--from must be one of: ${STEPS[*]}"
fi
((SKIP_IMAGES)) && TAGS=("${TAGS[@]/images}")
TAGS=("${TAGS[@]}"); TAGS=($(printf '%s\n' "${TAGS[@]}" | grep -v '^$'))

gv="$CH_ROOT/ansible/group_vars/all.yml"
LB_TYPE="$(awk -F'"' '/^    type:/ {print $2; exit}' "$gv")"

step "Bringing up: ${TAGS[*]}"
info "compute starts at Step 5 (nodes): ~\$2.32/hr while up, ~\$0.15/hr with nodes down"
info "load balancer type from group_vars: ${LB_TYPE:-none}"
info "each step is idempotent; anything already in place is left alone"
if ((!YES)); then
  read -r -p "  Proceed? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

start=$(date +%s)
"$CH_ROOT/scripts/play.sh" --tags "$(IFS=,; echo "${TAGS[*]}")"
rc=$?
mins=$(( ($(date +%s) - start) / 60 ))

if ((rc == 0)); then
  step "Up in ${mins}m"
  ok "connect:  scripts/ch-client.sh            (port-forward from this machine)"
  [[ "${LB_TYPE:-none}" != none ]] && ok "          scripts/ch-client.sh --lb       (via the $LB_TYPE NLB, where its address is reachable)"
  info "meter:    ~\$2.32/hr. Stop it with scripts/down.sh (keeps VPC/EKS, ~\$0.15/hr) or scripts/down.sh --all"
else
  step "Failed (exit $rc)"
  info "fix the cause and re-run; every step picks up where it left off"
fi
exit $rc
