# Part 3 — Steps 6–8: storage, IRSA, and the operator

By the end of Part 2 there was a cluster with eight nodes and nothing running
on it. These three steps give it somewhere to put data and something to manage
ClickHouse for it. None of them is expensive: an empty bucket, two IAM roles, a
CSI driver and two small operator pods.

```bash
ansible-playbook deploy.yml --tags storage    # Step 6
ansible-playbook deploy.yml --tags prereqs    # Step 7
ansible-playbook deploy.yml --tags operator   # Step 8
```

---

# Step 6 — S3 bucket and IAM roles

## IRSA, concretely

This is the step where the OIDC provider registered back in Step 4 finally
does something, so it is worth being precise about what happens.

ClickHouse stores its data in S3. Something has to authenticate those requests.
The old answers were both bad: put an access key in a Kubernetes Secret (a
long-lived credential sitting in etcd), or attach the permission to the *node*
role (which grants it to every pod on that node, not just ClickHouse).

**IRSA** — IAM Roles for Service Accounts — is the third answer:

```
1. Pod starts with a projected service account token: a JWT signed by
   the cluster's own OIDC issuer, saying "I am
   system:serviceaccount:clickhouse:ch-default-us-01-sa".

2. The AWS SDK inside the pod notices two env vars the kubelet injected
   (AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE) and calls
   sts:AssumeRoleWithWebIdentity, presenting that JWT.

3. STS verifies the signature against the OIDC provider you registered in
   IAM (Step 4), checks the role's trust policy, and returns temporary
   credentials valid for an hour.
```

No stored secret anywhere. The credential is minted on demand and expires.

## Reading the trust policy

