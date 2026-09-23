# Part 7 — FIPS 140-3 hardening: storage, endpoints, secrets and TLS

The `fips` switch (`ansible/group_vars/all.yml:21`) has existed since Part 2:
flip it and the container images, the target ECR hostname and the node
architecture all move to their FIPS-validated equivalents. What it did not
touch, until this phase, was everything *around* the compute layer: which AWS
API endpoints the deployment's own calls land on, whether anything at rest
carries a customer-controlled key, and whether any of the four network hops
inside the deployment (native ClickHouse, Langfuse-to-ClickHouse, Langfuse's
own load balancer, and AWS API calls) are encrypted at all. This part closes
those four gaps as four sections below, one per phase, still gated by the
same single `fips` boolean — no second switch to remember.

Each section states the risk it closes, the `group_vars` ternary that gates
it, the mechanism in the order it runs, and — because a compliance decision
deserves the caveats as much as the feature — an honest paragraph on what
that mechanism does and does not give you.

**What this part is not.** Every phase below was verified by reading the
actual diff, the actual pulled Helm charts, and the actual CloudFormation
templates — never by running `ansible-playbook`, `aws`, `kubectl`, or `helm
install` against this deployment's live account, per this cycle's own
constraints. A companion live-run document, in the style of
[`docs/part-6-langfuse-live-run.md`](part-6-langfuse-live-run.md), does **not**
exist yet for this phase and was deliberately not created in this cycle —
that pass, exercising `fips: true` end to end against a real cluster, is left
to your own manual post-merge run.

---

## 1. AWS API endpoints

**The risk.** Before this phase, `fips: true` changed which registry the
controller pulled container images from, but every other AWS API call this
project's own automation makes — STS, IAM, EKS, CloudFormation, S3 — still
went to AWS's standard endpoints. A FIPS posture that only covers image pulls
is not a FIPS posture for the control plane.

```yaml
# ansible/group_vars/all.yml -- Derived values block
s3_endpoint: "https://{{ 's3-fips' if fips else 's3' }}.{{ aws.target_region }}.amazonaws.com"
```

and, in the rendered `ansible/files/aws-config.ini.j2` (both `[profile sa]`
and `[profile private-us]`, since AWS SDKs do not inherit
`use_fips_endpoint` through `source_profile`):

```ini
use_fips_endpoint = {{ 'true' if fips else 'false' }}
```

**What the role does, in order:**

1. `scripts/lib/common.sh`'s `render_aws_config()` writes `.aws/config` from
   `ansible/files/aws-config.ini.j2` — credential-free, before any AWS
   authentication happens. This matters because `scripts/play.sh` and
   `scripts/part1-setup.sh` both call `aws sts get-caller-identity` *before*
   Ansible ever starts, so a rendering step that only ran inside Ansible's
   `pre_tasks` would be too late on a fresh checkout with no `.aws/config`
   yet. `render_aws_config()` is idempotent and self-heals a pre-existing
   old-format local file by checking for the `use_fips_endpoint` marker, not
   mere file existence.
2. `ansible/deploy.yml`'s own render task carries `tags: [always]`, so a
   tagged, targeted run (`--tags cluster`, say) still re-renders the file
   rather than silently reusing a stale one.
3. `ansible/deploy.yml`'s run-info report gains a line stating whether AWS
   API endpoints are FIPS or standard for this run.
4. `s3_endpoint` (above) is wired into ClickHouse's own S3 disk client
   configuration in `ansible/roles/clickhouse_cluster/tasks/main.yml`,
   replacing what had been a hardcoded standard-endpoint string.

