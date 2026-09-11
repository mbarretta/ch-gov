# Part 0 — ClickHouse Private, explained for people who run systems

This is the page to read first if you have never touched ClickHouse and someone
just handed you this repository. It assumes you know what a server, a database,
a container and an AWS account are, and nothing else. Parts 1–5 go deep on each
step and record every trap we hit; this part tells you what the thing *is*, why
it is shaped the way it is, and which two commands you will actually type.

---

## 1. What ClickHouse is, in one minute

ClickHouse is a database built for **analytics**: counting, summing and
filtering across billions of rows in well under a second. It is not the
database you put behind a shopping cart. It is the one you point at logs,
metrics, events, telemetry and audit trails, then ask "how many, by hour, by
region, over the last year".

It gets its speed from storing data by **column** rather than by row. A query
that touches three columns out of two hundred reads three columns' worth of
disk, not two hundred. Everything else about it (compression, vectorized
execution, the SQL dialect) is a consequence of that one decision.

You talk to it in **SQL**, over two doors:

| Door | Port | Who uses it |
|---|---|---|
| Native protocol | 9000 | `clickhouse-client`, the official drivers |
| HTTP | 8123 | `curl`, JDBC/ODBC, BI tools, anything that can speak HTTP |

## 2. What "ClickHouse Private" and "Government" mean

ClickHouse Inc. sells the same engine three ways:

- **Open source.** You download it, you run it, you are on your own.
- **ClickHouse Cloud.** They run it in their AWS/GCP/Azure account. You get a URL.
- **ClickHouse Private.** They give you the Cloud software, and **you run it in
  your own cloud account**, on your own Kubernetes cluster, with no connection
  back to ClickHouse Inc. once installed. "Government" is the same product with
  a **FIPS-validated** cryptography build, which changes CPU architecture
  (x86_64 instead of ARM64) and image tags, and nothing else you would notice.

The word that matters is **airgapped**. The product is designed so the cluster
that holds your data never needs a route to the internet. In practice that
means every container image is copied once from ClickHouse's registry into
yours, and the cluster only ever pulls from yours:

```
  ClickHouse's AWS account                 YOUR AWS account
  ┌───────────────────────────┐            ┌──────────────────────────────┐
  │ their container registry  │  one copy  │  your container registry     │
  │  clickhouse-server        │ ─────────► │   clickhouse-server          │
  │  clickhouse-keeper        │  (skopeo)  │   clickhouse-keeper          │
  │  clickhouse-operator      │            │   clickhouse-operator        │
  └───────────────────────────┘            │            │                 │
        read-only, cross-account           │            ▼  pull           │
                                           │  ┌──────────────────────┐    │
                                           │  │ your EKS cluster     │    │
                                           │  └──────────────────────┘    │
                                           └──────────────────────────────┘
```

This is why the setup needs credentials for **two** AWS accounts (theirs, read
only, to copy from; yours, to build in) and why the first deployment step is
copying images rather than creating servers.

## 3. The parts, and what each one is for

Think of it as a restaurant kitchen.

```
                       ┌──────────────────────────────────────────────────┐
   clients ──► NLB ──► │  ClickHouse servers  (3 pods, one per node)      │
   8123 / 9000         │  the cooks: parse SQL, read/write data, answer   │
                       │  keep a hot copy of recent data on local NVMe    │
                       └───────────┬──────────────────────┬───────────────┘
                                   │ metadata, locks      │ table data
                                   ▼                      ▼
                       ┌────────────────────┐   ┌────────────────────────┐
                       │  Keeper (3 pods)   │   │  S3 bucket             │
                       │  the order board:  │   │  the pantry: every     │
                       │  who owns what,    │   │  byte of every table   │
                       │  what is current   │   │  lives here            │
                       └────────────────────┘   └────────────────────────┘

                       ┌──────────────────────────────────────────────────┐
                       │  Operator (1 pod)  the manager: reads the spec   │
                       │  you wrote, builds and repairs everything above  │
                       └──────────────────────────────────────────────────┘
```

**ClickHouse server.** The database process. You run three of them. Every one
can take any query. They share one set of tables (the engine is called
SharedMergeTree), so a row inserted through server A is visible from server B
within a second or two.

