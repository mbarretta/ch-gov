#!/usr/bin/env bash
#
# Prove Langfuse end to end: post a trace, see it in the API, read it back
# from the ClickHouse Private cluster that stores it. Safe to run any time.
#
#   scripts/langfuse-smoke.sh          # ClickHouse queries via port-forward
#   scripts/langfuse-smoke.sh --lb     # ClickHouse queries via the Step 12 NLB
#
# What it does, in order:
#   1. Reads the API key pair Step 15 wrote to state/ (langfuse-public-key,
#      langfuse-secret-key) and works out the Langfuse URL: langfuse.url from
#      group_vars if set, else the langfuse-lb NLB hostname. When the load
#      balancer type is `none`, or the NLB does not answer, it falls back to
#      `kubectl port-forward svc/<release>-web 3000:3000` -- the port is fixed at
#      3000 because NEXTAUTH_URL for that mode is http://localhost:3000.
#   2. POSTs one trace -- a root span with a generation under it -- as
#      OTLP/JSON to /api/public/otel/v1/traces, then polls
#      GET /api/public/v2/observations?traceId=<id> until both spans are
#      readable (bounded retries). Langfuse v4 stores everything as OpenTelemetry
#      spans: in its default events_only mode the v3 batch ingestion types
#      (trace-create, generation-create) and the v3 read endpoints
#      (/api/public/traces, /api/public/observations) are refused, and
#      /api/public/v2/observations is the read path that remains.
#   3. Runs, through scripts/ch-client.sh -q, the two queries that show the
#      same trace inside ClickHouse. v4 writes to langfuse.events_core (the
#      traces and observations tables the migrations also create stay empty
#      in events_only mode):
#        SELECT trace_id, span_id, name, type FROM langfuse.events_core WHERE trace_id = '<id>'
#        SELECT hostName(), count() FROM langfuse.events_core GROUP BY 1
#      --lb is handed to ch-client.sh so those queries go through the ClickHouse
#      NLB instead of a pod port-forward.
#
# Secrets: the Basic Auth credential (pk:sk) never enters a shell variable or
# argv. It is assembled from the two state/ files straight into a mode-0600
# curl config under a private temp directory, handed to curl as `--config -`
# on stdin, and removed on exit. `bash -x` therefore shows only file paths.
#
# Override the URL with LANGFUSE_URL=http://... when you reach Langfuse by a
# name this script cannot discover (a VPN alias, an SSH tunnel).
#
# Needs curl, jq, kubectl, and whatever scripts/ch-client.sh needs.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

