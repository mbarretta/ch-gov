#!/usr/bin/env bash
# Shared helpers for the ClickHouse Private on EKS setup scripts.
# Source this, don't execute it:   source "$(dirname "$0")/lib/common.sh"

# Homebrew's bin must be on PATH even under non-login shells (cron, CI, agents).
[[ ":$PATH:" == *":/opt/homebrew/bin:"* ]] || export PATH="/opt/homebrew/bin:$PATH"
# krew installs kubectl plugins (we use `kubectl preflight`, Step 10) under
# ~/.krew/bin, which nothing adds to PATH for you.
[[ ":$PATH:" == *":$HOME/.krew/bin:"* ]] || export PATH="$HOME/.krew/bin:$PATH"

# This project keeps its AWS config in-repo rather than in ~/.aws, so the whole
# setup is portable. Point the CLI at it unless the caller already chose a file.
CH_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- output helpers -------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLU" "$*" "$C_RESET"; }
ok()    { printf '  %s[ ok ]%s %s\n'   "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '  %s[warn]%s %s\n'   "$C_YEL" "$C_RESET" "$*"; }
fail()  { printf '  %s[fail]%s %s\n'   "$C_RED" "$C_RESET" "$*"; }
info()  { printf '  %s%s%s\n'          "$C_DIM" "$*" "$C_RESET"; }
die()   { fail "$*"; exit 1; }

# ---- merged configuration resolver ------------------------------------------
# Every script reads its configuration through Ansible, the same way the
# playbook does, so state/deploy-vars.yml (passed with -e @file) over
# ansible/group_vars/all.yml is merged identically everywhere: dictionaries
# merge key by key (hash_behaviour = merge in ansible/ansible.cfg, which is why
# the call runs from ansible/) and Jinja defaults such as sso_region or the
# per-service bucket names are evaluated. One `ansible localhost` call emits
# every block the scripts read as JSON; it is cached in CH_VARS_JSON for the
# life of the script. Call ch_resolve (or ch_init, below) from the main shell,
# not inside $(...), or the cache is lost with the subshell.
CH_VARS_JSON=""

ch_resolve() {
  [[ -z "$CH_VARS_JSON" ]] || return 0
  have ansible || { fail "ansible is not installed -- run scripts/part1-setup.sh" >&2; return 1; }
  have jq      || { fail "jq is not installed -- run scripts/part1-setup.sh" >&2; return 1; }
  local extra=() out errf rc=0 json
  [[ -f "$CH_PROJECT_ROOT/state/deploy-vars.yml" ]] && extra=(-e "@$CH_PROJECT_ROOT/state/deploy-vars.yml")
  errf="$(mktemp)"
  out="$(cd "$CH_PROJECT_ROOT/ansible" && \
         ANSIBLE_STDOUT_CALLBACK=minimal ANSIBLE_CALLBACK_RESULT_FORMAT=json \
         ansible localhost ${extra[@]+"${extra[@]}"} -m ansible.builtin.debug \
           -a 'msg={{ {"fips": fips, "size": size, "pricing": pricing, "aws": aws, "infrastructure": infrastructure, "clickhouse": clickhouse, "sso": sso, "langfuse": langfuse, "grafana": grafana} }}' \
           </dev/null 2>"$errf")" || rc=$?
  json="${out#*=> }"
  if ((rc == 0)) && CH_VARS_JSON="$(jq -ce '.msg | select(type == "object")' <<<"$json" 2>/dev/null)" && [[ -n "$CH_VARS_JSON" ]]; then
    rm -f "$errf"
    return 0
  fi
  CH_VARS_JSON=""
  fail "could not resolve the configuration (ansible/group_vars/all.yml over state/deploy-vars.yml) with Ansible" >&2
  { [[ -n "$out" ]] && printf '%s\n' "$out"; cat "$errf"; } | head -20 | sed 's/^/      /' >&2
  rm -f "$errf"
  return 1
}

# Prints one merged value by dotted path (aws.target_profile, clickhouse.
# bucket_name, fips). Strings come back raw, booleans and numbers as
# true/false/80, and nothing is printed when the key is absent or null.
ch_var() {
  ch_resolve || return 1
  jq -r --arg p "$1" 'getpath($p | split(".")) | if . == null then empty elif type == "string" then . else tojson end' <<<"$CH_VARS_JSON"
}

# Succeeds when the persistent fips: switch is true.
ch_fips_enabled() { [[ "$(ch_var fips)" == "true" ]]; }

# The all-in hourly estimate for the configured size and fips: the pricing:
# table times the keeper, server and operator node counts at their minimums,
# plus the EKS control plane and the NAT gateway(s). Same formula as the cost
# line the nodes step prints, so the two agree. Prints two decimals, such as 2.32.
ch_hourly_cost() {
  ch_resolve || return 1
  local total
  total="$(jq -r '.pricing as $p | .infrastructure as $i
    | ([[$i.keeper.instance_type, $i.keeper.node_count],
        [$i.server.instance_type, $i.server.min_nodes],
        [$i.operator.instance_type, $i.operator.min_nodes]]
       | map(($p.instance_hourly_usd[.[0]] // 0) * (.[1] | tonumber)) | add) as $compute
    | $compute + $p.eks_control_plane_hourly_usd
      + $p.nat_gateway_hourly_usd * (if $i.nat_mode == "single" then 1 else 3 end)
    ' <<<"$CH_VARS_JSON")" || return 1
  printf '%.2f' "$total"
}

# sso | profile. Anything but "profile" is treated as sso, matching the
# playbook's default.
ch_auth_mode() {
  [[ "$(ch_var aws.auth_mode)" == profile ]] && echo profile || echo sso
}

# What to tell someone whose AWS credentials do not work, for the current auth
# mode. sso: the login command, with AWS_CONFIG_FILE prefixed only when the
# repo-local config is the one in use (always, once ch_init has run; a caller
# that has not run it may still point elsewhere). profile: refresh the named profile's
# credentials (there is no SSO session to log in to). PROFILE defaults to the
# deployment profile.
ch_login_hint() {
  local profile="${1:-$(ch_var aws.target_profile)}"
  if [[ "$(ch_auth_mode)" == sso ]]; then
    local prefix=""
    [[ "${AWS_CONFIG_FILE:-}" == "$CH_PROJECT_ROOT/.aws/config" ]] && prefix="AWS_CONFIG_FILE=$AWS_CONFIG_FILE "
    printf 'run: %saws sso login --profile %s' "$prefix" "$profile"
  else
    printf "refresh the credentials for AWS profile '%s' (aws.auth_mode is profile, so there is no SSO login)" "$profile"
  fi
}

# ---- AWS config bootstrap --------------------------------------------------
# aws.auth_mode: sso -- .aws/config is generated from
# ansible/files/aws-config.ini.j2, not tracked directly, so use_fips_endpoint
# always matches the `fips:` switch. The authoritative render happens inside
# ansible/deploy.yml's pre_tasks (tags: [always]), which honors whatever
# -e fips=... a given run passes. This one exists only because scripts/play.sh
# and scripts/part1-setup.sh both check AWS authentication BEFORE Ansible ever
# starts -- on a fresh checkout there is no .aws/config yet for that check to
# use. Credential-free (plain text substitution of the template's aws.*
# placeholders from the merged values above), and safe to re-run: it rewrites
# the file only when something other than the use_fips_endpoint lines would
# change, so it never clobbers a render already produced by an -e fips=...
# deploy.yml run.
#
# aws.auth_mode: profile -- nothing is rendered and AWS_CONFIG_FILE is left
# untouched: the caller's value, or the AWS CLI default. With no rendered config to carry
# use_fips_endpoint, fips: true exports AWS_USE_FIPS_ENDPOINT instead.
render_aws_config() {
  local out="$CH_PROJECT_ROOT/.aws/config"
  local tmpl="$CH_PROJECT_ROOT/ansible/files/aws-config.ini.j2"
  [[ -f "$tmpl" ]] || die "missing $tmpl -- checkout looks incomplete"
  local use_fips=false key val body
  ch_fips_enabled && use_fips=true
  body="$(<"$tmpl")"
  # bash 5.2 treats & in a ${var//pat/rep} replacement as the matched text.
  shopt -u patsub_replacement 2>/dev/null || true
  body="${body//"{{ 'true' if fips else 'false' }}"/$use_fips}"
  for key in sso_session_name sso_start_url sso_region sso_role_name target_profile \
             target_account_id target_region source_ecr_profile partition \
             ecr_pull_role_name ecr_pull_session_name; do
    val="$(ch_var "aws.$key")"
    body="${body//"{{ aws.$key }}"/$val}"
  done
  if [[ -f "$out" ]] && diff -q <(grep -v '^use_fips_endpoint' "$out") \
                               <(printf '%s\n' "$body" | grep -v '^use_fips_endpoint') >/dev/null; then
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$body" > "$out"
}

# ---- deploy-vars bootstrap -------------------------------------------------
# ansible/group_vars/all.yml's aws: block ships with two placeholders
# (target_account_id, source_ecr_account_id) because this is a public
# tutorial repo -- a real account number has no business in a tracked file.
# state/deploy-vars.yml is the gitignored local override a deployer fills in
# once with their real values, instead of hand-editing all.yml. Only fills in
# the file when it's missing, so it never clobbers a copy someone has already
# filled in. Keep it in step with state/deploy-vars.yml.example.
render_deploy_vars() {
  local out="$CH_PROJECT_ROOT/state/deploy-vars.yml"
  if [[ -f "$out" ]]; then
    chmod 600 "$out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<'EOF'
# Local override for ansible/group_vars/all.yml. Only the keys you set here
# change; every other default keeps its all.yml value (dictionaries merge key
# by key). This file is gitignored (state/) and every script picks it up
# automatically afterward.
aws:
  # sso     -- the kit renders a project-local .aws/config and you log in with
  #            `aws sso login`.
  # profile -- use a named profile you already have (target_profile, plus
  #            source_ecr_profile for the ECR pull); nothing is rendered.
  auth_mode: "sso"
  # Fill in your account ID and the source registry account ID ClickHouse gave you.
  target_account_id: "<YOUR_ACCOUNT_ID>"
  target_region: "us-east-1"
  target_profile: "ch-gov-target"
  source_ecr_account_id: "<SOURCE_ECR_ACCOUNT_ID>"
  source_ecr_region: "us-east-1"
  source_ecr_profile: "ch-gov-ecr-pull"
  # The role in your account that source_ecr_profile assumes. It is arranged
  # with ClickHouse; the playbook only checks that it can be assumed.
  ecr_pull_role_name: "ClickHouseAirgapECRPullRole"
  ecr_pull_session_name: "ch-gov-ecr-pull"
  # auth_mode: sso only -- ignored in profile mode. Your IAM Identity Center
  # portal start URL; `aws sso login` fails clearly until it is real.
  sso_start_url: "https://<YOUR_SSO_PORTAL_ID>.awsapps.com/start"
  sso_session_name: "ch-gov"
  sso_region: "{{ aws.target_region }}"
  sso_role_name: "AdministratorAccess"

# Optional -- only needed when grafana.enabled is true. A Docker Hub account
# entitled to the DHI (Docker Hardened Images) catalog, used to mirror the
# grafana/awscli images from dhi.io. Leave both empty to fall back to the
# DHI_USERNAME/DHI_TOKEN environment variables; the image_sync role fails
# clearly if grafana.enabled is true and neither is set.
dhi:
  username: ""   # your Docker Hub username
  token: ""      # your Docker Hub DHI access token

# Optional switches. Uncomment only the ones you want; every other key keeps
# its all.yml value. Defaults shown match ansible/group_vars/all.yml.
#
# Deployment size: minimal (the default) or tutorial (the upstream tutorial's
# larger node and pod sizes). See ansible/group_vars/all.yml for both profiles.
# size: tutorial
#
# FIPS build (x86_64, FIPS image tags and endpoints). See
# docs/part-7-fips-hardening.md.
# fips: false
#
# Langfuse (optional Steps 13-15). See docs/part-6-langfuse.md.
# langfuse:
#   enabled: false
#   load_balancer:
#     type: "internal"   # none | internal | public
#     tls: false
#
# Grafana (optional Steps 16-18). Needs the dhi: credentials above. See
# docs/part-8-grafana.md.
# grafana:
#   enabled: false
#   load_balancer:
#     type: "internal"   # none | internal | public
#     tls: false
EOF
  chmod 600 "$out"
}
render_deploy_vars

# Tracks non-fatal problems so the script can exit non-zero at the very end
# instead of stopping at the first issue -- you want the whole report.
PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# ---- python floor ---------------------------------------------------------
# 3.12 is the floor, and it is not an arbitrary choice: ansible-core 2.21
# declares Requires-Python >=3.12, so anything older cannot run the playbook at
# all. It also happens to be the oldest line with real life left -- 3.9 went EOL
# in Oct 2025 and 3.10 goes EOL in Oct 2026, while 3.12 is supported to Oct 2028.
readonly PY_MIN_MAJOR=3
readonly PY_MIN_MINOR=12
readonly PY_MIN="${PY_MIN_MAJOR}.${PY_MIN_MINOR}"

# Succeeds if the given interpreter (default: python3 on PATH) is >= PY_MIN.
py_at_least() {
  "${1:-python3}" -c \
    "import sys; sys.exit(0 if sys.version_info[:2] >= ($PY_MIN_MAJOR, $PY_MIN_MINOR) else 1)" \
    2>/dev/null
}

# Prints e.g. 3.14.7, or nothing if the interpreter is missing/unrunnable.
py_version() { "${1:-python3}" -c 'import platform; print(platform.python_version())' 2>/dev/null; }

# ---- constants (from the ClickHouse Private training guide) ---------------
# The source registry and profile values (SOURCE_ECR_ACCOUNT, SOURCE_ECR_REGION,
# SOURCE_ECR_PROFILE) and the deployment profile (TARGET_PROFILE) come from the
# merged configuration and are set by ch_init at the bottom of this file.

# The three images that make up a ClickHouse Private deployment.
readonly CH_REPOS=(clickhouse-server clickhouse-keeper clickhouse-operator)

# ---- Langfuse (optional Steps 13-15) --------------------------------------
# The certificate the langfuse role generates into state/ when
# langfuse.load_balancer.tls is true and terminates at the langfuse-lb NLB.
# Self-signed, so it is its own CA: `curl --cacert "$LF_TLS_CERT"` trusts it.
readonly LF_TLS_CERT="$CH_PROJECT_ROOT/state/langfuse-tls-cert.pem"

# Prints one merged value from a service block (langfuse: or grafana:) of the
# configuration. KEY is either a dotted path inside the block (namespace,
# load_balancer.type) or the indentation-carrying form the callers have always
# used: two spaces for a top-level key of the block ('  namespace:') and four
# for a key of its load_balancer: ('    type:', '    tls:', '    port:').
# Quoted and bare scalars alike come back without quotes; nothing is printed
# when the key is absent or null.
_ch_block_var() {
  local block="$1" key="$2" name lead
  name="${key#"${key%%[! ]*}"}"; name="${name%:}"
  lead="${key%%[! ]*}"
  case "${#lead}" in
    4) name="load_balancer.$name" ;;
  esac
  ch_var "$block.$name"
}

#   lf_var '  namespace:'      lf_var '    type:'      lf_var '  enabled:'
lf_var() { _ch_block_var langfuse "$1"; }

# Succeeds when the NLB terminates TLS -- the same effective state the
# langfuse role computes as _lf_tls: langfuse.load_balancer.tls,
# OR'd with the persistent fips: switch (ch_fips_enabled, defined above), but
# never for load_balancer.type: none, which has no NLB at all. `    tls:` and
# `    type:` are the only keys at that indentation spelled that way in the
# langfuse: block, so the prefix matches are unambiguous.
lf_tls() {
  [[ "$(lf_var '    type:')" != none ]] || return 1
  [[ "$(lf_var '    tls:')" == true ]] || ch_fips_enabled
}

# Prints the address Langfuse is reached at -- the same rule the langfuse role
# uses for NEXTAUTH_URL, so the two never disagree: langfuse.url when set;
# else the hostname of the langfuse-lb NLB, as https://<host> with :<port>
# appended unless it is 443 when lf_tls (langfuse.load_balancer.tls, or
# fips: true with load_balancer.type not none), and as
# http://<host> with :<port> appended unless it is 80 otherwise. Prints nothing
# and returns 1 when the NLB has no hostname (not provisioned yet, or the
# Service is absent). Reads the Service through state/kubeconfig, like every
# other script here. The load_balancer.type `none` case (kubectl port-forward,
# fixed at http://localhost:3000) has nothing to derive and is the caller's to
# handle.
lf_url() {
  local url host port scheme default_port
  url="$(lf_var '  url:')"
  if [[ -n "$url" ]]; then printf '%s\n' "$url"; return 0; fi
  host="$(KUBECONFIG="$CH_PROJECT_ROOT/state/kubeconfig" kubectl get service langfuse-lb \
            -n "$(lf_var '  namespace:')" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  port="$(lf_var '    port:')"
  if lf_tls; then scheme=https; default_port=443; else scheme=http; default_port=80; fi
  url="$scheme://$host"; [[ "${port:-$default_port}" == "$default_port" ]] || url="$url:$port"
  printf '%s\n' "$url"
}

# Prints the CA file curl needs for the address lf_url derives -- the role's
# self-signed certificate, LF_TLS_CERT -- when lf_tls (see above) and the
# file is readable. Prints nothing and returns 1 otherwise (TLS off, or the
# role has not generated it yet). Only for the derived NLB address: the certificate
# names the NLB hostname alone, so a langfuse.url or LANGFUSE_URL alias must be
# verified against the system trust store (or a CA the caller supplies).
lf_cacert() {
  lf_tls && [[ -r "$LF_TLS_CERT" ]] || return 1
  printf '%s\n' "$LF_TLS_CERT"
}

# ---- Grafana (optional Steps 16-18) ----------------------------------------

# The certificate the grafana role generates into state/ when
# grafana.load_balancer.tls is true and terminates at the grafana-lb NLB.
# Self-signed, so it is its own CA: `curl --cacert "$GF_TLS_CERT"` trusts it.
readonly GF_TLS_CERT="$CH_PROJECT_ROOT/state/grafana-tls-cert.pem"

# Same as lf_var, for the grafana: block.
#   gf_var '  namespace:'      gf_var '    type:'      gf_var '  enabled:'
gf_var() { _ch_block_var grafana "$1"; }

# Succeeds when the NLB terminates TLS -- the same effective state the
# grafana role computes as _gf_tls: grafana.load_balancer.tls, OR'd with the
# persistent fips: switch via the shared ch_fips_enabled function (never
# duplicated here), but never for load_balancer.type: none, which has no NLB
# at all.
gf_tls() {
  [[ "$(gf_var '    type:')" != none ]] || return 1
  [[ "$(gf_var '    tls:')" == true ]] || ch_fips_enabled
}

# Prints the address Grafana is reached at -- the same rule lf_url uses for
# Langfuse: grafana.url when set; else the hostname of the grafana-lb NLB, as
# https://<host> with :<port> appended unless it is 443 when gf_tls, and as
# http://<host> with :<port> appended unless it is 80 otherwise. Prints
# nothing and returns 1 when the NLB has no hostname yet. The
# load_balancer.type `none` case (kubectl port-forward, fixed at
# http://localhost:3000) has nothing to derive and is the caller's to handle.
gf_url() {
  local url host port scheme default_port
  url="$(gf_var '  url:')"
  if [[ -n "$url" ]]; then printf '%s\n' "$url"; return 0; fi
  host="$(KUBECONFIG="$CH_PROJECT_ROOT/state/kubeconfig" kubectl get service grafana-lb \
            -n "$(gf_var '  namespace:')" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  port="$(gf_var '    port:')"
  if gf_tls; then scheme=https; default_port=443; else scheme=http; default_port=80; fi
  url="$scheme://$host"; [[ "${port:-$default_port}" == "$default_port" ]] || url="$url:$port"
  printf '%s\n' "$url"
}

# Prints the CA file curl needs for the address gf_url derives -- the role's
# self-signed certificate, GF_TLS_CERT -- when gf_tls (see above) and the
# file is readable. Prints nothing and returns 1 otherwise.
gf_cacert() {
  gf_tls && [[ -r "$GF_TLS_CERT" ]] || return 1
  printf '%s\n' "$GF_TLS_CERT"
}

# ---- Single sign-on (optional Steps 6b and 11b) -----------------------------
# sso: sits before langfuse: in group_vars, and these helpers read it through
# ch_var like everything else, so state/deploy-vars.yml is merged over all.yml
# key by key exactly as the playbook resolves it (nested mappings merge, lists
# replace). Nothing here scrapes the YAML file.

# The file the sso_cognito role writes (sso_state_files.outputs_file): issuer,
# jwks_uri, hosted-UI and token endpoints, both app client IDs and callback
# URLs. It carries no secret.
readonly SSO_OUTPUTS="$CH_PROJECT_ROOT/state/sso-cognito-outputs.json"

# Prints one merged value from the sso: block by dotted path:
#   sso_var enabled      sso_var langfuse.enabled      sso_var clickhouse_jwt.enabled
sso_var() { ch_var "sso.$1"; }

# Succeed when the master switch is on / the Langfuse sign-in is wanted (it
# needs Langfuse itself too, as in the sso_cognito role) / ClickHouse accepts
# Cognito tokens (Step 11b).
sso_enabled()          { [[ "$(sso_var enabled)" == true ]]; }
sso_langfuse_enabled() { sso_enabled && [[ "$(sso_var langfuse.enabled)" == true && "$(lf_var '  enabled:')" == true ]]; }
sso_jwt_enabled()      { sso_enabled && [[ "$(sso_var clickhouse_jwt.enabled)" == true ]]; }

# Prints one key of the outputs file (nothing for an absent or null key).
sso_out() {
  [[ -r "$SSO_OUTPUTS" ]] || return 1
  jq -r --arg k "$1" '.[$k] // empty' "$SSO_OUTPUTS"
}

# Dies unless the outputs file exists, naming the step that writes it.
sso_require_outputs() {
  [[ -r "$SSO_OUTPUTS" ]] || die "no SSO outputs at $SSO_OUTPUTS -- run: scripts/play.sh --tags sso-idp"
}

# Signs in through the Cognito hosted UI and prints the ClickHouse app client's
# ID token on stdout (progress goes to stderr). Authorization-code flow with
# PKCE: the app client is public, so the code exchange carries the PKCE
# verifier instead of a secret. A loopback listener on the callback URL the
# stack registered (clickhouse_callback_url, fixed at http://localhost:8765/
# callback) catches the redirect. Only the ID token carries the aud claim the
# ClickHouse JWT directory requires, so that is the token returned.
#
# The token lives in the caller's variable only: nothing is written to disk.
# Set CH_SSO_NO_BROWSER=1 to print the sign-in URL without opening a browser,
# and CH_SSO_TIMEOUT=<seconds> to change the 180-second wait.
#
# Call as TOKEN="$(sso_login_id_token)" || exit 1.
sso_login_id_token() {
  have python3 || { fail "python3 is required for the browser sign-in" >&2; return 1; }
  have jq      || { fail "jq is not installed" >&2; return 1; }
  [[ -r "$SSO_OUTPUTS" ]] || { fail "no SSO outputs at $SSO_OUTPUTS -- run: scripts/play.sh --tags sso-idp" >&2; return 1; }
  local authz token_ep client redirect
  authz="$(sso_out authorization_endpoint)"; token_ep="$(sso_out token_endpoint)"
  client="$(sso_out clickhouse_client_id)"; redirect="$(sso_out clickhouse_callback_url)"
  [[ -n "$authz" && -n "$token_ep" && -n "$client" && -n "$redirect" ]] \
    || { fail "$SSO_OUTPUTS lacks authorization_endpoint, token_endpoint, clickhouse_client_id or clickhouse_callback_url -- re-run: scripts/play.sh --tags sso-idp" >&2; return 1; }
  python3 - "$authz" "$token_ep" "$client" "$redirect" <<'PY'
import base64, hashlib, http.server, json, os, secrets, sys, time, urllib.error, urllib.parse, urllib.request, webbrowser

authz, token_ep, client_id, redirect = sys.argv[1:5]
timeout = int(os.environ.get("CH_SSO_TIMEOUT", "180"))


def die(msg):
    print("  [fail] " + msg, file=sys.stderr)
    sys.exit(1)


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


cb = urllib.parse.urlsplit(redirect)
if cb.scheme != "http" or cb.hostname not in ("localhost", "127.0.0.1") or not cb.port:
    die("the callback URL must be http://localhost:<port>/<path>, got " + redirect)

verifier = secrets.token_urlsafe(64)
challenge = b64url(hashlib.sha256(verifier.encode()).digest())
state = secrets.token_urlsafe(24)
nonce = secrets.token_urlsafe(24)
got = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        params = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        if url.path != (cb.path or "/") or params.get("state") != state:
            # Not our redirect (a stray request): refuse it and keep waiting.
            self.send_response(400)
            self.end_headers()
            return
        got.update(params)
        body = b"Signed in. You can close this tab and return to the terminal.\n"
        if "code" not in params:
            body = b"Sign-in failed. See the terminal for details.\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


try:
    # Threaded, so an idle speculative connection a browser opens ahead of the
    # redirect cannot stall the real request behind it.
    server = http.server.ThreadingHTTPServer(("127.0.0.1", cb.port), Handler)
except OSError as exc:
    die("cannot listen on 127.0.0.1:%d (%s); stop whatever holds that port" % (cb.port, exc))
server.daemon_threads = True
server.timeout = 1

query = urllib.parse.urlencode({
    "response_type": "code",
    "client_id": client_id,
    "redirect_uri": redirect,
    "scope": "openid email profile",
    "state": state,
    "nonce": nonce,
    "code_challenge": challenge,
    "code_challenge_method": "S256",
})
sign_in = authz + ("&" if "?" in authz else "?") + query
print("  Sign in to Cognito in your browser:\n    " + sign_in, file=sys.stderr)
if not os.environ.get("CH_SSO_NO_BROWSER"):
    webbrowser.open(sign_in)

deadline = time.time() + timeout
while not got and time.time() < deadline:
    server.handle_request()
server.server_close()
if not got:
    die("no sign-in within %d seconds" % timeout)
if "code" not in got:
    die("Cognito returned %s: %s" % (got.get("error", "no code"), got.get("error_description", "")))

form = urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "client_id": client_id,
    "code": got["code"],
    "redirect_uri": redirect,
    "code_verifier": verifier,
}).encode()
request = urllib.request.Request(token_ep, data=form, headers={"Content-Type": "application/x-www-form-urlencoded"})
try:
    with urllib.request.urlopen(request, timeout=30) as resp:
        tokens = json.load(resp)
except urllib.error.HTTPError as exc:
    die("the token endpoint answered HTTP %d: %s" % (exc.code, exc.read(400).decode("utf-8", "replace")))
except (urllib.error.URLError, OSError) as exc:
    die("cannot reach the token endpoint: %s" % exc)

id_token = tokens.get("id_token")
if not id_token:
    die("the token response has no id_token")
try:
    payload = id_token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
except (IndexError, ValueError):
    die("the id_token is not a JWT")
if claims.get("aud") != client_id or claims.get("nonce") != nonce:
    die("the id_token does not match this sign-in (aud or nonce)")
print(id_token)
PY
}

# ---- fips (shared by ch-client.sh's TLS handling) -------------------------
# The CA clickhouse_cluster generates into state/ when fips is true (see
# ansible/group_vars/all.yml's clickhouse_tls_ca_cert_file) -- a leaf server
# cert signed by it terminates the ClickHouse native/HTTP TLS listeners once
# server.openSSL.required zeroes their plaintext ports.
readonly CH_TLS_CA="$CH_PROJECT_ROOT/state/clickhouse-tls-ca.pem"
# A minimal clickhouse-client openSSL config trusting CH_TLS_CA, rewritten by
# ch_tls_client_config() below every time it's needed. It carries no secret
# (just a path), so unlike the CA/leaf material it needs no idempotency
# check or tightened file mode.
readonly CH_TLS_CLIENT_CFG="$CH_PROJECT_ROOT/state/clickhouse-client-tls.xml"

# Writes CH_TLS_CLIENT_CFG so `clickhouse-client --config-file
# "$CH_TLS_CLIENT_CFG" --secure` trusts the CA clickhouse_cluster generated,
# instead of the system trust store (which never has our self-signed CA in
# it). verificationMode is strict, rejecting an unrecognized chain outright:
# the chart's TLS surface is CA-chain verification
# only (no separate hostname/SNI check exists to configure either way), so
# this is the whole story -- there is no hostname-matching flag to add.
# Dies with a clear message if fips: true but clickhouse_cluster has not
# generated the CA yet.
ch_tls_client_config() {
  [[ -r "$CH_TLS_CA" ]] || die "fips: true but no CA at $CH_TLS_CA -- run: scripts/play.sh --tags cluster"
  cat > "$CH_TLS_CLIENT_CFG" <<XML
<config><openSSL><client><caConfig>$CH_TLS_CA</caConfig><verificationMode>strict</verificationMode><invalidCertificateHandler><name>RejectCertificateHandler</name></invalidCertificateHandler></client></openSSL></config>
XML
}

# ---- initialise -------------------------------------------------------------
# Resolves the configuration once and activates the AWS auth mode. Runs when
# this file is sourced, unless the caller sets CH_DEFER_INIT=1 first and calls
# ch_init itself later (scripts/part1-setup.sh does, because Ansible and jq are
# what it installs). render_deploy_vars ran first so a fresh checkout resolves
# against the freshly written state/deploy-vars.yml, not only all.yml.
#
# aws.auth_mode sso always exports AWS_CONFIG_FILE as the repo-local
# .aws/config, replacing any value the caller had set; profile mode leaves it
# alone and, with fips on, exports AWS_USE_FIPS_ENDPOINT in its place.
ch_init() {
  [[ -z "${CH_INITED:-}" ]] || return 0
  ch_resolve || return 1
  if [[ "$(ch_auth_mode)" == sso ]]; then
    render_aws_config
    export AWS_CONFIG_FILE="$CH_PROJECT_ROOT/.aws/config"
  elif ch_fips_enabled; then
    export AWS_USE_FIPS_ENDPOINT=true
  fi
  # Non-empty only once state/deploy-vars.yml exists (render_deploy_vars always
  # creates it, so in practice this is "always" -- the explicit check keeps the
  # intent, "load the override file when there is one", legible at the
  # scripts/play.sh call site).
  if [[ -f "$CH_PROJECT_ROOT/state/deploy-vars.yml" ]]; then
    export CH_EXTRA_VARS="-e @$CH_PROJECT_ROOT/state/deploy-vars.yml"
  else
    export CH_EXTRA_VARS=""
  fi
  # Where ClickHouse publishes its images. You never deploy into this account;
  # you only read from it, then copy images into your own ECR.
  SOURCE_ECR_ACCOUNT="$(ch_var aws.source_ecr_account_id)"
  SOURCE_ECR_REGION="$(ch_var aws.source_ecr_region)"
  SOURCE_ECR_PROFILE="$(ch_var aws.source_ecr_profile)"
  # Your account, where everything actually gets built.
  TARGET_PROFILE="$(ch_var aws.target_profile)"
  CH_INITED=1
}
if [[ -z "${CH_DEFER_INIT:-}" ]]; then ch_init || exit 1; fi
