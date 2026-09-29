# Part 7 — FIPS 140-3 hardening: storage, endpoints, secrets and TLS

> **What you'll learn**
>
> - What the single `fips` switch changes beyond images and instance types: AWS endpoints, encryption keys, and TLS between components.
> - Why each mechanism is built the way it is, and what it does and does not give you.
> - How to check each claim on your own cluster.

The `fips` switch (`fips:` in `ansible/group_vars/all.yml`) has existed since Part 2. Flip it and the container images, the target ECR hostname, and the node architecture all move to their FIPS equivalents. On its own that covers the compute layer only. FIPS mode also has to decide which AWS API endpoints the deployment's own calls land on, whether anything at rest carries a customer-controlled key, and whether the network hops inside the deployment (native ClickHouse, Langfuse to ClickHouse, Langfuse's own load balancer, and AWS API calls) are encrypted. This part covers those four areas as four sections below, all gated by the same single `fips` boolean, with no second switch to remember.

Each section states the risk it closes, the `group_vars` ternary that gates it, the mechanism in the order it runs, and an honest paragraph on what that mechanism does and does not give you, because a compliance decision deserves the caveats as much as the feature. Each section ends with a self-check you can run on your own cluster.

**What has and has not been verified.** Every mechanism below was derived from the code, the pulled Helm charts, and the CloudFormation templates in this repository. It has not been confirmed by running the full deployment with `fips: true` against a real cluster, so the self-checks are yours to run. [Learning setup vs. production](limitations.md) collects the same boundaries in one place, and [FIPS.md](../FIPS.md) is the one-page summary.

To turn the switch on, set `fips: true` in `state/deploy-vars.yml` (or in `ansible/group_vars/all.yml`) before you run `scripts/up.sh`. The self-checks assume you have run `source scripts/env.sh` so that `kubectl` and the AWS CLI point at this project.

---

## 1. AWS API endpoints

**The risk.** `fips: true` changes which registry the controller pulls container images from, but every other AWS API call this project's automation makes (STS, IAM, EKS, CloudFormation, S3) would still go to AWS's standard endpoints. A FIPS posture that covers only image pulls is not a FIPS posture for the control plane.

```yaml
# ansible/group_vars/all.yml -- Derived values block
s3_endpoint: "https://{{ 's3-fips' if fips else 's3' }}.{{ aws.target_region }}.amazonaws.com"
```

How the AWS CLI and SDK learn to use FIPS endpoints depends on `aws.auth_mode`. In `sso` mode the kit renders `ansible/files/aws-config.ini.j2` into `.aws/config`, and both profiles (`aws.target_profile` and `aws.source_ecr_profile`) carry the setting, because AWS SDKs do not inherit `use_fips_endpoint` through `source_profile`:

```ini
use_fips_endpoint = {{ 'true' if fips else 'false' }}
```

In `profile` mode nothing is rendered, because the kit uses your own AWS configuration. The scripts and the playbook export `AWS_USE_FIPS_ENDPOINT=true` instead.

**What the role does, in order:**

1. In `sso` mode, `scripts/lib/common.sh`'s `render_aws_config()` writes `.aws/config` from the template, without credentials, before any AWS authentication happens. This matters because `scripts/play.sh` and `scripts/part1-setup.sh` both call `aws sts get-caller-identity` before Ansible ever starts, so a rendering step that ran only inside Ansible's `pre_tasks` would be too late on a fresh checkout with no `.aws/config` yet. `render_aws_config()` is idempotent: it writes only when the file is missing or differs from the template apart from the `use_fips_endpoint` lines, so it never fights the playbook's own render in the next step, which is the authoritative one that applies the current `fips` value.
2. `ansible/deploy.yml`'s own render task carries `tags: [always]`, so a tagged, targeted run (`--tags cluster`, say) still re-renders the file instead of silently reusing a stale one. In `profile` mode the playbook sets `AWS_USE_FIPS_ENDPOINT` in its `environment:` instead.
3. `ansible/deploy.yml`'s run-info banner includes a line stating whether AWS API endpoints are FIPS or standard for this run.
4. `s3_endpoint` (above) is wired into ClickHouse's own S3 disk client configuration in `ansible/roles/clickhouse_cluster/tasks/main.yml`, in place of a hardcoded standard-endpoint string.