**Keeper.** A small coordination service, ClickHouse's own replacement for
ZooKeeper. It holds the cluster's metadata: which parts exist, who is
currently writing what, which replica is up. You run three so that the loss of
one leaves a majority. It is the **only** component with a persistent disk, and
that disk is tiny (10Gi here).

**S3.** All table data lives in an S3 bucket. The servers are **stateless**:
they have no data volume. Kill one and a new one comes back and carries on,
because nothing was on it that is not also in S3 and Keeper. Each server does
keep a read cache on its node's local NVMe SSD so hot data does not round-trip
to S3 on every query.

**The operator.** A Kubernetes controller from ClickHouse. You do not create
pods yourself. You write a one-page specification (a `ClickHouseCluster`
resource) saying "three servers of this size, three keepers, this bucket", and
the operator creates and continuously repairs the StatefulSets, Services and
ConfigMaps that make it real.

**The load balancer.** An AWS Network Load Balancer in front of the three
servers so applications get one stable address. Optional. Without it you
reach the cluster only from inside Kubernetes or through a port-forward.

## 4. What it needs in order to work

Before any ClickHouse software runs, this has to exist:

| Layer | What | Why ClickHouse needs it |
|---|---|---|
| Network | A VPC with private subnets in **three** availability zones | Three servers and three keepers spread across zones; Keeper needs an odd quorum |
| Network | An S3 gateway endpoint | Table data traffic stays inside AWS and is not billed through NAT |
| Compute | An EKS (Kubernetes) cluster | The operator model only works on Kubernetes |
| Compute | Three **node groups**: keeper, server, operator | Different jobs, different machine shapes. Server nodes must have local NVMe for the cache |
| Storage | An S3 bucket | Where the data is |
| Storage | An encrypted EBS StorageClass | Keeper's small persistent disks |
| Identity | An IAM role the server pods can assume (IRSA) | So pods reach the bucket with no static keys anywhere |
| Registry | Your own ECR with the images copied in | The airgap: the cluster pulls only from your account |
| Laptop | aws, kubectl, helm, skopeo, jq, python, ansible, plus the `kubectl preflight` plugin | The tools the automation drives |

Nothing here is exotic. It is a normal EKS build with two deliberate oddities:
the server nodes carry a local SSD that is mounted and formatted at boot, and
the node groups are **tainted** so that only ClickHouse pods land on the
expensive machines.

## 5. How a deployment goes, in general

ClickHouse's own tutorial is twelve steps, and this project follows them
exactly. In plain terms:

| Step | What happens | Plain reading |
|---|---|---|
| 1 | IAM role for reading ClickHouse's registry | "Let me copy your images" |
| 2 | Copy images into your ECR | The one hop across the airgap |
| 3 | VPC, subnets, NAT, S3 endpoint | Build the room |
| 4 | EKS control plane | Install Kubernetes |
| 5 | Node groups | Buy the machines |
| 6 | S3 bucket and IAM role | Build the pantry, cut a key for the cooks |
| 7 | Kubernetes prerequisites (StorageClass, namespaces) | Shelving |
| 8 | Install the operator | Hire the manager |
| 9 | Deploy a ClickHouseCluster | Tell the manager what to build |
| 10 | Preflight checks | Inspection |
| 11 | Verify | Cook one meal on A, taste it from B |
| 12 | Load balancer | Put a sign on the door |

Steps 1–5 are generic AWS. Steps 6–8 are preparation that only ClickHouse
cares about. Steps 9–12 are the product itself. Only Step 5 onward costs
meaningful money, because that is when machines start running.

## 6. How to deploy it with this project

Everything above is automated as an **Ansible playbook** with one role per
step, and two shell scripts that call it in the right order. You do not need
to know Ansible to use it.

### 6.1 One-time setup on your machine

```bash
scripts/part1-setup.sh
```

Installs and version-checks the tools, creates a project-local Python
virtualenv for Ansible, installs the Ansible collections and the preflight
plugin. Safe to rerun. Details in Part 1.

### 6.2 Log in to AWS

All AWS configuration lives **inside the repo** at `.aws/config`, not in your
home directory, so the whole project moves as one folder. The consequence is
that a plain `aws sso login` does not help; you must point the CLI at the
repo's config:

```bash
AWS_CONFIG_FILE=$PWD/.aws/config aws sso login --profile sa
```

