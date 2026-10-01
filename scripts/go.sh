#!/usr/bin/env bash
#
# Stand up the whole environment with one command: tools, configuration, AWS
# sign-in, checks, then the deployment itself.
#
#   scripts/go.sh                                  # ClickHouse only
#   scripts/go.sh --langfuse --grafana             # plus the optional add-ons
#   scripts/go.sh --langfuse --sso --sso-domain-prefix acme-ch --sso-only-login
#   scripts/go.sh --fips --size tutorial
#   scripts/go.sh --dry-run --langfuse --grafana   # show the plan; deploy nothing
#
# Components (each has a --no- form that switches it off again):
#   --langfuse            Langfuse on ClickHouse (Steps 13-15)
#   --grafana             Grafana with a ClickHouse datasource (Steps 16-18). Needs a
#                         Docker Hardened Images login: DHI_USERNAME and DHI_TOKEN in
#                         the environment, or dhi.username and dhi.token in
#                         state/deploy-vars.yml
#   --sso                 Amazon Cognito single sign-on (Steps 6b and 11b): ClickHouse
#                         token logins, plus Langfuse sign-in when Langfuse is on.
#                         Needs --sso-domain-prefix the first time
#   --fips                the FIPS build (x86_64, FIPS image tags and AWS endpoints)
#   --size minimal|tutorial   node and pod sizing (default: minimal)
#
# Needed with --sso when Langfuse is also on, because Langfuse sign-up is open while
# Cognito sign-in is enabled. The script stops until you choose one:
#   --sso-only-login              hide Langfuse's email and password form; Cognito is the only way in
#   --sso-allow-password-signup   keep the form, and accept that anyone who can reach
#                                 Langfuse can register with an email and password
#
# Run options:
#   --yes, -y             skip the cost confirmation that scripts/up.sh asks for
#   --skip-images         skip the image copy (already mirrored)
#   --from STEP           start at a step, as in scripts/up.sh --from
#   --dry-run             print the plan and check the inputs, then stop: no installs,
#                         no AWS calls, no flags recorded
#
# What it does, in order:
#   1. installs and checks the tools          (scripts/part1-setup.sh --tools-only)
#   2. records your component flags           (state/deploy-flags.json)
#   3. checks the inputs the components need  (account IDs, DHI login, SSO choices)
#   4. signs in to AWS when you are not       (aws sso login, in sso mode)
#   5. checks both AWS profiles and the source registry (scripts/part1-setup.sh --check)
#   6. builds the stack                       (scripts/up.sh: prints the cost, asks, builds)
#
# Flags are remembered. They are written to state/deploy-flags.json, which is layered
# over state/deploy-vars.yml, so up.sh, down.sh, play.sh and the smoke tests all see
# the same configuration. A component you leave off the command line keeps its current
# setting; --no-langfuse and friends switch one off. Switching a component off only
# changes the configuration -- scripts/down.sh removes what is already deployed. Flags
# are recorded before the input checks run, so a run that a check then stops keeps them.
#
# Your account IDs and SSO portal URL are not flags. They go in state/deploy-vars.yml,
# which the first run creates; the script stops and names the keys that still hold a
# <placeholder>. Anything else in the configuration (the load balancer type, the SSO
# role grants, domain restrictions) is also set there. Every step is idempotent, so
# re-running over an existing stack changes only what differs.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolving the configuration needs Ansible and jq, which step 1 may only just
# install, so common.sh must not do it on source; ch_init runs after step 2.
CH_DEFER_INIT=1
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0; }

# ---- arguments --------------------------------------------------------------
# The component variables stay empty unless a flag sets them, so "not mentioned"
# (keep the current setting) and "explicitly off" stay distinct.
LANGFUSE=""; GRAFANA=""; SSO=""; FIPS=""; SIZE=""
SSO_PREFIX=""; SSO_LOGIN=""
YES=0; SKIP_IMAGES=0; FROM=""; DRY=0

