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

# ---- group_vars flag reader ------------------------------------------------
# Reads a top-level scalar key (e.g. `fips:`) straight out of group_vars/all.yml.
# Shared by render_aws_config below and ch_fips further down: both run before,
# or without, Ansible ever templating anything, so this is the only source.
# Defined ahead of render_aws_config (which runs immediately, at source time,
# before CH_GROUP_VARS further down even exists) so it takes the path
# explicitly rather than assuming that constant.
group_var_flag() {
  awk -F'[: \t]+' "/^$1:/"'{print $2; exit}' "$2"
}

# ---- AWS config bootstrap --------------------------------------------------
# .aws/config is generated from ansible/files/aws-config.ini.j2, not tracked
# directly, so use_fips_endpoint always matches the `fips:` switch. The
# authoritative render happens inside ansible/deploy.yml's pre_tasks
# (tags: [always]), which honors whatever -e fips=... a given run passes.
# This one exists only because scripts/play.sh and scripts/part1-setup.sh both
# check AWS authentication BEFORE Ansible ever starts -- on a fresh checkout
# there is no .aws/config yet for that check to use. Credential-free (plain
# text substitution against the persistent `fips:` default in group_vars),
# and safe to re-run: it only fills in the file when it's missing, so it never
# clobbers a render already produced by an -e fips=... deploy.yml run.
render_aws_config() {
  local out="$CH_PROJECT_ROOT/.aws/config"
  # Skip only when the existing file already carries use_fips_endpoint --
  # not merely when it exists. A checkout cloned before this template
  # existed may still have the old, tracked .aws/config on disk (now
  # gitignored, so nothing else would ever touch it); re-render that one
  # once so the new knob actually takes effect there too.
  [[ -f "$out" ]] && grep -q '^use_fips_endpoint' "$out" && return 0
  local tmpl="$CH_PROJECT_ROOT/ansible/files/aws-config.ini.j2"
  [[ -f "$tmpl" ]] || die "missing $tmpl -- checkout looks incomplete"
  local fips_default use_fips=false
  fips_default="$(group_var_flag fips "$CH_PROJECT_ROOT/ansible/group_vars/all.yml")"
  [[ "$fips_default" == "true" ]] && use_fips=true
  mkdir -p "$(dirname "$out")"
  sed "s/{{ 'true' if fips else 'false' }}/$use_fips/g" "$tmpl" > "$out"
}
render_aws_config
export AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$CH_PROJECT_ROOT/.aws/config}"

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
# Where ClickHouse publishes its images. You never deploy into this account;
# you only read from it, then copy images into your own ECR.
readonly SOURCE_ECR_ACCOUNT="<SOURCE_ECR_ACCOUNT_ID>"
readonly SOURCE_ECR_REGION="us-east-1"
readonly SOURCE_ECR_PROFILE="private-us"

# Your account, where everything actually gets built.
readonly TARGET_PROFILE="sa"

# The three images that make up a ClickHouse Private deployment.
readonly CH_REPOS=(clickhouse-server clickhouse-keeper clickhouse-operator)

# ---- Langfuse (optional Steps 13-15) --------------------------------------
readonly CH_GROUP_VARS="$CH_PROJECT_ROOT/ansible/group_vars/all.yml"

# The certificate the langfuse role generates into state/ when
# langfuse.load_balancer.tls is true and terminates at the langfuse-lb NLB.
# Self-signed, so it is its own CA: `curl --cacert "$LF_TLS_CERT"` trusts it.
readonly LF_TLS_CERT="$CH_PROJECT_ROOT/state/langfuse-tls-cert.pem"

# Prints one value from the langfuse: block of group_vars, e.g.
#   lf_var '  namespace:'      lf_var '    type:'      lf_var '  enabled:'
# The key carries its own indentation, which is what tells "  namespace:"
# under langfuse: apart from the same key under clickhouse:. The block is last
# in all.yml, so the scrape is block-scoped -- match the header first, then
# the key -- and the first-match scrapes of the ClickHouse keys elsewhere are
# unaffected. Quoted values come back without the quotes; bare ones (true,
# 80) as written. Prints nothing when the key is absent.
lf_var() {
  awk -v key="$1" '
    /^langfuse:/ { f = 1 }
    f && index($0, key) == 1 {
      if (split($0, q, "\"") > 2) print q[2]
      else { sub(/^[^:]*:[ \t]*/, ""); print $1 }
      exit
    }' "$CH_GROUP_VARS"
}

# Succeeds when the NLB terminates TLS -- the same effective state the
# langfuse role computes as _lf_tls (Phase 4c): langfuse.load_balancer.tls,
# OR'd with the persistent fips: switch (ch_fips, defined below -- function
# order in this file does not matter, only call order), but never for
# load_balancer.type: none, which has no NLB at all. `    tls:` and
# `    type:` are the only keys at that indentation spelled that way in the
# langfuse: block, so the prefix matches are unambiguous.
lf_tls() {
  [[ "$(lf_var '    type:')" != none ]] || return 1
  [[ "$(lf_var '    tls:')" == true ]] || ch_fips
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

# Prints one value from the grafana: block of group_vars, e.g.
#   gf_var '  namespace:'      gf_var '    type:'      gf_var '  enabled:'
# Same block-scoped first-match rule as lf_var above, anchored on
# /^grafana:/ -- the new last block in all.yml -- instead of /^langfuse:/.
gf_var() {
  awk -v key="$1" '
    /^grafana:/ { f = 1 }
    f && index($0, key) == 1 {
      if (split($0, q, "\"") > 2) print q[2]
      else { sub(/^[^:]*:[ \t]*/, ""); print $1 }
      exit
    }' "$CH_GROUP_VARS"
}

# Succeeds when the NLB terminates TLS -- the same effective state the
# grafana role computes as _gf_tls: grafana.load_balancer.tls, OR'd with the
# persistent fips: switch via the shared ch_fips function (never duplicated
# here), but never for load_balancer.type: none, which has no NLB at all.
gf_tls() {
  [[ "$(gf_var '    type:')" != none ]] || return 1
  [[ "$(gf_var '    tls:')" == true ]] || ch_fips
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

# ---- fips (shared by ch-client.sh's TLS handling) -------------------------
# Succeeds when the persistent fips: switch in group_vars is true.
ch_fips() {
  [[ "$(group_var_flag fips "$CH_GROUP_VARS")" == "true" ]]
}

# The CA clickhouse_cluster generates into state/ when fips is true (see
# ansible/group_vars/all.yml's clickhouse_tls_ca_cert_file) -- a leaf server
# cert signed by it terminates the ClickHouse native/HTTP TLS listeners once
# server.openSSL.required zeroes their plaintext ports (4a-spike findings).
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
# per 4a-spike's findings the chart's TLS surface is CA-chain verification
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
