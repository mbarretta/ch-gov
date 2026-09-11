# Part 2 — Steps 1 & 2: ECR access and the image hop

> **What this covers:** getting ClickHouse's container images into your own
> registry. Nothing is deployed yet; no EKS cluster, no compute cost.
>
> **Run it:** `cd ansible && ansible-playbook deploy.yml --tags images`

Follows the official tutorial:
[deploy-aws](https://clickhouse.com/docs/cloud/clickhouse-private/tutorials/deploy-aws),
Steps 1–2 of 11.

---

## Step 1 — IAM role for ECR access: already done

The tutorial gives you CloudFormation that creates a role named
`ClickHouseAirgapECRPullRole` **in your own account**, whose policy grants read
access to ClickHouse's registry. That role already exists here, and Part 1
verified the `private-us` profile assumes it successfully.

This is worth pausing on, because the three-account shape confuses everyone:

| Account | Role in the story |
|---|---|
| `<YOUR_ACCOUNT_ID>` | **Yours.** Holds the pull role, your ECR, and eventually the cluster. |
| `<SOURCE_ECR_ACCOUNT_ID>` | **ClickHouse's.** Where the images live. You only ever read. |

The pull role lives in *your* account and points *outward*. Nothing is created
in ClickHouse's account, and they grant nothing per-customer — the source repos
just permit cross-account reads.

---

## Step 2 — Copy the images

### What gets copied, and why six things

```
                    source ECR (<SOURCE_ECR_ACCOUNT_ID>)         your ECR (<YOUR_ACCOUNT_ID>)
  container images  clickhouse-server:26.2.1.525   →  same
                    clickhouse-keeper:26.2.1.258   →  same
                    clickhouse-operator:main-…     →  same
  helm charts       helm/clickhouse-operator-helm  →  same
                    helm/onprem-clickhouse-cluster →  same
                    helm/preflight-check           →  same
```

The **Helm charts travel through the registry too**, which surprises people.
They are OCI artifacts, not container images — you can see it in the manifest:

```
config: application/vnd.cncf.helm.config.v1+json
layers: application/vnd.cncf.helm.chart.content.v1.tar+gzip
```

That is the whole point of the airgap model. In a normal deployment you would
`helm repo add https://…` and pull charts over the internet. Here the cluster
has no internet, so charts are stored as OCI artifacts in your ECR and
installed with `helm install oci://…`. Nothing reaches outside your account.

### One thing the tutorial omits

**ECR does not create repositories on push.** The tutorial jumps straight to
`skopeo copy`, which fails with `RepositoryNotFoundException` unless the target
repos already exist. Our `ecr_setup` role creates all six first.

We also set two options the tutorial doesn't mention:

- `image_tag_mutability: immutable` — once `26.2.1.525` is pushed, that tag can
  never be repointed at different content. For a database you must be able to
  reason about after an incident, "the tag means what it meant last week" is
  worth a lot.
- `scan_on_push: true` — ECR scans for CVEs on arrival. Cheap, and relevant if
  you must produce vulnerability evidence for an authorization package.

### Why skopeo instead of docker

`docker pull` + `docker push` would drag every layer down to your laptop and
back up again — ~2.4 GB each way, per architecture. `skopeo copy` tells the two
registries to transfer directly. It needs no Docker daemon, and your machine
only relays metadata. Our full sync took **8m23s** for ~5 GB across both
architectures.

### `--all` is not optional

```bash
skopeo copy --all docker://source/repo:tag docker://target/repo:tag
```

Without `--all`, skopeo copies only the manifest matching *your* platform —
arm64, on an Apple Silicon Mac. You would publish an arm64-only image and then
watch pods fail to schedule on x86 nodes with an opaque manifest error.

With `--all` you get the whole manifest list. Verified on the copy we made:

```
linux/amd64      3141B
linux/arm64      3142B
unknown/unknown   839B   ← SBOM / provenance attestations
```

Both architectures in one tag. This is exactly what makes the standard build
(arm64) and the FIPS build (x86_64) able to share the same plain tags — though
FIPS also needs its own separate `-fips` tags, which are different images.

---

## The `fips` switch

`ansible/group_vars/all.yml` has one variable that changes the whole build:

```yaml
fips: false     # true = FIPS x86_64 build
```

```bash
ansible-playbook deploy.yml --tags images                 # standard
ansible-playbook deploy.yml --tags images -e fips=true    # FIPS
```

What it changes today:

| | `fips: false` | `fips: true` |
|---|---|---|
| image tags | `26.2.1.525` | `26.2.1.525-fips` |
| chart tags | `1.8.7` | `1.8.7` — *unchanged* |
| target registry | `<acct>.dkr.ecr.us-east-1.amazonaws.com` | `<acct>.dkr-ecr-fips.us-east-1.on.aws` |

Only the three **container images** have `-fips` variants. The Helm charts are
shared between both builds — the FIPS variant is selected by image tag, not by
a different chart. Getting this wrong is an easy mistake: appending `-fips` to a
chart version produces a tag that does not exist.

What it will also change, once we reach those steps: **x86_64 nodes only**
(FIPS crypto is not validated on ARM64, so the ARM instance types are out),
TLS-only on port 9440, RSA-3072+ certificates per cluster, and an S3 bucket
name with no periods in it.

---

## Notes on the Ansible itself

**Where the AWS config comes from.** The playbook sets
`AWS_CONFIG_FILE: {{ playbook_dir }}/../.aws/config`, so it works whether or not
you sourced `scripts/env.sh`.

**Why there is a venv.** The `community.aws` modules import `boto3` inside
whichever Python runs the module. Homebrew's Python doesn't have it, and PEP 668
blocks installing into it. `.venv/` at the repo root holds it, and
`ansible_python_interpreter` in `group_vars/all.yml` points there.
`scripts/part1-setup.sh` creates it.

**Both roles are idempotent**, verified by re-running:

```
ecr_setup:   changed=0
image_sync:  "0 copied, 6 already present"
```

The sync checks each target tag before copying, so an interrupted run resumes
rather than recopying gigabytes.

**Why no shell pipelines.** The obvious way to log in is
`aws ecr get-login-password | skopeo login --password-stdin`. We deliberately
don't. Inside a folded YAML scalar (`>-`), continuation lines indented deeper
than the first are preserved as *real newlines*, which silently breaks the
pipe — and a broken pipe makes `get-login-password`'s stdout become the task's
stdout, dumping a live registry token into the log. We hit exactly this. The
fix: two `command` tasks passing the token via `stdin`, which keeps it out of
argv, out of the process table, and out of the log.

**Where the skopeo credentials go.** `state/skopeo-auth.json`, not
`~/.config/containers/auth.json`, keeping the project self-contained. It holds
live registry tokens and is gitignored.

---

## Checkpoint

- [x] `ClickHouseAirgapECRPullRole` verified (Step 1)
- [x] Six ECR repositories created in your account, immutable + scan-on-push
- [x] All six artifacts copied, both architectures (Step 2)
- [x] Both roles idempotent and resumable
- [ ] Steps 3–11: VPC, EKS, node groups, S3/IRSA, operator, cluster, preflight

**Next:** Step 3, the VPC. This is where AWS spend starts — NAT gateways bill
hourly whether or not anything runs.

---

# Step 3 — VPC and networking

**Run it:** `cd ansible && ansible-playbook deploy.yml --tags vpc`
**Tear it down:** `ansible-playbook deploy.yml --tags vpc -e vpc_state=absent`

## Why CloudFormation here, when Steps 1–2 used plain modules

Infrastructure gets a CloudFormation stack rather than a chain of
`ec2_vpc_*` Ansible tasks, for one reason: **teardown**. NAT gateways and
Elastic IPs bill hourly whether or not anything uses them, and a half-finished
module chain leaves orphans that quietly cost money. `state: absent` on a stack
deletes every resource in dependency order.

## The AZ trap

Subnets are pinned to an availability zone and cannot be moved. If you place
one in an AZ that does not offer your node instance type, nothing fails until
the node group is created — and the error does not mention availability zones.

In `us-east-1`, **`us-east-1e` offers none** of the candidate instance types
(`m7gd.16xlarge`, `m7g.2xlarge`, `m7i.2xlarge`, `m5d.16xlarge`, `m8i.2xlarge`).
We use `1a/1b/1c`, which support every type for both builds. The `vpc` role
asserts this before creating anything.

## The layout

| | CIDR | Purpose |
|---|---|---|
| VPC | `10.20.0.0/16` | |
| private ×3 | `10.20.0.0/18`, `.64.0/18`, `.128.0/18` | all nodes and pods |
| public ×3 | `10.20.192.0/20`, `.208.0/20`, `.224.0/20` | NAT gateways, internet-facing LBs |

**Why /18 for private subnets** (~16k addresses each): the AWS VPC CNI gives
every *pod* a real VPC IP address. Pod density is therefore bounded by subnet
size, not just by node count. Undersizing here is painful to fix later.

## Two things EKS needs that are easy to miss

- **`EnableDnsSupport` + `EnableDnsHostnames`** — without both, pods get no
  working DNS and the private hosted zones that EKS and VPC endpoints depend on
  do not resolve.
- **Subnet tags** — `kubernetes.io/role/elb=1` on public,
  `kubernetes.io/role/internal-elb=1` on private. This is how the load balancer
  controller decides where to place a service's load balancer. Without them,
  `type: LoadBalancer` services just hang in `pending`.

## NAT: the first real cost decision

```yaml
nat_mode: "single"    # or "per_az"
```

| Mode | NAT gateways | ~Idle cost | Failure behavior |
|---|---|---|---|
| `single` | 1 | ~$33/mo | all private egress dies if that one AZ fails |
| `per_az` | 3 | ~$100/mo | AZ-independent egress |

We default to `single` because this is a learning deployment. Production and
gov postures want `per_az`.

The template creates **one private route table per AZ even in single mode**, so
flipping to `per_az` later only changes route targets — no subnet
re-association, no resource replacement.

## The S3 gateway endpoint is not optional

ClickHouse Private stores its table data in S3. Without a gateway endpoint,
every byte of that traffic would route through the NAT gateway and be billed
per GB. The endpoint is free and attaches to all three private route tables.

This is also the first piece of true airgap architecture: S3 traffic never
leaves the AWS network. A fully airgapped posture extends this with *interface*
endpoints for ECR, STS and CloudWatch, which would let you delete the NAT
gateway entirely. We haven't done that yet — worth revisiting for the FIPS
build.

## What got created

```
vpc-0d5974aa53e1b0031
private: subnet-04d867d3…(1a)  subnet-03a9e5dc…(1b)  subnet-09f986b8…(1c)
public:  subnet-04c1db39…(1a)  subnet-094e6106…(1b)  subnet-047bcb03…(1c)
nat-063e3858e1aeb9a78 (available)
```

Verified: private subnets do not auto-assign public IPs, all three private
route tables default to the NAT plus carry the S3 prefix-list route, and 6/6
subnets have their `kubernetes.io/role` tag.

## Note on `--check`

Two check-mode bugs surfaced while building this, both worth knowing as
patterns:

1. A read-only `command` used to gather facts gets **skipped** under `--check`,
   so a downstream `assert` sees empty output and fails misleadingly. Fix:
   `check_mode: false` on read-only lookups.
2. `set_fact` reading `stack_outputs` fails under `--check` because no stack
   exists. Fix: guard on `_vpc_stack.stack_outputs is defined`, not on state.

## Checkpoint

- [x] VPC, 3 AZs, public + private subnets, correct EKS tags
- [x] Single NAT gateway, per-AZ private route tables
- [x] S3 gateway endpoint on all private route tables
- [x] AZ/instance-type compatibility asserted before creation
- [ ] Step 4: EKS control plane
- [ ] Step 5: node groups ← **where cost becomes significant**

---

# Step 4 — EKS control plane and IRSA

**Run it:** `cd ansible && ansible-playbook deploy.yml --tags eks`
Takes ~12 min. Costs **$0.10/hr** for the control plane, with or without nodes.

## This account is shared

Account `<YOUR_ACCOUNT_ID>` is shared by all ClickHouse SAs. Two rules follow, and
they shaped the code:

1. **Never delete or modify a resource we did not create** — including stacks
   stuck in `ROLLBACK_COMPLETE`, which may be a colleague's debugging session.
   The role therefore *refuses* to clear a rolled-back stack unless you pass
   `-e clear_failed_stack=true`.
2. **Never use explicit resource names.** See below — this cost us three failed
   attempts.

## The bug worth remembering: named resources collide

The first three attempts failed with exactly this, and nothing else:

```
Validation failed with 1 error(s). Call DescribeEvents to retrieve the full
list of issues with resource and property details...
```

That message names neither the resource nor the reason, and `DescribeEvents`
is not a real API you can call for more. `validate-template` passed happily.

The cause: the template set `RoleName: !Sub "${EnvironmentName}-eks-cluster-role"`,
and **a role of that name already existed** — left orphaned by another SA's
attempt on 2026-08-31, its stack long gone.

The fix is to omit `RoleName` and let CloudFormation generate one
(`clickhouse-private-eks-EksClusterRole-h70WrPCu8OCf`). Two benefits: runs can
never collide with anyone's leftovers, and the stack needs only
`CAPABILITY_IAM` instead of `CAPABILITY_NAMED_IAM`.

**Diagnostic technique that cracked it:** the Ansible module reported only
`Module failed: Unknown error`. Re-creating the identical stack with
`aws cloudformation create-stack` directly, then reading
`describe-stack-events`, isolated it to a parameter value rather than to
Ansible. When a wrapper hides an error, go under the wrapper.

## Other traps hit

**Strings are not booleans.** `EndpointPublicAccess: !Ref PublicEndpointAccess`
from a `String` parameter fails property validation with that same opaque
message. Use a `Condition` to produce a real boolean:

```yaml
Conditions:
  PublicEndpoint: !Equals [!Ref PublicEndpointAccess, 'true']
# ...
        EndpointPublicAccess: !If [PublicEndpoint, true, false]
```

**A failed CREATE leaves an unusable husk.** The stack sits in
`ROLLBACK_COMPLETE` holding no resources, and can neither be updated nor
re-created. It must be deleted — deliberately, in a shared account.

## Choosing the Kubernetes version

Don't inherit a version from an old doc. Ask AWS:

```bash
aws eks describe-cluster-versions --profile sa --region us-east-1
```

`1.36` is the current default. `1.34` is still supported but reaches end of
standard support **2026-12-01**. Picking 1.36 also puts kubectl 1.37 within the
supported ±1 minor skew — the skew problem Part 1 flagged, now resolved:

```
kubectl client: v1.37.0
cluster server: v1.36.2-eks-bca9cf6
```

## Access: EKS access entries, not aws-auth

```yaml
AccessConfig:
  AuthenticationMode: API_AND_CONFIG_MAP
  BootstrapClusterCreatorAdminPermissions: true
```

Historically cluster permissions lived in an `aws-auth` ConfigMap that you
hand-edited, and a mistake could lock you out of your own cluster
irrecoverably. `API_AND_CONFIG_MAP` grants permissions with EKS **access
entries** — real IAM-side objects. `BootstrapClusterCreatorAdminPermissions`
gives whoever creates the stack cluster-admin; without it you can build a
cluster you cannot log into.

## Endpoint access

`EndpointPrivateAccess` stays `true` always — nodes inside the VPC resolve the
API through it, and disabling it pushes node→API traffic out over the NAT.

`EndpointPublicAccess` defaults to `true` here so `kubectl` works from your
laptop. A hardened or gov posture sets it `false` and reaches the API via
bastion, VPN, or Direct Connect. Override without editing the config:

```bash
ansible-playbook deploy.yml --tags eks -e eks_public_endpoint=false
ansible-playbook deploy.yml --tags eks -e eks_public_cidrs=1.2.3.4/32
```

## IRSA: why there's a separate OIDC step

**IRSA** (IAM Roles for Service Accounts) is how a pod gets AWS credentials
with no static keys: the cluster hands the pod a signed JWT, and STS trades it
for temporary credentials. Step 6 uses this so ClickHouse can reach its S3
bucket.

For STS to trust those tokens, the cluster's OIDC issuer must be registered in
IAM as an identity provider. That is **not** done in CloudFormation, because
`AWS::IAM::OIDCProvider` needs a CA thumbprint that can only be computed from
the live endpoint after the cluster exists.

The thumbprint is the SHA-1 fingerprint of the **root** certificate in the
endpoint's chain — the last one `openssl` prints, not the leaf:

```
cert-1: CN=*.eks.us-east-1.amazonaws.com          ← leaf, wrong one
cert-2: CN=Amazon RSA 2048 M01                    ← intermediate
cert-3: CN=Amazon Root CA 1                       ← this one
        06b25927c42a721631c1efd9431e648fa62e1e39
```

## What exists now

```
cluster:  clickhouse-private-eks  (v1.36, ACTIVE)
endpoint: https://168697C932A4ED501BF7EB85D199193C.gr7.us-east-1.eks.amazonaws.com
oidc:     arn:aws:iam::<YOUR_ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/1686...
kubeconfig: state/kubeconfig  (project-local; `source scripts/env.sh` exports KUBECONFIG)
```

```
$ kubectl get nodes
No resources found

$ kubectl get pods -A
kube-system  coredns-b8b6dd877-8qzdz  Pending
kube-system  coredns-b8b6dd877-lsvzr  Pending
```

CoreDNS pending with nothing to schedule on is exactly right — the control
plane is healthy and waiting for Step 5.

## Checkpoint

- [x] EKS 1.36 control plane, private + public endpoint access
- [x] Control plane logging (api, audit, authenticator) to CloudWatch
- [x] Project-local kubeconfig; API verified, skew within ±1
- [x] OIDC provider registered — IRSA trust policies can reference it
- [x] Role idempotent (`changed=0` on re-run)
- [x] Step 5: node groups — see below (done at ~$2.32/hr, not the ~$12.18/hr the tutorial's sizes cost)

---

# Step 5 — Managed node groups

This is the first step that starts real compute, and the most expensive thing
in the whole deployment. Everything up to now cost about $3.50/day; this adds
roughly $52/day at the sizes we picked, and would add $289/day at the sizes the
tutorial specifies.

Run it with:

```bash
ansible-playbook deploy.yml --tags nodes
```

## Three node groups, because there are three different jobs

| Group | What runs there | Why it is separate |
|---|---|---|
| **keeper** | ClickHouse Keeper (the Raft-style consensus service) | Small, odd-numbered, latency-sensitive. Three nodes, never two or four — a quorum needs an odd count. |
| **server** | `clickhouse-server` — the database itself | Large, and the only group that needs local NVMe SSD for its read cache. |
| **operator** | The ClickHouse operator, plus cluster add-ons (CoreDNS, EBS CSI controller) | The only **untainted** group. Once the other two are tainted, this is the only place an ordinary pod can land. |

That last row is the one people miss. If you taint every node group, CoreDNS
never schedules and DNS inside the cluster silently never works.

## Picking sizes: let the chart tell you the floor

The tutorial specifies `m7g.2xlarge` / `m7gd.16xlarge` / `m7i.2xlarge`. We are
running smaller ones — but not arbitrarily smaller. The floor is set by what
the `onprem-clickhouse-cluster` chart actually asks for. Pull it and look:

```bash
helm pull oci://<your-ecr>/helm/onprem-clickhouse-cluster --version 1.8.7 --untar
grep -A12 'podPolicy:' onprem-clickhouse-cluster/values.yaml
```

```yaml
server.podPolicy.resources.requests:   {cpu: "4", memory: 8Gi}
keeper.podPolicy.resources.requests:   {cpu: "2", memory: 4Gi}
server.replicaCount: 3
keeper.replicaCount: 3
```

Now the subtlety: **a node's allocatable CPU is less than its vCPU count.**
The kubelet reserves some for itself and the OS, so a 4-vCPU node advertises
around 3,920m of allocatable CPU. A pod requesting exactly `4` CPU therefore
does *not* fit on a 4-vCPU node — it stays `Pending` with
`0/9 nodes are available: Insufficient cpu`, which is a maddening error to
debug because the node looks big enough.

So the smallest types that actually work are one size class up from the pod
request:

| Group | Pod request | Smallest node that fits | Tutorial size |
|---|---|---|---|
| keeper | 2 CPU / 4Gi | `m7g.xlarge` (4 vCPU, 16Gi) | `m7g.2xlarge` |
| server | 4 CPU / 8Gi | `m7gd.2xlarge` (8 vCPU, 32Gi, 474 GB NVMe) | `m7gd.16xlarge` |
| operator | — | `m7i.xlarge` (4 vCPU, 16Gi) | `m7i.2xlarge` |

To go smaller than this you must also override the chart's resource requests,
which changes what you are testing. This is the honest floor for an unmodified
chart.

### What that saves

Prices are us-east-1 on-demand, read from the AWS Pricing API on 2026-09-03.

| | Tutorial sizes | Our sizes |
|---|---|---|
| keeper (3) | $0.98/hr | $0.49/hr |
| server (3) | $10.25/hr | $1.28/hr |
| operator (2) | $0.81/hr | $0.40/hr |
| **compute** | **$12.04/hr** | **$2.17/hr** |
| + control plane + NAT | $12.18/hr | $2.32/hr |
| **per day** | **~$292** | **~$56** |

The role prints this before it creates anything. Note that `max_nodes` costs
nothing until something scales — only `min_nodes` is running.

The knobs are in `group_vars/all.yml` under `infrastructure`, and the VPC role
re-validates any instance type you choose against the AZs before use.

## Labels: the `-arm64` suffix that looks like a bug — and is one

The tutorial says to label ARM64 node groups:

```
clickhouseGroup: server-arm64      # not "server"
clickhouseGroup: keeper-arm64
```

But the chart's `nodeSelector` stays:

```yaml
server.podPolicy.nodeSelector:
  clickhouseGroup: server          # no suffix
```

The chart's own comment says this is intended:

> **This value must match the node labels of the server node group** excluding
> the `-arm64` suffix, if using arm64.

and its README explains the mechanism: the
`clickhouse-server-configuration-webhook` appends `-arm64` to the selector at
admission time when the CR is labelled `arm64-preferred`. **Step 8 disables
webhooks**, on the tutorial's own instruction, and nothing else appends it.
The first Step 9 run proved this directly — every Keeper pod Pending, with the
scheduler's reason and the pod's actual selector:

```
0/8 nodes are available: 8 node(s) didn't match Pod's node affinity/selector.
nodeSelector: {"clickhouseGroup":"keeper"}      # nodes say keeper-arm64
```

So the tutorial's Step 5 and Step 9, followed literally with webhooks off,
produce a cluster that cannot schedule. The resolution here: **keep the node
labels as the tutorial has them, and put the suffix in the chart's selector**
(`clickhouseGroup: keeper{{ node_label_suffix }}`). `group_vars` derives the
suffix from the `fips` switch, since the FIPS build is x86 and takes no
suffix, and the Step 9 role uses that same variable — so the two sides cannot
drift. An earlier version of this section said the operator appends the suffix
itself; it does not.

## Taints, and a deliberate asymmetry

| Group | Taints |
|---|---|
| keeper | `clickhouse.com/do-not-schedule=true:NoSchedule` + (arm64 only) `clickhouse.com/arch=arm64:NoSchedule` |
| server | `clickhouse.com/do-not-schedule=true:NoSchedule` |
| operator | none |

`do-not-schedule` fences off the dedicated database nodes. Notice the chart
ships `tolerations: []` — you do **not** add tolerations yourself; the operator
injects the matching ones when it creates the pods. (DaemonSets like
`aws-node` and `kube-proxy` tolerate everything by default, so the CNI still
comes up on tainted nodes.)

The arch taint appears on **keeper only**, not server. That asymmetry is in the
tutorial and we reproduce it exactly rather than tidying it up. The reasoning is
about which mistake is worse: a taint the operator does not tolerate leaves
pods `Pending` forever, whereas a missing taint merely allows an unrelated pod
onto a database node. Deviating toward the silent-failure side is not worth it,
and taints can be changed on a live node group later if Step 9 shows otherwise.

## Launch templates, and three gotchas

All three groups use a launch template. Two of the reasons are CloudFormation
trivia worth knowing:

**1. `DiskSize` and `LaunchTemplate` are mutually exclusive.** Set both on an
`AWS::EKS::Nodegroup` and it fails validation. Once you want a launch template
for any reason, the boot disk moves into its `BlockDeviceMappings`.

**2. Omit `ImageId`, and EKS *merges* rather than replaces.** With no `ImageId`
in the template, EKS supplies the AMI from `AmiType` and appends its own
`nodeadm` bootstrap config to your user data. This is why the user data must be
a **MIME multipart document**, not a bare `#!/bin/bash` script — a bare script
would be discarded and the node would boot without ever joining the cluster.

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/usr/bin/env bash
...our NVMe setup...
--//--
```

**3. IMDS hop limit.** The template sets `HttpTokens: required` (IMDSv2 only,
which defeats the SSRF attack class that made IMDSv1 notorious) and
`HttpPutResponseHopLimit: 2`. A hop limit of 1 stops at the host and cuts
*pods* off from IMDS entirely; the tutorial states nodes require IMDS for
authentication. Once every workload uses IRSA instead, drop it to 1.

## The NVMe cache disk

The `d` in `m7gd` is not cosmetic — it means local NVMe SSD, and it is the
whole reason to choose that family. ClickHouse uses it as a read cache, at
`/nvme/disk` (the operator's default `hostPathBaseDirectory`). Pick a type
without the `d` and the cache silently lands on the 20 GiB root volume and
fills it.

Nothing mounts that disk for you. The user data does it, and there is one trap
in doing it safely:

> **On Nitro instances, EBS volumes also appear as `/dev/nvme*`.** Selecting
> devices by path would happily reformat your root disk. The only safe
> discriminator is the model string — ephemeral instance store reports
> `Amazon EC2 NVMe Instance Storage`.

```bash
lsblk -dn -o NAME,MODEL | awk '/Amazon EC2 NVMe Instance Storage/ {print $1}'
```

With more than one device (the bigger `d` types expose several) the script
stripes them with `mdadm --level=0`. RAID0 has no redundancy, which is the
right call for a cache that can be rebuilt from S3.

### Verifying it, because it fails silently

A missing cache mount does not throw an error anywhere — ClickHouse just gets
slower and the root disk fills up days later. So the role proves it directly by
running a probe pod on a server node:

```yaml
spec:
  nodeName: ip-10-20-x-x.ec2.internal     # note: nodeName, not nodeSelector
  containers:
    - image: <ecr>/clickhouse-server:26.2.1.525
      command: ["sh", "-c", "df -h /nvme/disk && mount | grep ' /nvme/disk '"]
  volumes:
    - name: nvme
      hostPath: {path: /nvme/disk, type: Directory}
```

Two deliberate choices there:

- **`.spec.nodeName` bypasses the scheduler entirely**, so the pod lands on a
  tainted node without needing any toleration. That is a genuinely useful trick
  for probing tainted nodes.
- It runs the **`clickhouse-server` image**, because in an airgapped cluster
  that is an image we *know* is in ECR. Reaching for `busybox` would fail —
  there is no Docker Hub here.

`hostPath: {type: Directory}` means the pod stays `Pending` if the directory
does not exist, rather than kubelet quietly creating an empty one — so a failed
user-data script shows up as a failed check instead of a working-looking mount
on the root volume.

If that check fails, the log is on the node:

```bash
aws ssm start-session --target <instance-id> --profile sa
sudo cat /var/log/clickhouse-nvme-setup.log
```

which works because the node role carries `AmazonSSMManagedInstanceCore` — no
SSH key, no bastion, no inbound security group rule. That policy is not in the
tutorial; it is there so you can inspect a node that refuses to join.

## Why the node groups have no names

None of the three sets `NodegroupName`. Beyond the shared-account
name-collision reasoning from Step 4, there is a specific mechanical reason:

**Changing an instance type forces CloudFormation to replace a node group**,
and it cannot create the replacement while a same-named one still exists. An
explicit name turns every resize into a failed update. With generated names,
CFN creates the new group, moves on, and deletes the old one.

Find them by label instead:

```bash
kubectl get nodes -L clickhouseGroup
```

## One node group across three AZs, not three groups

Each group spans all three private subnets, so EKS spreads its nodes across
AZs. The tutorial suggests one node group *per AZ* instead. That only matters
once cluster-autoscaler is involved: the autoscaler cannot tell which AZ a
pending pod's EBS volume is pinned to, so it may grow a group in the wrong AZ
and never satisfy the pod. We are not running the autoscaler, so one group per
workload is simpler and behaves identically.

## The trap we actually hit: the AMI type enum

Our first run failed, and it is a good example of a failure that costs money
and time for a trivial reason. The tutorial writes the AMI types as:

```
AL2023_x86_64      /  AL2023_ARM_64
```

Those are not the API's values. The real enum is:

```
AL2023_x86_64_STANDARD    AL2023_ARM_64_STANDARD
AL2023_x86_64_NVIDIA      AL2023_ARM_64_NVIDIA
AL2023_x86_64_NEURON
```

`aws cloudformation validate-template` passes either way — it does not know
what EKS accepts. The failure only shows up when the node group resource is
created, several minutes in, *after* the IAM role and both launch templates
have already been built:

```
KeeperNodeGroup  CREATE_FAILED  "AMI type AL2023_ARM_64 is not valid"
```

CloudFormation then rolls the whole stack back and leaves it in
`ROLLBACK_COMPLETE`, which cannot be updated — so the fix also needs the
opt-in husk cleanup from Step 4:

```bash
ansible-playbook deploy.yml --tags nodes -e clear_failed_stack=true
```

The general lesson: enum values in prose documentation are worth checking
against the API before a long-running create. Where to look:

```bash
aws eks create-nodegroup help | grep -oE 'AL2023_[A-Za-z0-9_]+' | sort -u
```

## What exists now

```
$ kubectl get nodes -L clickhouseGroup -L node.kubernetes.io/instance-type -L topology.kubernetes.io/zone
NAME                            STATUS  VERSION              CLICKHOUSEGROUP  INSTANCE-TYPE  ZONE
ip-10-20-52-145.ec2.internal    Ready   v1.36.3-eks-cb19647  server-arm64     m7gd.2xlarge   us-east-1a
ip-10-20-102-15.ec2.internal    Ready   v1.36.3-eks-cb19647  server-arm64     m7gd.2xlarge   us-east-1b
ip-10-20-167-37.ec2.internal    Ready   v1.36.3-eks-cb19647  server-arm64     m7gd.2xlarge   us-east-1c
ip-10-20-61-232.ec2.internal    Ready   v1.36.3-eks-cb19647  keeper-arm64     m7g.xlarge     us-east-1a
ip-10-20-80-106.ec2.internal    Ready   v1.36.3-eks-cb19647  keeper-arm64     m7g.xlarge     us-east-1b
ip-10-20-142-145.ec2.internal   Ready   v1.36.3-eks-cb19647  keeper-arm64     m7g.xlarge     us-east-1c
ip-10-20-106-4.ec2.internal     Ready   v1.36.3-eks-cb19647                   m7i.xlarge     us-east-1b
ip-10-20-148-38.ec2.internal    Ready   v1.36.3-eks-cb19647                   m7i.xlarge     us-east-1c
```

Three nodes per group, one per AZ, labels carrying the `-arm64` suffix, and
the two operator nodes deliberately unlabelled.

Taints landed as intended — note keeper carries two and server one:

```
GROUP          TAINTS
server-arm64   clickhouse.com/do-not-schedule
keeper-arm64   clickhouse.com/do-not-schedule,clickhouse.com/arch
<none>         <none>
```

The NVMe cache is real, not a directory on the root volume:

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1    442G  3.2G  439G   1% /nvme/disk
/dev/nvme1n1 /nvme/disk xfs rw,seclabel,noatime,inode64,logbufs=8,logbsize=32k,noquota 0 0
```

442 GiB of local SSD per server node, versus the 20 GiB root disk it would
otherwise have silently used.

### The sizing argument, confirmed by the cluster itself

The claim above was that allocatable CPU is less than vCPU count. The nodes
now say so directly:

```
m7g.xlarge   (4 vCPU)  ->  cpu=3920m   mem=15031500Ki
m7gd.2xlarge (8 vCPU)  ->  cpu=7910m   mem=31231064Ki
```

`3920m < 4000m`. A server pod requesting exactly `4` CPU would not fit on a
4-vCPU node — which is precisely why the server group is `2xlarge` and not
`xlarge`. This is the single most useful number to check whenever a pod is
inexplicably `Pending`:

```bash
kubectl describe node <name> | grep -A8 'Allocatable:'
```

### CoreDNS moved, which proves the taints work

Before this step CoreDNS was `Pending` with nowhere to go. It is now running —
and specifically on an **operator** node:

```
kube-system  coredns-b8b6dd877-8qzdz  Running  ip-10-20-148-38.ec2.internal   <- operator node
kube-system  coredns-b8b6dd877-lsvzr  Running  ip-10-20-148-38.ec2.internal   <- operator node
kube-system  aws-node-*     (8 pods)  Running  every node, tainted included
kube-system  kube-proxy-*   (8 pods)  Running  every node, tainted included
```

That is the whole taint design visible in one output. CoreDNS is an ordinary
Deployment with no tolerations, so it can only land on the untainted operator
group. `aws-node` (the VPC CNI) and `kube-proxy` are DaemonSets that tolerate
everything, so they run on the tainted database nodes too — which they must,
or those nodes would have no pod networking at all.

## Checkpoint

- [x] Three node groups: keeper (3), server (3), operator (2) — all `Ready`
- [x] One node per AZ per group across us-east-1a/b/c
- [x] Labels `keeper-arm64` / `server-arm64`; operator unlabelled
- [x] Taints applied; CoreDNS confirmed scheduling only on the operator group
- [x] Instance-store NVMe striped and mounted at `/nvme/disk` (442 GiB/node)
- [x] Node role carries worker, CNI, ECR-read and SSM policies
- [x] Role idempotent (`changed=0` on re-run)
- [x] Running cost ~$2.32/hr (~$56/day), vs ~$12.18/hr at tutorial sizes
- [ ] Step 6: S3 bucket + IRSA roles

**Teardown for the expensive part only**, leaving the cluster and VPC intact:

```bash
ansible-playbook deploy.yml --tags nodes -e nodegroups_state=absent
```

That drops the bill back to ~$3.50/day. Re-running `--tags nodes` rebuilds the
nodes in about five minutes, so there is no reason to leave them running
overnight while working through this guide.
