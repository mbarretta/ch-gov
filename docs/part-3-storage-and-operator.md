# Part 3 — Steps 6–8: storage, IRSA, and the operator

> **What you'll learn**
>
> - How IRSA (IAM Roles for Service Accounts) lets a pod reach S3 with no stored credential, and how to read the trust policy that makes it safe.
> - What the kit installs so the cluster can store data: an S3 bucket, an EBS CSI driver, a `gp3-encrypted` StorageClass, and the ClickHouse operator.
> - Why an airgapped install has to account for every image a Helm chart references, and how the kit checks that for you.
>
> **Run it:** `scripts/up.sh` runs every step in order and asks before it starts. This Part covers the storage, prerequisites and operator steps, which use the tags `storage`, `prereqs` and `operator`. These steps are cheap: an empty bucket, two IAM roles, a CSI driver and two small operator pods. The nodes from Step 5 are already running, so your hourly rate does not change.

By the end of Part 2 you have a Kubernetes cluster with eight nodes and nothing running on it. These three steps give it somewhere to put data and something to manage ClickHouse for it.

> **Advanced: run individual steps.** To run one step at a time, pass its tag to `scripts/play.sh`:
>
> ```bash
> scripts/play.sh --tags storage    # Step 6
> scripts/play.sh --tags prereqs    # Step 7
> scripts/play.sh --tags operator   # Step 8
> ```
>
> Add `--check` for a dry run. Section 5 of [Part 1](part-1-prerequisites.md) explains what `play.sh` sets up for you.

---

## Step 6 — S3 bucket and IAM roles

### IRSA, concretely

This is the step where the OIDC provider registered in Step 4 finally does something, so it is worth being precise about what happens.

ClickHouse stores its data in S3, and something has to authenticate those requests. There are two older answers, and both are weak:

- **A stored access key.** The key sits in a Kubernetes Secret, which is a long-lived credential in etcd.
- **A node role permission.** The permission attaches to the *node* role, which grants it to every pod on that node, not just ClickHouse.

**IRSA** is the third answer. The flow has three parts:

```
1. Pod starts with a projected service account token: a JWT signed by
   the cluster's own OIDC issuer, saying "I am
   system:serviceaccount:ns-default-us-01:ch-default-us-01-sa".

2. The AWS SDK inside the pod notices two env vars the kubelet injected
   (AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE) and calls
   sts:AssumeRoleWithWebIdentity, presenting that JWT.

3. STS verifies the signature against the OIDC provider registered in
   IAM (Step 4), checks the role's trust policy, and returns temporary
   credentials valid for an hour.
```

No secret is stored anywhere. AWS mints the credential on demand and it expires.

### Reading the trust policy