Everything above hinges on this document, so read it as two separate claims:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::...:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/1686..." },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/1686...:aud": "sts.amazonaws.com",
      "oidc.eks.us-east-1.amazonaws.com/id/1686...:sub": "system:serviceaccount:clickhouse:ch-default-us-01-sa"
    }
  }
}
```

- **`Principal.Federated`** — only tokens from *this* cluster's issuer count.
  A token from a different EKS cluster is signed by a different issuer and
  fails here.
- **`:aud`** — the token's audience must be `sts.amazonaws.com`. This stops a
  token minted for some other consumer being replayed against STS.
- **`:sub`** — the exact service account, namespace included. **This is the
  condition that does the real work.** Leave it out and *any* pod in the
  cluster can assume the role and read your database's storage.

Note the shape of those condition keys: the issuer URL is part of the key
*name*, not the value. That detail causes a problem below.

## The one place CloudFormation could not do the job

Every other piece of infrastructure in this project is a CloudFormation
template applied verbatim. The IRSA stack is the exception — it is a Jinja
template that Ansible renders first. The reason:

```
Template format error:
[/Resources/ClickHouseS3Role/.../Condition/StringEquals]
map keys must be strings; received a map instead
```

`!Sub` returns a map (`{"Fn::Sub": "..."}`) until CloudFormation evaluates it,
and **a map cannot be a map key**. Since the issuer has to appear *in the key*,
CloudFormation cannot build this document at all. Rendering the issuer in with
Ansible first turns it into a literal string, and the stack is ordinary
CloudFormation from there on:

```yaml
template_body: "{{ lookup('template', role_path ~ '/templates/irsa-roles.yaml.j2') }}"
#                          ^^^^^^^^ not 'file'
```

This is worth knowing generally: any IAM condition key with a dynamic name has
this problem, and IRSA is the most common case of it.

## Why the bucket is not in CloudFormation

The bucket is created with `amazon.aws.s3_bucket` instead, deliberately. A
bucket holding a database's data must outlive the stack that made it, and
CloudFormation offers only bad options:

- default behaviour — stack teardown tries to delete the bucket, **fails**
  because it is not empty, and leaves the whole stack stuck `DELETE_FAILED`;
- `DeletionPolicy: Retain` — teardown succeeds but orphans the bucket, and the
  *next* create then fails because the name is taken.

The module is idempotent, so an existing bucket is adopted rather than
recreated, and teardown simply never touches it. Deleting it is a deliberate,
manual act:

```bash
aws s3 rm s3://clickhouse-private-<YOUR_ACCOUNT_ID>-us-east-1 --recursive --profile sa
aws s3 rb s3://clickhouse-private-<YOUR_ACCOUNT_ID>-us-east-1 --profile sa
```

## Three bucket settings, and why

| Setting | Value | Reason |
|---|---|---|
| Encryption | `AES256` | Required by the tutorial. SSE-S3 rather than KMS: no per-request cost, and one less IAM policy to get right. |
| Public access block | all four on | Blocks public access at the bucket level, independent of any policy or ACL added later. |
| Versioning | **off** | ClickHouse manages its own object lifecycle. Versioning would retain every overwritten part forever and quietly multiply your storage bill. |

The tutorial is emphatic about the related point: **do not add S3 lifecycle
rules to this bucket.** ClickHouse decides when its objects die; a lifecycle
rule transitioning objects to Glacier will corrupt a live table.

Bucket naming has one non-obvious constraint — **no periods**. A name like
`clickhouse.private.data` breaks TLS hostname matching for virtual-hosted-style
requests, which is why the FIPS guidance calls it out. Ours is
`clickhouse-private-<account-id>-<region>`, which is deterministic and
globally unique without a period in sight.

## Key prefixes: one bucket, many clusters

The chart enforces a prefix format of `ch-s3-<uuid>`:

```yaml
server.storage.s3.keyPrefix: ch-s3-4f6a1d2e-8b3c-4a5d-9e7f-1c2b3a4d5e6f
```

That is how several ClickHouse clusters share one bucket without colliding.
The uuid is not decorative — it must be unique per cluster, and the schema
rejects anything that does not match the pattern.

## On the role naming convention

The tutorial suggests `CH-S3-$NAME-$REGION-$ORDINAL-Role`, e.g.
`CH-S3-default-xx-01-uw2-00-Role`. We let CloudFormation generate names
instead, for the reason established in Step 4: in a shared account an explicit
name that collides reports only `Validation failed with 1 error(s)`, naming
neither the resource nor the reason. Nothing depends on the name — the service
account is annotated from the stack's output.

---

# Step 7 — Kubernetes prerequisites

Three separate things, in dependency order: snapshot CRDs, the EBS CSI driver,
and a StorageClass.

## VolumeSnapshot CRDs: vendored, not fetched

The tutorial says:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/...
```

We commit the three files to the repo instead, at tag **v8.6.0**. Two reasons,
and both matter more than they look:

1. **`master` is not a version.** What you install depends on the day you run
   it. Two people following the same guide a month apart get different CRDs.
2. **An airgapped cluster cannot reach `raw.githubusercontent.com`.** Any step
   that needs the public internet at deploy time is a step that fails in
   exactly the environment this guide exists for.

They are applied **server-side**:

```yaml
apply: true
server_side_apply:
  field_manager: clickhouse-private-ansible
```

Client-side apply stores the entire manifest in a
`kubectl.kubernetes.io/last-applied-configuration` annotation, and these CRDs
are 27 KB each and growing — that runs into the 256 KiB annotation limit.
Server-side apply keeps ownership metadata per field instead.

**One caveat the tutorial does not mention:** these are the CRDs *only*. They
satisfy the operator's requirement that the types be registered, but snapshots
do not actually *work* without the `snapshot-controller` Deployment, which is a
separate install. If you later need working volume snapshots for backups, that
is the missing piece.

## EBS CSI driver: the managed add-on, not the Helm chart

The tutorial installs the driver from the upstream Helm repository:

```bash
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver ...
```

We use the **EKS managed add-on** instead. This is a deliberate deviation:

- The Helm route requires reaching a public Helm repository at deploy time —
  the same airgap problem as the CRD URLs.
