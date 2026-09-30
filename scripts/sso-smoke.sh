#!/usr/bin/env bash
#
# Prove single sign-on end to end: the Cognito issuer answers, Langfuse offers
# Cognito as a sign-in provider, and a Cognito token signs in to ClickHouse.
# Safe to run any time; parts whose switch is off are skipped with a message.
#
#   scripts/sso-smoke.sh                   # issuer and Langfuse checks
#   scripts/sso-smoke.sh --sso             # also sign in through the browser and test ClickHouse
#   CH_JWT=<id token> scripts/sso-smoke.sh # also test ClickHouse with a token you already have
#   scripts/sso-smoke.sh --sso --lb        # ClickHouse queries via the Step 12 NLB
#   scripts/sso-smoke.sh --negative        # also run the opt-in forged-token check (read the warning below)
#
# What it does, in order:
#   1. Needs sso.enabled (lib/common.sh's sso_enabled, which reads the merged
#      sso: block). Reads the issuer from state/sso-cognito-outputs.json,
#      GETs <issuer>/.well-known/openid-configuration and asserts the
#      document's own issuer and jwks_uri match the state file.
#   2. When Langfuse sign-in is enabled (sso.langfuse.enabled and
#      langfuse.enabled), works out the Langfuse URL the way
#      scripts/langfuse-smoke.sh does (LANGFUSE_URL, langfuse.url, the NLB,
#      else a port-forward to localhost:3000) and asserts GET
#      /api/auth/providers lists cognito.
#   3. When ClickHouse token login is enabled (sso.clickhouse_jwt.enabled)
#      and a token is at hand (CH_JWT, or --sso to sign in), runs through
#      scripts/ch-client.sh --sso:
#        SELECT currentUser()  -- must start with JWT::
#        SHOW GRANTS           -- must not be empty
#      SHOW GRANTS, not currentRoles(): the roles in a token's groups are
#      flattened into direct grants on the token user, so currentRoles() is
#      always empty for it. An empty SHOW GRANTS means no role was granted
#      anything for this user's groups (sso.clickhouse_jwt.role_grants) or the
#      user is in no group.
#   4. Only with --negative, and only when ClickHouse token login is enabled:
#      sends one locally built token to the server and expects a clean
#      authentication failure. The token has a key ID (kid) in its header,
#      the ClickHouse app client's ID as aud, and a random signature; it is
#      built with python3's standard library and is not signed by anything.
#      It passes when the client reports AUTHENTICATION_FAILED and the server
#      pods' restart counts are the same before and after.
#
# WARNING about --negative: this check is opt-in and is never part of a
# default run, because a token that carries a kid, sent to a server whose JWKS
# has never loaded, crashes that server process before authentication. The
# check is therefore itself the crash trigger on a server that is in that
# state. The JWKS gate in Step 9 is point-in-time (see docs/part-9-sso.md,
# section 6). Run --negative only when you accept a possible server restart,
# for example right after a rollout you have watched load the JWKS. It sends
# nothing else, and the token is discarded with the process.
#
# Secrets: the token stays in this process's memory and environment; nothing
# is written to disk. It reaches clickhouse-client on its command line, as
# scripts/ch-client.sh --sso documents.
#
# TLS: the derived Langfuse NLB address is verified against the role's
# self-signed certificate (lf_cacert, lib/common.sh); a LANGFUSE_URL or
# langfuse.url alias uses the system trust store, or set LANGFUSE_CACERT=<pem>.
# Verification is never switched off (no -k / --insecure).
#
# Needs curl and jq; kubectl for the port-forward fallback and for --negative;
# python3 for --sso and --negative; and whatever scripts/ch-client.sh needs.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

SSO_LOGIN=0; NEGATIVE=0; CH_CLIENT_ARGS=()
while (($#)); do
  case "$1" in
    --sso) SSO_LOGIN=1 ;;
    --lb)  CH_CLIENT_ARGS=(--lb) ;;
    --negative) NEGATIVE=1 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac; shift
done

for tool in curl jq; do have "$tool" || die "$tool not installed"; done
export KUBECONFIG="$CH_ROOT/state/kubeconfig"

if ! sso_enabled; then
  info "skipped: sso.enabled is false in the merged configuration, so there is no Cognito pool to check"
  exit 0
fi

umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sso-smoke.XXXXXX")"
PF=""
cleanup() { [[ -n "$PF" ]] && { kill "$PF" 2>/dev/null || true; }; rm -rf "$TMP"; }
trap cleanup EXIT

# ---- 1. the issuer -----------------------------------------------------------
step "Checking the Cognito issuer"
sso_require_outputs
ISSUER="$(sso_out issuer)"; JWKS_URI="$(sso_out jwks_uri)"
[[ -n "$ISSUER" && -n "$JWKS_URI" ]] || die "$SSO_OUTPUTS lacks issuer or jwks_uri -- re-run: scripts/play.sh --tags sso-idp"
DISCOVERY="$ISSUER/.well-known/openid-configuration"
if ! curl --silent --show-error --fail --max-time 15 --output "$TMP/discovery.json" "$DISCOVERY" 2>"$TMP/curl.err"; then
  fail "cannot read $DISCOVERY: $(head -c 300 "$TMP/curl.err")"; note_problem