Two profiles are defined. `sa` is your deployment account. `private-us` is
read-only access to ClickHouse's registry, used only during Step 2. Both hang
off the same SSO session, so one login covers both. Tokens last hours, not
days; every script checks and tells you this exact command when it has expired.

### 6.3 Look at the one config file

`ansible/group_vars/all.yml` is the whole configuration. The values you are
most likely to touch:

| Key | Default | What it decides |
|---|---|---|
| `fips` | `false` | Standard ARM64 build, or FIPS x86_64. Changes images, instance types, registry |
| `infrastructure.eks_version` | `"1.36"` | Kubernetes version |
| `infrastructure.nat_mode` | `single` | One NAT gateway (cheap) or one per zone (resilient) |
| `infrastructure.*.instance_type` | learning sizes | Machine shapes per node group. Smaller than the tutorial's, sized to just fit the pods |
| `clickhouse.cluster_name` | `default-us-01` | Names everything else. Must match `^[a-z]+-[a-z]{2}-[0-9]{2}$` |
| `clickhouse.server` / `.keeper` | 3 × 4cpu/16Gi, 3 × 2cpu/4Gi | Pod sizes. Must fit the instance types |
| `clickhouse.load_balancer.type` | `internal` | `none`, `internal` (private address) or `public` |
| `clickhouse.load_balancer.allowed_cidrs` | `[]` | Who may connect. Empty means the VPC for `internal`, an error for `public` |

Every value has a comment explaining why it is what it is. Nothing secret is
in this file. Passwords are generated on first run and written to `state/`,
which is gitignored.

### 6.4 Bring it up

```bash
scripts/up.sh
```

It prints what it is about to do and the hourly cost, asks for a `y`, then
runs Steps 1–12 in order. Budget about an hour the first time; almost all of
it is waiting for AWS to build the EKS control plane and the node groups. The
resume path from Step 5 was measured at 15 minutes. When it finishes it prints
how to connect.

Useful variants:

```bash
scripts/up.sh --skip-images    # images already mirrored; skip Step 2
scripts/up.sh --from nodes     # start at Step 5 (typical after a down.sh)
scripts/up.sh --yes            # no prompt
```

**Every step is idempotent.** Running `up.sh` over a stack that already
exists changes nothing and takes a few minutes. If a run fails halfway, fix
the cause and run it again; it picks up where it stopped. This is your main
recovery tool and it is safe to lean on.

If you want one step at a time, the underlying command is:

```bash
scripts/play.sh --tags cluster       # any of: images vpc eks nodes storage
                                     #   prereqs operator cluster preflight verify lb
```

## 7. What exists once it is up

### In AWS

| Resource | Name | Created by |
|---|---|---|
| CloudFormation stacks | `clickhouse-private-vpc`, `-eks`, `-nodegroups`, `-irsa` | Steps 3, 4, 5, 6 |
| VPC | `10.20.0.0/16`, 3 private + 3 public subnets, 1 NAT, S3 endpoint | Step 3 |
| EKS cluster | `clickhouse-private-eks` | Step 4 |
| EC2 instances | 3 keeper, 3 server, 2 operator nodes (8 total) | Step 5 |
| S3 bucket | `clickhouse-private-<account>-<region>` | Step 6 |
| IAM roles | `clickhouse-private-irsa-ClickHouseS3Role-…` (server pods to S3) and `…-EbsCsiDriverRole-…` (Keeper volumes) | Step 6 |
| ECR repositories | `clickhouse-server`, `clickhouse-keeper`, `clickhouse-operator`, `kubebuilder/kube-rbac-proxy`, and the three charts under `helm/` | Step 2 |
| EBS volumes | 3 × 10Gi gp3, encrypted (Keeper) | Step 9, via Kubernetes |
| Network Load Balancer | one, internal, in the private subnets | Step 12, via Kubernetes |

### In Kubernetes

```
namespace ns-default-us-01
  ClickHouseCluster  c-default-us-01               the spec you wrote
  statefulset        c-default-us-01-keeper        3 pods, 3 PVCs
  statefulset        c-default-us-01-server-<id>   one per replica, 1 pod each, no PVCs;
                                                   <id> is a random 7-character suffix
  service            c-default-us-01-server-any    round-robins the servers inside the cluster
  service            default-us-01-lb              type LoadBalancer -> the NLB
  serviceaccount     ch-default-us-01-sa           carries the IAM role annotation

namespace clickhouse-operator-system
  deployment  clickhouse-operator-clickhouse-operator-helm   the manager
```