Everything above depends on the role's trust policy. Read it as three separate claims:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<YOUR_ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com",
      "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:ns-default-us-01:ch-default-us-01-sa"
    }
  }
}
```

- **`Principal.Federated`** accepts only tokens from *this* cluster's issuer. A token from a different EKS cluster is signed by a different issuer and fails here.
- **`:aud`** requires the token's audience to be `sts.amazonaws.com`. This stops a token minted for some other consumer from being replayed against STS.
- **`:sub`** names the exact service account, namespace included. **This is the condition that does the real work.** Leave it out and *any* pod in the cluster can assume the role and read your database's storage.

Because the namespace is part of the `:sub` string, the namespace is not a free choice you make later at `helm install` time. It is fixed here, in IAM. The kit keeps it in one variable, `clickhouse.namespace`, whose default is `ns-default-us-01`. If you change it, run Step 6 again (`scripts/play.sh --tags storage`) so the trust policy names the new namespace.

Notice the shape of the condition keys: the issuer URL is part of the key *name*, not the value. That detail matters in the next section.

### The one place CloudFormation cannot do the job

Every other piece of infrastructure in the kit is a CloudFormation template applied as written. The IRSA stack is the exception. It is a Jinja template that Ansible renders first, because CloudFormation rejects the plain version:

```
Template format error:
[/Resources/ClickHouseS3Role/.../Condition/StringEquals]
map keys must be strings; received a map instead
```

`!Sub` returns a map (`{"Fn::Sub": "..."}`) until CloudFormation evaluates it, and **a map cannot be a map key**. Since the issuer has to appear *in the key*, CloudFormation cannot build this document by itself. Ansible looks up the issuer, renders it into the template as a literal string, and the stack is ordinary CloudFormation from there on. The `storage_iam` role does this with a `template` lookup, not a `file` lookup:

```yaml
template_body: "{{ lookup('template', role_path ~ '/templates/irsa-roles.yaml.j2') }}"
#                          ^^^^^^^^ not 'file'
```

Any IAM condition key with a dynamic name has this problem, and IRSA is the most common case.

### Why the bucket is not in CloudFormation

The `storage_iam` role creates the bucket with the `amazon.aws.s3_bucket` module instead, on purpose. A bucket that holds a database's data must outlive the stack that made it, and CloudFormation offers only two options, both poor:

- **Default behavior.** Stack teardown tries to delete the bucket, **fails** because it is not empty, and leaves the whole stack stuck in `DELETE_FAILED`.
- **`DeletionPolicy: Retain`.** Teardown succeeds but orphans the bucket, and the *next* create then fails because the name is taken.

The module is idempotent, so an existing bucket is adopted rather than recreated, and teardown never touches it. Deleting the bucket is a deliberate, manual act. The bucket is named `clickhouse-private-<target_account_id>-<target_region>` by default, so with your profile active (`source scripts/env.sh`) you can empty and remove it like this:

```bash
aws s3 rm s3://<BUCKET_NAME> --recursive --profile "$AWS_PROFILE"
aws s3 rb s3://<BUCKET_NAME> --profile "$AWS_PROFILE"
```

To delete only the ClickHouse cluster's own objects and keep the bucket, use `scripts/s3-purge-cluster-data.sh` (Part 4 explains why that takes a script).

### Three bucket settings, and why

| Setting | Value | Reason |
|---|---|---|
| Encryption | `AES256` | The tutorial requires encryption. SSE-S3 (S3-managed keys) is used instead of KMS: no per-request cost, and one less IAM policy to get right. With `fips: true` the bucket uses a customer-managed KMS key instead (see Part 7). |
| Public access block | all four on | Blocks public access at the bucket level, independent of any policy or ACL added later. |
| Versioning | **off** | ClickHouse manages its own object lifecycle. Versioning would keep every overwritten part forever and quietly multiply your storage bill. |

The tutorial is emphatic about a related point: **do not add S3 lifecycle rules to this bucket.** ClickHouse decides when its objects die, and a lifecycle rule that moves objects to Glacier will corrupt a live table.

Bucket naming has one non-obvious constraint: **no periods**. A name like `clickhouse.private.data` breaks TLS hostname matching for virtual-hosted-style requests, which is why the FIPS guidance calls it out. The default name, `clickhouse-private-<account-id>-<region>`, is deterministic and globally unique without a period in sight.

### Key prefixes: one bucket, many clusters

The chart enforces a prefix format of `ch-s3-<uuid>`:

```yaml
server.storage.s3.keyPrefix: ch-s3-4f6a1d2e-8b3c-4a5d-9e7f-1c2b3a4d5e6f
```

That is how several ClickHouse clusters share one bucket without colliding. The uuid must be unique per cluster, and the chart's schema rejects anything that does not match the pattern. The kit reads it from `clickhouse.s3_key_prefix`.

### On the role naming convention

The tutorial suggests role names like `CH-S3-$NAME-$REGION-$ORDINAL-Role`. The kit lets CloudFormation generate the names instead, because in a shared account an explicit name that collides reports only `Validation failed with 1 error(s)`, naming neither the resource nor the reason. Nothing depends on the name: the service account is annotated from the stack's output.

---

## Step 7 — Kubernetes prerequisites

Step 7 installs three things, in dependency order: snapshot CRDs, the EBS CSI driver, and a StorageClass.

### VolumeSnapshot CRDs: vendored, not fetched

The tutorial applies the snapshot CRDs from a URL:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/...
```