need_val() { [[ -n "${2:-}" && "${2:-}" != -* ]] || die "$1 needs a value (see --help)"; }
while (($#)); do
  case "$1" in
    --langfuse)                   LANGFUSE=true ;;
    --no-langfuse)                LANGFUSE=false ;;
    --grafana)                    GRAFANA=true ;;
    --no-grafana)                 GRAFANA=false ;;
    --sso)                        SSO=true ;;
    --no-sso)                     SSO=false ;;
    --fips)                       FIPS=true ;;
    --no-fips)                    FIPS=false ;;
    --size)                       need_val "$@"; SIZE="$2"; shift ;;
    --sso-domain-prefix)          need_val "$@"; SSO_PREFIX="$2"; shift ;;
    --sso-only-login)             [[ -z "$SSO_LOGIN" || "$SSO_LOGIN" == only ]] || die "--sso-only-login and --sso-allow-password-signup are alternatives; pass one"
                                  SSO_LOGIN=only ;;
    --sso-allow-password-signup)  [[ -z "$SSO_LOGIN" || "$SSO_LOGIN" == signup ]] || die "--sso-only-login and --sso-allow-password-signup are alternatives; pass one"
                                  SSO_LOGIN=signup ;;
    --yes|-y)                     YES=1 ;;
    --skip-images)                SKIP_IMAGES=1 ;;
    --from)                       need_val "$@"; FROM="$2"; shift ;;
    --dry-run)                    DRY=1 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac; shift
done
# The SSO sub-options mean nothing without --sso on this run or already on.
if [[ "$SSO" == false && ( -n "$SSO_PREFIX" || -n "$SSO_LOGIN" ) ]]; then
  die "--sso-domain-prefix and the --sso-*-login options do not combine with --no-sso"
fi

# ---- step 1: tools ----------------------------------------------------------
# A dry run installs nothing: it only reports whether the tools are there.
step "deploy 1/6  Tools"
if ((DRY)); then
  "$CH_ROOT/scripts/part1-setup.sh" --tools-only --check || die "tools are missing; a dry run installs nothing -- run scripts/part1-setup.sh (or scripts/go.sh without --dry-run)"
else
  "$CH_ROOT/scripts/part1-setup.sh" --tools-only || die "the tools are not ready; fix the problems above and re-run"
fi

# ---- step 2: record the component flags -------------------------------------
step "deploy 2/6  Component flags"
if ((DRY)); then
  # Work on a copy so the plan below reflects the flags without recording them.
  flags_tmp="$(mktemp)"
  trap 'rm -f "$flags_tmp"' EXIT
  [[ -s "$CH_FLAGS_FILE" ]] && cat "$CH_FLAGS_FILE" > "$flags_tmp"
  CH_FLAGS_FILE="$flags_tmp"; export CH_FLAGS_FILE
fi

# The flags the stack is already running with, read before this run changes them.
OLD_FIPS=""; HAD_CLUSTER=0
[[ -s "$CH_PROJECT_ROOT/state/kubeconfig" ]] && HAD_CLUSTER=1
if ((HAD_CLUSTER)) && ch_resolve; then OLD_FIPS="$(ch_var fips)"; fi

if [[ -n "$SIZE" ]]; then
  ch_resolve || die "could not read the configuration"
  jq -e --arg s "$SIZE" '.size_profile_names | index($s)' <<<"$CH_VARS_JSON" >/dev/null \
    || die "--size must be one of: $(jq -r '.size_profile_names | join(", ")' <<<"$CH_VARS_JSON")"