Everything in the second namespace derives from the release name
`default-us-01`. Rename it and the IAM trust policy no longer matches, so treat
it as fixed once deployed.

### On your machine, in `state/` (gitignored)

| File | What |
|---|---|
| `kubeconfig` | Access to the EKS cluster. The scripts export `KUBECONFIG` to it so your personal kubeconfig is never touched |
| `clickhouse-admin-password` | The `default` user's password. Generated on first run |
| `clickhouse-prometheus-password` | For the metrics endpoint |
| `preflight/` | The rendered preflight spec and the last report |
| `skopeo-auth.json` | Short-lived registry credentials from Step 2 |

Lose `state/` and you lose the admin password. Back it up somewhere
appropriate if the cluster matters.

## 8. Operating it

### The meter

| State | Approx. cost | How to get there |
|---|---|---|
| Everything up | ~$2.34/hr | `scripts/up.sh` |
| Nodes down, everything else kept | ~$0.15/hr | `scripts/down.sh` |
| Everything gone except S3 data and ECR images | ~$0 | `scripts/down.sh --all` |

The $0.15/hr floor is the EKS control plane plus the NAT gateway. It is what
you pay for being able to come back in 15 minutes instead of 45.

### Down

```bash
scripts/down.sh                # load balancer, cluster, node groups. ~10 min
scripts/down.sh --nodes-only   # just the machines. Pods go Pending, NLB stays
scripts/down.sh --all          # everything except the S3 bucket and ECR
```

Use the script, not the console, because teardown is **not** the reverse of
bring-up. Three things point the wrong way and the script handles them:

- The load balancer must go before the cluster or EKS, or the NLB is
  orphaned, keeps billing, and blocks deleting the VPC.
- The ClickHouse cluster must be removed **while nodes are still running**,
  because the operator and the EBS driver do the cleanup. With no nodes the
  namespace hangs forever and the Keeper volumes are orphaned. `down.sh`
  refuses to start if it finds this state and tells you what to do.
- The IAM and storage steps read the EKS cluster, so they run before it goes.

### Up again

```bash
scripts/up.sh --from nodes     # after a default down.sh, ~15 min
```

The data is in S3 and Keeper's volumes were deleted with the cluster, so this
is a **fresh, empty cluster** pointed at the same bucket. Old table data in the
bucket is not automatically re-adopted. If you need data to survive a down/up
cycle, use `--nodes-only`, which keeps the cluster objects and the Keeper
volumes and only stops the machines. The NLB hostname also changes on every
full rebuild; put a Route 53 record in front of it if applications need a
stable name.

### Looking around

```bash
source scripts/env.sh                                   # sets AWS_CONFIG_FILE, AWS_PROFILE, KUBECONFIG
kubectl get nodes -L clickhouseGroup                    # 8 nodes, labelled by job
kubectl -n ns-default-us-01 get pods -o wide            # 3 keeper + 3 server, all Running
kubectl -n ns-default-us-01 get clickhousecluster       # the spec, and its status
kubectl -n ns-default-us-01 get svc default-us-01-lb    # the NLB hostname
kubectl -n ns-default-us-01 logs -l app.kubernetes.io/name=clickhouse-server --tail=100 --prefix
kubectl -n clickhouse-operator-system logs deploy/clickhouse-operator-clickhouse-operator-helm --tail=100
```

The one non-obvious behaviour: the Keeper StatefulSet uses an `OnDelete`
update strategy, so changing its spec does **not** restart its pods. The
cluster role handles this on deploy. If you ever edit Keeper by hand, you
delete the pods yourself.

### Health checks

```bash
scripts/play.sh --tags preflight     # ClickHouse's own checks: node sizes, cache disk, storage class
scripts/play.sh --tags verify        # create a table on one replica, read it from another
```

Both run as part of `up.sh`. Both are safe any time.

### What is safe to delete by hand

Nothing in the two Kubernetes namespaces, and none of the four CloudFormation
stacks. Use the scripts. The account is shared with other people's clusters,
so never delete an AWS resource you cannot trace to this project's names.

Two things the scripts deliberately never delete, and you must:

- **The S3 bucket.** It is the data. `scripts/s3-purge-cluster-data.sh` removes
  one cluster's objects by their unique prefix and confirms before it does.
- **The ECR images.** Cheap to keep, slow to recopy.

## 9. Talking to ClickHouse

### From your laptop, the easy way

```bash
brew install clickhouse                          # once
scripts/ch-client.sh                             # interactive SQL prompt
scripts/ch-client.sh -q "SELECT version()"       # one query
```

This opens a `kubectl port-forward` to a server pod, reads the password from
`state/`, connects as the admin user `default`, and closes the tunnel when you
exit. It works from anywhere your kubeconfig works and needs no load balancer.

### Through the load balancer

The address:

```bash
kubectl -n ns-default-us-01 get svc default-us-01-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

With `type: internal` that hostname resolves to private IPs. You can reach it
from anything inside the VPC, or over a VPN or peering into it, but not from a
laptop on the office Wi-Fi. `scripts/ch-client.sh --lb` uses it where it is
reachable. `type: public` gives a public address restricted to
`allowed_cidrs`, but be aware the connection is plain TCP with no TLS in this
build, so treat that as a lab setting.

### From an application

| Client | Connection |
|---|---|
| `clickhouse-client` | `--host <nlb-hostname> --port 9000 --user default --password …` |
| HTTP / curl | `http://<nlb-hostname>:8123/?query=SELECT%201` with `X-ClickHouse-User` / `X-ClickHouse-Key` headers |
| JDBC | `jdbc:clickhouse://<nlb-hostname>:8123/default` |
| Python | `clickhouse-connect` on 8123, or `clickhouse-driver` on 9000 |

The password is in `state/clickhouse-admin-password`. Pass it through the
environment or a secret store, never on a command line.

### Five queries that tell you it is healthy

```sql
SELECT version();                                        -- it answers
SELECT * FROM system.clusters;                           -- 3 replicas listed
SELECT * FROM system.zookeeper WHERE path = '/';         -- Keeper reachable
SELECT name, type FROM system.disks;                     -- the s3 disk with cache
SELECT hostName(), count() FROM system.parts GROUP BY 1; -- who holds what
```

### Creating users

The admin user is `default`. Do not hand its password to applications. Make a
user with what it needs and nothing else:

```sql
CREATE USER app IDENTIFIED WITH sha256_password BY '…';
CREATE DATABASE app;
GRANT SELECT, INSERT ON app.* TO app;
```

Users and grants are cluster metadata, kept in Keeper and shared by all three
servers. Create them once, from any replica.

### Where a table actually goes

Create a table with `ENGINE = SharedMergeTree` and insert into it. The parts
land in the S3 bucket under a key prefix that starts with `ch-s3-`, sharded by
a short hash so no single prefix gets hot. Keeper records which parts exist.
The server that took the insert caches them on its NVMe. Any other server
answering a query on that table fetches from S3 and caches too. That is the
whole storage model, and it is why a server pod can be deleted without
anyone noticing.

---

## Glossary

| Term | Meaning here |
|---|---|
| **Airgapped** | The cluster has no need to reach the internet. Images come from your own registry |
| **Operator** | A Kubernetes controller that turns a one-page spec into running pods and keeps them that way |
| **CR / ClickHouseCluster** | The spec. A Kubernetes custom resource the operator watches |
| **Keeper** | ClickHouse's coordination service. Three pods, small disks, holds metadata |
| **SharedMergeTree** | The table engine for S3-backed, stateless-server clusters. Every replica sees every part |
| **IRSA** | IAM Roles for Service Accounts. How a pod gets AWS credentials without a key file |
| **StatefulSet** | The Kubernetes object that gives pods stable names and, optionally, disks |
| **NLB** | AWS Network Load Balancer. Layer 4, one hostname, three healthy targets |
| **Preflight** | ClickHouse's checklist run against the live cluster before you trust it |
| **FIPS** | The US federal cryptography standard. The Government build uses validated libraries, which forces x86_64 |
| **state/** | The gitignored folder holding kubeconfig, passwords and reports. Back it up |

**Where to go next:** Part 1 for tools and AWS access, Parts 2–3 for the
infrastructure and what went wrong building it, Part 4 for the cluster itself,
Part 5 for the load balancer.