The kit commits the three files to the repository instead, at tag **v8.6.0**, in `ansible/roles/k8s_prereqs/files/volumesnapshot-crds/`. There are two reasons, and both matter more than they look:

1. **`master` is not a version.** What you install depends on the day you run it. Two people following the same guide a month apart get different CRDs.
2. **An airgapped cluster cannot reach `raw.githubusercontent.com`.** Any step that needs the public internet at deploy time fails in exactly the environment this kit exists for.

The `k8s_prereqs` role applies them **server-side**:

```yaml
apply: true
server_side_apply:
  field_manager: clickhouse-private-ansible
```

Client-side apply stores the entire manifest in a `kubectl.kubernetes.io/last-applied-configuration` annotation. These CRDs are large and growing, and that runs into the 256 KiB annotation limit. Server-side apply keeps ownership metadata per field instead.

**One caveat the tutorial does not mention:** these are the CRDs *only*. They satisfy the operator's requirement that the types be registered, but snapshots do not actually *work* without the `snapshot-controller` Deployment, which is a separate install. If you later need working volume snapshots for backups, that is the missing piece.

### EBS CSI driver: the managed add-on, not the Helm chart

The tutorial installs the driver from the upstream Helm repository:

```bash
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver ...
```

The kit uses the **EKS managed add-on** instead. This is a deliberate deviation:

- The Helm route requires reaching a public Helm repository at deploy time, which is the same airgap problem as the CRD URLs.
- The add-on's images come from an AWS-owned ECR registry, so no public Helm repository or third-party registry is involved. In an airgapped network that registry is reachable through ECR VPC endpoints (PrivateLink), so pulling the images does not depend on the public internet. The learning environment has no such endpoints and pulls through its NAT gateway. The add-on is *more* airgap-friendly, not less.
- EKS selects the driver version that matches the cluster's Kubernetes version and keeps it patched, instead of pinning a chart version that ages.

The tutorial's Helm path is still the right answer for Kubernetes outside EKS. On EKS, the add-on is the supported one.

Wiring IRSA to the driver takes a single property in `ansible/roles/k8s_prereqs/files/ebs-csi-addon.yaml`:

```yaml
ServiceAccountRoleArn: !Ref EbsCsiRoleArn
```

The add-on then annotates `kube-system/ebs-csi-controller-sa` for you. The driver fixes its own service account name, so you cannot choose it, which is why the name is hardcoded in the trust policy.

The `k8s_prereqs` role checks that annotation explicitly. It is the single point of failure in the chain, and its absence surfaces much later as an opaque `AccessDenied` during volume creation. On success the role prints:

```
ebs-csi-controller-sa -> clickhouse-private-irsa-EbsCsiDriverRole-<suffix>
```

Also worth knowing: `AmazonEBSCSIDriverPolicy` lives under the **`service-role/` path**, not at the top level. `arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicy` does not exist, and a stack that names it fails at creation.

### The StorageClass, and one bug in the tutorial's command

The StorageClass comes from the same chart that deploys the cluster in Step 9, with everything except the StorageClass switched off:

```yaml
storageClass: {create: true}
createCluster: false
serviceAccount: {create: false}
resourceQuota: {enabled: false}     # <- not in the tutorial
```

That last line is a fix. The chart's `resourcequota.yaml` template is gated **only** on `resourceQuota.enabled`, not on `createCluster`. The tutorial's command therefore drops a `ResourceQuota` into the `default` namespace, capping ClickHouseClusters at 1 *there*, for a release that creates no cluster at all. It is harmless today and confusing in six months. You can verify this with a render before you install anything:

```bash
helm template clickhouse-prerequisites ./onprem-clickhouse-cluster \
  --set-json="storageClass.create=true" --set-json="createCluster=false" \
  --set-json="serviceAccount.create=false" --set-json="resourceQuota.enabled=false"
```

