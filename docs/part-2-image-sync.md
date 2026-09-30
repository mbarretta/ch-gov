# Part 2 — Steps 1 to 5: registry access, the image hop, the network, EKS and nodes

> **What you'll learn**
>
> - How the ECR pull role and the source-registry grant let your account read ClickHouse's images, and what the playbook checks before it copies anything (Step 1).
> - How container images and Helm charts make one hop into your own registry with `skopeo`, why the copy uses `--all`, and what the `fips` switch changes (Step 2).
> - What Steps 3 to 5 build (the VPC, the EKS control plane, and three node groups), why each design choice was made, and where the money starts.
> - How to check each step yourself, and how to fix the common failures.
>
> **Run it:** `scripts/up.sh` runs every step in order and asks before it starts. To run one step at a time while you read, see "Advanced: run individual steps" below. Steps 1 and 2 need no cluster and no compute. Step 3 is where AWS charges start, and Step 5 is where they become significant.

The upstream tutorial for this deployment is [deploy-aws](https://clickhouse.com/docs/cloud/clickhouse-private/tutorials/deploy-aws). The playbook implements its Steps 1 to 5 in the roles named in each section below, and this Part explains the reasoning behind them.

Three placeholders appear in this Part, and each is a value you set in `state/deploy-vars.yml` (Part 1, section 3b). `<YOUR_ACCOUNT_ID>` is your AWS account (`aws.target_account_id`). `<SOURCE_ECR_ACCOUNT_ID>` is the account that hosts ClickHouse's source registry (`aws.source_ecr_account_id`), which ClickHouse gives you. `<region>` is your AWS Region (`aws.target_region`, default `us-east-1`).

## Advanced: run individual steps

`scripts/play.sh` runs the playbook with your environment set up (Part 1, section 5). Pass it one tag to run one step. These are the tags for this Part:

| Step | Tag | What it does | Roles |
|---|---|---|---|
| 1 | `pull-role` | Read-only check that the ECR pull role can be assumed | `ecr_pull_role` |
| 1 and 2 | `images` | The check, then the ECR repositories, then the copy | `ecr_pull_role`, `ecr_setup`, `image_sync` |
| 3 | `vpc` | The VPC, subnets, NAT gateway and S3 endpoint | `vpc` |
| 4 | `eks` | The EKS control plane and the IRSA identity provider | `eks_cluster` |
| 5 | `nodes` | The three node groups | `eks_nodegroups` |

```bash
scripts/play.sh --tags images          # Steps 1 and 2
scripts/play.sh --check --tags vpc     # dry run: preview a step without creating anything
scripts/up.sh --from vpc               # start the ordered run at a step
```

Each step is idempotent, so running one again changes nothing that already matches. That makes re-running the step the standard way to recover from a failure.

---

## Step 1: The ECR pull role and the source-registry grant

**Run it:** `scripts/play.sh --tags pull-role`

Step 1 of the upstream tutorial is about permission. ClickHouse Government is built for airgapped networks, so your cluster pulls images only from your own registry. *You* first copy those images out of ClickHouse's registry, and that needs an identity that is allowed to read it. Two accounts are involved:

| Account | Role in the story |
|---|---|
| `<YOUR_ACCOUNT_ID>` | **Yours.** Holds the pull role, your ECR, and the cluster. |
| `<SOURCE_ECR_ACCOUNT_ID>` | **ClickHouse's.** Where the images live. You only ever read. |

The pull role lives in *your* account and points *outward*. ClickHouse sets it up there, together with a read grant on the source repositories for your account. You create nothing in either account.

### What has to exist

1. **The grant.** Share your AWS account ID with your ClickHouse contact. They arrange read access to the source registry for your account.
2. **The role.** ClickHouse sets up `ClickHouseAirgapECRPullRole` (the name is `aws.ecr_pull_role_name`) in your account. Its trust relationship lets your deploying identity assume it, and it carries the read access to the three source repositories the kit uses. You do not create it. Part 1 lists the exact actions under [What the pull role needs](part-1-prerequisites.md#what-the-pull-role-needs).
3. **The profile.** `aws.source_ecr_profile` (default `ch-gov-ecr-pull`) assumes that role, chaining off your target profile. In SSO mode the kit renders it for you. In profile mode you add it to your own AWS config, as Part 1 shows under Path B in [AWS access: one setting, two paths](part-1-prerequisites.md#3-aws-access-one-setting-two-paths).

The kit never creates or changes the role, and the playbook only proves that you can assume it.

### What the playbook checks

The `ecr_pull_role` role runs first, before any image work, and it is read-only. It makes one `aws sts get-caller-identity` call, which changes nothing, so it also runs during a `--check` dry run. Two checks then read the result:

- **The profile authenticates.** If `aws.source_ecr_profile` fails to authenticate, the run stops with a message that names the profile, the AWS exit code and the error text. It tells you to ask ClickHouse to confirm the role is set up for your account, and to check that your target profile is logged in.
- **The identity is the pull role.** An IAM user or an unrelated role can also authenticate, so authenticating is not enough. The role checks that the identity is an assumed-role session of `aws.ecr_pull_role_name` in `aws.target_account_id`. Anything else stops the run with a message that says what it expected and what it got.

Failing here is deliberate. A missing or mis-trusted role stops the run with a plain message at the start, instead of surfacing as a `skopeo` error several steps later.

The check proves you can assume the role. It does not prove the role can read the source repositories. The first real read happens in Step 2, and `scripts/part1-setup.sh` also checks it (Part 1, section 6).

### Verify it yourself

```bash
source scripts/env.sh
aws sts get-caller-identity --profile ch-gov-ecr-pull --query Arn --output text
scripts/play.sh --tags pull-role
```

Replace `ch-gov-ecr-pull` with your `source_ecr_profile` if you changed the name. The first command prints an ARN in your account that ends `assumed-role/ClickHouseAirgapECRPullRole/` followed by the session name. The second prints a line that says the profile assumes the pull role in your account. If either fails, see Troubleshooting at the end of this Part.

---

## Step 2: Copy the images

**Run it:** `scripts/play.sh --tags images` (this runs Step 1's check first)

Two roles run in this step. `ecr_setup` creates the repositories in your account, and `image_sync` copies everything into them.

### What gets copied: at least these seven artifacts

The default build copies seven artifacts, four container images and three Helm charts:

```
                    source                                        your ECR (<YOUR_ACCOUNT_ID>)
  container images  clickhouse-server   (versions.server)         →  same
                    clickhouse-keeper   (versions.keeper)         →  same
                    clickhouse-operator (versions.operator_image) →  same
                    kubebuilder/kube-rbac-proxy (registry.k8s.io) →  same
  helm charts       helm/clickhouse-operator-helm                 →  same
                    helm/onprem-clickhouse-cluster                →  same
                    helm/preflight-check                          →  same
```

The ClickHouse images and charts come from the source registry in `<SOURCE_ECR_ACCOUNT_ID>`. The fourth image, `kube-rbac-proxy`, is a small sidecar that sits in front of the operator's metrics endpoint. ClickHouse's charts reference it but do not publish it, so it comes from `registry.k8s.io`. The airgapped design has the cluster pull only from your registry, so every image it needs must be there, or the pod that needs it stays in `ImagePullBackOff`. (The NAT gateway that Step 3 creates exists only in this learning environment, so that you can reach and test the cluster. It is not part of the production deployment.) The tags come from the `versions:` block in `ansible/group_vars/all.yml`.

The **Helm charts travel through the registry too**, which surprises people. They are OCI artifacts, not container images, and the manifest shows it:

```
config: application/vnd.cncf.helm.config.v1+json
layers: application/vnd.cncf.helm.chart.content.v1.tar+gzip
```

That is the point of the airgapped design. A typical deployment would `helm repo add https://…` and pull charts over the internet. Here the charts are stored as OCI artifacts in your ECR and installed with `helm install oci://…`, so the install pulls only from your own registry.

Two options add more artifacts to the list, and both are off by default. With `langfuse.enabled` the sync also copies the Langfuse images and chart (Part 6), and with `grafana.enabled` it copies the Grafana images and chart (Part 8), so seven is the minimum. The Langfuse and Grafana charts come from plain Helm HTTP repositories, which `skopeo` cannot read, so `image_sync` pulls them with `helm pull` and pushes them to your ECR with `helm push`.

### Why the repositories are created first

**ECR does not create repositories on push.** Copying into a repository that does not exist fails with `RepositoryNotFoundException`. The `ecr_setup` role therefore creates every repository before the copy starts. It first checks that your target profile resolves to `aws.target_account_id`, so a profile that points at the wrong account stops the run before it creates anything.

The role also sets two options on each repository:

- `image_tag_mutability: immutable`. Once a tag is pushed (for example your `versions.server` tag), it can never be repointed at different content. For a database you must be able to reason about after an incident, "the tag means what it meant last week" is worth a lot.
- `scan_on_push: true`. ECR scans each image for known CVEs on arrival. It costs little, and it is useful if you have to produce vulnerability evidence for an authorization package.

### Why skopeo instead of docker

`docker pull` followed by `docker push` drags every layer down to your machine and back up again, which is several gigabytes moved twice per architecture. `skopeo copy` tells the two registries to transfer layers directly. It needs no Docker daemon, and your machine only relays metadata. How long the full copy takes depends on your region and network, and a first run moves several gigabytes.

### `--all` is not optional

```bash
skopeo copy --all docker://source/repo:tag docker://target/repo:tag
```

Without `--all`, `skopeo` copies only the manifest that matches *your* platform, which is arm64 on an Apple Silicon Mac. You would publish an arm64-only image and then watch pods fail to start on x86 nodes with an opaque manifest error. With `--all` you get the whole manifest list, which for a ClickHouse image looks like this:

```
linux/amd64
linux/arm64
unknown/unknown      ← SBOM and provenance attestations, when the source publishes them
```

A plain tag is therefore a manifest list, and each node pulls the entry that matches its own architecture. The FIPS build does not reuse the plain tags. It uses separate `-fips` tags, which are different images, and `group_vars` appends the suffix for you (see below).

### The `fips` switch

`ansible/group_vars/all.yml` has one variable that changes the whole build:

```yaml
fips: false     # true = FIPS x86_64 build
```

Set `fips: true` in `state/deploy-vars.yml` to make it persistent. For a single run, pass it on the command line:

```bash
scripts/play.sh --tags images                 # standard
scripts/play.sh --tags images -e fips=true    # FIPS
```

What it changes in this Part:

| | `fips: false` | `fips: true` |
|---|---|---|
| image tags | the `versions:` value, such as `versions.server` | the same value with `-fips` appended |
| chart tags | the `versions:` value, such as `versions.cluster_chart` | the same value, *unchanged* |
| target registry | `<YOUR_ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com` | `<YOUR_ACCOUNT_ID>.dkr-ecr-fips.<region>.on.aws` |

Only the three ClickHouse **container images** have `-fips` variants. The Helm charts are shared between both builds, and the FIPS variant is selected by image tag, not by a different chart. Appending `-fips` to a chart version produces a tag that does not exist.

The switch changes more than tags:

- **x86_64 nodes only.** ClickHouse validates its FIPS crypto on x86_64 and not on ARM64, so the ARM instance types are out. `node_ami_type` in `ansible/group_vars/all.yml` selects `AL2023_x86_64_STANDARD` under `fips: true`.
- **TLS-only on port 9440.** [Part 7 §4](part-7-fips-hardening.md#4-in-transit-tls-clickhouse-native-langfuse-to-clickhouse-and-the-langfuse-nlb) wires `server.openSSL` and `keeper.openSSL` so ClickHouse's native protocol moves to port 9440 under `fips: true`, with the certificate chain verified.
- **RSA-3072 or larger certificates per cluster.** The same section adds `tls_rsa_bits` (3072 under `fips: true`) and generates the CA and leaf certificate at that size.

One related rule does not depend on `fips`: `clickhouse.bucket_name` never contains a period, so virtual-hosted-style S3 requests never break on TLS certificate matching.

[FIPS.md](../FIPS.md) is the one-page summary of what `fips: true` covers and what it does not. The FIPS validation belongs to ClickHouse's crypto modules, and the kit selects and wires them. [Limitations](limitations.md) states what the kit covers and does not cover by design.

### Notes on the Ansible

**Where the AWS config comes from.** In SSO mode the playbook points `AWS_CONFIG_FILE` at the repo's `.aws/config`, so it works whether or not you sourced `scripts/env.sh`. In profile mode it leaves your AWS config alone.

**Why there is a virtual environment.** The `community.aws` modules import `boto3` inside whichever Python runs the module. `.venv/` at the repo root holds it, and `ansible_python_interpreter` in `group_vars/all.yml` points there. `scripts/part1-setup.sh` creates it (Part 1, section 2).

**Both roles are idempotent and resumable.** `image_sync` checks each target tag before it copies, so an interrupted run resumes instead of recopying gigabytes. Re-running the step reports no changes:

```
ecr_setup:   changed=0
image_sync:  0 copied, N already present (standard build); 0 chart(s) to push with helm
```

`N` is the number of artifacts in play: 7 for the default set, more when `langfuse.enabled` or `grafana.enabled` adds theirs.

**Why there are no shell pipelines.** The role does not pipe `aws ecr get-login-password` into `skopeo login`. It passes the registry token through the `command` module's `stdin` instead, which keeps the token out of the argument list, the process table and the log.

**Where the skopeo credentials go.** `state/skopeo-auth.json`, not `~/.config/containers/auth.json`, which keeps the project self-contained. It holds live registry tokens that expire after 12 hours, and it is gitignored.

---

## Step 3: VPC and networking

**Run it:** `scripts/play.sh --tags vpc`

**Tear it down:** `scripts/down.sh --all` removes the whole stack in the right order, and keeps only your S3 data and ECR images. To remove only this step, after the cluster and node groups are gone: `scripts/play.sh --tags vpc -e vpc_state=absent`.

### Why CloudFormation here, when Steps 1 and 2 used plain modules

Infrastructure gets a CloudFormation stack rather than a chain of `ec2_vpc_*` Ansible tasks, for one reason: **teardown**. NAT gateways and Elastic IPs bill hourly whether or not anything uses them, and a half-finished module chain leaves orphans that quietly cost money. `state: absent` on a stack deletes every resource in dependency order. The `vpc` role deploys the stack `clickhouse-private-vpc` (the name comes from `infrastructure.environment_name`).

### The availability-zone trap

Subnets are pinned to an availability zone and cannot be moved. If you place one in a zone that does not offer your node instance type, nothing fails until the node group is created, and the error does not mention availability zones.

In `us-east-1`, `us-east-1e` offers none of the default node instance types. The default zones are the first three of your region (`a`, `b` and `c` in `us-east-1`), which support every default type for both builds. Before it creates anything, the `vpc` role asks EC2 which zones offer each instance type and stops with a clear message if one does not.

### The layout

| | CIDR | Purpose |
|---|---|---|
| VPC | `10.20.0.0/16` | |
| private ×3 | `10.20.0.0/18`, `.64.0/18`, `.128.0/18` | all nodes and pods |
| public ×3 | `10.20.192.0/20`, `.208.0/20`, `.224.0/20` | NAT gateways, internet-facing load balancers |

**Why /18 for the private subnets** (about 16,000 addresses each): the AWS VPC CNI gives every *pod* a real VPC IP address. Pod density is therefore bounded by subnet size, not only by node count, and undersizing is painful to fix later. You can change the ranges under `infrastructure` in `state/deploy-vars.yml`.

### Two things EKS needs that are easy to miss

- **`EnableDnsSupport` and `EnableDnsHostnames`.** Without both, pods get no working DNS, and the private hosted zones that EKS and VPC endpoints depend on do not resolve.
- **Subnet tags.** `kubernetes.io/role/elb=1` marks the public subnets and `kubernetes.io/role/internal-elb=1` marks the private ones. This is how Kubernetes decides where to place the load balancer for a service. Without the tags, `type: LoadBalancer` services hang in `pending`.

### NAT: the first real cost decision

```yaml
infrastructure:
  nat_mode: "single"    # or "per_az"
```

| Mode | NAT gateways | Approximate idle cost | Failure behavior |
|---|---|---|---|
| `single` | 1 | $33 a month | all private egress stops if that one zone fails |
| `per_az` | 3 | $100 a month | zone-independent egress |

The kit defaults to `single` because it is sized for learning and workshops, not production. A production or government posture wants `per_az`. The template creates **one private route table per zone even in single mode**, so switching to `per_az` later only changes route targets, with no subnet re-association and no resource replacement.

### The S3 gateway endpoint is not optional

ClickHouse stores its table data in S3. Without a gateway endpoint, every byte of that traffic would route through the NAT gateway and be billed per GB. The endpoint is free, and it attaches to all three private route tables.

It also fits the airgapped design, because S3 traffic never leaves the AWS network. The NAT gateway exists only in this learning environment, so that you can reach and test the cluster, and it is not part of the production deployment. *Interface* endpoints for ECR, STS and CloudWatch would let you remove the NAT gateway entirely. The kit does not create them. [Limitations](limitations.md) lists this and the other scope boundaries.

### Dry runs

`scripts/play.sh --check --tags vpc` previews the change without creating a stack. Read-only lookups still run in check mode, and tasks that read stack outputs skip cleanly when no stack exists yet, so the preview reports what would change instead of failing on empty values.

---

## Step 4: EKS control plane and IRSA

**Run it:** `scripts/play.sh --tags eks`

The step takes 10 to 15 minutes. The control plane costs $0.10 an hour, with or without nodes.

**Tear it down:** `scripts/down.sh --all` removes the whole stack in the right order, and keeps only your S3 data and ECR images. To remove only this step, after the node groups are gone: `scripts/play.sh --tags eks -e eks_state=absent`.

### Do not name what CloudFormation can name

Neither the cluster stack nor the node group stack sets an explicit `RoleName` or `NodegroupName`. CloudFormation generates the names instead (for example, an IAM role called `clickhouse-private-eks-EksClusterRole-` followed by a random suffix). That avoids two problems:

- **Collisions.** An explicit name collides with any leftover of the same name in the account, and CloudFormation reports the collision only as `Validation failed with 1 error(s). Call DescribeEvents to retrieve the full list of issues...`, which names neither the resource nor the reason.
- **Capabilities.** The stack needs only `CAPABILITY_IAM` instead of `CAPABILITY_NAMED_IAM`.

If you edit a template and meet that message, create the identical stack with `aws cloudformation create-stack` and read `aws cloudformation describe-stack-events` for the real error.

The same message appears when a `String` parameter is used where a boolean is required: `EndpointPublicAccess: !Ref PublicEndpointAccess` fails property validation. The template therefore uses a `Condition` to produce a real boolean:

```yaml
Conditions:
  PublicEndpoint: !Equals [!Ref PublicEndpointAccess, 'true']
# ...
        EndpointPublicAccess: !If [PublicEndpoint, true, false]
```

### A failed first create leaves an unusable stack

When the very first CREATE of a stack fails, the stack sits in `ROLLBACK_COMPLETE`. It holds no resources, and it can neither be updated nor re-created. It must be deleted. Because an account can hold stacks this playbook did not create, the `eks_cluster` and `eks_nodegroups` roles never delete such a stack on their own. They stop and tell you to confirm the stack is yours, then re-run with `-e clear_failed_stack=true`:

```bash
scripts/play.sh --tags eks -e clear_failed_stack=true
```

### Choosing the Kubernetes version

Do not inherit a version from an old document. Ask AWS:

```bash
aws eks describe-cluster-versions --profile "$AWS_PROFILE"
```

The kit pins `infrastructure.eks_version` in `ansible/group_vars/all.yml`. The output shows each version's status and the date its standard support ends, so use it to pick a version that will stay supported for as long as you plan to use the cluster. Pick a version that keeps your `kubectl` within one minor version of the cluster, which is the supported skew ([Part 1 troubleshooting](part-1-prerequisites.md#7-troubleshooting) covers the warning).

### Access: EKS access entries, not aws-auth

```yaml
AccessConfig:
  AuthenticationMode: API_AND_CONFIG_MAP
  BootstrapClusterCreatorAdminPermissions: true
```

Historically, cluster permissions lived in an `aws-auth` ConfigMap that you edited by hand, and a mistake could lock you out of your own cluster irrecoverably. `API_AND_CONFIG_MAP` grants permissions with EKS **access entries**, which are real IAM-side objects. `BootstrapClusterCreatorAdminPermissions` makes whoever creates the stack a cluster administrator. Without it you can build a cluster you cannot log in to. That is why Part 1 tells you to use the same identity for `kubectl` that you deployed with.

### Endpoint access and logging

`EndpointPrivateAccess` stays `true` always. Nodes inside the VPC resolve the API through it, and disabling it pushes node-to-API traffic out over the NAT.

`EndpointPublicAccess` defaults to `true` so `kubectl` works from your laptop. A hardened or government posture sets it to `false` and reaches the API through a bastion, VPN or Direct Connect. Override it without editing any file:

```bash
scripts/play.sh --tags eks -e eks_public_endpoint=false
scripts/play.sh --tags eks -e eks_public_cidrs=203.0.113.4/32
```

The control plane sends its `api`, `audit` and `authenticator` logs to CloudWatch. The role sets the log group to expire after `infrastructure.eks_log_retention_days` (default 30), because EKS creates the group with no expiry and it outlives the cluster.

With `fips: true`, the cluster also encrypts Kubernetes Secrets in etcd with a customer-managed KMS key. EKS never lets you remove or repoint that key on an existing cluster, so the role refuses to add it to a cluster that already exists unless you pass `-e confirm_encryption_config=true`. [Part 7 §3](part-7-fips-hardening.md#3-eks-secrets-envelope-encryption) explains it.

### IRSA: why there is a separate OIDC step

**IRSA** (IAM Roles for Service Accounts) is how a pod gets AWS credentials with no static keys. The cluster hands the pod a signed token, and STS trades it for temporary credentials. Part 3 uses this so ClickHouse can reach its S3 bucket.

For STS to trust those tokens, the cluster's OIDC issuer must be registered in IAM as an identity provider. That is **not** done in CloudFormation, because `AWS::IAM::OIDCProvider` needs a CA thumbprint, and the thumbprint can only be computed from the live endpoint after the cluster exists.

#### Going deeper: which certificate the thumbprint comes from

The thumbprint is the SHA-1 fingerprint of the **root** certificate in the endpoint's chain. That is the last certificate `openssl` prints, not the leaf:

```
cert-1: CN=*.eks.<region>.amazonaws.com      ← leaf, the wrong one
cert-2: CN=Amazon RSA 2048 M01               ← intermediate
cert-3: CN=Amazon Root CA 1                  ← this one
```

### The project-local kubeconfig

The role writes the kubeconfig to `state/kubeconfig` instead of `~/.kube/config`, so it cannot overwrite a kubeconfig you use for other clusters. `source scripts/env.sh` exports `KUBECONFIG` to point at it, and the scripts set it on their own.

Right after Step 4 there are no nodes, so the cluster looks like this:

```
$ kubectl get nodes
No resources found

$ kubectl get pods -A
kube-system  coredns-…  Pending
kube-system  coredns-…  Pending
```

CoreDNS pending with nothing to schedule on is exactly right. The control plane is healthy and waiting for Step 5.

---

## Step 5: Managed node groups

**Run it:** `scripts/play.sh --tags nodes`

This is the first step that starts real compute, and it is the most expensive thing in the whole deployment. Steps 1 to 4 cost about $3.50 a day (the control plane and one NAT gateway). The node groups add roughly $52 a day at the default sizes, and roughly $290 a day at the sizes the upstream tutorial specifies. The step takes 5 to 10 minutes.

**Tear down only this step**, leaving the cluster and VPC in place:

```bash
scripts/down.sh --nodes-only
```

That drops the bill back to about $0.15 an hour. `scripts/up.sh --from nodes` rebuilds the nodes, so there is no reason to leave them running overnight while you work through this guide. To run the teardown as a single step, use `scripts/play.sh --tags nodes -e nodegroups_state=absent`.

### Three node groups, because there are three different jobs

| Group | What runs there | Why it is separate |
|---|---|---|
| **keeper** | ClickHouse Keeper (the Raft-style consensus service) | Small, odd-numbered, latency-sensitive. Three nodes, never two or four, because a quorum needs an odd count. |
| **server** | `clickhouse-server`, the database itself | Large, and the only group that needs local NVMe SSD for its read cache. |
| **operator** | The ClickHouse operator, plus cluster add-ons (CoreDNS, EBS CSI controller) | The only **untainted** group. Once the other two are tainted, this is the only place an ordinary pod can land. |

That last row is the one people miss. If you taint every node group, CoreDNS never schedules and DNS inside the cluster silently never works.

### Picking sizes: let the chart tell you the floor

The upstream tutorial specifies `m7g.2xlarge`, `m7gd.16xlarge` and `m7i.2xlarge`. The kit uses smaller ones, sized for learning and workshops rather than production. They are not arbitrarily smaller, because the floor is set by what the `onprem-clickhouse-cluster` chart actually asks for. Pull the chart from your registry and look:

```bash
source scripts/env.sh
REGION="$(aws configure get region)"
REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$REGION.amazonaws.com"
CHART_VERSION=$(aws ecr describe-images --repository-name helm/onprem-clickhouse-cluster \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
aws ecr get-login-password | helm registry login --username AWS --password-stdin "$REGISTRY"
helm pull "oci://$REGISTRY/helm/onprem-clickhouse-cluster" --version "$CHART_VERSION" --untar
grep -A12 'podPolicy:' onprem-clickhouse-cluster/values.yaml
```

The region comes from your profile (`target_region`), and the chart version is the tag the kit copied, which is `versions.cluster_chart`. With `fips: true`, use the host name `<YOUR_ACCOUNT_ID>.dkr-ecr-fips.$REGION.on.aws` for `REGISTRY` instead, and keep the chart version as it is, because charts take no `-fips` suffix. The chart's defaults amount to this:

```yaml
server.podPolicy.resources.requests:   {cpu: "4", memory: 8Gi}
keeper.podPolicy.resources.requests:   {cpu: "2", memory: 4Gi}
server.replicaCount: 3
keeper.replicaCount: 3
```

The kit raises the server memory to 16Gi (`clickhouse.server.memory` in `ansible/group_vars/all.yml`), which the 32Gi server nodes hold comfortably.

Now the subtlety: **a node's allocatable CPU is less than its vCPU count.** The kubelet reserves some for itself and the OS, so a 4-vCPU node advertises a little under 4,000m of allocatable CPU. A pod that requests exactly `4` CPU therefore does *not* fit on a 4-vCPU node. It stays `Pending` with `Insufficient cpu`, which is a maddening error to debug because the node looks big enough.

So the smallest types that actually work are one size class up from the pod request:

| Group | Pod request | Smallest node that fits (standard) | With `fips: true` | Upstream tutorial size |
|---|---|---|---|---|
| keeper | 2 CPU / 4Gi | `m7g.xlarge` (4 vCPU, 16Gi) | `m7i.xlarge` | `m7g.2xlarge` |
| server | 4 CPU / 8Gi | `m7gd.2xlarge` (8 vCPU, 32Gi, local NVMe) | `m6id.2xlarge` | `m7gd.16xlarge` |
| operator | none | `m7i.xlarge` (4 vCPU, 16Gi) | `m7i.xlarge` | `m7i.2xlarge` |

To go smaller than this you must also override the chart's resource requests. This is the floor for an unmodified chart.

### What the sizes cost

These figures are approximate. They come from the static price table (`pricing:`) in `ansible/group_vars/all.yml`, which lists us-east-1 on-demand prices for the default instance types. Refresh that table when AWS changes its prices.

| Standard build | Nodes | Approximate cost |
|---|---|---|
| keeper | 3 × `m7g.xlarge` | $0.49 an hour |
| server | 3 × `m7gd.2xlarge` | $1.28 an hour |
| operator | 2 × `m7i.xlarge` | $0.40 an hour |
| **compute** | | **$2.17 an hour** |
| plus control plane and NAT | | **$2.32 an hour, about $56 a day** |

At the upstream tutorial's sizes the compute alone is roughly $12 an hour. The role prints this estimate before it creates anything. Note that `max_nodes` costs nothing until something scales, because only `min_nodes` is running. The knobs are under `infrastructure` in `ansible/group_vars/all.yml`, and the `vpc` role re-validates any instance type you choose against the zones before it is used.

### Labels: the `-arm64` suffix and the chart's node selector

For ARM64 node groups the upstream tutorial labels the nodes with a suffix:

```
clickhouseGroup: server-arm64      # not "server"
clickhouseGroup: keeper-arm64
```

The chart's `nodeSelector` is written without the suffix:

```yaml
server.podPolicy.nodeSelector:
  clickhouseGroup: server          # no suffix
```

The chart's own comment says the selector must match the node labels *excluding* the `-arm64` suffix, and its README explains the mechanism. The `clickhouse-server-configuration-webhook` appends `-arm64` to the selector at admission time, when the cluster resource is labelled `arm64-preferred`. The upstream tutorial turns webhooks off in Step 8, and the kit does the same, so nothing else appends the suffix. A selector without it would then leave the Keeper pods unschedulable. The scheduler says so, and the pod's actual selector shows the mismatch:

```
0/N nodes are available: N node(s) didn't match Pod's node affinity/selector.
nodeSelector: {"clickhouseGroup":"keeper"}      # nodes say keeper-arm64
```

The kit therefore **keeps the node labels as the upstream tutorial has them and puts the suffix in the chart's selector** (`clickhouseGroup: keeper{{ node_label_suffix }}`). `group_vars` derives `node_label_suffix` from the `fips` switch, because the FIPS build is x86 and takes no suffix. The node group stack and the Step 9 role read that same variable, so the two sides cannot drift.

### Taints, and a deliberate asymmetry

| Group | Taints |
|---|---|
| keeper | `clickhouse.com/do-not-schedule=true:NoSchedule`, plus (ARM64 builds only) `clickhouse.com/arch=arm64:NoSchedule` |
| server | `clickhouse.com/do-not-schedule=true:NoSchedule` |
| operator | none |

`do-not-schedule` fences off the dedicated database nodes. The chart ships `tolerations: []`, so you do **not** add tolerations yourself. The operator injects the matching ones when it creates the pods. DaemonSets like `aws-node` and `kube-proxy` tolerate everything by default, so the CNI still comes up on tainted nodes.

The arch taint appears on **keeper only**, not server. The upstream tutorial has the same asymmetry, and the kit follows it. The reasoning is about which mistake is worse. A taint the operator does not tolerate leaves pods `Pending` forever, whereas a missing taint merely allows an unrelated pod onto a database node. Deviating toward the silent-failure side is not worth it, and taints can be changed on a live node group later.

### Launch templates, and three gotchas

All three groups use a launch template. Two of the reasons are CloudFormation details worth knowing:

**1. `DiskSize` and `LaunchTemplate` are mutually exclusive.** Set both on an `AWS::EKS::Nodegroup` and it fails validation. Once you want a launch template for any reason, the boot disk moves into its `BlockDeviceMappings`.

**2. Omit `ImageId`, and EKS *merges* rather than replaces.** With no `ImageId` in the template, EKS supplies the AMI from `AmiType` and appends its own `nodeadm` bootstrap configuration to your user data. This is why the user data must be a **MIME multipart document**, not a bare `#!/bin/bash` script. A bare script would be discarded, and the node would boot without ever joining the cluster.

**3. The IMDS hop limit.** The template sets `HttpTokens: required` (IMDSv2 only, which defeats the SSRF attack class that made IMDSv1 notorious) and `HttpPutResponseHopLimit: 2`. A hop limit of 1 stops at the host and cuts *pods* off from IMDS entirely, and the upstream tutorial states that nodes require IMDS for authentication. Once every workload uses IRSA instead, you can drop it to 1.

#### Going deeper: the MIME multipart user data

The user data has this shape, with the NVMe setup script as the shell-script part:

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/usr/bin/env bash
...NVMe setup...
--//--
```

### The NVMe cache disk

The `d` in `m7gd` is not cosmetic. It means local NVMe SSD, and it is the whole reason to choose that family. ClickHouse uses it as a read cache at `/nvme/disk`, which is the operator's default `hostPathBaseDirectory`. Pick a type without the `d`, and the cache silently lands on the 20 GiB root volume and fills it.

Nothing mounts that disk for you. The launch template's user data finds the local NVMe devices, stripes them if there is more than one, and mounts the result at `/nvme/disk`. It formats a device only when it has no filesystem yet, so re-running it does not throw away a warm cache.

#### Going deeper: finding and striping the disks

> **On Nitro instances, EBS volumes also appear as `/dev/nvme*`.** Selecting devices by path would happily reformat your root disk. The only safe discriminator is the model string, because ephemeral instance store reports `Amazon EC2 NVMe Instance Storage`.

```bash
lsblk -dn -o NAME,MODEL | awk '/Amazon EC2 NVMe Instance Storage/ {print $1}'
```

With more than one device (the bigger `d` types expose several), the script stripes them with `mdadm --level=0`. RAID0 has no redundancy, which is the right call for a cache that can be rebuilt from S3.

#### How the role verifies it

A missing cache mount does not throw an error anywhere. ClickHouse just gets slower, and the root disk fills up days later. So the `eks_nodegroups` role proves the mount directly by running a short-lived pod named `nvme-probe` on a server node. Two choices in that pod are worth knowing:

- **`.spec.nodeName` bypasses the scheduler entirely**, so the pod lands on a tainted node without needing any toleration.
- **It runs the `clickhouse-server` image from your ECR**, because that image is known to be present in your registry, which is the only registry the cluster pulls from. A public image such as `busybox` would not be there.

The pod mounts `/nvme/disk` as a `hostPath` with `type: Directory`. That means the pod stays `Pending` if the directory does not exist, instead of kubelet quietly creating an empty one. A failed user-data script therefore shows up as a failed check, not as a working-looking mount on the root volume. The role then asserts that `/nvme/disk` is backed by an `nvme` or `md` device.

If that check fails, the setup log is on the node. Session Manager reaches it (this needs the Session Manager plugin for the AWS CLI). Find the node's instance ID from its provider ID, which ends in `i-` followed by the ID:

```bash
kubectl get node NODE_NAME -o jsonpath='{.spec.providerID}'
aws ssm start-session --target INSTANCE_ID --profile "$AWS_PROFILE"
sudo cat /var/log/clickhouse-nvme-setup.log
```

Replace `NODE_NAME` with a name from `kubectl get nodes` and `INSTANCE_ID` with the ID from the provider ID. Session Manager works because the node role carries `AmazonSSMManagedInstanceCore`, so you need no SSH key, no bastion and no inbound security group rule. The upstream tutorial does not include that policy. The kit adds it so you can inspect a node that refuses to join.

### Why the node groups have no names

None of the three sets `NodegroupName`. Beyond the name-collision reasoning from Step 4, there is a mechanical reason: **changing an instance type forces CloudFormation to replace a node group**, and it cannot create the replacement while a same-named one still exists. An explicit name turns every resize into a failed update. With generated names, CloudFormation creates the new group, moves on, and deletes the old one. Find the groups by label instead:

```bash
kubectl get nodes -L clickhouseGroup
```

### One node group across three zones, not three groups

Each group spans all three private subnets, so EKS spreads its nodes across zones. The upstream tutorial suggests one node group *per zone* instead. That only matters once the cluster autoscaler is involved, because the autoscaler cannot tell which zone a pending pod's EBS volume is pinned to, so it may grow a group in the wrong zone and never satisfy the pod. This kit has no cluster autoscaler, so one group per workload is simpler and behaves identically.

---

## Self-checks

Run these in order after the steps you have completed. Each gives a command and the result you should see, and together they work as exercises for a workshop. The commands use the `AWS_PROFILE` and `KUBECONFIG` that `source scripts/env.sh` sets, and they use your profile's default region, which is `target_region`.

```bash
source scripts/env.sh
```

**Step 1**

1. **The pull profile assumes the pull role.**

   ```bash
   aws sts get-caller-identity --profile ch-gov-ecr-pull --query Arn --output text
   ```

   You should see an ARN in your account that ends `assumed-role/ClickHouseAirgapECRPullRole/` and a session name. Use your `source_ecr_profile` if you renamed it.

2. **The playbook agrees.**

   ```bash
   scripts/play.sh --tags pull-role
   ```

   You should see a line saying the profile assumes `ClickHouseAirgapECRPullRole` in your account, and no failed tasks.

**Step 2**

3. **At least these seven repositories exist, with immutable tags and scanning.**

   ```bash
   aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
   aws ecr describe-repositories --repository-names clickhouse-server \
     --query 'repositories[0].[imageTagMutability,imageScanningConfiguration.scanOnPush]' --output text
   ```

   The first command lists at least `clickhouse-server`, `clickhouse-keeper`, `clickhouse-operator`, `kubebuilder/kube-rbac-proxy`, `helm/clickhouse-operator-helm`, `helm/onprem-clickhouse-cluster` and `helm/preflight-check`, plus the Langfuse and Grafana repositories if you enabled them. The second prints `IMMUTABLE` and `True`.

4. **The copy kept both architectures.**

   ```bash
   REGION="$(aws configure get region)"
   REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$REGION.amazonaws.com"
   TAG=$(aws ecr describe-images --repository-name clickhouse-server \
     --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
   skopeo inspect --raw --authfile state/skopeo-auth.json "docker://$REGISTRY/clickhouse-server:$TAG" \
     | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"'
   ```

   You should see `linux/amd64` and `linux/arm64`, and possibly `unknown/unknown` entries for attestations. With `fips: true`, set `REGISTRY` to `<YOUR_ACCOUNT_ID>.dkr-ecr-fips.$REGION.on.aws` instead, with your own account ID. The logins in `state/skopeo-auth.json` expire after 12 hours, so run `scripts/play.sh --tags images` again if `skopeo` reports an authorization error.

5. **The step is idempotent.**

   ```bash
   scripts/play.sh --tags images
   ```

   You should see `0 copied, N already present` in the report, where `N` is the number of artifacts in play (7 for the default set), and `changed=0` in the recap.

**Step 3**

6. **The VPC stack is healthy and has six subnets.**

   ```bash
   VPC_ID=$(aws cloudformation describe-stacks --stack-name clickhouse-private-vpc \
     --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
   aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" --query 'length(Subnets)'
   ```

   You should see `6`.

7. **The private subnets are tagged for internal load balancers and hand out no public IPs.**

   ```bash
   aws ec2 describe-subnets \
     --filters Name=vpc-id,Values="$VPC_ID" Name=tag:kubernetes.io/role/internal-elb,Values=1 \
     --query 'Subnets[].MapPublicIpOnLaunch' --output text
   ```

   You should see `False False False`.

8. **There is one NAT gateway in `single` mode, and the S3 endpoint is attached.**

   ```bash
   aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC_ID" Name=state,Values=available \
     --query 'length(NatGateways)'
   aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC_ID" \
     --query 'VpcEndpoints[].[ServiceName,VpcEndpointType]' --output text
   ```

   You should see `1`, then a line for `com.amazonaws.<region>.s3` of type `Gateway`, where the region is your `target_region`.

**Step 4**

9. **The control plane is active.**

   ```bash
   aws eks describe-cluster --name clickhouse-private-eks --query 'cluster.[status,version]' --output text
   ```

   You should see `ACTIVE` and the version set in `infrastructure.eks_version`.

10. **The Kubernetes API answers, within one minor version of your `kubectl`.**

    ```bash
    kubectl version
    ```

    You should see a client version and a server version whose minor numbers differ by at most one.

11. **The OIDC provider is registered for IRSA.**

    ```bash
    aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
    ```

    You should see an ARN that contains `oidc.eks.` and your region.

12. **Before Step 5, the cluster is empty and waiting.**

    ```bash
    kubectl get nodes
    kubectl get pods -n kube-system
    ```

    You should see `No resources found`, and CoreDNS pods in `Pending`.

**Step 5**

13. **Eight nodes are `Ready`, spread across the zones.**

    ```bash
    kubectl get nodes -L clickhouseGroup -L node.kubernetes.io/instance-type -L topology.kubernetes.io/zone
    ```

    You should see three `server` nodes, three `keeper` nodes and two nodes with an empty `CLICKHOUSEGROUP`, which are the operator nodes. In the standard build the labels read `server-arm64` and `keeper-arm64`, and with `fips: true` they carry no suffix. The keeper and server groups each have one node per zone. The operator group has two nodes, so they sit in two of the three zones.

14. **The taints landed as designed.**

    ```bash
    kubectl get nodes -o custom-columns=GROUP:.metadata.labels.clickhouseGroup,TAINTS:.spec.taints[*].key
    ```

    You should see `clickhouse.com/do-not-schedule` on the server nodes, both `clickhouse.com/do-not-schedule` and `clickhouse.com/arch` on the keeper nodes in the standard build, and `<none>` on the operator nodes.

15. **CoreDNS runs only on the operator group.**

    ```bash
    kubectl get pods -n kube-system -o wide
    ```

    You should see the `coredns` pods `Running` on the two unlabelled operator nodes, and `aws-node` and `kube-proxy` pods `Running` on every node, tainted ones included. CoreDNS has no tolerations, so it can only land on the untainted group, while the two DaemonSets tolerate everything and must run everywhere, or the database nodes would have no pod networking at all.

16. **Allocatable CPU is below the vCPU count.**

    ```bash
    kubectl get nodes -o custom-columns=NAME:.metadata.name,GROUP:.metadata.labels.clickhouseGroup,CPU:.status.allocatable.cpu
    ```

    You should see values a little under the vCPU count, such as `3920m` for a 4-vCPU node and `7910m` for an 8-vCPU node. That gap is why the server group is `2xlarge`, not `xlarge`. It is also the first number to check when a pod is inexplicably `Pending`.

17. **The NVMe cache is a real disk.**

    ```bash
    scripts/play.sh --tags nodes
    ```

    You should see `/nvme/disk is mounted from instance-store NVMe on` a server node, then the probe output. The `df` line shows a filesystem of hundreds of GB, not the 20 GiB root volume, and the mount line names an `nvme` or `md` device.

## Troubleshooting

Each entry gives the symptom, the cause and the fix. Three errors that can appear in Steps 1 and 2 have their canonical entries in [Part 1's Troubleshooting](part-1-prerequisites.md#7-troubleshooting): a pull profile that could not authenticate or is not the ECR pull role, a `resolves to account X, but group_vars says Y` mismatch, and a copy that fails because a tag does not exist. Part 1 also covers the tools and the authentication path.

**`RepositoryNotFoundException` during the copy (Step 2)**

- *Cause:* ECR does not create a repository on push, and you ran only the `sync` tag, so `ecr_setup` never created the repositories.
- *Fix:* run `scripts/play.sh --tags images`, which creates the repositories first.

**Pods fail to start on a node with a manifest or `exec format error` (Step 2)**

- *Cause:* an image was copied for one architecture only. The kit always copies with `--all`, so this only happens with an image you copied by hand without it.
- *Fix:* copy it again with `skopeo copy --all`. Also check that the node architecture matches your `fips` setting.

**`... is not offered in ...` from the `vpc` role (Step 3)**

- *Cause:* one of your availability zones does not offer a node instance type. Subnets are pinned to a zone, so the check runs before anything is created.
- *Fix:* set `infrastructure.availability_zones` to zones that offer the type (the message names the missing ones), or choose a different instance type.

**`Validation failed with 1 error(s). Call DescribeEvents ...` (Steps 4 and 5)**

- *Cause:* CloudFormation does not name the real reason. The usual causes are an explicit resource name that collides with a leftover in the account, or a string parameter used where a boolean is required. The kit's own templates avoid both.
- *Fix:* if you edited a template, undo the change or fix the value. To see the real error, create the stack with `aws cloudformation create-stack` and read `describe-stack-events`.

**The stack is in `ROLLBACK_COMPLETE`, and the playbook refuses to continue (Steps 4 and 5)**

- *Cause:* the first create of the stack failed. The stack holds no resources, and it cannot be updated or re-created.
- *Fix:* confirm the stack is yours, then re-run the step with `-e clear_failed_stack=true`, for example `scripts/play.sh --tags nodes -e clear_failed_stack=true`.

**`Refuse to change EncryptionConfig on an existing cluster without explicit confirmation` (Step 4)**

- *Cause:* you set `fips: true` on a cluster that already exists. The customer-managed KMS key for Secrets is a one-way change, so the role asks you to confirm it.
- *Fix:* if you want it, re-run with `-e confirm_encryption_config=true`. If you are unsure, tear the cluster down and start the FIPS build from scratch. [Part 7 §3](part-7-fips-hardening.md#3-eks-secrets-envelope-encryption) explains why.

**`kubectl` times out after you set `eks_public_endpoint=false` (Step 4)**

- *Cause:* the API endpoint is now private, so only machines with a network path into the VPC can reach it.
- *Fix:* run `kubectl` from a bastion, or over a VPN or Direct Connect. To go back, run `scripts/play.sh --tags eks -e eks_public_endpoint=true`.

**`AMI type AL2023_ARM_64 is not valid` when the node group is created (Step 5)**

- *Cause:* the value is not one of the API's AMI types, for example `AL2023_x86_64` or `AL2023_ARM_64` without the `_STANDARD` suffix, which is how the upstream tutorial abbreviates them. `aws cloudformation validate-template` cannot catch it, so the failure only shows several minutes in, after the IAM role and launch templates already exist. CloudFormation then rolls the stack back.
- *Fix:* use the API's enum values. The kit derives `node_ami_type` for you (`AL2023_ARM_64_STANDARD` or `AL2023_x86_64_STANDARD`), so this only bites if you override it. List the valid values with `aws eks create-nodegroup help | grep -oE 'AL2023_[A-Za-z0-9_]+' | sort -u`. Then clear the rolled-back stack as described above.

**A pod stays `Pending` with `Insufficient cpu` although the node looks big enough (Step 5 onward)**

- *Cause:* the pod requests as much CPU as the node has vCPUs, and the kubelet reserves some of it. The node's allocatable CPU is lower.
- *Fix:* check `kubectl describe node NODE_NAME` and read the `Allocatable` block, then use the next instance size up or lower the pod's request.

**Keeper pods stay `Pending` with `didn't match Pod's node affinity/selector` (Step 9)**

- *Cause:* the pod's `nodeSelector` and the node labels disagree on the `-arm64` suffix. Nothing appends the suffix at admission when webhooks are off.
- *Fix:* keep the selector and the labels on the same `node_label_suffix`. Do not override the chart's `nodeSelector` by hand. If you changed `fips` after the nodes were created, recreate the node groups so the labels match.

**The NVMe check fails after the node group is created (Step 5)**

- *Cause:* the user-data script did not finish, or the server instance type has no local NVMe disk (a type without the `d`).
- *Fix:* choose a `d` instance type, or read `/var/log/clickhouse-nvme-setup.log` on the node with Session Manager, as described under "The NVMe cache disk".

**Where to go next:** [Part 3](part-3-storage-and-operator.md) adds the S3 bucket and IRSA roles for storage, then installs the ClickHouse operator.