- The add-on's images come from an AWS-owned ECR registry, reachable over
  PrivateLink with **no internet route at all**. It is *more* airgap-friendly,
  not less.
- EKS selects the driver version matching the cluster's Kubernetes version and
  keeps it patched, rather than pinning a chart version that ages.

The tutorial's Helm path is still the right answer for non-EKS Kubernetes. On
EKS this is the supported one.

Wiring IRSA to the driver is a single property:

```yaml
ServiceAccountRoleArn: !Ref EbsCsiRoleArn
```

The add-on then annotates `kube-system/ebs-csi-controller-sa` for you. Note
that the driver's service account name is fixed by the driver — you do not get
to choose it, which is why it is hardcoded in the trust policy.

The role checks that annotation explicitly, because it is the single point of
failure in the chain and its absence surfaces much later as an opaque
`AccessDenied` during volume creation:

```
ebs-csi-controller-sa -> clickhouse-private-irsa-EbsCsiDriverRole-CWgWugDIMUUZ
```

Also worth knowing: `AmazonEBSCSIDriverPolicy` lives under the **`service-role/`
path**, not at the top level. `arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicy`
does not exist and fails at stack creation.

## The StorageClass, and one bug in the tutorial's command

The StorageClass comes from the same chart that will deploy the cluster in
Step 9, with everything except the StorageClass switched off:

```yaml
storageClass: {create: true}
createCluster: false
serviceAccount: {create: false}
resourceQuota: {enabled: false}     # <- not in the tutorial
```

That last line is a fix. The chart's `resourcequota.yaml` template is gated
**only** on `resourceQuota.enabled`, not on `createCluster` — so the tutorial's
command drops a `ResourceQuota` into the `default` namespace, capping
ClickHouseClusters at 1 *there*, for a release that creates no cluster at all.
Harmless today, confusing in six months. Verify with a render before you
install anything:

```bash
helm template clickhouse-prerequisites ./onprem-clickhouse-cluster \
  --set-json="storageClass.create=true" --set-json="createCluster=false" \
  --set-json="serviceAccount.create=false" --set-json="resourceQuota.enabled=false"
```

The resulting class:

```
NAME            PROVISIONER      BINDING                EXPAND
gp3-encrypted   ebs.csi.aws.com  WaitForFirstConsumer   true
```

`WaitForFirstConsumer` is the important field. **An EBS volume exists in exactly
one availability zone and cannot move.** With immediate binding, Kubernetes
would create the volume as soon as the claim appeared — possibly in
`us-east-1a` — and only later try to schedule the pod, which might have to run
in `us-east-1c`, where that volume cannot be attached. Deadlock.
`WaitForFirstConsumer` inverts the order: schedule the pod first, then create
the volume in whichever AZ the pod landed in.

## Proving storage works before trusting it

CRDs, driver and StorageClass can all look healthy while provisioning is
quietly broken — a missing IAM permission, a driver that cannot assume its
role, an AZ mismatch. The symptom in Step 9 would be ClickHouse pods `Pending`
on an unbound PVC, a long way from the cause.

So the role provisions one throwaway 1Gi volume, mounts it, writes to it, and
deletes it. Because the class is `WaitForFirstConsumer`, a PVC alone would
never bind — the probe has to create a pod too.

---

# Step 8 — Install the operator

## What the operator actually is

The operator is a **controller**, not a database. It watches for
`ClickHouseCluster` custom resources and reconciles reality to match them —
creating StatefulSets, Services, PVCs and config maps. Installing it starts no
ClickHouse at all; it just makes the cluster capable of understanding what a
ClickHouseCluster *is*. That happens in Step 9.

Concretely, this step registers **12 CRDs** and runs one small Deployment.

## The tutorial's four switches

```yaml
cilium: {enabled: false}
idleScalerEnabled: false
webhooks: {enabled: false}
operator: {availabilityZones: [us-east-1a, us-east-1b, us-east-1c]}
```

