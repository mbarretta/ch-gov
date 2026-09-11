#!/usr/bin/env bash
#
# Delete THIS cluster's data from the S3 bucket. Deliberate, manual, and asks.
#
#   scripts/s3-purge-cluster-data.sh            # lists, asks, deletes
#   scripts/s3-purge-cluster-data.sh --dry-run  # lists only
#
# Why a script: the cluster's objects are not under one prefix. With the
# chart's default `enableKeyTemplate`, ClickHouse shards keys for S3
# throughput as  ch-s3-<3 hex>/<uuid>/...  -- hundreds of top-level prefixes,
# with the cluster's uuid one level down. `aws s3 rm s3://bucket/ch-s3-<uuid>
# --recursive` therefore deletes nothing and reports success. This script
# selects on the uuid segment and deletes in batches of 1000.
#
# Teardown of the Helm release (`-e cluster_state=absent`) never runs this.
#
set -euo pipefail

CH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CH_ROOT/scripts/lib/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

gv="$CH_ROOT/ansible/group_vars/all.yml"
PREFIX="$(awk -F'"' '/^  s3_key_prefix:/ {print $2; exit}' "$gv")"
UUID="${PREFIX#ch-s3-}"
ACCOUNT="$(awk -F'"' '/^  target_account_id:/ {print $2; exit}' "$gv")"
REGION="$(awk -F'"' '/^  target_region:/ {print $2; exit}' "$gv")"
BUCKET="clickhouse-private-${ACCOUNT}-${REGION}"
[[ -n "$UUID" && -n "$ACCOUNT" ]] || die "could not read s3_key_prefix / target_account_id from $gv"

info "bucket: s3://$BUCKET   cluster uuid: $UUID"
keys="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix ch-s3- \
          --query "Contents[?contains(Key, '/$UUID/')].Key" --output text --profile "$TARGET_PROFILE" \
        | tr '\t' '\n' | grep -v '^None$' || true)"
n="$(printf '%s' "$keys" | grep -c . || true)"
info "$n object(s) belong to this cluster"
((n > 0)) || { ok "nothing to delete"; exit 0; }
printf '%s\n' "$keys" | head -5 | sed 's/^/      /'; ((n > 5)) && info "      ..."
((DRY)) && exit 0

read -r -p "  Delete all $n objects from s3://$BUCKET? Type the uuid to confirm: " ans
[[ "$ans" == "$UUID" ]] || die "aborted"

printf '%s\n' "$keys" | xargs -n 1000 | while read -r batch; do
  json="$(printf '%s\n' $batch | jq -R . | jq -sc '{Objects: map({Key: .}), Quiet: true}')"
  aws s3api delete-objects --bucket "$BUCKET" --delete "$json" --profile "$TARGET_PROFILE" >/dev/null
done
ok "deleted $n objects"
