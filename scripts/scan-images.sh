#!/usr/bin/env bash
#
# Pull every container image this deployment uses into the local Docker
# daemon and scan each one for known vulnerabilities with Grype.
#
#   scripts/scan-images.sh                # the build that fips: selects
#   scripts/scan-images.sh --build both   # standard and FIPS side by side
#   scripts/scan-images.sh --nocve        # add each ClickHouse image's -nocve build
#   scripts/scan-images.sh --no-pull      # rescan what is already pulled
#   scripts/scan-images.sh --only server  # just the images whose repo matches
#
# The image list is the one image sync copies (all_artifacts, charts left
# out), resolved through Ansible exactly as a deploy resolves it, so the
# optional Langfuse and Grafana images are scanned only when they are enabled.
#
# Each image is pulled from your ECR when the tag is mirrored there. A tag
# that is not -- typically the other build's ClickHouse images, or a -nocve
# build -- comes from where image sync would copy it from: ClickHouse's ECR
# for the ClickHouse images, the image's own upstream registry otherwise.
#
# Images are pulled for the architecture they run on: clickhouse-server and
# clickhouse-keeper run on arm64 nodes in the standard build and on x86_64 in
# the FIPS build; everything else runs on the operator node group, which is
# x86_64 in both.
#
# Grype's full JSON report for each image lands in state/scans/<timestamp>/,
# and a summary of findings by severity is printed at the end.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

BUILD=""; NOCVE=false; PULL=true; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)   BUILD="${2:-}"; shift 2 ;;
    --nocve)   NOCVE=true; shift ;;
    --no-pull) PULL=false; shift ;;
    --only)    ONLY="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
if [[ -z "$BUILD" ]]; then
  ch_fips_enabled && BUILD=fips || BUILD=standard
fi
case "$BUILD" in
  standard) BUILDS="standard" ;;
  fips)     BUILDS="fips" ;;
  both)     BUILDS="standard fips" ;;
  *) die "--build takes standard, fips or both, not '$BUILD'" ;;
esac

have docker || die "docker is not installed"
have grype  || die "grype is not installed -- brew install grype"
docker info >/dev/null 2>&1 || die "the Docker daemon is not running"

# --- the image list --------------------------------------------------------
# One Ansible call per build, because fips changes both the tags and the
# target registry hostname. Prints one tab-separated line per image:
#   build  target_ref  fallback_ref  platform
images_for_build() {
  local build="$1" fips_flag out json
  [[ "$build" == fips ]] && fips_flag=true || fips_flag=false
  # CH_EXTRA_VARS is the deploy-vars/flags layer ch_init assembled; -e fips
  # goes last so it wins over both. It is passed as JSON because the
  # key=value form makes "false" a string, which Jinja reads as true.
  # shellcheck disable=SC2086
  out="$(cd "$CH_ROOT/ansible" && \
         ANSIBLE_STDOUT_CALLBACK=minimal ANSIBLE_CALLBACK_RESULT_FORMAT=json \
         ansible localhost $CH_EXTRA_VARS -e "{\"fips\": $fips_flag}" -m ansible.builtin.debug \
           -a 'msg={{ {"target": target_registry, "source": source_registry, "images": (all_artifacts | rejectattr("repo", "match", "helm/") | list)} }}' \
           </dev/null 2>/dev/null)" || die "could not resolve the image list for the $build build with Ansible"
  json="${out#*=> }"
  jq -r --arg build "$build" '
    .msg as $m | $m.images[] |
    (if (.repo == "clickhouse-server" or .repo == "clickhouse-keeper") and $build == "standard"
       then "linux/arm64" else "linux/amd64" end) as $platform |
    [$build,
     "\($m.target)/\(.repo):\(.tag)",
     "\(.source // $m.source)/\(.source_repo // .repo):\(.source_tag // .tag)",
     $platform] | @tsv' <<<"$json"
}

LIST="$(mktemp)"; trap 'rm -f "$LIST"' EXIT
for b in $BUILDS; do images_for_build "$b" >>"$LIST"; done

