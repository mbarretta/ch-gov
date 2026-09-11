#!/usr/bin/env bash
#
# Open a clickhouse-client session against the cluster from your laptop.
#
#   scripts/ch-client.sh                       # interactive session
#   scripts/ch-client.sh -q "SELECT version()" # one query, any client flags
#
# Does what the tutorial's Step 11 does by hand: port-forward the first server
# pod's native port (9000) to localhost, connect with the admin user, and tear
# the forward down on exit. The password is read from state/ (written by the
# clickhouse_cluster role) and passed via the environment, not on argv.
#
# Needs `clickhouse-client` or `clickhouse` locally: brew install clickhouse
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

export KUBECONFIG="$CH_ROOT/state/kubeconfig"

# Read what the playbook decided, so this stays in step with group_vars.
gv="$CH_ROOT/ansible/group_vars/all.yml"
NS="$(awk -F'"' '/^  namespace:/ {print $2; exit}' "$gv")"
USER_="$(awk -F'"' '/^  admin_username:/ {print $2; exit}' "$gv")"
PW_FILE="$CH_ROOT/state/clickhouse-admin-password"
LOCAL_PORT="${CH_LOCAL_PORT:-19000}"

[[ -r "$PW_FILE" ]] || die "no password file at $PW_FILE -- run: scripts/play.sh --tags cluster"
if have clickhouse-client; then CLIENT=(clickhouse-client)
elif have clickhouse; then CLIENT=(clickhouse client)
else die "clickhouse-client not installed: brew install clickhouse"; fi

pod="$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=clickhouse-server \
         --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$pod" ]] || die "no Running server pod in $NS -- are the node groups up?"

kubectl port-forward -n "$NS" "pod/$pod" "$LOCAL_PORT:9000" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
# Wait for the forward to accept connections rather than sleeping a guess.
for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/"$LOCAL_PORT") 2>/dev/null && { exec 3>&- ; break; }
  sleep 0.1
done

info "forwarding localhost:$LOCAL_PORT -> $pod:9000 in $NS"
CLICKHOUSE_PASSWORD="$(<"$PW_FILE")" "${CLIENT[@]}" --host 127.0.0.1 --port "$LOCAL_PORT" --user "$USER_" "$@"