- **`cilium.enabled=false`** — the chart can create `CiliumNetworkPolicy`
  objects. This cluster runs the AWS VPC CNI, which does not implement that
  resource; leaving it on creates policies that enforce nothing, which is worse
  than none at all because they look like protection.
- **`idleScalerEnabled=false`** — scale-to-zero-on-idle is a ClickHouse Cloud
  feature needing control plane components a private deployment does not have.
- **`webhooks.enabled=false`** — admission webhooks need a serving certificate
  and a reachable webhook service. Off is the documented posture here.
- **`operator.availabilityZones`** — not optional. The operator pins replicas
  and spreads them across zones; without a zone list it cannot place anything.

## Two overrides the tutorial omits, and airgap needs

This is the most useful thing in Step 8. The tutorial's command sets
`image.repository` to your ECR — but the chart references **two more images**,
and neither is covered:

```yaml
operator:
  imageRegistryBasePath: "<your-ecr>"          # default: ClickHouse's us-west-2 ECR
kubeRBACProxy:
  image:
    repository: "<your-ecr>/kubebuilder/kube-rbac-proxy"   # default: registry.k8s.io
```

**`operator.imageRegistryBasePath`** becomes the `IMAGE_REGISTRY_BASE_PATH` env
var, which the operator hands to the debug and init containers it generates.
Left at its default, the operator emits pod specs pointing at
`609927696493.dkr.ecr.us-west-2.amazonaws.com` — an account you have no access
to. Those pods sit in `ImagePullBackOff` with nothing to connect them back to a
Helm value you did not set.

**`kubeRBACProxy.image.repository`** defaults to
`registry.k8s.io/kubebuilder/kube-rbac-proxy:v0.13.0` — a public registry an
airgapped cluster cannot reach. The alternative is `kubeRBACProxy.enabled=false`,
which does work, but it removes the RBAC guard in front of the operator's
metrics endpoint. For a hardened deployment, mirroring the image is the right
call, so `group_vars` gained a `third_party_images` list and the Step 2 sync
now handles it:

```yaml
third_party_images:
  - repo: kubebuilder/kube-rbac-proxy
    tag: "v0.13.0"
    source: "registry.k8s.io"
```

The version is the chart's own pin — do not float it, because the chart passes
flags that changed in later releases.

This generalises: **in an airgapped install, "which images does this chart
reference?" is a question you have to answer exhaustively, not per the
instructions.** The way to answer it:

```bash
helm template <release> <chart> --set ... | grep -E '^\s+image:' | sort -u
```

Which is exactly what the role then asserts against a live cluster:

```yaml
that: _op_images.stdout_lines | reject('search', '^' ~ target_registry) | list | length == 0
```

If any container in the operator namespace pulls from anywhere but your
registry, the run fails and names the offender, rather than leaving you to
discover it as a stuck pod.

---

# Traps hit while building these three steps

## `kubernetes` is a second missing Python library

Step 7 failed immediately with:

```
Failed to import the required Python library (kubernetes) on
/Users/.../.venv/bin/python3
```

Exactly the same shape as the `boto3` problem from Part 1, and for the same
reason: Ansible modules import their SDK inside whichever Python runs the
*module*, not the one running `ansible-playbook`. `amazon.aws` needs `boto3`;
`kubernetes.core` needs `kubernetes`. `part1-setup.sh` now provisions and
verifies both, so a fresh checkout does not hit this.

```bash
scripts/part1-setup.sh --check
#   [ ok ] venv present: python 3.14.7, boto3 1.43.86, kubernetes 36.0.3
```

## Helm's fullname is not the release name

The operator wait failed with:

```
Error from server (NotFound): deployments.apps "clickhouse-operator" not found
```

while the release was perfectly healthy. Helm's `fullname` convention is
`<release>-<chart>` *unless* the release name already contains the chart name.
Release `clickhouse-operator` plus chart `clickhouse-operator-helm` gives:

```
clickhouse-operator-clickhouse-operator-helm-84cd548497-72cq6
```