**What you get, and what you don't.** This closes the endpoint gap for the
*controller's own* AWS calls — everything the `sa` and `private-us` profiles
make (STS, IAM, EKS, CloudFormation, ECR's own token exchange) — and for
ClickHouse's own in-pod S3 client, which authenticates via its pod's IRSA
service-account annotation and now targets `s3_endpoint` explicitly. It does
**not** cover every pod-side AWS call in the deployment. The controller's
`.aws/config` is evidence only for the controller's own process; it says
nothing about what a pod's AWS SDK, running under its own IRSA-issued
credentials with its own SDK configuration (or none), actually routes
through. Concretely, as of this phase:

| Caller | FIPS-routed? | How |
|---|---|---|
| Controller's own AWS CLI/SDK calls (`sa`, `private-us` profiles) | Yes | `use_fips_endpoint` in the rendered `.aws/config` |
| ECR image pulls (`target_registry`) | Yes | Predates this phase — the `-fips` registry hostname |
| ClickHouse's own in-pod S3 client (its native S3-disk backend, its own IRSA) | Yes | `s3_endpoint`, wired into the chart's S3 disk config |
| Langfuse's own in-pod S3 client (its own separate IRSA, for object storage) | **No** | Untouched by this phase — still targets the standard S3 endpoint under `fips: true` |
| Any other pod-side AWS SDK call outside the two paths above | **No**, unless independently configured | No blanket coverage exists |

That Langfuse gap is a real, named limitation, not an oversight to be read
past — see `FIPS.md`. VPC interface endpoints for ECR/STS/CloudWatch (which
would let a fully airgapped posture drop the NAT gateway entirely) remain
out of scope for this phase, as already tracked in
[Part 2](part-2-image-sync.md).

**Checkpoint**

- [x] `use_fips_endpoint` present under both AWS CLI profiles, rendered before any pre-Ansible auth check runs
- [x] Rendering task carries `tags: [always]`; a tagged invocation does not skip it
- [x] `s3_endpoint` wired into ClickHouse's own S3 disk client
- [x] `ansible/deploy.yml`'s run-info report states FIPS vs. standard AWS endpoints
- [ ] Langfuse's own pod-side S3/IRSA client is FIPS-routed — explicit gap, not done in this phase
- [ ] Live confirmation that a `fips: true` run's AWS calls actually land on the FIPS hostnames — deferred to your own manual pass

---

## 2. Customer-managed KMS keys

**The risk.** No KMS resource existed anywhere in this repository before
this phase. Both S3 buckets explicitly disclaimed customer-managed
encryption, and every EBS-backed volume (Keeper's persistent disk today,
Langfuse's Postgres/Valkey volumes if it is enabled) sat behind whatever
default key AWS supplied, with no dedicated key to control or rotate.

```yaml
# storage_iam/tasks/main.yml
encryption: "{{ 'aws:kms' if fips else 'AES256' }}"
encryption_key_id: "{{ clickhouse_bucket_kms_key_arn if fips else omit }}"
```

with an equivalent ternary in `langfuse_storage/tasks/main.yml` for the
Langfuse bucket, and an EBS StorageClass parameter block in
`k8s_prereqs/tasks/main.yml`:

```yaml
storageClass:
  parameters: "{{ {'encrypted': 'true', 'fsType': 'ext4', 'type': 'gp3', 'kmsKeyId': _ebs_kms_key_arn} if fips else {} }}"
```

**What the role does, in order:**

1. Three separate `AWS::KMS::Key` resources are added, one per blast-radius
   boundary the repo already keeps separate: `ClickHouseBucketKmsKey` and
   `EbsKmsKey` in `storage_iam`'s CloudFormation template, and a Langfuse
   bucket key in `langfuse_storage`'s. Each grants account-root admin plus
   the minimum actions its one owning IRSA role needs — bucket roles get
   `kms:Decrypt`/`kms:GenerateDataKey*`/`kms:DescribeKey`; the EBS CSI role
   additionally gets `kms:Encrypt`/`kms:ReEncrypt*` and a separate
   grant-management statement scoped to `kms:GrantIsForAWSResource=true`.
   No key is shared across ClickHouse, Langfuse and EBS.
2. Both `storage_iam` and `langfuse_storage` reorder their tasks so bucket
   creation runs *after* the CloudFormation stack that creates its key,
   since the bucket's `encryption_key_id` now depends on that stack's
   output.
3. Bucket encryption flips to `aws:kms` (backed by the new key) under
   `fips: true`, `AES256` otherwise — unchanged from the pre-phase default.
4. The shared `gp3-encrypted` StorageClass gains `encrypted`/`fsType`/`type`
   plus `kmsKeyId` under `fips: true`, read back from `storage_iam`'s stack
   via `amazon.aws.cloudformation_info` so `--tags prereqs` still works
   standalone. Because **StorageClass parameters are immutable in
   Kubernetes**, the role inspects any existing target StorageClass first:
   matching parameters are an idempotent no-op, but a mismatch fails the
   run clearly, before Helm ever attempts an in-place update — it never
   silently deletes or replaces the class or its PVCs.
5. The two bucket-protecting keys (`ClickHouseBucketKmsKey`,
   `LangfuseBucketKmsKey`) carry `DeletionPolicy: Retain` and
   `UpdateReplacePolicy: Retain`, because the buckets they protect
   deliberately outlive their own IRSA/CloudFormation stack across teardown
   while the stack itself does not. `EbsKmsKey` does **not** carry that
   policy: the EBS volumes it protects are deleted, by design, before the
   storage stack ever is, in this project's teardown order, so nothing
   retained needs recovering.

**What you get, and what you don't.** New objects written to either bucket
under `fips: true` are encrypted with a key you own, can audit, and can
rotate independently per boundary. What this does **not** do is retroactively
re-encrypt anything already sitting in a bucket before the switch flipped —
changing a non-empty bucket's default encryption changes only future `PUT`s;
existing objects keep whatever encryption they were written with. This repo
does not attempt an S3 Batch Operations rewrite to backfill that; it is
explicitly out of scope. If you recreate the IRSA/CloudFormation stack after
a teardown, the retained key's ARN must be read back from the still-standing
key (CloudFormation stack outputs on the deleted stack are gone, so recover
it via `aws kms list-aliases` / `describe-key` against the account, not the
stack), and the newly recreated IRSA role must be re-granted access to it
explicitly — there is no supported path that lets a freshly generated key
silently become the bucket's `encryption_key_id` and still decrypt old
ciphertext; that combination is rejected outright, not attempted.

**Checkpoint**

- [x] Three FIPS-gated KMS keys, one per blast-radius boundary, no sharing
- [x] Bucket creation reordered after its key's stack deploy in both `storage_iam` and `langfuse_storage`
- [x] Bucket encryption ternary (`aws:kms` / `AES256`) wired to the new key
- [x] StorageClass parameters ternary, with an immutable-parameter mismatch guard that fails clearly instead of attempting an update
- [x] `ClickHouseBucketKmsKey`/`LangfuseBucketKmsKey` retained across teardown; `EbsKmsKey` deliberately not, matching teardown order
- [ ] Future-`PUT`s-only limitation: no retroactive re-encryption of pre-existing objects — stated, not fixed, by design
- [ ] Live confirmation of the retained-key recovery runbook against a real torn-down-and-recreated stack — deferred to your own manual pass

---

## 3. EKS Secrets envelope encryption

**The risk, stated correctly.** This is the one phase where the "risk" framing
needs a correction before anything else: an EKS 1.28+ cluster — this
deployment runs 1.36 — already receives envelope encryption of Kubernetes
Secrets in etcd by default, using an AWS-owned key. `fips: false` does **not**
mean Secrets sit unencrypted; it means the key encrypting them is one AWS
owns and you do not control. This phase's actual value is swapping in a
customer-managed key for explicit ownership, policy and lifecycle control —
not "introducing" encryption where none existed.

```yaml
# eks_cluster/tasks/main.yml, in template_parameters
EnableSecretsEncryption: "{{ 'true' if fips else 'false' }}"
```

**What the role does, in order:**

1. `ansible/roles/eks_cluster/files/eks-cluster.yaml` gains an
   `EnableSecretsEncryption` CloudFormation parameter, a matching
   `SecretsEncryptionEnabled` condition, a dedicated `EksSecretsKey` (its own
   key, separate from every Phase 2 key) with a policy granting the
   cluster's own IAM role `kms:Encrypt`/`kms:Decrypt`/`kms:DescribeKey`/
   `kms:CreateGrant` plus account-root admin, an alias, and
   `EncryptionConfig: !If [...]` on the `AWS::EKS::Cluster` resource —
   following the exact `Conditions:`/`!If` idiom this same template already
   uses for `PublicEndpointAccess`/`EndpointPublicAccess`.
2. The role's existing report gains a line describing the intended
   `EncryptionConfig` outcome, read back from the CloudFormation stack's own
   outputs — not a live `aws eks describe-cluster` call, per this cycle's
   constraints; this documents intent against the template's correctness,
   not a live cluster's actual state.
3. An `ansible.builtin.assert` guard requires `-e
   confirm_encryption_config=true` alongside `fips: true` before applying to
   a cluster that **already exists**, mirroring the repo's existing
   `clear_failed_stack`/`allow_open_internet` explicit-confirmation pattern.

**What you get, and what you don't.** `EncryptionConfig` is a **one-way
door**: EKS lets you add it to an existing cluster in place, but once set it
cannot be removed or repointed at a different key without a full teardown
(`-e eks_state=absent`) and recreate. The confirmation guard exists so a
casual `fips: true` re-run never locks this in without you noticing — and it
is required on **every** `fips: true` run against an already-existing
cluster, not only the first transition. That is a deliberately conservative
reading: it means you will type `confirm_encryption_config=true` on every
subsequent FIPS re-run against a cluster that already has the setting, which
is more friction than a one-time confirmation would be. It was kept this way
because a one-time-only confirmation needs a way to remember "already
confirmed" across separate invocations that this project's stateless-run
model does not currently have; revisit it if the friction proves too heavy
operationally.

**Checkpoint**

- [x] `EnableSecretsEncryption` parameter/condition/`EncryptionConfig` `!If`, matching the file's existing idiom
- [x] Dedicated `EksSecretsKey`, distinct from every Phase 2 key
- [x] Report line describing the intended encryption outcome from stack outputs, not a live cluster read
- [x] `confirm_encryption_config` guard, scoped to existing-cluster updates under `fips: true`, required on every such re-run
- [ ] Live confirmation that a real cluster's `describe-cluster` actually reports the customer-managed key — deferred to your own manual pass

---

## 4. In-transit TLS: ClickHouse native, Langfuse-to-ClickHouse, and the Langfuse NLB

**The risk.** Three network hops inside this deployment were cleartext
regardless of `fips`: ClickHouse's own native protocol (port 9000) and
Keeper-to-Keeper traffic, the Langfuse-to-ClickHouse hop (both the one-time
schema migration and every ongoing query), and Langfuse's own load balancer
(which already supported hand-enabled TLS, just not a FIPS-designated policy
or FIPS-sized key). This section covers all three, because they share one CA
and one derived key-size variable.

```yaml
# ansible/group_vars/all.yml -- Derived values block
tls_rsa_bits: "{{ 3072 if fips else 2048 }}"
```

```yaml
# clickhouse_cluster/tasks/main.yml -- both server. and keeper. chart values
openSSL:
  enabled: "{{ fips }}"
  required: "{{ fips }}"
  secret: "{{ clickhouse_tls_secret_name }}"
```

```yaml
# langfuse/tasks/main.yml -- effective TLS state, Phase 4c
_lf_tls: "{{ langfuse.load_balancer.type != 'none' and ((langfuse.load_balancer.tls | bool) or (fips | bool)) }}"
_lf_tls_policy: "{{ 'ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04' if fips else 'ELBSecurityPolicy-TLS13-1-2-2021-06' }}"
```

**What the role does, in order:**

1. **ClickHouse native TLS (Phase 4a).** `clickhouse_cluster` generates a
   self-signed CA and a CA-signed leaf server certificate — reusing the exact
   SAN-check/key-existence idempotency pattern already used for Langfuse's
   NLB certificate — and writes both into a Kubernetes Secret named to match
   the chart's own default. `server.openSSL.*` and `keeper.openSSL.*` are
   set on the chart values under `fips: true`. This was resolved against the
   *real* pulled `onprem-clickhouse-cluster` chart (task 4a-spike), not
   guessed: its TLS surface is **CA-chain verification only** — there is no
   SAN/hostname field anywhere in `server.openSSL`/`keeper.openSSL`'s schema
   to configure, so no leaf reissue is needed when the load-balancer hostname
   changes. `server.openSSL.required: true` zeroes the plaintext
   `http_port`/`tcp_port` for **every** caller, not only the load balancer —
   so `clickhouse_loadbalancer`'s Service ports, health probe, and
   `scripts/ch-client.sh` (both its `--lb` and port-forward paths) all move
   to the secure ports (8443 HTTPS, 9440 native-TLS) under `fips: true`, and
   the old "TLS is not configured in this deployment" message is struck.
   Keeper's own plaintext-listener fate under `openSSL.required` was **not**
   confirmed — that lives in the un-pulled Keeper operator chart, out of
   scope for the spike — so 4a-impl builds against the conservative default
   of assuming Keeper's plaintext port may still be reachable, rather than
   assuming it is gone.
2. **Langfuse-to-ClickHouse (Phase 4b).** With the plaintext ClickHouse ports
   gone under `fips: true`, `langfuse_clickhouse`'s own health-check calls
   and `langfuse`'s migration and runtime connections all move to the secure
   ports and gain the ClickHouse CA, distributed into the Langfuse namespace
   as its own Secret. The chart's own `clickhouse.protocol` helper (read
   directly from the pulled 2.1.0 chart's templates) derives `https://` for
   `CLICKHOUSE_URL` from a `https://`-prefixed `clickhouse.host` value — the
   only way to flip the scheme without a duplicate-name `additionalEnv`
   override, since the chart's own validation rejects overriding
   `CLICKHOUSE_URL` directly while `clickhouse.host` is set. The runtime
   query connection (both web and worker) trusts the CA via
   `NODE_EXTRA_CA_CERTS`, confirmed against the pinned ClickHouse Node
   client's own source to be the trust path it actually consults, with full
   hostname verification intact — the leaf certificate's SAN list already
   covers both the bare `.svc` hostname `langfuse_clickhouse` uses and the
   `.svc.cluster.local` form the migration block uses.
3. **The one real gap this phase cannot close.** The pinned Langfuse app
   image (v4.25.0) has its own bundled schema-migration runner that
   unconditionally appends `skip_verify=true` to the migration connection
   string whenever `CLICKHOUSE_MIGRATION_SSL` is true — confirmed by reading
   that script at its pinned git tag. That setting is not reachable from any
   Helm value, `additionalEnv`, or Ansible setting this role controls. So
   the **one-time schema-migration connection is TLS-encrypted but not
   certificate- or hostname-verified** under `fips: true`; the **ongoing
   runtime query connection is fully CA-and-hostname verified**. Leaving
   `migration.ssl` off entirely was not a viable alternative: with the
   plaintext port gone, migrations would not connect at all, and Langfuse
   could never start.
4. **Langfuse's own NLB (Phase 4c).** The TLS security policy swaps to
   `ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04`, and the self-signed
   certificate's key grows to `tls_rsa_bits` (3072 under `fips: true`). The
   existing idempotency check — SAN match plus key existence — gains a third
   condition: an existing certificate whose RSA key is below 3072 bits is
   regenerated and re-imported even when its SAN still matches; one already
   at or above the required strength is reused untouched. Separately, and
   critically: `langfuse.load_balancer.tls` defaulted to `false` and, before
   this phase, gated *all* NLB TLS setup by itself — so `fips: true` alone
   changed nothing about NLB TLS on a fresh deployment, contradicting the
   plan's single-switch premise. `_lf_tls` (above) is now the effective
   state consumed everywhere the raw `tls` flag used to be read: certificate
   and listener setup, `NEXTAUTH_URL`, and `scripts/lib/common.sh`'s
   `lf_url()`/`lf_cacert()` helpers. `fips: true` now forces NLB TLS on
   whenever `load_balancer.type` is not `none`, even with the legacy `tls`
   flag left `false`; `fips: false` leaves today's `tls`-alone behavior
   completely unchanged; and `load_balancer.type: none` has **no** NLB TLS
   termination regardless of `fips` — there is no NLB for either switch to
   terminate TLS on.

**What you get, and what you don't.** ClickHouse's own native client-server
and Keeper-facing traffic gets CA-chain-verified TLS at a FIPS-140-3-floor
key size; the Langfuse runtime query path gets full CA-and-hostname
verification; Langfuse's NLB gets a FIPS-validated TLS policy and a
3072-bit self-signed certificate whenever it has a load balancer to
terminate on. What you do **not** get: hostname verification on
ClickHouse's own native protocol (the chart's TLS surface never offers it —
CA-chain trust is the whole story there); certificate verification on
Langfuse's one-time schema migration (an upstream limitation in the pinned
app image, not a choice this role makes); a confirmed answer on whether
Keeper's plaintext listener is actually gone under `fips: true` (deferred to
a live-cluster check the spike was out of scope to make); and — named
explicitly, not fixed — the self-signed certificates involved (both
ClickHouse's leaf cert and Langfuse's NLB cert) are generated by the
controller's own OpenSSL build, which this plan does not itself make
FIPS-140-3 validated. Whether that last point matters for your specific
compliance target is a question this repo does not answer for you.