fi
if [[ -n "$SSO_PREFIX" ]]; then
  [[ "$SSO_PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && "$SSO_PREFIX" != *aws* && "$SSO_PREFIX" != *amazon* && "$SSO_PREFIX" != *cognito* ]] \
    || die "--sso-domain-prefix must be lowercase letters, digits and hyphens, and must not contain \"aws\", \"amazon\" or \"cognito\""
fi

# Build the patch from only the flags that were given, then deep-merge it over
# what an earlier run recorded (jq's * merges objects key by key and replaces
# everything else).
PATCH='{}'
patch_add() { PATCH="$(jq -c --argjson p "$1" '. * $p' <<<"$PATCH")"; }
[[ -n "$LANGFUSE" ]] && patch_add "{\"langfuse\":{\"enabled\":$LANGFUSE}}"
[[ -n "$GRAFANA"  ]] && patch_add "{\"grafana\":{\"enabled\":$GRAFANA}}"
[[ -n "$FIPS"     ]] && patch_add "{\"fips\":$FIPS}"
[[ -n "$SIZE"     ]] && patch_add "$(jq -nc --arg s "$SIZE" '{size:$s}')"
if [[ "$SSO" == true ]]; then
  # The master switch, ClickHouse token logins, and Langfuse sign-in (which the
  # role only acts on while Langfuse itself is on).
  patch_add '{"sso":{"enabled":true,"langfuse":{"enabled":true},"clickhouse_jwt":{"enabled":true}}}'
elif [[ "$SSO" == false ]]; then
  patch_add '{"sso":{"enabled":false}}'
fi
[[ -n "$SSO_PREFIX" ]] && patch_add "$(jq -nc --arg p "$SSO_PREFIX" '{sso:{cognito:{domain_prefix:$p}}}')"
case "$SSO_LOGIN" in
  only)   patch_add '{"sso":{"langfuse":{"disable_password_login":true,"allow_password_signup":false}}}' ;;
  signup) patch_add '{"sso":{"langfuse":{"disable_password_login":false,"allow_password_signup":true}}}' ;;
esac

if [[ "$PATCH" == '{}' ]]; then
  ok "no component flags on this run; the recorded configuration is unchanged"
else
  current='{}'
  [[ -s "$CH_FLAGS_FILE" ]] && current="$(<"$CH_FLAGS_FILE")"
  jq -e 'type == "object"' <<<"$current" >/dev/null 2>&1 \
    || die "$CH_FLAGS_FILE is not a JSON object; fix or delete it"
  merged="$(jq -S --argjson p "$PATCH" '. * $p' <<<"$current")"
  if ((DRY)); then
    printf '%s\n' "$merged" > "$CH_FLAGS_FILE"
    ok "would record in state/deploy-flags.json: $(jq -c . <<<"$PATCH")"
  else
    mkdir -p "$(dirname "$CH_FLAGS_FILE")"
    (umask 077; printf '%s\n' "$merged" > "$CH_FLAGS_FILE")
    ok "recorded in state/deploy-flags.json: $(jq -c . <<<"$PATCH")"
  fi
fi

# From here on the configuration is final for this run: drop anything resolved
# before the flags were applied, then resolve and activate the auth mode.
CH_VARS_JSON=""
ch_init || exit 1

if [[ -n "$OLD_FIPS" && "$OLD_FIPS" != "$(ch_var fips)" ]]; then
  warn "fips changes from $OLD_FIPS to $(ch_var fips) on a stack that already has a cluster (state/kubeconfig exists)"
  info "it moves the images, node architecture and encryption keys; docs/part-7-fips-hardening.md says what happens to an existing cluster"
fi

# ---- step 3: inputs the chosen components need ------------------------------
step "deploy 3/6  Inputs"
is_true() { [[ "$1" == true ]]; }
placeholder_re='<[^<>]+>'

for key in aws.target_account_id aws.source_ecr_account_id; do
  val="$(ch_var "$key")"
  if [[ -z "$val" || "$val" =~ $placeholder_re ]]; then
    fail "$key is not set (still a <placeholder>)"; note_problem
  fi
done
if [[ "$(ch_auth_mode)" == sso ]]; then
  val="$(ch_var aws.sso_start_url)"
  if [[ -z "$val" || "$val" =~ $placeholder_re ]]; then
    fail "aws.sso_start_url is not set (still a <placeholder>); or set aws.auth_mode: profile to use a profile you already have"; note_problem
  fi
fi
if ((PROBLEMS)); then
  info "edit state/deploy-vars.yml (state/deploy-vars.yml.example explains each key), then re-run this script"
fi

LF_ON="$(lf_var '  enabled:')"; GF_ON="$(gf_var '  enabled:')"; SSO_ON="$(sso_var enabled)"
if is_true "$GF_ON" && [[ "$(ch_var dhi_configured)" != true ]]; then
  fail "Grafana is on but there is no Docker Hardened Images login: set DHI_USERNAME and DHI_TOKEN in the environment, or dhi.username and dhi.token in state/deploy-vars.yml"
  note_problem
