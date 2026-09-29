#!/usr/bin/env bash
#
# Tear the stack down in the right order -- the reverse of up.sh, with the
# dependencies that are NOT simply the reverse handled for you.
#
#   scripts/down.sh                # stop the meter: load balancer, cluster, node groups
#   scripts/down.sh --nodes-only   # just the node groups (fastest; pods go Pending, NLB stays)
#   scripts/down.sh --all          # everything but the S3 bucket and the ECR images
#   scripts/down.sh --yes          # no confirmation prompt
#
# Why order matters here, and why it is not just up.sh backwards:
#
#   * The load balancer Service must go BEFORE the cluster or EKS. Deleting the
#     Service is what deletes the NLB and its security-group rules; delete the
#     EKS cluster first and the NLB is orphaned, still billing, and blocks the
#     VPC stack.
#   * The ClickHouse cluster must go WHILE THE NODES ARE UP. Its namespace
#     deletion relies on the operator (to unwind the CR's finalizers) and on
#     the EBS CSI controller (to release Keeper's volumes). With no nodes,
#     neither runs, the namespace hangs in Terminating and the EBS volumes
#     are orphaned.
#   * The prerequisites and storage teardowns read the EKS cluster and the
#     IRSA stack respectively, so they run before EKS goes; and prereqs
#     before storage.
#   * Langfuse (optional Steps 13-15) goes BEFORE ClickHouse. Its tables live
#     in the ClickHouse cluster and its PostgreSQL and Valkey volumes are EBS
#     PVCs, so removing it needs the operator and the EBS CSI driver alive --
#     i.e. the cluster and the nodes still up. Only what exists is torn down;
#     a ClickHouse-only stack runs none of these steps.
#   * Grafana (optional Steps 16-18) goes BEFORE ClickHouse too, for the same
#     NLB-before-EKS reason as Langfuse above. Unlike Langfuse it holds no
#     PVC-backed storage (no persistence, by design), so its namespace
#     deletion does not need the nodes-alive guard below -- it works even
#     with zero nodes. Only what exists is torn down, same as Langfuse.
#
# What each mode leaves behind and what it costs:
#   --nodes-only  VPC, EKS, IRSA, operator, StorageClass, cluster objects (Pending),
#                 Keeper EBS volumes, NLB.                 ~$0.15/hr + NLB ~$0.02/hr
#   (default)     VPC, EKS, IRSA, operator, StorageClass.  ~$0.15/hr
#   --all         S3 bucket (data!), ECR images.           ~$0 (S3/ECR storage only)
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

MODE=default; YES=0
while (($#)); do
  case "$1" in
    --all)        MODE=all ;;
    --nodes-only) MODE=nodes ;;
    --yes|-y)     YES=1 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac; shift
done

export KUBECONFIG="$CH_ROOT/state/kubeconfig"
NS="$(ch_var clickhouse.namespace)"
CLUSTER="$(ch_var clickhouse.cluster_name)"
REGION="$(ch_var aws.target_region)"
ENVIRONMENT_NAME="$(ch_var infrastructure.environment_name)"
# The three bucket names, exactly as the playbook resolves them (merged
# deploy-vars over group_vars, account and region already substituted).
CH_BUCKET="$(ch_var clickhouse.bucket_name)"
LF_BUCKET="$(ch_var langfuse.bucket_name)"
GF_BUCKET="$(ch_var grafana.bucket_name)"
# lf_var/gf_var (lib/common.sh) read the merged langfuse:/grafana: blocks.
LF_NAMESPACE="$(lf_var '  namespace:')"
LF_RELEASE="$(lf_var '  release:')"
GF_NAMESPACE="$(gf_var '  namespace:')"
GF_RELEASE="$(gf_var '  release:')"