The resulting class looks like this:

```
NAME            PROVISIONER      BINDING                EXPAND
gp3-encrypted   ebs.csi.aws.com  WaitForFirstConsumer   true
```

`WaitForFirstConsumer` is the important field. **An EBS volume exists in exactly one availability zone and cannot move.** With immediate binding, Kubernetes would create the volume as soon as the claim appeared, possibly in `us-east-1a`, and only later try to schedule the pod. The pod might have to run in `us-east-1c`, where that volume cannot be attached, and the two would deadlock. `WaitForFirstConsumer` inverts the order: Kubernetes schedules the pod first, then creates the volume in whichever zone the pod landed in.

### Proving storage works before trusting it

CRDs, driver and StorageClass can all look healthy while provisioning is quietly broken: a missing IAM permission, a driver that cannot assume its role, an AZ mismatch. The symptom in Step 9 would be ClickHouse pods `Pending` on an unbound PVC, a long way from the cause.

So the role provisions one throwaway 1Gi volume, mounts it, writes to it, and deletes it. Because the class is `WaitForFirstConsumer`, a PVC alone would never bind, so the probe creates a pod too. On success the role prints the pod's `df` line for `/data` and a line that starts with `Bound`.

---

## Step 8 — Install the operator

### What the operator actually is

The operator is a **controller**, not a database. It watches for `ClickHouseCluster` custom resources and reconciles reality to match them, creating StatefulSets, Services, PVCs and config maps. Installing it starts no ClickHouse at all. It only makes the cluster capable of understanding what a ClickHouseCluster *is*. That happens in Step 9.

Concretely, this step registers the ClickHouse CRDs (the exact count depends on the operator chart version) and runs one small Deployment.

### The tutorial's four switches

The `clickhouse_operator` role sets these chart values:

```yaml
cilium: {enabled: false}
idleScalerEnabled: false
webhooks: {enabled: false}
operator: {availabilityZones: [us-east-1a, us-east-1b, us-east-1c]}
```

- **`cilium.enabled=false`**: the chart can create `CiliumNetworkPolicy` objects. This cluster runs the AWS VPC CNI, which does not implement that resource. Leaving it on creates policies that enforce nothing, which is worse than none at all because they look like protection.
- **`idleScalerEnabled=false`**: scale-to-zero on idle is a ClickHouse Cloud feature that needs control plane components a private deployment does not have.
- **`webhooks.enabled=false`**: admission webhooks need a serving certificate and a reachable webhook service. Off is the documented posture here.
- **`operator.availabilityZones`**: not optional. The operator pins replicas and spreads them across zones, and without a zone list it cannot place anything. The kit fills this from `infrastructure.availability_zones`.

### Two overrides the tutorial omits, and airgap needs

This is the most useful lesson in Step 8. The tutorial's command sets `image.repository` to your ECR, but the chart references **two more images**, and the tutorial covers neither:

```yaml
operator:
  imageRegistryBasePath: "<your-ecr>"          # default: ClickHouse's us-west-2 ECR
kubeRBACProxy:
  image:
    repository: "<your-ecr>/kubebuilder/kube-rbac-proxy"   # default: registry.k8s.io
```

**`operator.imageRegistryBasePath`** becomes the `IMAGE_REGISTRY_BASE_PATH` env var, which the operator hands to the debug and init containers it generates. Left at its default, the operator emits pod specs that point at ClickHouse's own us-west-2 ECR registry, an account you have no access to. Those pods sit in `ImagePullBackOff` with nothing to connect them back to a Helm value you did not set.

**`kubeRBACProxy.image.repository`** defaults to `registry.k8s.io/kubebuilder/kube-rbac-proxy:v0.13.0`, a public registry an airgapped cluster cannot reach. The alternative is `kubeRBACProxy.enabled=false`, which works, but it removes the RBAC guard in front of the operator's metrics endpoint. For a hardened deployment, mirroring the image is the right call. That is why `ansible/group_vars/all.yml` has a `third_party_images` list, which the Step 2 image sync handles:

