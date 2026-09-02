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