else
  DOC_ISSUER="$(jq -r '.issuer // empty' "$TMP/discovery.json" 2>/dev/null || true)"
  DOC_JWKS="$(jq -r '.jwks_uri // empty' "$TMP/discovery.json" 2>/dev/null || true)"
  if [[ "$DOC_ISSUER" == "$ISSUER" && "$DOC_JWKS" == "$JWKS_URI" ]]; then
    ok "discovery document reachable; issuer $ISSUER and jwks_uri match the state file"
  else
    fail "discovery document disagrees with $SSO_OUTPUTS: issuer '$DOC_ISSUER' (state: '$ISSUER'), jwks_uri '$DOC_JWKS' (state: '$JWKS_URI')"; note_problem
  fi
fi

# ---- 2. Langfuse offers Cognito ------------------------------------------------
step "Checking Langfuse sign-in"
if ! sso_langfuse_enabled; then
  info "skipped: Langfuse sign-in is off (needs sso.langfuse.enabled and langfuse.enabled)"
else
  LF_NS="$(lf_var '  namespace:')"; LF_RELEASE="$(lf_var '  release:')"
  LF_URL_CFG="$(lf_var '  url:')"; LF_LB_TYPE="$(lf_var '    type:')"
  CURL_TLS=()
  reachable() {
    [[ "$(curl --silent --max-time 5 --output /dev/null --write-out '%{http_code}' \
           ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$1/api/public/health" 2>/dev/null || true)" == 200 ]]
  }

  LF_URL="${LANGFUSE_URL:-}"
  if [[ -n "$LF_URL" ]]; then
    info "using LANGFUSE_URL=$LF_URL"
  elif [[ -n "$LF_URL_CFG" ]]; then
    LF_URL="$LF_URL_CFG"
    info "using langfuse.url from group_vars: $LF_URL"
  elif [[ "${LF_LB_TYPE:-none}" != none ]]; then
    if LF_URL="$(lf_url)"; then
      info "load balancer ($LF_LB_TYPE NLB): $LF_URL"
      if LF_CACERT="$(lf_cacert)"; then CURL_TLS=(--cacert "$LF_CACERT"); fi
    else
      warn "no hostname on Service langfuse-lb in $LF_NS yet"
    fi
  fi
  if [[ -n "${LANGFUSE_CACERT:-}" ]]; then
    [[ -r "$LANGFUSE_CACERT" ]] || die "LANGFUSE_CACERT=$LANGFUSE_CACERT is not readable"
    CURL_TLS=(--cacert "$LANGFUSE_CACERT")
  fi

  if [[ -z "$LF_URL" ]] || ! reachable "$LF_URL"; then
    [[ -n "$LF_URL" ]] && warn "$LF_URL does not answer /api/public/health from here (VPN? security group?)"
    have kubectl || die "kubectl not installed, and Langfuse is not reachable directly"
    # The same fixed local port as langfuse-smoke.sh: NEXTAUTH_URL for a
    # deployment without a load balancer is http://localhost:3000.
    if (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null; then
      exec 3>&-
      die "something already listens on localhost:3000; stop it or set LANGFUSE_URL"
    fi
    kubectl port-forward -n "$LF_NS" "svc/$LF_RELEASE-web" 3000:3000 >/dev/null 2>&1 &
    PF=$!
    disown "$PF"
    for _ in $(seq 1 50); do
      (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && { exec 3>&- ; break; }
      sleep 0.1
    done
    LF_URL="http://localhost:3000"; CURL_TLS=()
    info "forwarding localhost:3000 -> svc/$LF_RELEASE-web:3000 in $LF_NS"
    reachable "$LF_URL" || die "Langfuse does not answer at $LF_URL -- is the release healthy? kubectl get pods -n $LF_NS"
  fi

  code="$(curl --silent --max-time 15 --output "$TMP/providers.json" --write-out '%{http_code}' \
            ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$LF_URL/api/auth/providers" 2>/dev/null || true)"
  if [[ "$code" != 200 ]]; then
    fail "GET $LF_URL/api/auth/providers returned HTTP $code"; note_problem
  elif [[ "$(jq -r 'has("cognito")' "$TMP/providers.json" 2>/dev/null || true)" == true ]]; then
    ok "Langfuse lists cognito as a sign-in provider ($(jq -r 'keys | join(", ")' "$TMP/providers.json"))"
  else
    fail "Langfuse does not list cognito at /api/auth/providers (found: $(jq -r 'keys | join(", ")' "$TMP/providers.json" 2>/dev/null || head -c 200 "$TMP/providers.json")) -- run: scripts/play.sh --tags lf-app"; note_problem
  fi
  signout="$(sso_langfuse_signout_url || true)"
  [[ -z "$signout" ]] || info "to sign in as a different Cognito user, open this first (it clears the browser's Cognito session): $signout"
fi

# ---- 3. a Cognito token signs in to ClickHouse -----------------------------------
step "Checking ClickHouse token login"
if ! sso_jwt_enabled; then
  info "skipped: ClickHouse token login is off (needs sso.clickhouse_jwt.enabled)"
else
  TOKEN="${CH_JWT:-}"
  if [[ -z "$TOKEN" ]] && ((SSO_LOGIN)); then
    TOKEN="$(sso_login_id_token)" || die "Cognito sign-in failed"
  fi
  if [[ -z "$TOKEN" ]]; then
    info "skipped: no token -- pass --sso to sign in through the browser, or set CH_JWT=<id token>"
  else
    # One client session for both statements: the first output line is the
    # user, the rest are that user's grants.
    if out="$(CH_JWT="$TOKEN" "$CH_ROOT/scripts/ch-client.sh" --sso ${CH_CLIENT_ARGS[@]+"${CH_CLIENT_ARGS[@]}"} \
                --multiquery -q 'SELECT currentUser() FORMAT TSVRaw; SHOW GRANTS FORMAT TSVRaw' 2>"$TMP/ch.err")"; then
      CH_USER="$(head -n 1 <<<"$out")"
      GRANTS="$(tail -n +2 <<<"$out" | grep -c . || true)"
      if [[ "$CH_USER" == JWT::* ]]; then
        ok "SELECT currentUser() = $CH_USER"
      else
        fail "SELECT currentUser() returned '$CH_USER', expected a name starting with JWT::"; note_problem
      fi
      if ((GRANTS > 0)); then
        ok "SHOW GRANTS lists $GRANTS grant(s) for the token user"
      else
        fail "SHOW GRANTS is empty: the token's groups map to no role with grants -- check sso.clickhouse_jwt.role_grants and the user's Cognito groups"; note_problem
      fi
    else
      fail "ClickHouse refused the token or the session failed: $(tail -n 5 "$TMP/ch.err")"; note_problem
    fi
  fi
fi

# ---- 4. a forged token gets a clean refusal (opt-in) ---------------------------
step "Checking that a forged token is refused cleanly"
if ((NEGATIVE == 0)); then
  info "skipped: opt-in only -- pass --negative to run it. A token with a kid sent to a server whose JWKS is not loaded crashes that server, so this check is never part of a default run (see --help)"
elif ! sso_jwt_enabled; then
  info "skipped: ClickHouse token login is off (needs sso.clickhouse_jwt.enabled)"
else
  have python3 || die "python3 not installed (--negative builds its token with the standard library)"
  have kubectl || die "kubectl not installed (--negative compares the server pods' restart counts)"
  CH_NS="$(ch_var clickhouse.namespace)"
  CH_AUD="$(sso_out clickhouse_client_id)"
  [[ -n "$CH_AUD" ]] || die "$SSO_OUTPUTS lacks clickhouse_client_id -- re-run: scripts/play.sh --tags sso-idp"
  warn "sending a forged token that carries a kid; if this server's JWKS is not loaded, the server process crashes"
  server_restarts() {
    kubectl get pods -n "$CH_NS" -l app.kubernetes.io/name=clickhouse-server \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[*].restartCount} {end}' 2>/dev/null
  }
  FORGED="$(python3 - "$ISSUER" "$CH_AUD" <<'PY'
import base64, json, os, sys, time
def seg(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
iss, aud = sys.argv[1:3]
header = {"alg": "RS256", "typ": "JWT", "kid": "sso-smoke-negative-check"}
payload = {"iss": iss, "aud": aud, "sub": "sso-smoke-negative-check",
           "token_use": "id", "iat": int(time.time()), "exp": int(time.time()) + 300}
print(seg(json.dumps(header).encode()) + "." + seg(json.dumps(payload).encode()) + "." + seg(os.urandom(256)))
PY
)"
  BEFORE="$(server_restarts || true)"
  if [[ -z "$BEFORE" ]]; then
    fail "cannot read the server pods in $CH_NS, so the restart counts cannot be compared -- is the cluster reachable (state/kubeconfig)?"; note_problem
  else
    if CH_JWT="$FORGED" "$CH_ROOT/scripts/ch-client.sh" --sso ${CH_CLIENT_ARGS[@]+"${CH_CLIENT_ARGS[@]}"} \
         -q 'SELECT 1' >/dev/null 2>"$TMP/forged.err"; then
      fail "ClickHouse accepted a token with a random signature -- that must never happen"; note_problem
    elif grep -Eq 'AUTHENTICATION_FAILED|Code: 516' "$TMP/forged.err"; then
      ok "the forged token was refused with AUTHENTICATION_FAILED"
    else
      fail "the forged token was not refused cleanly (a dropped connection here points at the crash): $(tail -n 3 "$TMP/forged.err" | head -c 400)"; note_problem
    fi
    sleep 3
    AFTER="$(server_restarts || true)"
    if [[ "$AFTER" == "$BEFORE" ]]; then
      ok "server pod restart counts unchanged ($BEFORE)"
    else
      fail "server pod restart counts changed: before '$BEFORE', after '$AFTER' -- see docs/part-9-sso.md, section 6"; note_problem
    fi
  fi
fi

step "Done"
if ((PROBLEMS)); then
  fail "$PROBLEMS check(s) failed"
  exit 1
fi
ok "every enabled single sign-on check passed"
