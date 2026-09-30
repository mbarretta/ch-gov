#!/usr/bin/env bash
#
# Open a clickhouse-client session against the cluster from your laptop.
#
#   scripts/ch-client.sh                       # interactive session
#   scripts/ch-client.sh -q "SELECT version()" # one query, any client flags
#   scripts/ch-client.sh --lb [-q ...]         # via the Step 12 load balancer
#   scripts/ch-client.sh --sso [--lb] [-q ...] # sign in as yourself with Cognito
#
# Default: does what the tutorial's Step 11 does by hand -- port-forward the
# first server pod's native port to localhost, connect with the admin user,
# and tear the forward down on exit. With --lb it connects straight to the
# NLB hostname instead (no port-forward), which works from anywhere the
# NLB's address is reachable: the internet for type `public`, the VPC or a
# VPN/peering into it for `internal`. The password is read from state/
# (written by the clickhouse_cluster role) and passed via the environment,
# not on argv.
#
# --sso (needs sso.enabled and sso.clickhouse_jwt.enabled) replaces the admin
# password with your own Cognito identity: it opens the Cognito hosted UI in
# your browser, catches the redirect on http://localhost:8765/callback, and
# connects with `clickhouse-client --jwt` and the ID token that comes back (only
# ID tokens carry the aud claim ClickHouse checks). Which tables you can reach
# follows your Cognito groups. The token is held in memory and never written to
# disk; it does appear on the client's command line for the life of the session.
# CH_JWT=<id token> reuses a token you already have instead of signing in again.
# CH_SSO_NO_BROWSER=1 prints the sign-in URL without opening a browser.
#
# fips: true moves both paths to the native TLS port (9440) with --secure
# and a CA-verified connection against the CA clickhouse_cluster generated
# (see scripts/lib/common.sh's ch_tls_client_config) -- 9000 has no listener
# left once server.openSSL.required zeroes the plaintext ports.
#
# Needs `clickhouse-client` or `clickhouse` locally: brew install clickhouse
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

export KUBECONFIG="$CH_ROOT/state/kubeconfig"

# Read what the playbook decided, so this stays in step with group_vars.
NS="$(ch_var clickhouse.namespace)"
USER_="$(ch_var clickhouse.admin_username)"
PW_FILE="$CH_ROOT/state/clickhouse-admin-password"
LOCAL_PORT="${CH_LOCAL_PORT:-19000}"

# Leading flags, in any order: --lb and --sso. Everything after them goes to
# the client unchanged.
LB=0; SSO=0
while (($#)); do
  case "$1" in
    --lb)  LB=1 ;;
    --sso) SSO=1 ;;
    *) break ;;
  esac; shift
done

if have clickhouse-client; then CLIENT=(clickhouse-client)
elif have clickhouse; then CLIENT=(clickhouse client)
else die "clickhouse-client not installed: brew install clickhouse"; fi

# Who we connect as. --sso signs in first, before any port-forward is opened,
# so the forward does not sit idle while the browser tab is open.
TOKEN=""
if ((SSO)); then
  sso_jwt_enabled || die "--sso needs sso.enabled and sso.clickhouse_jwt.enabled in state/deploy-vars.yml, then: scripts/play.sh --tags sso-idp,cluster,ch-jwt"
  TOKEN="${CH_JWT:-}"
  [[ -n "$TOKEN" ]] || TOKEN="$(sso_login_id_token)" || exit 1
else
  [[ -r "$PW_FILE" ]] || die "no password file at $PW_FILE -- run: scripts/play.sh --tags cluster"
fi

# Native port and TLS args, decided once and reused by both paths below.
# fips: true means server.openSSL.required has zeroed 9000's listener --
# 9440 is ClickHouse's own tcp_port_secure default.
CH_PORT=9000
SECURE_ARGS=()
if ch_fips_enabled; then
  CH_PORT=9440
  ch_tls_client_config
  SECURE_ARGS=(--secure --config-file "$CH_TLS_CLIENT_CFG")
fi

# connect HOST PORT [client args...]: the admin password travels in the
# environment, never on argv; an SSO token has no such channel and goes to
# --jwt.
connect() {
  local host="$1" port="$2"; shift 2
  if ((SSO)); then
    "${CLIENT[@]}" --host "$host" --port "$port" ${SECURE_ARGS[@]+"${SECURE_ARGS[@]}"} --jwt "$TOKEN" "$@"
  else
    CLICKHOUSE_PASSWORD="$(<"$PW_FILE")" "${CLIENT[@]}" --host "$host" --port "$port" ${SECURE_ARGS[@]+"${SECURE_ARGS[@]}"} --user "$USER_" "$@"
  fi
}
WHO="$( ((SSO)) && echo 'Cognito token' || echo "user $USER_")"

# Diagnostics go to stderr so a scripted -q query's output stays clean.
if ((LB)); then
  CLUSTER="$(ch_var clickhouse.cluster_name)"
  host="$(kubectl get service "$CLUSTER-lb" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$host" ]] || die "no load balancer Service '$CLUSTER-lb' in $NS -- set clickhouse.load_balancer.type and run: scripts/play.sh --tags lb"
  info "connecting to $host:$CH_PORT (NLB) as $WHO$(((${#SECURE_ARGS[@]})) && echo ', TLS CA-verified')" >&2
  connect "$host" "$CH_PORT" "$@"
  exit 0
fi

pod="$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=clickhouse-server \
         --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$pod" ]] || die "no Running server pod in $NS -- are the node groups up?"

kubectl port-forward -n "$NS" "pod/$pod" "$LOCAL_PORT:$CH_PORT" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
# Wait for the forward to accept connections rather than sleeping a guess.
for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/"$LOCAL_PORT") 2>/dev/null && { exec 3>&- ; break; }
  sleep 0.1
done

info "forwarding localhost:$LOCAL_PORT -> $pod:$CH_PORT in $NS as $WHO$(((${#SECURE_ARGS[@]})) && echo ', TLS CA-verified')" >&2
connect 127.0.0.1 "$LOCAL_PORT" "$@"
