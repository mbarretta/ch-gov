#!/usr/bin/env bash
# Activate this project's AWS configuration in your current shell:
#
#     source scripts/env.sh
#
# Everything AWS-related for this project lives in the repo, not in ~/.aws,
# so the whole setup moves as one directory. The one exception is the SSO
# token cache: the AWS CLI hardcodes ~/.aws/sso/cache and offers no env var
# to relocate it. That's only a short-lived token -- `aws sso login`
# regenerates it -- so nothing you need to carry.

_ch_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Resolved in a bash subshell (common.sh is bash-only; this file is also
# sourced from zsh): the auth mode, the deployment profile, whether fips is on,
# and the mode-appropriate login hint, from state/deploy-vars.yml over
# ansible/group_vars/all.yml. Any problem resolving is printed by common.sh on
# stderr.
_ch_vals="$(bash -c '
  source "$1" >&2 || exit 1
  printf "%s\t%s\t%s\t%s\n" "$(ch_auth_mode)" "$(ch_var aws.target_profile)" "$(ch_fips_enabled && echo true || echo false)" "$(ch_login_hint)"
' _ "${_ch_root}/scripts/lib/common.sh")" || { unset _ch_root _ch_vals; return 1 2>/dev/null || exit 1; }
IFS=$'\t' read -r _ch_mode _ch_profile _ch_fips _ch_hint <<< "$_ch_vals"

# aws.auth_mode: sso always points AWS_CONFIG_FILE at the repo's .aws/config,
# replacing any value already set. profile mode leaves AWS_CONFIG_FILE
# untouched (yours, or the AWS CLI default) and, with no rendered config to
# carry use_fips_endpoint, exports AWS_USE_FIPS_ENDPOINT when fips is on.
if [[ "$_ch_mode" == sso ]]; then
  export AWS_CONFIG_FILE="${_ch_root}/.aws/config"
elif [[ "$_ch_fips" == true ]]; then
  export AWS_USE_FIPS_ENDPOINT=true
fi

# Default to the deployment account so bare `aws ...` calls do the right thing.
# Override per-command with --profile <aws.source_ecr_profile> when reading
# the source ECR.
export AWS_PROFILE="$_ch_profile"

# Same reasoning: never touch ~/.kube/config, which may hold unrelated
# clusters. Written by the eks_cluster role.
export KUBECONFIG="${_ch_root}/state/kubeconfig"

# Homebrew tools must be reachable even in a non-login shell.
[[ ":$PATH:" == *":/opt/homebrew/bin:"* ]] || export PATH="/opt/homebrew/bin:$PATH"

printf 'AWS_CONFIG_FILE=%s\nAWS_PROFILE=%s\nKUBECONFIG=%s\n' "${AWS_CONFIG_FILE:-(AWS CLI default)}" "$AWS_PROFILE" "$KUBECONFIG"
if command -v aws >/dev/null 2>&1; then
  if arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    printf 'identity: %s\n' "$arn"
  else
    printf 'not logged in -- %s\n' "$_ch_hint"
  fi
fi
unset _ch_root _ch_vals _ch_mode _ch_profile _ch_fips _ch_hint