**What you get, and what you don't.** This closes the endpoint gap for the controller's own AWS calls, which are everything the two profiles make (STS, IAM, EKS, CloudFormation, and ECR's own token exchange), and for ClickHouse's own in-pod S3 client, which authenticates through its pod's IAM-role-for-service-accounts (IRSA) annotation and targets `s3_endpoint` explicitly. It does **not** cover every pod-side AWS call in the deployment. The controller's AWS configuration is evidence only for the controller's own process. It says nothing about what a pod's AWS SDK, running under its own IRSA-issued credentials with its own SDK configuration (or none), routes through. In concrete terms:

| Caller | FIPS-routed? | How |
|---|---|---|
| Controller's own AWS CLI and SDK calls (both profiles) | Yes | `use_fips_endpoint` in the rendered `.aws/config`, or `AWS_USE_FIPS_ENDPOINT` in `profile` mode |
| ECR image pulls (`target_registry`) | Yes | The `-fips` registry hostname |
| ClickHouse's own in-pod S3 client (its native S3-disk backend, with its own IRSA) | Yes | `s3_endpoint`, wired into the chart's S3 disk config |
| Langfuse's own in-pod S3 client (its own separate IRSA, for object storage) | **No** | Not wired. It still targets the standard S3 endpoint under `fips: true` |
| Any other pod-side AWS SDK call outside the two paths above | **No**, unless independently configured | No blanket coverage exists |

The Langfuse gap is a real, named limitation, not an oversight to read past. See [FIPS.md](../FIPS.md). VPC interface endpoints for ECR, STS, and CloudWatch, which would let a fully airgapped posture drop the NAT gateway entirely, are outside what the kit builds. See [Learning setup vs. production](limitations.md).

**Self-check**

Run each command and compare it with what you should see.

```bash
grep use_fips_endpoint .aws/config     # sso mode: "use_fips_endpoint = true", once per profile
echo "$AWS_USE_FIPS_ENDPOINT"          # profile mode: "true" (after source scripts/env.sh)
grep -n -A7 'Render AWS CLI config' ansible/deploy.yml                                # the render task carries tags: [always]
grep -n 's3_endpoint' ansible/roles/clickhouse_cluster/tasks/main.yml                   # the S3 disk endpoint uses it
```

Start any `scripts/play.sh` run and read the opening banner. It should include `aws api endpoints: FIPS-validated (use_fips_endpoint)`.

Two checks are still yours to make, because nothing has run them against a real cluster:

- Confirm that the endpoint hostnames your calls reach are FIPS ones. Run `aws sts get-caller-identity --debug 2>&1 | grep -i fips` and look for an `sts-fips` hostname.
- Confirm the Langfuse gap for yourself. Langfuse's pods use the standard S3 endpoint, which is the expected result under `fips: true`.

---

## 2. Customer-managed KMS keys

**The risk.** Without this section, both S3 buckets use S3-managed encryption, and every EBS-backed volume (Keeper's persistent disk, plus Langfuse's PostgreSQL and Valkey volumes if Langfuse is enabled) sits behind whatever default key AWS supplies, with no dedicated key to control or rotate.

```yaml
# storage_iam/tasks/main.yml
encryption: "{{ 'aws:kms' if fips else 'AES256' }}"
encryption_key_id: "{{ clickhouse_bucket_kms_key_arn if fips else omit }}"
bucket_key_enabled: "{{ true if fips else omit }}"
```

`langfuse_storage/tasks/main.yml` carries an equivalent ternary for the Langfuse bucket, and `k8s_prereqs/tasks/main.yml` carries an EBS StorageClass parameter block:

```yaml
storageClass:
  parameters: "{{ {'encrypted': 'true', 'fsType': 'ext4', 'type': 'gp3', 'kmsKeyId': _ebs_kms_key_arn} if fips else {} }}"
```

**What the role does, in order:**

1. Three separate `AWS::KMS::Key` resources exist, one per blast-radius boundary the repo already keeps separate: `ClickHouseBucketKmsKey` and `EbsKmsKey` in `storage_iam`'s CloudFormation template, and a Langfuse bucket key in `langfuse_storage`'s. Each grants account-root admin plus the minimum actions its one owning IRSA role needs. Bucket roles get `kms:Decrypt`, `kms:GenerateDataKey*`, and `kms:DescribeKey`. The EBS CSI role additionally gets `kms:Encrypt` and `kms:ReEncrypt*`, and a separate grant-management statement scoped to `kms:GrantIsForAWSResource=true`. No key is shared across ClickHouse, Langfuse, and EBS.
2. Both `storage_iam` and `langfuse_storage` create the bucket *after* the CloudFormation stack that creates its key, because the bucket's `encryption_key_id` depends on that stack's output.
3. Bucket encryption is `aws:kms` (backed by the new key) under `fips: true` and `AES256` otherwise. Under `fips: true` the S3 Bucket Key is also enabled, so S3 uses a bucket-level data key instead of calling KMS for every object. Without it, each ClickHouse GET and PUT would be a billed KMS request, and ClickHouse makes a lot of them.
4. The shared `gp3-encrypted` StorageClass gets `encrypted`, `fsType`, and `type` plus `kmsKeyId` under `fips: true`. The key ARN is read back from `storage_iam`'s stack with `amazon.aws.cloudformation_info`, so `--tags prereqs` still works standalone. Because **StorageClass parameters are immutable in Kubernetes**, the role inspects any existing target StorageClass first. Matching parameters are an idempotent no-op, but a mismatch fails the run clearly, before Helm ever attempts an in-place update. The role never silently deletes or replaces the class or its PVCs.
5. The two bucket-protecting keys (`ClickHouseBucketKmsKey` and `LangfuseBucketKmsKey`) carry `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`, because the buckets they protect deliberately outlive their own IRSA CloudFormation stack across teardown while the stack itself does not. `EbsKmsKey` does **not** carry that policy. The EBS volumes it protects are deleted, by design, before the storage stack ever is, in this project's teardown order, so nothing retained needs recovering.

**What you get, and what you don't.** New objects written to either bucket under `fips: true` are encrypted with a key you own, can audit, and can rotate independently per boundary. This does **not** re-encrypt anything already in a bucket before the switch flipped. Changing a non-empty bucket's default encryption changes only future `PUT` requests, and existing objects keep whatever encryption they were written with. The kit does not attempt an S3 Batch Operations rewrite to backfill them.

If you recreate the IRSA CloudFormation stack after a teardown, you have to recover the retained key's ARN from the still-standing key, because CloudFormation outputs on the deleted stack are gone. Use `aws kms list-aliases` and `aws kms describe-key` against the account, not the stack. You then have to grant the newly recreated IRSA role access to that key explicitly. No supported path lets a freshly generated key silently become the bucket's `encryption_key_id` and still decrypt old ciphertext. That combination is rejected outright, not attempted.

**Self-check**

```bash
aws cloudformation describe-stack-resources --stack-name clickhouse-private-irsa \
  --query "StackResources[?ResourceType=='AWS::KMS::Key'].LogicalResourceId"   # ClickHouseBucketKmsKey and EbsKmsKey
aws s3api get-bucket-encryption --bucket "clickhouse-private-<account>-<region>"   # aws:kms, a key ARN, BucketKeyEnabled true
kubectl get storageclass gp3-encrypted -o jsonpath='{.parameters}'                 # includes encrypted, type, fsType, and kmsKeyId
aws kms describe-key --key-id alias/clickhouse-private-clickhouse-bucket           # the retained bucket key resolves by alias
grep -n 'Retain\|KmsKey:' ansible/roles/storage_iam/templates/irsa-roles.yaml.j2    # Retain on the bucket key and its alias; none on EbsKmsKey
```

If Langfuse is on, repeat the bucket check for `langfuse-<account>-<region>` and the key check for `alias/clickhouse-private-langfuse-bucket`.

To see the immutable-parameter guard work, run `scripts/play.sh --tags prereqs` against a cluster whose `gp3-encrypted` class was created without a key. The run stops with a message naming the mismatched parameters instead of changing the class.

Two items are yours to confirm on a real cluster:

- The retained-key recovery procedure above, on a torn-down-and-recreated stack.
- That objects written before you enabled `fips: true` keep their old encryption. Check one with `aws s3api head-object` and read `ServerSideEncryption`.

---

## 3. EKS Secrets envelope encryption

**The risk, stated correctly.** This is the one section where the "risk" needs a correction before anything else. An EKS 1.28 or later cluster (this kit deploys 1.36) already receives envelope encryption of Kubernetes Secrets in etcd by default, using an AWS-owned key. `fips: false` does **not** mean Secrets sit unencrypted. It means the key encrypting them is one AWS owns and you do not control. This section's actual value is swapping in a customer-managed key for explicit ownership, policy, and lifecycle control, not introducing encryption where none existed.

```yaml
# eks_cluster/tasks/main.yml, in template_parameters
EnableSecretsEncryption: "{{ 'true' if fips else 'false' }}"
```

**What the role does, in order:**

1. `ansible/roles/eks_cluster/files/eks-cluster.yaml` has an `EnableSecretsEncryption` CloudFormation parameter, a matching `SecretsEncryptionEnabled` condition, and a dedicated `EksSecretsKey`. That key is separate from every key in section 2, and its policy grants the cluster's own IAM role `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey`, and `kms:CreateGrant` plus account-root admin. The template also defines an alias and sets `EncryptionConfig: !If [...]` on the `AWS::EKS::Cluster` resource, following the `Conditions:` and `!If` idiom the same template already uses for `PublicEndpointAccess` and `EndpointPublicAccess`.
2. The role's report includes a line describing the intended `EncryptionConfig` outcome, read back from the CloudFormation stack's own outputs rather than from a live `aws eks describe-cluster` call. It documents intent against the template, not a live cluster's actual state.
3. An `ansible.builtin.assert` guard requires `-e confirm_encryption_config=true` alongside `fips: true` before applying to a cluster that **already exists**, mirroring the repo's existing `clear_failed_stack` and `allow_open_internet` explicit-confirmation pattern.

**What you get, and what you don't.** `EncryptionConfig` is a **one-way door**. EKS lets you add it to an existing cluster in place, but once it is set you cannot remove it or repoint it at a different key without a full teardown (`-e eks_state=absent`) and recreate. The confirmation guard exists so that a casual `fips: true` re-run never locks this in without you noticing. It is required on **every** `fips: true` run against an already-existing cluster, not only the first transition. That is deliberately conservative: you type `confirm_encryption_config=true` on every later FIPS re-run against a cluster that already has the setting, which is more friction than a one-time confirmation. A one-time confirmation would need a way to remember "already confirmed" across separate invocations, and this project's stateless-run model has no such mechanism.

**Self-check**

```bash
aws eks describe-cluster --name clickhouse-private-eks --query cluster.encryptionConfig   # "secrets" and a customer-managed key ARN
aws kms describe-key --key-id alias/clickhouse-private-eks-secrets                        # the key exists and is enabled
```

On an existing cluster, run `scripts/play.sh --tags eks` with `fips: true` and without `-e confirm_encryption_config=true`. It stops at the guard and explains the one-way door.

On a real cluster, confirm that `describe-cluster` reports the customer-managed key, as in the first command above. The template-derived report line in the role's output is intent, not proof.

---

## 4. In-transit TLS: ClickHouse native, Langfuse to ClickHouse, and the Langfuse NLB

**The risk.** Three network hops inside this deployment would be cleartext regardless of `fips`: ClickHouse's own native protocol (port 9000) and Keeper-to-Keeper traffic, the Langfuse-to-ClickHouse hop (both the one-time schema migration and every ongoing query), and Langfuse's own load balancer (which supports hand-enabled TLS, but not a FIPS-designated policy or a FIPS-sized key). This section covers all three, because they share one CA and one derived key-size variable. Grafana's load balancer follows the same rule as Langfuse's. See [Part 8](part-8-grafana.md).

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
# langfuse/tasks/main.yml -- effective TLS state
_lf_tls: "{{ langfuse.load_balancer.type != 'none' and ((langfuse.load_balancer.tls | bool) or (fips | bool)) }}"
_lf_tls_policy: "{{ 'ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04' if fips else 'ELBSecurityPolicy-TLS13-1-2-2021-06' }}"
```

**What the role does, in order:**

1. **ClickHouse native TLS.** `clickhouse_cluster` generates a self-signed CA and a CA-signed leaf server certificate. It reuses the SAN-check and key-existence idempotency pattern that Langfuse's NLB certificate already uses, and it writes both into a Kubernetes Secret named to match the chart's own default. `server.openSSL.*` and `keeper.openSSL.*` are set on the chart values under `fips: true`.

   This was resolved against the real pulled `onprem-clickhouse-cluster` chart rather than guessed. Its TLS surface is **CA-chain verification only**: no SAN or hostname field exists anywhere in the schema of `server.openSSL` or `keeper.openSSL`, so no leaf reissue is needed when the load-balancer hostname changes.

   `server.openSSL.required: true` zeroes the plaintext `http_port` and `tcp_port` for **every** caller, not only the load balancer. So `clickhouse_loadbalancer`'s Service ports and health probe, and `scripts/ch-client.sh` (both its `--lb` and port-forward paths), all move to the secure ports (8443 HTTPS and 9440 native TLS) under `fips: true`.

   What happens to Keeper's own plaintext listener under `openSSL.required` is **not** confirmed. That behavior lives in the Keeper operator chart, which the kit does not vendor or inspect, so the kit assumes the conservative default that Keeper's plaintext port may still be reachable, rather than assuming it is gone.
2. **Langfuse to ClickHouse.** With the plaintext ClickHouse ports gone under `fips: true`, `langfuse_clickhouse`'s health-check calls and `langfuse`'s migration and runtime connections all move to the secure ports and gain the ClickHouse CA, which is distributed into the Langfuse namespace as its own Secret (`langfuse-clickhouse-ca`).

   The chart's own `clickhouse.protocol` helper (read from the pulled 2.1.0 chart's templates) derives `https://` for `CLICKHOUSE_URL` from a `https://`-prefixed `clickhouse.host` value. That is the only way to flip the scheme without a duplicate-name `additionalEnv` override, because the chart's own validation rejects overriding `CLICKHOUSE_URL` directly while `clickhouse.host` is set.

   The runtime query connection (both web and worker) trusts the CA through `NODE_EXTRA_CA_CERTS`, which is the trust path the pinned ClickHouse Node client's source consults. Full hostname verification stays on: the leaf certificate's SAN list covers both the bare `.svc` hostname `langfuse_clickhouse` uses and the `.svc.cluster.local` form the migration block uses.
3. **The one real gap this section cannot close.** The pinned Langfuse application image (v4.25.0) has a bundled schema-migration runner that unconditionally appends `skip_verify=true` to the migration connection string whenever `CLICKHOUSE_MIGRATION_SSL` is true. This is visible in that script at its pinned git tag. No Helm value, `additionalEnv`, or Ansible setting this role controls can reach that setting. So under `fips: true`, the **one-time schema-migration connection is TLS-encrypted but not certificate- or hostname-verified**, while the **ongoing runtime query connection is fully CA-and-hostname verified**. Leaving `migration.ssl` off entirely is not a viable alternative: with the plaintext port gone, migrations would not connect at all, and Langfuse could never start.
4. **Langfuse's own NLB.** The TLS security policy becomes `ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04`, and the self-signed certificate's key grows to `tls_rsa_bits` (3072 under `fips: true`). The certificate's idempotency check (SAN match plus key existence) includes a third condition: an existing certificate whose RSA key is below 3072 bits is regenerated and re-imported even when its SAN still matches, while one already at or above the required strength is reused untouched.

   `langfuse.load_balancer.tls` defaults to `false` and, on its own, gates all NLB TLS setup. Without a rule to the contrary, `fips: true` alone would change nothing about NLB TLS on a fresh deployment, which would break the single-switch design. `_lf_tls` (above) is therefore the effective state, consumed everywhere the raw `tls` flag would otherwise be read: certificate and listener setup, `NEXTAUTH_URL`, and `scripts/lib/common.sh`'s `lf_url()` and `lf_cacert()` helpers. `fips: true` forces NLB TLS on whenever `load_balancer.type` is not `none`, even with the `tls` flag left `false`. `fips: false` leaves the `tls`-alone behavior unchanged. And `load_balancer.type: none` has **no** NLB TLS termination regardless of `fips`, because there is no NLB for either switch to terminate TLS on.

**What you get, and what you don't.** ClickHouse's native client-server and Keeper-facing traffic gets CA-chain-verified TLS at a FIPS 140-3 floor key size. The Langfuse runtime query path gets full CA-and-hostname verification. Langfuse's NLB gets a FIPS TLS policy and a 3072-bit self-signed certificate whenever it has a load balancer to terminate on.

What you do **not** get:

- Hostname verification on ClickHouse's own native protocol. The chart's TLS surface never offers it, so CA-chain trust is the whole story.
- Certificate verification on Langfuse's one-time schema migration. This is an upstream limitation in the pinned application image, not a choice this role makes.
- A confirmed answer on whether Keeper's plaintext listener is gone under `fips: true`. That needs a check against a running cluster.
- A FIPS-validated certificate source. Both ClickHouse's leaf certificate and Langfuse's NLB certificate are self-signed and generated by the controller's own OpenSSL build, which this kit does not itself validate. Whether that matters for your compliance target is a question this repo does not answer for you.

### In-pod HTTPS checks with the bundled `wget`

Several helper tasks run inside the ClickHouse image and use its BusyBox `wget` to probe the secure HTTP port. Under `fips: true` two properties of that `wget` matter:

- **It has no CA-pinning flag.** `--ca-certificate` is an unrecognized option. The auth-check task in `langfuse_clickhouse` (which the role's `assert` gates on) therefore cannot pass the CA on the command line. Instead, the CA goes into the image's system trust store, which gives real chain-and-hostname verification. A leaf certificate with a mismatched hostname is rejected.
- **Its TLS backend offers a post-quantum key share the FIPS provider cannot generate.** By default it sends an ML-KEM-768 hybrid key share in its `ClientHello`, and the image's FIPS OpenSSL provider cannot generate it, so every `wget https://` call fails regardless of the CA. A per-exec `OPENSSL_CONF` restricts the offered TLS groups to FIPS-approved classical curves (`X25519`, `P-256`, and `P-384`), which routes around the failure.

The load balancer's informational probe line uses the same `OPENSSL_CONF` fix but stays on `--no-check-certificate`. Its leaf certificate's SAN list covers only the in-cluster `.svc` hostnames, not the external load-balancer hostname it connects to.

**Self-check**

```bash
scripts/ch-client.sh -q "SELECT 1"                                                       # 1, over 9440 with the CA checked
kubectl -n ns-default-us-01 get secret default-us-01-server-cert-secret                   # the CA and leaf certificate Secret exists
openssl x509 -in state/clickhouse-tls-ca.pem -noout -text | grep Public-Key               # 3072 bit
kubectl -n langfuse get secret langfuse-clickhouse-ca                                     # Langfuse has the CA (Langfuse on)
openssl x509 -in state/langfuse-tls-cert.pem -noout -text | grep Public-Key               # 3072 bit (Langfuse on)
kubectl -n langfuse get service langfuse-lb -o yaml | grep ssl-negotiation-policy         # ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04
scripts/langfuse-smoke.sh                                                                # a trace goes in and comes back out of ClickHouse
```

Three checks are yours to make on a running cluster, because nothing has confirmed them:

- Look at the ports Keeper's pods declare and try each one, for example `kubectl -n ns-default-us-01 get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].ports}{"\n"}{end}'`. Decide for yourself whether a plaintext Keeper client port still answers.
- Capture a TLS handshake for each of the three hops (ClickHouse native, Langfuse to ClickHouse, and the Langfuse NLB) and confirm the protocol and cipher.
- Confirm that a `fips: true` deployment starts Langfuse without errors on its schema migration, since that connection relies on the unverified-certificate path described above.

---

## Where to go next

[`FIPS.md`](../FIPS.md), at the repository root, gives the short version of everything above for someone deciding whether this posture clears their compliance bar. [Learning setup vs. production](limitations.md) lists what else differs from a production deployment. This part is the long version, with the mechanism and the caveats attached to each claim, and the self-checks above are how you turn those claims into evidence on your own cluster.