The fix is to never guess the generated name. Select by label:

```bash
kubectl wait --for=condition=Available deployment \
  --selector=app.kubernetes.io/instance=clickhouse-operator \
  -n clickhouse-operator-system
```

---

# What exists now

```
$ kubectl get sc
NAME            PROVISIONER             BINDING                EXPAND
gp2             kubernetes.io/aws-ebs   WaitForFirstConsumer   <none>
gp3-encrypted   ebs.csi.aws.com         WaitForFirstConsumer   true
```

`gp2` is EKS's own default class, unencrypted and on the legacy in-tree
provisioner name. Note that **neither class is marked as the cluster default**,
so every PVC must name its class explicitly — which the ClickHouse chart does.

```
$ kubectl get pods -n clickhouse-operator-system
NAME                                                     READY   STATUS    NODE
clickhouse-operator-clickhouse-operator-helm-...-72cq6   2/2     Running   ip-10-20-106-4   (operator node)
```

Two containers — the operator and the mirrored `kube-rbac-proxy` sidecar — and
it landed on an operator node, because the keeper and server groups are
tainted.

```
clickhouse CRDs (12): backups, billingschemas, clickhouseclusters,
  distributedcacheconfigurations, distributedcachegroups, keeperclusters,
  licenses, persistentvolumeclaimcleaners, scalingoverrides,
  statelessworkerconfigurations, statelessworkergroups, udfdeployments
snapshot CRDs (3):  volumesnapshots, volumesnapshotcontents, volumesnapshotclasses
```

Storage proved end to end, then cleaned up:

```
--- pod output ---
/dev/nvme1n1    974M   28K  958M   1% /data
--- volume ---
Bound pvc-f7545d1d-23ef-47f7-8d38-95c60f23a801 1Gi
```

And the airgap assertion, which is the claim that matters most here:

```
all 2 operator containers pull from <YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
```

## Cost check

Steps 6–8 add essentially nothing: an empty S3 bucket, two IAM roles, a CSI
driver DaemonSet and one operator pod all fit inside the compute already
running. Still ~**$2.32/hr**, unchanged from the end of Step 5.

## Checkpoint

- [x] S3 bucket, encrypted, public access blocked, versioning off, no lifecycle rules
- [x] IRSA role for `clickhouse:ch-default-us-01-sa`, scoped to that one service account
- [x] IRSA role for `kube-system:ebs-csi-controller-sa`
- [x] VolumeSnapshot CRDs vendored at v8.6.0 and applied server-side
- [x] EBS CSI driver as an EKS managed add-on, service account verified annotated
- [x] `gp3-encrypted` StorageClass, `WaitForFirstConsumer`
- [x] Dynamic provisioning proven with a real volume, then deleted
- [x] Operator running, 12 CRDs registered
- [x] Every operator container pulls from your ECR — asserted, not assumed
- [x] All three roles idempotent (`changed=0` on re-run)
- [ ] Step 9: deploy a ClickHouseCluster

## What Step 9 will need

Everything is now in place for an actual cluster. The values already decided
here that Step 9 has to line up with:

| Value | Setting |
|---|---|
| `default-us-01` | release name / cluster name (chart schema: `^[a-z]+-[a-z]{2}-[0-9]{2}$`) |
| `clickhouse` | namespace |
| `ch-default-us-01-sa` | service account, annotated with the S3 role ARN |
| `clickhouse-private-<YOUR_ACCOUNT_ID>-us-east-1` | bucket |
| `ch-s3-4f6a1d2e-...` | key prefix |
| `https://s3.us-east-1.amazonaws.com` | endpoint — the chart defaults to **us-west-2** and must be overridden |
| `gp3-encrypted` | storage class |

That endpoint default is the one to watch: the chart's AWS defaults are
`endpoint: https://s3.us-west-2.amazonaws.com` and `region: us-west-2`. Deploy
without overriding them and ClickHouse will try to store your data in the wrong
region.
