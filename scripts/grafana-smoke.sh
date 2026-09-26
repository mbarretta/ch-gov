#!/usr/bin/env bash
#
# Prove the Grafana ClickHouse datasource end to end: the datasource is
# healthy, a live query against system.tables returns real data, and --
# when Langfuse is also enabled -- the same read-only user's blanket
# GRANT SELECT ON *.* reaches Langfuse's own database too. Safe to run any
# time.
#
#   scripts/grafana-smoke.sh
#
# What it does, in order:
#   1. Reads the grafana: block of group_vars (namespace, release, url,
#      load balancer type) and works out the Grafana URL: grafana.url if
#      set, else the grafana-lb NLB hostname (gf_url/gf_cacert,
#      lib/common.sh). When load_balancer.type is `none`, or the NLB does
#      not answer, it falls back to `kubectl port-forward svc/<release>
#      3000:3000` -- the port is fixed at 3000 because GF_SERVER_ROOT_URL
#      for that mode is http://localhost:3000 (grafana/tasks/main.yml:572).
#   2. GET /api/datasources/uid/clickhouse/health (Basic Auth, admin /
#      state/grafana-admin-password) and asserts status "OK" -- the
#      datasource the grafana role provisioned with the fixed uid
#      "clickhouse" (grafana/tasks/main.yml:734-754).
#   3. POST /api/ds/query against that same datasource --
#      SELECT count() AS n FROM system.tables -- asserting a real numeric
#      result. This runs the query through the datasource itself, the same
#      path Grafana's own panels use, so it proves the Step 17 ClickHouse
#      user's GRANT SELECT ON *.* actually reaches ClickHouse, not just
#      that the health ping above succeeded.
#   4. When langfuse.enabled (lf_var, lib/common.sh) is true, a third query
#      -- SELECT count() AS n FROM langfuse.events_core -- proves that same
#      blanket grant reaches Langfuse's own database too, with no separate
#      grant of its own (grafana_clickhouse/tasks/main.yml).
#
# Secrets: the Basic Auth credential (admin:<password>) never enters a
# shell variable or argv. It is assembled from state/grafana-admin-password
# straight into a mode-0600 curl config under a private temp directory,
# handed to curl as `--config -` on stdin, and removed on exit. `bash -x`
# therefore shows only file paths.
#
# TLS: with grafana.load_balancer.tls true (or fips: true) the NLB
# terminates TLS with the self-signed certificate the role generated, so
# the derived https:// address is verified against that file,
# state/grafana-tls-cert.pem, via `--cacert` (gf_cacert, lib/common.sh).
# The certificate names the NLB hostname only, so a GRAFANA_URL or
# grafana.url alias is verified against the system trust store instead;
# set GRAFANA_CACERT=<pem> to trust another CA. Verification is never
# switched off (no -k / --insecure).
#
# Override the URL with GRAFANA_URL=http(s)://... when you reach Grafana by
# a name this script cannot discover (a VPN alias, an SSH tunnel).
#
# Needs curl, jq, and kubectl.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }
(($#)) && die "unknown argument: $1 (see --help)"

for tool in curl jq kubectl; do have "$tool" || die "$tool not installed"; done
export KUBECONFIG="$CH_ROOT/state/kubeconfig"

# Read what the playbook decided, so this stays in step with group_vars
# (gf_var, lib/common.sh, is block-scoped to grafana:).
GF_NS="$(gf_var '  namespace:')"
GF_RELEASE="$(gf_var '  release:')"
GF_URL_CFG="$(gf_var '  url:')"
GF_LB_TYPE="$(gf_var '    type:')"
[[ -n "$GF_NS" && -n "$GF_RELEASE" ]] || die "could not read the grafana: block from $CH_GROUP_VARS"

PW_FILE="$CH_ROOT/state/grafana-admin-password"
[[ -r "$PW_FILE" ]] || die "no admin password at $PW_FILE -- run: scripts/play.sh --tags gf-app"

# ---- private temp dir, tunnel bookkeeping, one EXIT trap for both ----------
umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grafana-smoke.XXXXXX")"
PF=""
cleanup() { [[ -n "$PF" ]] && { kill "$PF" 2>/dev/null || true; }; rm -rf "$TMP"; }
trap cleanup EXIT

# curl config carrying the credential. The admin username is a fixed,
# non-secret literal (grafana/tasks/main.yml:327); only the password's own
# bytes are secret, and they reach the file solely via `cat`'s stdout --
# never through a shell variable, command substitution, or argv.
AUTH_CFG="$TMP/auth.cfg"
{ printf 'user = "admin:'; cat "$PW_FILE"; printf '"\n'; } > "$AUTH_CFG"
# TLS trust for both curl wrappers below, settled once the URL is chosen:
# (--cacert <pem>) for the NLB's self-signed certificate or an explicit
# GRAFANA_CACERT, empty for the system trust store. Never -k.
CURL_TLS=()
# curl wrapper: config on stdin, body to $TMP/body, HTTP status on stdout
# (000 when the connection fails). Callers add the URL and any method/body
# flags; nothing secret is ever among them.
http_code() {
  curl --silent --max-time 30 --config - --output "$TMP/body" --write-out '%{http_code}' \
    ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$@" < "$AUTH_CFG" 2>/dev/null || true
}

# ---- 1. find a URL that answers ---------------------------------------------
step "Reaching Grafana"
# The health probe deliberately bypasses http_code: /api/health needs no
# credential, and at this point the URL is not yet confirmed to be the
# right server, so the key must not travel with the probe (000 on
# connection failure).
reachable() {
  [[ "$(curl --silent --max-time 5 --output /dev/null --write-out '%{http_code}' \
         ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$1/api/health" 2>/dev/null || true)" == 200 ]]
}

GF_URL="${GRAFANA_URL:-}"
if [[ -n "$GF_URL" ]]; then
  info "using GRAFANA_URL=$GF_URL"
elif [[ -n "$GF_URL_CFG" ]]; then
  GF_URL="$GF_URL_CFG"
  info "using grafana.url from group_vars: $GF_URL"
elif [[ "${GF_LB_TYPE:-none}" != none ]]; then
  # gf_url (lib/common.sh): the NLB hostname; https with the port appended
  # unless 443 when grafana.load_balancer.tls (or fips) is true, else http
  # unless 80.
  if GF_URL="$(gf_url)"; then
    info "load balancer ($GF_LB_TYPE NLB): $GF_URL"
    # The NLB presents the role's self-signed certificate, and this derived
    # address is the one name it carries -- so only here is it the CA.
    if GF_CACERT="$(gf_cacert)"; then
      CURL_TLS=(--cacert "$GF_CACERT")
      info "TLS: trusting the role's self-signed certificate at $GF_CACERT"
    elif [[ "$GF_URL" == https://* ]]; then
      warn "tls is on but $GF_TLS_CERT is missing; curl will refuse the NLB's certificate -- run: scripts/play.sh --tags gf-app"
    fi
  else
    warn "no hostname on Service grafana-lb in $GF_NS yet"
  fi
fi
# An explicit CA wins over both the system trust store and the derived one.
if [[ -n "${GRAFANA_CACERT:-}" ]]; then
  [[ -r "$GRAFANA_CACERT" ]] || die "GRAFANA_CACERT=$GRAFANA_CACERT is not readable"
  CURL_TLS=(--cacert "$GRAFANA_CACERT")
  info "TLS: trusting GRAFANA_CACERT=$GRAFANA_CACERT"
fi

if [[ -n "$GF_URL" ]] && reachable "$GF_URL"; then
  ok "health check passed at $GF_URL"
else
  [[ -n "$GF_URL" ]] && warn "$GF_URL does not answer /api/health from here (VPN? security group?)"
  # Same tunnel handling as scripts/ch-client.sh / langfuse-smoke.sh, except
  # the local port is fixed: GF_SERVER_ROOT_URL for type none is
  # http://localhost:3000 (grafana/tasks/main.yml:572), and any redirect
  # Grafana issues to itself would break otherwise.
  if (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null; then
    exec 3>&-
    die "something already listens on localhost:3000; stop it or set GRAFANA_URL"
  fi
  kubectl port-forward -n "$GF_NS" "svc/$GF_RELEASE" 3000:3000 >/dev/null 2>&1 &
  PF=$!
  disown "$PF"   # the EXIT trap kills it; without this bash announces "Terminated"
  # Wait for the forward to accept connections rather than sleeping a guess.
  for _ in $(seq 1 50); do
    (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && { exec 3>&- ; break; }
    sleep 0.1
  done
  GF_URL="http://localhost:3000"
  CURL_TLS=()   # plain http through the tunnel; no CA applies
  info "forwarding localhost:3000 -> svc/$GF_RELEASE:3000 in $GF_NS"
  reachable "$GF_URL" || die "Grafana does not answer at $GF_URL -- is the release healthy? kubectl get pods -n $GF_NS"
  ok "health check passed through the port-forward"
fi

# ---- 2. the datasource's own health check -----------------------------------
step "Checking the ClickHouse datasource"
code="$(http_code "$GF_URL/api/datasources/uid/clickhouse/health")"
[[ "$code" == 200 ]] || die "GET /api/datasources/uid/clickhouse/health returned HTTP $code: $(head -c 400 "$TMP/body" 2>/dev/null)"
status="$(jq -r '.status // empty' "$TMP/body" 2>/dev/null)"
[[ "$status" == "OK" ]] || die "datasource health status is '$status', expected OK: $(head -c 400 "$TMP/body" 2>/dev/null)"
ok "datasource uid=clickhouse is healthy: $(jq -r '.message // "OK"' "$TMP/body" 2>/dev/null)"

# ---- 3. a live query, through the datasource itself --------------------------
# POST /api/ds/query is the same path Grafana's own panels use -- this
# proves the Step 17 ClickHouse user's GRANT SELECT ON *.* actually reaches
# ClickHouse, not just that the health ping above succeeded. format: 1 is
# the plugin's table format; a one-row, one-column result comes back as
# frames[0].data.values[0][0] (one array per field, in field order).
query() {
  local sql="$1" req="$TMP/query_req.json"
  jq -n --arg sql "$sql" '{
    queries: [ { refId: "A", datasource: {type: "grafana-clickhouse-datasource", uid: "clickhouse"},
                 rawSql: $sql, format: 1, queryType: "sql" } ]
  }' > "$req"
  local code
  code="$(http_code --request POST --header 'Content-Type: application/json' --data "@$req" "$GF_URL/api/ds/query")"
  [[ "$code" == 200 ]] || die "POST /api/ds/query ($sql) returned HTTP $code: $(head -c 400 "$TMP/body" 2>/dev/null)"
  jq -r '.results.A.frames[0].data.values[0][0] // empty' "$TMP/body" 2>/dev/null
}

step "Querying system.tables through the datasource"
N="$(query 'SELECT count() AS n FROM system.tables')"
[[ "$N" =~ ^[0-9]+$ ]] || die "expected a numeric count from system.tables, got: '$N' ($(head -c 400 "$TMP/body" 2>/dev/null))"
ok "SELECT count() FROM system.tables = $N"

# ---- 4. the blanket grant reaches Langfuse too (when it's also enabled) -----
# lf_var (lib/common.sh) reads Langfuse's own group_vars block, independent
# of grafana:; the grant itself needs nothing extra for this (grafana
# GRANT SELECT ON *.* already covers every database, langfuse.* included).
if [[ "$(lf_var '  enabled:')" == true ]]; then
  step "Querying langfuse.events_core (blanket GRANT SELECT ON *.* reach check)"
  N2="$(query 'SELECT count() AS n FROM langfuse.events_core')"
  [[ "$N2" =~ ^[0-9]+$ ]] || die "expected a numeric count from langfuse.events_core, got: '$N2' ($(head -c 400 "$TMP/body" 2>/dev/null))"
  ok "SELECT count() FROM langfuse.events_core = $N2 -- the grafana ClickHouse user's blanket grant reaches Langfuse's data too"
fi

step "Done"
ok "datasource uid=clickhouse is healthy and returns real data"
if [[ -n "$PF" ]]; then
  info "open it: kubectl port-forward -n $GF_NS svc/$GF_RELEASE 3000:3000, then http://localhost:3000"
else
  info "open it: $GF_URL"
  # CURL_TLS[1] is the CA curl actually used (GRAFANA_CACERT if it was set).
  if [[ -n "${GF_CACERT:-}" ]]; then
    info "self-signed certificate: expect a browser warning; curl needs --cacert ${CURL_TLS[1]}"
  fi
fi
info "login: admin / password in state/grafana-admin-password"
