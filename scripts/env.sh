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

export AWS_CONFIG_FILE="${_ch_root}/.aws/config"

# Default to the deployment account so bare `aws ...` calls do the right thing.
# Override per-command with --profile private-us when reading the source ECR.
export AWS_PROFILE="sa"

# Same reasoning: never touch ~/.kube/config, which may hold unrelated
# clusters. Written by the eks_cluster role.
export KUBECONFIG="${_ch_root}/state/kubeconfig"

# Homebrew tools must be reachable even in a non-login shell.
[[ ":$PATH:" == *":/opt/homebrew/bin:"* ]] || export PATH="/opt/homebrew/bin:$PATH"

printf 'AWS_CONFIG_FILE=%s\nAWS_PROFILE=%s\nKUBECONFIG=%s\n' "$AWS_CONFIG_FILE" "$AWS_PROFILE" "$KUBECONFIG"
if command -v aws >/dev/null 2>&1; then
  if arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    printf 'identity: %s\n' "$arn"
  else
    printf 'not logged in -- run: aws sso login --profile %s\n' "$AWS_PROFILE"
  fi
fi
unset _ch_root
