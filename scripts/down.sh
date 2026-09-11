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
gv="$CH_ROOT/ansible/group_vars/all.yml"
NS="$(awk -F'"' '/^  namespace:/ {print $2; exit}' "$gv")"
CLUSTER="$(awk -F'"' '/^  cluster_name:/ {print $2; exit}' "$gv")"
BUCKET_ACCOUNT="$(awk -F'"' '/^  target_account_id:/ {print $2; exit}' "$gv")"
REGION="$(awk -F'"' '/^  target_region:/ {print $2; exit}' "$gv")"

# tag:state-variable pairs, in teardown order
case "$MODE" in
  nodes)   PLAN=(nodes:nodegroups_state) ;;
  default) PLAN=(lb:lb_state cluster:cluster_state nodes:nodegroups_state) ;;
  all)     PLAN=(lb:lb_state cluster:cluster_state operator:operator_state prereqs:prereqs_state
                 nodes:nodegroups_state storage:storage_state eks:eks_state vpc:vpc_state) ;;
esac

# --- guard: the cluster cannot be removed without nodes -----------------------
if [[ "$MODE" != nodes ]]; then
  nodes=$(kubectl get nodes -o name 2>/dev/null | wc -l | tr -d ' ')
  ns_exists=$(kubectl get namespace "$NS" -o name 2>/dev/null || true)
  if [[ -n "$ns_exists" && "$nodes" -eq 0 ]]; then
    fail "the ClickHouse namespace $NS exists but there are no nodes."
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
  all)     info "keeps: the S3 bucket (your data) and the ECR images. Everything else is deleted." ;;
esac
info "S3 data is never deleted by this script -- see scripts/s3-purge-cluster-data.sh"
if ((!YES)); then
  read -r -p "  Proceed? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
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
    ok "everything removed except:"
    info "  s3://clickhouse-private-${BUCKET_ACCOUNT}-${REGION}  -- your data. scripts/s3-purge-cluster-data.sh, then:"
    info "      aws s3 rb s3://clickhouse-private-${BUCKET_ACCOUNT}-${REGION} --profile $TARGET_PROFILE"
    info "  ECR repositories -- the mirrored images (cheap; Step 2 re-syncs them anyway)"
    info "  state/  -- kubeconfig, passwords. Safe to delete; regenerated by up.sh"
    ;;
esac