```yaml
third_party_images:
  - repo: kubebuilder/kube-rbac-proxy
    tag: "v0.13.0"
    source: "registry.k8s.io"
```

The version is the chart's own pin. Do not float it, because the chart passes flags that changed in later releases.

This generalizes: **in an airgapped install, "which images does this chart reference?" is a question you have to answer exhaustively, not per the instructions.** You can answer it by rendering the chart:

```bash
helm template <release> <chart> --set ... | grep -E '^\s+image:' | sort -u
```

The role then asserts the same thing against the live cluster:

```yaml
that: _op_images.stdout_lines | reject('search', '^' ~ target_registry) | list | length == 0
```

If any container in the operator namespace pulls from anywhere but your registry, the run fails and names the offender, so you do not discover it later as a stuck pod.

---

## Troubleshooting

**Step 7 fails with `Failed to import the required Python library (kubernetes)`**

- *Cause:* Ansible modules import their SDK inside whichever Python runs the *module*, not the Python that runs `ansible-playbook`. `amazon.aws` needs `boto3`, and `kubernetes.core` needs `kubernetes`. This is the same shape of problem as a missing `boto3`.
- *Fix:* run `scripts/part1-setup.sh`, which provisions and verifies both libraries in the project's `.venv/`. `scripts/part1-setup.sh --check` should print an `[ ok ] venv present` line that lists both `boto3` and `kubernetes`.

**The operator wait fails with `deployments.apps "clickhouse-operator" not found`, but the release is healthy**

- *Cause:* Helm's generated name is `<release>-<chart>`, unless the release name already contains the chart name. Release `clickhouse-operator` with chart `clickhouse-operator-helm` produces a Deployment named `clickhouse-operator-clickhouse-operator-helm`.
- *Fix:* never guess the generated name. Select by label instead, as the role does:

  ```bash
  kubectl wait --for=condition=Available deployment \
    --selector=app.kubernetes.io/instance=clickhouse-operator \
    -n clickhouse-operator-system
  ```

**Volume creation fails with `AccessDenied`, or the storage probe never binds**

- *Cause:* the EBS CSI controller's service account is missing its `eks.amazonaws.com/role-arn` annotation, so the driver cannot assume its IAM role.
- *Fix:* run the annotation check in the self-checks below. If it prints nothing, run `scripts/play.sh --tags storage` and then `scripts/play.sh --tags prereqs` again.

---

## Cost check

Steps 6–8 add essentially nothing. An empty S3 bucket, two IAM roles, a CSI driver DaemonSet and one operator pod all fit inside the compute that is already running. With the default sizing, the rate stays at about **$2.32/hr** while the nodes are up, unchanged from the end of Step 5. The kit sizes the nodes for learning and workshops, not production. To stop the meter when you finish, run `scripts/down.sh`.

## Self-checks

Run these in order. Each gives a command and what you should see, and they double as workshop exercises. Start with `source scripts/env.sh` so that `AWS_PROFILE` and `KUBECONFIG` point at your deployment.

1. **The bucket is encrypted.** Replace `<BUCKET_NAME>` with your bucket name.

   ```bash
   aws s3api get-bucket-encryption --bucket <BUCKET_NAME> --profile "$AWS_PROFILE" \
     --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text
   ```

   You should see `AES256`. With `fips: true` you see `aws:kms`.

2. **Public access is blocked.**

   ```bash
   aws s3api get-public-access-block --bucket <BUCKET_NAME> --profile "$AWS_PROFILE" \
     --query 'PublicAccessBlockConfiguration'
   ```

   You should see `true` for all four settings.

3. **Versioning is off and no lifecycle rules exist.**

   ```bash
   aws s3api get-bucket-versioning --bucket <BUCKET_NAME> --profile "$AWS_PROFILE"
   aws s3api get-bucket-lifecycle-configuration --bucket <BUCKET_NAME> --profile "$AWS_PROFILE"
   ```

   The first command prints nothing, because versioning was never enabled. It must never print `Enabled`. The second fails with `NoSuchLifecycleConfiguration`, which is the answer you want.