**Update:** the `wget` question above (formerly open deferral `d1`) is now
resolved -- a live pull of the real `-fips` image from source ECR (the
account this deployment already has read access to; no live *cluster* was
touched) found two distinct defects, both fixed. First, this BusyBox `wget`
has no CA-pinning flag at all -- `--ca-certificate` is a hard "unrecognized
option" -- which meant `langfuse_clickhouse`'s auth-check task (the one this
role's `assert` actually gates on, not merely an informational line) would
have failed on every single `fips: true` deploy. Second, `wget`'s TLS backend
unconditionally offers an ML-KEM-768 post-quantum-hybrid key share in its
`ClientHello` that this image's FIPS OpenSSL provider cannot generate,
failing every `wget https://` call regardless of the CA flag. The fix: the
CA now goes into the image's system trust store (real chain-*and*-hostname
verification -- confirmed against a leaf cert with a mismatched-hostname
negative control) instead of the nonexistent flag, and a per-exec
`OPENSSL_CONF` restricts the offered TLS groups to FIPS-approved classical
curves to route around the ML-KEM failure. The load balancer's own
informational probe line gets the same `OPENSSL_CONF` fix but stays on
`--no-check-certificate`, since its leaf cert's SAN list only covers the
in-cluster `.svc` hostnames, not the external LB hostname it connects to.