# -nocve builds exist only in ClickHouse's ECR, for some server and keeper
# versions; a missing one is reported and skipped, not treated as an error.
# They have no mirror ref, so that field holds "-": bash's read collapses
# consecutive tabs, which would shift an empty field into the next column.
if $NOCVE; then
  src_registry="$SOURCE_ECR_ACCOUNT.dkr.ecr.$SOURCE_ECR_REGION.amazonaws.com"
  while IFS=$'\t' read -r build ref fallback platform; do
    case "$fallback" in
      "$src_registry"/clickhouse-server:*|"$src_registry"/clickhouse-keeper:*)
        printf '%s\t-\t%s\t%s\n' "$build" "$fallback-nocve" "$platform" ;;
    esac
  done <"$LIST" >>"$LIST.nocve"
  cat "$LIST.nocve" >>"$LIST"; rm -f "$LIST.nocve"
fi

if [[ -n "$ONLY" ]]; then
  grep -F -- "$ONLY" "$LIST" >"$LIST.only" || die "no image matches --only '$ONLY'"
  mv "$LIST.only" "$LIST"
fi

# --- registry logins -------------------------------------------------------
# Docker keeps these in its own credential store. ECR tokens last 12 hours.
ecr_login() {  # profile region registry
  local token
  token="$(aws ecr get-login-password --profile "$1" --region "$2" 2>/dev/null)" || return 1
  docker login --username AWS --password-stdin "$3" <<<"$token" >/dev/null 2>&1
}

if $PULL; then
  step "Logging in to the registries"
  aws sts get-caller-identity --profile "$TARGET_PROFILE" >/dev/null 2>&1 \
    || die "not authenticated -- $(ch_login_hint "$TARGET_PROFILE")"
  target_hosts="$(cut -f2 "$LIST" | grep -vx -- - | cut -d/ -f1 | sort -u || true)"
  for host in $target_hosts; do
    ecr_login "$TARGET_PROFILE" "$(ch_var aws.target_region)" "$host" \
      && ok "your ECR ($host)" || warn "could not log in to your ECR ($host); every image will come from its source"
  done
  src_host="$SOURCE_ECR_ACCOUNT.dkr.ecr.$SOURCE_ECR_REGION.amazonaws.com"
  ecr_login "$SOURCE_ECR_PROFILE" "$SOURCE_ECR_REGION" "$src_host" \
    && ok "ClickHouse's ECR ($src_host)" || warn "could not log in to ClickHouse's ECR ($src_host)"
fi

# --- pull and scan ---------------------------------------------------------
OUT="$CH_ROOT/state/scans/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.tsv"
printf 'build\timage\tplatform\tcritical\thigh\tmedium\tlow\tother\n' >"$SUMMARY"

# Pull ref for platform; prints nothing and fails when the tag is absent.
pull() {
  [[ "$1" != - ]] || return 1
  if $PULL; then docker pull --quiet --platform "$2" "$1" >/dev/null 2>&1 || return 1
  else docker image inspect "$1" >/dev/null 2>&1 || return 1
  fi
}

step "Pulling and scanning ($(wc -l <"$LIST" | tr -d ' ') images, build: $BUILD)"
while IFS=$'\t' read -r build ref fallback platform; do
  if pull "$ref" "$platform"; then image="$ref"; from="your ECR"
  elif pull "$fallback" "$platform"; then image="$fallback"; from="source"
  else warn "$build: $fallback -- not found in your ECR or at the source, skipped"; continue
  fi
  name="${image##*/}"; report="$OUT/$build-${name//:/_}.json"
  # --platform makes Grype read the image it was pulled for, not whichever
  # architecture the local daemon would default to.
echo $image
  if ! grype "docker:$image" --platform "$platform" -q -o json --file "$report" </dev/null; then
    fail "$build: $name -- grype failed"; continue
  fi
  counts="$(jq -r '[.matches[].vulnerability.severity] as $s |
    [("Critical","High","Medium","Low") as $l | ($s | map(select(. == $l)) | length)]
    + [($s | map(select(. != "Critical" and . != "High" and . != "Medium" and . != "Low")) | length)]
    | @tsv' "$report")"
  printf '%s\t%s\t%s\t%s\n' "$build" "$name" "$platform" "$counts" >>"$SUMMARY"
  ok "$build: $name ($platform, from $from)"
done <"$LIST"

step "Findings by severity"
column -t -s $'\t' "$SUMMARY"
info "full reports: ${OUT#"$CH_ROOT"/}/"
