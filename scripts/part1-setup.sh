#!/usr/bin/env bash
#
# Part 1: Prerequisites and Environment Setup
# ClickHouse Private on AWS EKS
#
# What this does, in order:
#   1. Installs the seven required CLI tools (idempotent -- skips what's present)
#   2. Reports the helm version (we run v4; guide was written for v3)
#   3. Installs the helm-diff plugin and the four Ansible collections
#   4. Verifies every tool reports a usable version
#   5. Verifies both AWS profiles authenticate
#   6. Proves you can actually reach ClickHouse's source ECR, and reports
#      which image versions really exist there
#
# Usage:
#   ./part1-setup.sh              install what's missing, then verify
#   ./part1-setup.sh --check      verify only; change nothing (safe to re-run)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib/common.sh

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { sed -n '2,26p' "$0" | sed 's/^#\s\?//'; exit 0; }

# ===========================================================================
step "1/6  Required CLI tools"
# ===========================================================================
# Each tool maps to a real job in the deployment:
#   aws      -- talks to AWS; also mints the ECR login token
#   kubectl  -- talks to the Kubernetes API once EKS exists
#   helm     -- installs the ClickHouse operator and cluster as charts
#   skopeo   -- copies images registry->registry WITHOUT a local docker pull;
#               this is the heart of the airgap model
#   jq       -- parses the JSON that aws/kubectl emit
#   python3  -- Ansible's runtime; 3.12+ (ansible-core 2.21 requires it)
#   ansible  -- runs the 14-phase deployment playbook
BREW_PKGS=(awscli kubectl skopeo jq ansible)
MISSING=()
for t in aws kubectl skopeo jq ansible; do have "$t" || MISSING+=("$t"); done
have python3 || MISSING+=(python3)

if ((${#MISSING[@]} == 0)); then
  ok "all base tools already present"
elif ((CHECK_ONLY)); then
  fail "missing: ${MISSING[*]}"; note_problem
else
  have brew || die "Homebrew required: https://brew.sh"
  info "installing: ${BREW_PKGS[*]}"
  brew install "${BREW_PKGS[@]}" >/dev/null 2>&1 || warn "brew install reported errors; verification below is authoritative"
  ok "base tools installed"
fi

# Presence is not enough for Python. ansible-core 2.21 declares
# Requires-Python >=3.12, so check the floor here rather than letting a stale
# python3 fail obscurely inside an Ansible module several steps later.
if have python3; then
  if py_at_least; then
    ok "python3 $(py_version) (floor is ${PY_MIN})"
  else
    fail "python3 is $(py_version); need ${PY_MIN}+ -- run: brew install python@3.14"
    note_problem
  fi
fi

# ===========================================================================
step "2/6  Helm version"
# ===========================================================================
# We run helm v4 by choice. Note the original guide specifies v3.x, and
# Ansible's kubernetes.core helm modules were written against v3 -- so if a
# helm task misbehaves later, version skew is the first thing to check.
# helm@3 is kept installed (keg-only) so you can flip back:
#   brew unlink helm && brew link --overwrite --force helm@3
HELM_V="$(helm version --short 2>/dev/null || echo none)"
case "$HELM_V" in
  v4.*) ok "helm is $HELM_V (guide targets v3; v4 in use by choice)" ;;
  v3.*) ok "helm is $HELM_V" ;;
  none)
    if ((CHECK_ONLY)); then fail "helm not installed"; note_problem
    else brew install helm >/dev/null 2>&1 && ok "helm installed: $(helm version --short)" \
         || { fail "helm install failed"; note_problem; }
    fi ;;
  *)    warn "unrecognized helm version: $HELM_V"; note_problem ;;
esac

# ===========================================================================
step "3/6  helm-diff plugin and Ansible collections"
# ===========================================================================
# helm-diff shows what a helm upgrade WOULD change before it changes it.
# The playbooks use it to stay idempotent -- rerunning a deploy is a no-op
# instead of a surprise.
if helm plugin list 2>/dev/null | grep -q '^diff'; then
  ok "helm-diff present ($(helm plugin list 2>/dev/null | awk '/^diff/{print $2}'))"
