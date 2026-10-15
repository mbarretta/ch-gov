#!/usr/bin/env bash
#
# Bring the whole stack up, Steps 1-12, in order.
#
#   scripts/up.sh                 # everything
#   scripts/up.sh --skip-images   # skip the Step 2 image hop (already mirrored)
#   scripts/up.sh --from nodes    # start at a step: images|vpc|eks|nodes|storage|
#                                 #   prereqs|operator|cluster|preflight|verify|lb
#                                 #   (plus sso-idp after storage and ch-jwt after
#                                 #   verify when single sign-on is switched on,
#                                 #   and second-service after verify and second-lb
#                                 #   after lb when the second service is)
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

# Resolve the configuration once here; the $(...) lookups below run in
# subshells that inherit the cached result instead of each re-running Ansible.
ch_resolve || exit 1

# Deployment order. Each entry is a playbook tag; deploy.yml runs them in
# this order when no tags are given, so the list here only serves --from.
#
# Single sign-on (Steps 6b and 11b) is optional and splices into the list at
# the two places deploy.yml runs it: the Cognito stack (sso-idp) right after
# storage, so it exists before the cluster step reads its issuer, and the
# ClickHouse roles for token logins (ch-jwt) right after verify, once the
# cluster answers. sso_enabled/sso_jwt_enabled (lib/common.sh) read the merged
# sso: block, so a config/deploy-vars.yml override counts. --from slices this
# same list, so it keeps the order.
#
# The second service (clickhouse.second_service) splices in the same way, at
# the two places deploy.yml runs it: second-service right after verify, once
# the parent it attaches to has passed its checks, and its own load balancer
# (second-lb) right after the main one.
SSO_ENABLED=false; SSO_JWT=false; SECOND_ENABLED=false
sso_enabled && SSO_ENABLED=true
sso_jwt_enabled && SSO_JWT=true
[[ "$(ch_var clickhouse.second_service.enabled)" == true ]] && SECOND_ENABLED=true
STEPS=(images vpc eks nodes storage)
[[ "$SSO_ENABLED" == true ]] && STEPS+=(sso-idp)
STEPS+=(prereqs operator cluster preflight verify)
[[ "$SECOND_ENABLED" == true ]] && STEPS+=(second-service)
[[ "$SSO_JWT" == true ]] && STEPS+=(ch-jwt)
STEPS+=(lb)
[[ "$SECOND_ENABLED" == true ]] && STEPS+=(second-lb)

# Langfuse (Steps 13-15) is optional and joins the list only when switched on.
# lf_var (lib/common.sh) reads the merged langfuse: block, so a deploy-vars
# override of langfuse.enabled counts.
LF_ENABLED="$(lf_var '  enabled:')"
[[ "$LF_ENABLED" == true ]] && STEPS+=(lf-storage lf-db lf-app)

# Grafana (Steps 16-18) is optional and joins the list only when switched on,
# after Langfuse's own three -- so a run with both on reaches the blanket
# ClickHouse grant only once Langfuse's data already exists. gf_var
# (lib/common.sh) reads the merged grafana: block, same as lf_var above.
GF_ENABLED="$(gf_var '  enabled:')"
[[ "$GF_ENABLED" == true ]] && STEPS+=(gf-storage gf-db gf-app)

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

LB_TYPE="$(ch_var clickhouse.load_balancer.type)"
SECOND_LB_TYPE="$(ch_var clickhouse.second_service.load_balancer.type)"
# The all-in hourly figure follows the configured size and fips, so it agrees
# with the cost table in docs/part-2-image-sync.md for that profile.
SIZE="$(ch_var size)"
HOURLY="$(ch_hourly_cost)"

step "Bringing up: ${TAGS[*]}"
info "compute starts at Step 5 (nodes): ~\$${HOURLY}/hr while up (size: $SIZE), ~\$0.15/hr with nodes down"
info "load balancer type (clickhouse.load_balancer.type): ${LB_TYPE:-none}"
[[ "$LF_ENABLED" == true ]] && info "langfuse: enabled -- Steps 13-15 run after the load balancer (adds ~\$0.02/hr for its NLB)"
[[ "$SSO_ENABLED" == true ]] && info "sso: enabled -- Step 6b (Cognito) runs after storage$([[ "$SSO_JWT" == true ]] && echo ', Step 11b (ClickHouse token roles) after verify')"
[[ "$GF_ENABLED" == true ]] && info "grafana: enabled -- Steps 16-18 run after Langfuse (adds ~\$0.02/hr for its NLB)"
if [[ "$SECOND_ENABLED" == true ]]; then
  if [[ "${SECOND_LB_TYPE:-none}" != none ]]; then
    info "second service: enabled -- runs after verify on its own node group, its own $SECOND_LB_TYPE load balancer after the main one; both are in the hourly figure above"
  else
    info "second service: enabled -- runs after verify on its own node group, with no load balancer of its own (type none); its nodes are in the hourly figure above"
  fi