# tag:state-variable pairs, in teardown order. lf-db (the Langfuse database
# and user inside ClickHouse) and gf-db (the Grafana ClickHouse user, Step
# 17) are deliberately NOT in the default plan: cluster_state=absent takes
# the whole cluster with it anyway, and keeping them out means "drop only
# Langfuse/Grafana's ClickHouse object, keep the cluster" stays an explicit
# `scripts/play.sh --tags lf-db -e langfuse_db_state=absent` (or gf-db /
# grafana_db_state).
case "$MODE" in
  nodes)   PLAN=(nodes:nodegroups_state) ;;
  default) PLAN=(lf-app:langfuse_state gf-app:grafana_state lb:lb_state cluster:cluster_state nodes:nodegroups_state) ;;
  all)     PLAN=(lf-app:langfuse_state lf-db:langfuse_db_state gf-app:grafana_state gf-db:grafana_db_state
                 lb:lb_state cluster:cluster_state
                 operator:operator_state prereqs:prereqs_state lf-storage:langfuse_storage_state gf-storage:grafana_storage_state
                 nodes:nodegroups_state storage:storage_state eks:eks_state vpc:vpc_state) ;;
esac

# --- Langfuse: keep only the lf-* steps whose object actually exists ----------
# deploy.yml runs a Langfuse teardown whenever its *_state is absent, whether
# or not langfuse.enabled is still true -- so Langfuse gets removed even after
# the switch went back to false. The other side of that: on a ClickHouse-only
# stack the roles would fail on missing preconditions and the loop's `die`
# would stop the run. So each lf-* entry stays only if there is something to
# remove. lf-app checks all three of release, NLB Service and namespace, so a
# run that died between creating the NLB and installing the chart still gets
# cleaned up.
lf_app_exists() {
  helm status -n "$LF_NAMESPACE" "$LF_RELEASE" >/dev/null 2>&1 \
    || kubectl get service langfuse-lb -n "$LF_NAMESPACE" >/dev/null 2>&1 \
    || kubectl get namespace "$LF_NAMESPACE" >/dev/null 2>&1
}
lf_storage_exists() {
  aws cloudformation describe-stacks --stack-name "${ENVIRONMENT_NAME}-langfuse-irsa" \
    --profile "$TARGET_PROFILE" --region "$REGION" >/dev/null 2>&1
}

# --- Grafana: keep only the gf-* steps whose object actually exists ----------
# Same reasoning as Langfuse above: deploy.yml tears Grafana down whenever
# its *_state is absent, whether or not grafana.enabled is still true, so a
# previously-deployed-then-disabled Grafana still gets removed. gf-app checks
# all three of release, NLB Service and namespace, so a run that died between
# creating the NLB and installing the chart still gets cleaned up.
gf_app_exists() {
  helm status -n "$GF_NAMESPACE" "$GF_RELEASE" >/dev/null 2>&1 \
    || kubectl get service grafana-lb -n "$GF_NAMESPACE" >/dev/null 2>&1 \
    || kubectl get namespace "$GF_NAMESPACE" >/dev/null 2>&1
}
gf_storage_exists() {
  aws cloudformation describe-stacks --stack-name "${ENVIRONMENT_NAME}-grafana-irsa" \
    --profile "$TARGET_PROFILE" --region "$REGION" >/dev/null 2>&1
}
LF_STORAGE=0; GF_STORAGE=0
kept=()
for entry in "${PLAN[@]}"; do
  case "${entry%%:*}" in
    lf-app)     lf_app_exists || continue ;;
    lf-db)      kubectl get namespace "$LF_NAMESPACE" >/dev/null 2>&1 || continue ;;
    lf-storage) lf_storage_exists || continue; LF_STORAGE=1 ;;
    gf-app)     gf_app_exists || continue ;;
    gf-db)      kubectl get namespace "$GF_NAMESPACE" >/dev/null 2>&1 || continue ;;
    gf-storage) gf_storage_exists || continue; GF_STORAGE=1 ;;
  esac
  kept+=("$entry")
done
PLAN=("${kept[@]}")   # never empty: nodes is in every plan and is never dropped