**Checkpoint**

- [x] ClickHouse native TLS: self-signed CA + leaf cert, `server.openSSL`/`keeper.openSSL` wired per the spike's findings
- [x] `clickhouse_loadbalancer`, `scripts/ch-client.sh`, and every in-pod `clickhouse-client`/`wget` helper downstream of the ordered deployment updated for the secure ports
- [x] Langfuse-to-ClickHouse: CA distributed, secure ports, `NODE_EXTRA_CA_CERTS` runtime verification
- [x] Migration-connection cert-verification gap documented as an upstream limitation, not silently claimed as covered
- [x] Langfuse NLB: FIPS TLS policy, 3072-bit key with a key-size-aware regeneration check, effective `_lf_tls` forcing TLS on under `fips: true` for any non-`none` load-balancer type
- [ ] Keeper's own plaintext-listener behavior under `openSSL.required` — unconfirmed, conservative default in place
- [x] `clickhouse-server`'s bundled `wget` HTTPS support — resolved: no CA-pinning flag exists (CA goes into the system trust store instead) and its TLS backend's default ML-KEM key share fails under the FIPS provider (routed around via a per-exec `OPENSSL_CONF`)
- [ ] Live end-to-end TLS handshake evidence (the kind of transcript in [`docs/part-6-langfuse-live-run.md`](part-6-langfuse-live-run.md)) for all three hops under `fips: true` — deferred to your own manual pass

---

## Where to go next

`FIPS.md`, at the repository root, gives the short version of everything
above for someone deciding whether this posture clears their compliance bar.
This part is the long version, with the mechanism and the caveats attached
to each claim. There is no `docs/part-7-fips-hardening-live-run.md` yet — the
live, end-to-end run against a real `fips: true` cluster that would produce
one is a manual pass you run after merging this work, the same way
[Part 6's live run](part-6-langfuse-live-run.md) followed Part 6 itself.