elif ((CHECK_ONLY)); then
  fail "helm-diff plugin missing"; note_problem
else
  helm plugin install https://github.com/databus23/helm-diff --verify=false >/dev/null 2>&1 \
    && ok "helm-diff installed" || { fail "helm-diff install failed"; note_problem; }
fi

# These teach Ansible how to speak CloudFormation, EC2, and Kubernetes.
# Without them the playbook fails on its first task with "module not found".
COLLECTIONS=(amazon.aws community.aws kubernetes.core community.general)
MISSING_COLL=()
for c in "${COLLECTIONS[@]}"; do
  ansible-galaxy collection list "$c" 2>/dev/null | grep -qE "^$c " || MISSING_COLL+=("$c")
done
if ((${#MISSING_COLL[@]} == 0)); then
  ok "all 4 Ansible collections present"
elif ((CHECK_ONLY)); then
  fail "missing collections: ${MISSING_COLL[*]}"; note_problem
else
  ansible-galaxy collection install "${MISSING_COLL[@]}" >/dev/null 2>&1 \
    && ok "collections installed" || { fail "collection install failed"; note_problem; }
fi

# ===========================================================================
step "3b/6  Python venv for Ansible AWS and Kubernetes modules"
# ===========================================================================
# Ansible modules import their SDK inside whichever Python runs the module:
# amazon.aws / community.aws need boto3, and kubernetes.core needs the
# `kubernetes` client. Homebrew's Python has neither, and PEP 668 blocks
# pip-installing into it. A project-local venv keeps the repo self-contained;
# ansible/group_vars/all.yml points ansible_python_interpreter at it.
VENV="$(cd .. && pwd)/.venv"
if [[ -x "$VENV/bin/python3" ]] && py_at_least "$VENV/bin/python3" \
   && "$VENV/bin/python3" -c 'import boto3, kubernetes' 2>/dev/null; then
  ok "venv present: python $(py_version "$VENV/bin/python3"), boto3 $("$VENV/bin/python3" -c 'import boto3;print(boto3.__version__)'), kubernetes $("$VENV/bin/python3" -c 'import kubernetes;print(kubernetes.__version__)')"
elif ((CHECK_ONLY)); then
  fail "venv at $VENV is missing, below python ${PY_MIN}, or lacks boto3/kubernetes"; note_problem
else
  # A venv is pinned to the interpreter that built it, so one left over from an
  # older Python has to be rebuilt, not just re-pip'd. --clear does that; the
  # venv is gitignored and created by this script, so discarding it is safe.
  if [[ -x "$VENV/bin/python3" ]] && ! py_at_least "$VENV/bin/python3"; then
    info "existing venv runs python $(py_version "$VENV/bin/python3"); rebuilding on ${PY_MIN}+"
    python3 -m venv --clear "$VENV" >/dev/null 2>&1 || true
  else
    python3 -m venv "$VENV" >/dev/null 2>&1 || true
  fi
  if "$VENV/bin/pip" install -q --upgrade pip boto3 botocore packaging kubernetes >/dev/null 2>&1; then
    ok "venv created with boto3 $("$VENV/bin/python3" -c 'import boto3;print(boto3.__version__)'), kubernetes $("$VENV/bin/python3" -c 'import kubernetes;print(kubernetes.__version__)')"
  else
    fail "could not provision venv at $VENV"; note_problem
  fi
fi

# ===========================================================================
step "4/6  Version report"
# ===========================================================================
# Minimum versions per the guide. We warn rather than hard-fail on drift,
# because "newer than required" is usually fine -- except for helm, handled above.
printf '  %-10s %-28s %s\n' TOOL VERSION REQUIRED
printf '  %-10s %-28s %s\n' ---- ------- --------
vrow() { printf '  %-10s %-28s %s\n' "$1" "${2:-NOT FOUND}" "$3"; }
vrow aws     "$(aws --version 2>&1 | awk '{print $1}')"                      "v2.x"
vrow kubectl "$(kubectl version --client 2>/dev/null | awk '/Client/{print $3}')" "v1.28+"
vrow helm    "$(helm version --short 2>/dev/null)"                           "v3+ (v4 in use)"
vrow skopeo  "$(skopeo --version 2>/dev/null | awk '{print $3}')"            "v1.x"
vrow jq      "$(jq --version 2>/dev/null)"                                   "any"
vrow python3 "$(py_version)"                                                 "${PY_MIN}+"
vrow ansible "$(ansible --version </dev/null 2>/dev/null | head -1 | tr -d '[]' | awk '{print $3}')" "2.21+ (sets py floor)"

# ===========================================================================
step "5/6  AWS profiles"
# ===========================================================================
# Two profiles, because the airgap model spans two accounts:
#   sa          -> your account. Builds VPC/EKS/S3/ECR. Holds your data.
#   private-us  -> an assumed role that can READ ClickHouse's source ECR.
#                  It chains off sa, so `aws sso login` once covers both.
check_profile() {
  local p="$1" desc="$2" arn
  if ! aws configure list-profiles 2>/dev/null | grep -qx "$p"; then
    fail "profile '$p' not defined in ~/.aws/config ($desc)"; note_problem; return 1
  fi
  if arn="$(aws sts get-caller-identity --profile "$p" --query Arn --output text 2>/dev/null)"; then
    ok "$p -> $arn"
  else
    fail "profile '$p' will not authenticate. Run: aws sso login --profile $TARGET_PROFILE"
    note_problem; return 1
  fi
}
check_profile "$TARGET_PROFILE"     "your deployment account" || true
check_profile "$SOURCE_ECR_PROFILE" "cross-account source ECR read" || true

# ===========================================================================
step "6/6  Source ECR reachability and real image versions"
# ===========================================================================
# This is the check the original guide lacks, and the one most likely to bite:
# deploy-config.yaml pins exact image tags, and old tags get purged from the
# source registry over time. A pinned tag that no longer exists fails the
# deployment at the image-sync phase, ~30 minutes in.
if aws ecr get-login-password --profile "$SOURCE_ECR_PROFILE" --region "$SOURCE_ECR_REGION" >/dev/null 2>&1; then
  ok "ECR authorization token obtained"
  info "registry: ${SOURCE_ECR_ACCOUNT}.dkr.ecr.${SOURCE_ECR_REGION}.amazonaws.com"
  for r in "${CH_REPOS[@]}"; do
    latest="$(aws ecr describe-images \
                --registry-id "$SOURCE_ECR_ACCOUNT" --repository-name "$r" \
                --profile "$SOURCE_ECR_PROFILE" --region "$SOURCE_ECR_REGION" \
                --output json 2>/dev/null \
              | jq -r '[.imageDetails[] | select(.imageTags != null)]
                       | sort_by(.imagePushedAt) | reverse
                       | .[0:3][] | "\(.imagePushedAt[0:10])  \(.imageTags | join(" "))"' 2>/dev/null)"
    if [[ -n "$latest" ]]; then
      printf '  %s%s%s\n' "$C_BOLD" "$r" "$C_RESET"
      sed 's/^/      /' <<<"$latest"
    else
      warn "$r: could not list images (no permission, or repo renamed)"; note_problem
    fi
  done
  info "note: -fips / -nocve / -ubi9 suffixes are compliance-hardened variants"
else
  fail "cannot reach source ECR via '$SOURCE_ECR_PROFILE'"
  info "you may not have the cross-account role; contact your ClickHouse rep"
  note_problem
fi

# ===========================================================================
if ((PROBLEMS == 0)); then
  step "Part 1 complete"
  ok "tools installed, both profiles authenticate, source ECR reachable"
  info "next: obtain the deployment repo, then configure deploy-config.yaml"
  exit 0
else
  step "Part 1 finished with $PROBLEMS problem(s)"
  info "re-run with --check after fixing to re-verify"
  exit 1
fi