# --- guard: the cluster cannot be removed without nodes -----------------------
# Both namespaces hold PVC-backed pods (Keeper; Langfuse's PostgreSQL and
# Valkey), so either would hang in Terminating with the CSI controller gone.
if [[ "$MODE" != nodes ]]; then
  # `|| die`: under set -eo pipefail a failing kubectl used to abort the script
  # right here with no output at all. Say what usually broke instead.
  nodes=$(kubectl get nodes -o name 2>/dev/null | wc -l | tr -d ' ') \
    || die "kubectl cannot reach the cluster -- no kubeconfig at state/kubeconfig (scripts/up.sh writes it)," \
           "expired AWS credentials ($(ch_login_hint))," \
           "or the EKS cluster is gone"
  ns_exists=$(kubectl get namespace "$NS" -o name 2>/dev/null || true)
  lf_ns_exists=$(kubectl get namespace "$LF_NAMESPACE" -o name 2>/dev/null || true)
  if [[ ( -n "$ns_exists" || -n "$lf_ns_exists" ) && "$nodes" -eq 0 ]]; then
    if [[ -n "$ns_exists" && -n "$lf_ns_exists" ]]; then
      fail "the ClickHouse namespace $NS and the Langfuse namespace $LF_NAMESPACE exist but there are no nodes."
    elif [[ -n "$ns_exists" ]]; then
      fail "the ClickHouse namespace $NS exists but there are no nodes."
    else
      fail "the Langfuse namespace $LF_NAMESPACE exists but there are no nodes."
    fi
    info "removing it now would hang: the operator and the EBS CSI controller are not running."
    info "either bring the nodes back first (scripts/up.sh --from nodes --yes, ~10 min) and re-run this,"
    info "or use --nodes-only, which is already the state you are in."
    exit 1
  fi
fi

step "Tearing down ($MODE): $(printf '%s ' "${PLAN[@]%%:*}")"
case "$MODE" in
  nodes)   info "keeps: everything else. Pods go Pending; NLB and Keeper volumes stay. ~\$0.17/hr" ;;
  default) info "keeps: VPC, EKS control plane, IRSA, operator, StorageClass. ~\$0.15/hr" ;;
  all)     info "keeps: the S3 bucket$( ((LF_STORAGE)) && echo s) (your data) and the ECR images. Everything else is deleted." ;;
esac
info "S3 data is never deleted by this script -- see scripts/s3-purge-cluster-data.sh"
if ((!YES)); then
  # `|| ans=n`: with stdin at EOF (a wrapper or CI calling without --yes) read
  # returns 1 and set -e used to exit here with no output. Treat EOF as "n".
  read -r -p "  Proceed? [y/N] " ans || ans=n
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

start=$(date +%s)
for entry in "${PLAN[@]}"; do
  tag="${entry%%:*}"; var="${entry##*:}"
  step "down: $tag"
  # One playbook run per step: each role ends the play after its teardown
  # task, so they cannot be combined into one --tags list.
  "$CH_ROOT/scripts/play.sh" --tags "$tag" -e "$var=absent" || die "teardown of '$tag' failed; fix and re-run (steps already removed are skipped)"
done
mins=$(( ($(date +%s) - start) / 60 ))

step "Down in ${mins}m"
case "$MODE" in
  nodes)   ok "node groups removed. Bring them back: scripts/up.sh --from nodes" ;;
  default) ok "load balancer, cluster and node groups removed. Rebuild: scripts/up.sh --from nodes (~15 min)" ;;
  all)
    # The Grafana bucket holds one re-downloadable plugin zip, so the
    # grafana_storage teardown deletes it with its stack; report it as gone.
    ((GF_STORAGE)) && ok "deleted: s3://${GF_BUCKET}  -- Grafana's plugin mirror (removed with its storage stack)"
    ok "everything removed except:"
    info "  s3://${CH_BUCKET}  -- your data. scripts/s3-purge-cluster-data.sh, then:"
    info "      aws s3 rb s3://${CH_BUCKET} --profile $TARGET_PROFILE"
    ((LF_STORAGE)) && info "  s3://${LF_BUCKET}  -- Langfuse's events, exports and media. Empty it, then aws s3 rb it the same way"
    info "  ECR repositories -- the mirrored images (cheap; Step 2 re-syncs them anyway)"
    info "  state/  -- kubeconfig, passwords. Safe to delete; regenerated by up.sh"
    ;;
esac