CH_CLIENT_ARGS=()
while (($#)); do
  case "$1" in
    --lb) CH_CLIENT_ARGS=(--lb) ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac; shift
done

for tool in curl jq kubectl; do have "$tool" || die "$tool not installed"; done
export KUBECONFIG="$CH_ROOT/state/kubeconfig"

# Read what the playbook decided, so this stays in step with group_vars
# (lf_var, lib/common.sh, is block-scoped to langfuse:).
LF_NS="$(lf_var '  namespace:')"
LF_RELEASE="$(lf_var '  release:')"
LF_DB="$(lf_var '  clickhouse_database:')"
LF_URL_CFG="$(lf_var '  url:')"
LF_LB_TYPE="$(lf_var '    type:')"
[[ -n "$LF_NS" && -n "$LF_RELEASE" && -n "$LF_DB" ]] || die "could not read the langfuse: block from $CH_GROUP_VARS"

PK_FILE="$CH_ROOT/state/langfuse-public-key"
SK_FILE="$CH_ROOT/state/langfuse-secret-key"
[[ -r "$PK_FILE" && -r "$SK_FILE" ]] || die "no API keys at $PK_FILE / $SK_FILE -- run: scripts/play.sh --tags lf-app"

# ---- private temp dir, tunnel bookkeeping, one EXIT trap for both ----------
umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/langfuse-smoke.XXXXXX")"
PF=""
cleanup() { [[ -n "$PF" ]] && { kill "$PF" 2>/dev/null || true; }; rm -rf "$TMP"; }
trap cleanup EXIT

# curl config carrying the credential. paste/sed build the `user = "pk:sk"`
# line from the files directly, so the secret is never expanded by the shell.
AUTH_CFG="$TMP/auth.cfg"
paste -d: "$PK_FILE" "$SK_FILE" | sed 's/^/user = "/; s/$/"/' > "$AUTH_CFG"
# curl wrapper: config on stdin, body to $TMP/body, HTTP status on stdout
# (000 when the connection fails). Callers add the URL and any method/body
# flags; nothing secret is ever among them.
http_code() {
  curl --silent --max-time 30 --config - --output "$TMP/body" --write-out '%{http_code}' "$@" \
    < "$AUTH_CFG" 2>/dev/null || true
}

# ---- 1. find a URL that answers ---------------------------------------------
step "Reaching Langfuse"
# The health probe deliberately bypasses http_code: /api/public/health needs
# no credential, and at this point the URL is not yet confirmed to be the right
# server, so the key must not travel with the probe (000 on connection failure).
reachable() {
  [[ "$(curl --silent --max-time 5 --output /dev/null --write-out '%{http_code}' "$1/api/public/health" 2>/dev/null || true)" == 200 ]]
}

LF_URL="${LANGFUSE_URL:-}"
if [[ -n "$LF_URL" ]]; then
  info "using LANGFUSE_URL=$LF_URL"
elif [[ -n "$LF_URL_CFG" ]]; then
  LF_URL="$LF_URL_CFG"
  info "using langfuse.url from group_vars: $LF_URL"
elif [[ "${LF_LB_TYPE:-none}" != none ]]; then
  # lf_url (lib/common.sh): the NLB hostname, port appended unless 80.
  if LF_URL="$(lf_url)"; then
    info "load balancer ($LF_LB_TYPE NLB): $LF_URL"
  else
    warn "no hostname on Service langfuse-lb in $LF_NS yet"
  fi
fi

if [[ -n "$LF_URL" ]] && reachable "$LF_URL"; then
  ok "health check passed at $LF_URL"
else
  [[ -n "$LF_URL" ]] && warn "$LF_URL does not answer /api/public/health from here (VPN? security group?)"
  # Same tunnel handling as scripts/ch-client.sh, except the local port is
  # fixed: NEXTAUTH_URL for type none is http://localhost:3000, and the web
  # app redirects browsers there, so any other port would break the UI.
  if (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null; then
    exec 3>&-
    die "something already listens on localhost:3000; stop it or set LANGFUSE_URL"
  fi
  kubectl port-forward -n "$LF_NS" "svc/$LF_RELEASE-web" 3000:3000 >/dev/null 2>&1 &
  PF=$!
  disown "$PF"   # the EXIT trap kills it; without this bash announces "Terminated"
  # Wait for the forward to accept connections rather than sleeping a guess.
  for _ in $(seq 1 50); do
    (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && { exec 3>&- ; break; }
    sleep 0.1
  done
  LF_URL="http://localhost:3000"
  info "forwarding localhost:3000 -> svc/$LF_RELEASE-web:3000 in $LF_NS"
  reachable "$LF_URL" || die "Langfuse does not answer at $LF_URL -- is the release healthy? kubectl get pods -n $LF_NS"
  ok "health check passed through the port-forward"
fi

# ---- 2. post a trace and a generation, then read the trace back -------------
step "Posting a trace"
rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
TRACE_ID="$(rand_hex 16)"   # an OpenTelemetry trace id: 16 bytes, 32 hex
ROOT_ID="$(rand_hex 8)"     # span ids: 8 bytes, 16 hex
GEN_ID="$(rand_hex 8)"
NOW_S="$(date -u +%s)"
START_NS="${NOW_S}000000000"
END_NS="$((NOW_S + 1))000000000"
RUN_TAG="smoke-$(date -u +%Y%m%d-%H%M%S)"

# One OTLP/JSON request with two spans: the root (the trace itself, named
# RUN_TAG) and a generation (an LLM call) under it. Langfuse reads its own
# semantics from span attributes: langfuse.user.id, langfuse.trace.input and
# .output on the root, langfuse.observation.type=generation plus the gen_ai.*
# model and token counts on the child. The trace id is what we look up.
BODY="$TMP/otlp.json"
jq -n --arg tid "$TRACE_ID" --arg rid "$ROOT_ID" --arg gid "$GEN_ID" \
      --arg start "$START_NS" --arg end "$END_NS" --arg run "$RUN_TAG" '{
  resourceSpans: [{
    resource: {attributes: [{key: "service.name", value: {stringValue: "langfuse-smoke"}}]},
    scopeSpans: [{
      scope: {name: "scripts/langfuse-smoke.sh"},
      spans: [
        { traceId: $tid, spanId: $rid, name: $run, kind: 1,
          startTimeUnixNano: $start, endTimeUnixNano: $end,
          attributes: [
            {key: "langfuse.user.id",      value: {stringValue: "smoke-test"}},
            {key: "langfuse.trace.input",  value: {stringValue: "Where do these traces live?"}},
            {key: "langfuse.trace.output", value: {stringValue: "In ClickHouse Private."}},
            {key: "langfuse.trace.tags",   value: {arrayValue: {values: [{stringValue: "smoke"}]}}} ] },
        { traceId: $tid, spanId: $gid, parentSpanId: $rid, name: "answer", kind: 1,
          startTimeUnixNano: $start, endTimeUnixNano: $end,
          attributes: [
            {key: "langfuse.observation.type", value: {stringValue: "generation"}},
            {key: "gen_ai.request.model",       value: {stringValue: "demo-model"}},
            {key: "gen_ai.usage.input_tokens",  value: {intValue: "7"}},
            {key: "gen_ai.usage.output_tokens", value: {intValue: "5"}} ] }
      ] }] }] }' > "$BODY"

code="$(http_code --request POST --header 'Content-Type: application/json' --data "@$BODY" "$LF_URL/api/public/otel/v1/traces")"
# 200 with the queued ingestion job; anything else is the error text.
[[ "$code" == 200 ]] || die "POST /api/public/otel/v1/traces returned HTTP $code: $(head -c 400 "$TMP/body" 2>/dev/null)"
ok "accepted trace $TRACE_ID (name $RUN_TAG) with one generation"

# Ingestion is asynchronous (web -> S3 -> worker -> ClickHouse), so poll. The
# v3 GET /api/public/traces/<id> is refused in events_only mode; the v2
# observations list, filtered by trace, is the read path that remains.
info "waiting for GET /api/public/v2/observations?traceId=$TRACE_ID to list both spans"
for attempt in $(seq 1 30); do
  code="$(http_code "$LF_URL/api/public/v2/observations?traceId=$TRACE_ID&limit=10")"
  [[ "$code" == 200 && "$(jq -r '.data | length' "$TMP/body" 2>/dev/null || echo 0)" -ge 2 ]] && break
  ((attempt == 30)) && die "trace not readable after 30 attempts (last HTTP $code) -- check the worker: kubectl logs -n $LF_NS deploy/$LF_RELEASE-worker"
  sleep 2
done
ok "API returns the trace: $(jq -r '"traceId=\(.data[0].traceId) observations=\(.data | length) (\(.data | map(.type) | join(", ")))"' "$TMP/body")"

# ---- 3. the same trace, straight from ClickHouse ----------------------------
# events_core is the v4 table (one row per span); FINAL because it is a
# ReplacingMergeTree and a re-delivered span would otherwise show twice.
step "Reading it back from ClickHouse ($LF_DB database)"
CH_CLIENT="$CH_ROOT/scripts/ch-client.sh"
info "SELECT trace_id, span_id, name, type FROM $LF_DB.events_core WHERE trace_id = '$TRACE_ID'"
"$CH_CLIENT" ${CH_CLIENT_ARGS[@]+"${CH_CLIENT_ARGS[@]}"} -q "SELECT trace_id, span_id, name, type FROM $LF_DB.events_core FINAL WHERE trace_id = '$TRACE_ID' ORDER BY start_time FORMAT PrettyCompact"
info "SELECT hostName(), count() FROM $LF_DB.events_core GROUP BY 1"
"$CH_CLIENT" ${CH_CLIENT_ARGS[@]+"${CH_CLIENT_ARGS[@]}"} -q "SELECT hostName(), count() FROM $LF_DB.events_core GROUP BY 1 FORMAT PrettyCompact"

step "Done"
ok "trace $TRACE_ID went in through the API and came back out of ClickHouse Private"
if [[ -n "$PF" ]]; then
  info "open it: kubectl port-forward -n $LF_NS svc/$LF_RELEASE-web 3000:3000, then http://localhost:3000"
else
  info "open it: $LF_URL"
fi
info "login: the init user in group_vars; password in state/langfuse-admin-password"