fi
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
  [[ "$SSO_JWT" == true ]] && ok "          scripts/ch-client.sh --sso      (sign in as yourself with Cognito)"
  if [[ "$SECOND_ENABLED" == true ]]; then
    ok "          scripts/ch-client.sh --second   (the second service: same data, refuses inserts and mutations)"
    [[ "${SECOND_LB_TYPE:-none}" != none ]] && ok "          scripts/ch-client.sh --second --lb  (via its own $SECOND_LB_TYPE NLB)"
  fi
  [[ "$SSO_ENABLED" == true ]] && ok "sso:      scripts/sso-smoke.sh            (checks the Cognito issuer, Langfuse sign-in and a ClickHouse token login)"
  if [[ "$LF_ENABLED" == true ]]; then
    # The address NEXTAUTH_URL was baked with: langfuse.url if set, else the
    # NLB hostname via lf_url (https with the port appended unless it is 443
    # when tls is true; otherwise http with the port appended unless it is 80;
    # the same rule the langfuse role uses), else the fixed 3000:3000
    # port-forward.
    LF_NS="$(lf_var '  namespace:')"; LF_RELEASE="$(lf_var '  release:')"; LF_URL="$(lf_var '  url:')"; LF_LB_TYPE="$(lf_var '    type:')"
    if [[ -n "$LF_URL" ]]; then
      ok "langfuse: $LF_URL   (langfuse.url from group_vars; login: state/langfuse-admin-password)"
    elif [[ "${LF_LB_TYPE:-none}" == none ]]; then
      ok "langfuse: kubectl port-forward -n $LF_NS svc/$LF_RELEASE-web 3000:3000, then http://localhost:3000"
    elif LF_URL="$(lf_url)"; then
      ok "langfuse: $LF_URL   (via the $LF_LB_TYPE NLB; login: state/langfuse-admin-password)"
    else
      warn "langfuse: could not read the $LF_LB_TYPE NLB hostname; try: kubectl get service langfuse-lb -n $LF_NS"
    fi
    ok "          scripts/langfuse-smoke.sh       (posts a trace and reads it back from ClickHouse)"
  fi
  if [[ "$GF_ENABLED" == true ]]; then
    # Same rule gf_url and the grafana role's GF_SERVER_ROOT_URL agree on:
    # grafana.url if set; else the grafana-lb NLB hostname via gf_url
    # (https with the port appended unless it is 443 when gf_tls; otherwise
    # http with the port appended unless it is 80); else the fixed
    # 3000:3000 port-forward for load_balancer.type: none.
    GF_NS="$(gf_var '  namespace:')"; GF_RELEASE="$(gf_var '  release:')"; GF_URL="$(gf_var '  url:')"; GF_LB_TYPE="$(gf_var '    type:')"
    if [[ -n "$GF_URL" ]]; then
      ok "grafana:  $GF_URL   (grafana.url from group_vars; login: admin / state/grafana-admin-password)"
    elif [[ "${GF_LB_TYPE:-none}" == none ]]; then
      ok "grafana:  kubectl port-forward -n $GF_NS svc/$GF_RELEASE 3000:3000, then http://localhost:3000"
    elif GF_URL="$(gf_url)"; then
      ok "grafana:  $GF_URL   (via the $GF_LB_TYPE NLB; login: admin / state/grafana-admin-password)"
    else
      warn "grafana:  could not read the $GF_LB_TYPE NLB hostname; try: kubectl get service grafana-lb -n $GF_NS"
    fi
    ok "          scripts/grafana-smoke.sh        (checks the ClickHouse datasource health and a live query)"
  fi
  info "meter:    ~\$${HOURLY}/hr (size: $SIZE). Stop it with scripts/down.sh (keeps VPC/EKS, ~\$0.15/hr) or scripts/down.sh --all"
else
  step "Failed (exit $rc)"
  info "fix the cause and re-run; every step picks up where it left off"
fi
exit $rc
