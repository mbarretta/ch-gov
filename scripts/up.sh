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

gv="$CH_ROOT/ansible/group_vars/all.yml"
# Langfuse (Steps 13-15) is optional and joins the list only when switched on.
# The langfuse: block is last in all.yml, so this scrape is block-scoped --
# match the block header first, then the key -- and the first-match scrapes
# below keep landing on the ClickHouse keys.
LF_ENABLED="$(awk '/^langfuse:/{f=1} f && /^  enabled:/ {print $2; exit}' "$gv")"
[[ "$LF_ENABLED" == true ]] && STEPS+=(lf-storage lf-db lf-app)

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

LB_TYPE="$(awk -F'"' '/^    type:/ {print $2; exit}' "$gv")"

step "Bringing up: ${TAGS[*]}"
info "compute starts at Step 5 (nodes): ~\$2.32/hr while up, ~\$0.15/hr with nodes down"
info "load balancer type from group_vars: ${LB_TYPE:-none}"
[[ "$LF_ENABLED" == true ]] && info "langfuse: enabled -- Steps 13-15 run after the load balancer (adds ~\$0.02/hr for its NLB)"
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
  if [[ "$LF_ENABLED" == true ]]; then
    # The address NEXTAUTH_URL was baked with, derived the way the langfuse
    # role derives it: langfuse.url if set, else the NLB hostname (port
    # appended unless 80), else the fixed 3000:3000 port-forward.
    lf_var() { awk -F'"' -v key="$1" '/^langfuse:/{f=1} f && index($0, key) == 1 {print $2; exit}' "$gv"; }
    LF_NS="$(lf_var '  namespace:')"; LF_RELEASE="$(lf_var '  release:')"; LF_URL="$(lf_var '  url:')"; LF_LB_TYPE="$(lf_var '    type:')"
    LF_LB_PORT="$(awk '/^langfuse:/{f=1} f && /^    port:/ {print $2; exit}' "$gv")"
    if [[ -n "$LF_URL" ]]; then
      ok "langfuse: $LF_URL   (langfuse.url from group_vars; login: state/langfuse-admin-password)"
    elif [[ "${LF_LB_TYPE:-none}" == none ]]; then
      ok "langfuse: kubectl port-forward -n $LF_NS svc/$LF_RELEASE-web 3000:3000, then http://localhost:3000"
    else
      host="$(KUBECONFIG="$CH_ROOT/state/kubeconfig" kubectl get service langfuse-lb -n "$LF_NS" \
                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
      if [[ -n "$host" ]]; then
        LF_URL="http://$host"; [[ "${LF_LB_PORT:-80}" != 80 ]] && LF_URL="$LF_URL:$LF_LB_PORT"
        ok "langfuse: $LF_URL   (via the $LF_LB_TYPE NLB; login: state/langfuse-admin-password)"
      else
        warn "langfuse: could not read the $LF_LB_TYPE NLB hostname; try: kubectl get service langfuse-lb -n $LF_NS"
      fi
    fi
    ok "          scripts/langfuse-smoke.sh       (posts a trace and reads it back from ClickHouse)"
  fi
  info "meter:    ~\$2.32/hr. Stop it with scripts/down.sh (keeps VPC/EKS, ~\$0.15/hr) or scripts/down.sh --all"
else
  step "Failed (exit $rc)"
  info "fix the cause and re-run; every step picks up where it left off"
fi
exit $rc