4. **The ClickHouse role trusts exactly one service account.**

   ```bash
   ROLE=$(aws cloudformation describe-stacks --stack-name clickhouse-private-irsa --profile "$AWS_PROFILE" \
     --query "Stacks[0].Outputs[?OutputKey=='ClickHouseS3RoleArn'].OutputValue" --output text | sed 's|.*/||')
   aws iam get-role --role-name "$ROLE" --profile "$AWS_PROFILE" \
     --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
   ```

   You should see the `:aud` and `:sub` keys. With default settings the `:sub` value is `system:serviceaccount:ns-default-us-01:ch-default-us-01-sa`.

   **Exercise:** which of these two keys stops a different pod in the same cluster from assuming the role?

5. **The EBS CSI driver is wired to IAM.**

   ```bash
   kubectl get serviceaccount ebs-csi-controller-sa -n kube-system \
     -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
   ```

   You should see a role ARN that contains `EbsCsiDriverRole`.

6. **The StorageClass exists and waits for the first consumer.**

   ```bash
   kubectl get storageclass gp3-encrypted
   ```

   You should see provisioner `ebs.csi.aws.com` and binding mode `WaitForFirstConsumer`.

   **Exercise:** what would go wrong for a Keeper pod if the binding mode were `Immediate`?

7. **The CRDs are registered.**

   ```bash
   kubectl get crd | grep -E 'clickhouse\.com|snapshot\.storage\.k8s\.io'
   ```

   You should see the ClickHouse CRDs, including `clickhouseclusters.clickhouse.com` and `keeperclusters.clickhouse.com`, and the three snapshot CRDs `volumesnapshotclasses`, `volumesnapshotcontents` and `volumesnapshots`.

8. **The operator runs on an operator node.**

   ```bash
   kubectl get pods -n clickhouse-operator-system -o wide
   ```

   You should see one pod with `2/2` containers `Running`: the operator and the `kube-rbac-proxy` sidecar. It lands on an operator node because the keeper and server node groups are tainted.

9. **Every operator container pulls from your registry.**

   ```bash
   kubectl get pods -n clickhouse-operator-system \
     -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}'
   ```

   You should see two lines, and both start with your ECR hostname (`<target_account_id>.dkr.ecr.<target_region>.amazonaws.com`, or the `dkr-ecr-fips` form with `fips: true`).

10. **The steps are idempotent.**

    ```bash
    scripts/play.sh --tags storage,prereqs,operator
    ```

    Everything already matches, so the play recap should report `changed=0`.

## What Step 9 needs

Everything is now in place for an actual cluster. Step 9 has to line up with the values decided here:

| Value | Setting |
|---|---|
| `default-us-01` | Release name and cluster name. The chart schema requires `^[a-z]+-[a-z]{2}-[0-9]{2}$`. |
| `ns-default-us-01` | Namespace: `ns-` plus the cluster name, the convention the preflight chart assumes. |
| `ch-default-us-01-sa` | Service account, annotated with the S3 role ARN. |
| `clickhouse-private-<target_account_id>-<target_region>` | Bucket. |
| `ch-s3-<uuid>` | Key prefix. |
| `https://s3.<target_region>.amazonaws.com` | Endpoint. The chart defaults to **us-west-2** and must be overridden. |
| `gp3-encrypted` | Storage class. |

That endpoint default is the one to watch. The chart's AWS defaults are `endpoint: https://s3.us-west-2.amazonaws.com` and `region: us-west-2`. Deploy without overriding them and ClickHouse tries to store your data in the wrong region. The kit sets both from your configuration, and Part 4 shows where.

**Next:** [Part 4](part-4-cluster-preflight-verify.md) deploys the ClickHouseCluster, runs ClickHouse's preflight checks, and proves the cluster replicates.