fi
if is_true "$SSO_ON"; then
  if [[ -z "$(sso_var cognito.domain_prefix)" ]]; then
    fail "single sign-on is on but sso.cognito.domain_prefix is not set: pass --sso-domain-prefix NAME (unique in the region)"
    note_problem
  fi
  if is_true "$LF_ON" && is_true "$(sso_var langfuse.enabled)" \
     && ! is_true "$(sso_var langfuse.disable_password_login)" && ! is_true "$(sso_var langfuse.allow_password_signup)"; then
    fail "Langfuse sign-in through Cognito opens Langfuse sign-up, so choose: --sso-only-login (Cognito is the only way in) or --sso-allow-password-signup (anyone who can reach Langfuse can register with a password)"
    note_problem
  fi
fi

COMPONENTS="ClickHouse"
is_true "$LF_ON"  && COMPONENTS+=", Langfuse"
is_true "$GF_ON"  && COMPONENTS+=", Grafana"
is_true "$SSO_ON" && COMPONENTS+=", single sign-on (Cognito)"
ok "components:  $COMPONENTS"
ok "build:       $(ch_fips_enabled && echo 'FIPS (x86_64)' || echo 'standard (arm64)'), size $(ch_var size), $(ch_var aws.target_region)"
ok "estimate:    ~\$$(ch_hourly_cost)/hr with the stack up (before the add-ons' load balancers, ~\$0.02/hr each)"
if is_true "$SSO_ON" && is_true "$(sso_var clickhouse_jwt.enabled)" && [[ "$(jq -r '.sso.clickhouse_jwt.role_grants | length' <<<"$CH_VARS_JSON")" == 0 ]]; then
  info "sso.clickhouse_jwt.role_grants is empty, so a token login reaches ClickHouse with no privileges until you add grants in state/deploy-vars.yml"
fi
if is_true "$SSO_ON" && ! is_true "$LF_ON"; then
  info "sso.langfuse.enabled has no effect while Langfuse is off; add --langfuse for Langfuse sign-in"
fi

if ((PROBLEMS)); then
  step "Stopped: $PROBLEMS input problem(s)"
  exit 1
fi
if ((DRY)); then
  step "Dry run complete"
  info "would continue: sign in to AWS if needed, check both profiles and the source registry, then run scripts/up.sh${FROM:+ --from $FROM}$( ((SKIP_IMAGES)) && echo ' --skip-images')"
  info "nothing was installed, recorded or deployed"
  exit 0
fi

# ---- step 4: sign in ---------------------------------------------------------
step "deploy 4/6  AWS sign-in"
if aws sts get-caller-identity --profile "$TARGET_PROFILE" --query Arn --output text >/dev/null 2>&1; then
  ok "already signed in as profile $TARGET_PROFILE"
elif [[ "$(ch_auth_mode)" == sso ]]; then
  info "opening the IAM Identity Center sign-in in your browser"
  aws sso login --profile "$TARGET_PROFILE" || die "aws sso login did not complete -- re-run this script when you are ready to sign in"
  aws sts get-caller-identity --profile "$TARGET_PROFILE" --query Arn --output text >/dev/null 2>&1 \
    || die "signed in, but profile $TARGET_PROFILE still will not authenticate -- check aws.sso_role_name and aws.target_account_id"
  ok "signed in as profile $TARGET_PROFILE"
else
  die "profile '$TARGET_PROFILE' will not authenticate: $(ch_login_hint "$TARGET_PROFILE"), then re-run this script"
fi

# ---- step 5: profiles and registry ------------------------------------------
step "deploy 5/6  Profiles and source registry"
"$CH_ROOT/scripts/part1-setup.sh" --check || die "the checks above failed; fix them and re-run this script"

# ---- step 6: build ----------------------------------------------------------
step "deploy 6/6  Deploy"
UP_ARGS=()
((YES))         && UP_ARGS+=(--yes)
((SKIP_IMAGES)) && UP_ARGS+=(--skip-images)
[[ -n "$FROM" ]] && UP_ARGS+=(--from "$FROM")
exec "$CH_ROOT/scripts/up.sh" ${UP_ARGS[@]+"${UP_ARGS[@]}"}
