# Part 0 — ClickHouse Government and Langfuse, explained for people who run systems

> **What you'll learn**
>
> - What ClickHouse Government and Langfuse are, and why Langfuse keeps its data in ClickHouse.
> - What this kit builds in your AWS account, and why the build is shaped the way it is.
> - What it means to *deploy* and to *operate* the system, and which two commands you type to do both.

This is the page to read first if you have never touched ClickHouse and someone handed you this repository. It assumes you know what a server, a database, a container and an AWS account are, and nothing else. Parts 1–8 go deep on each step and explain the traps you can meet. This part tells you what the thing *is*, why it is shaped the way it is, and which commands you will actually run.

Two words come up constantly, so here is what they mean in this repository:

- **Deploy** means building everything the software needs and then installing it. You create a private network, a Kubernetes cluster, storage and permissions in AWS, then install ClickHouse (and, if you choose, Langfuse and Grafana) on top and check that it works. `scripts/up.sh` does all of it.
- **Operate** means what you do after that to keep the system healthy and affordable. You connect to it, look at its state, run its health checks, stop the machines when you are not using them, start them again, and tear everything down when you are finished. Section 8 lists exactly what the kit gives you for that. The kit is sized for learning and evaluation, not production, so it is a place to learn these tasks, not a production runbook.

---

## 1. What ClickHouse is, in one minute

ClickHouse is a database built for **analytics**: counting, summing and filtering across billions of rows in well under a second. It is not the database you put behind a shopping cart. It is the one you point at logs, metrics, events, telemetry and audit trails, then ask "how many, by hour, by region, over the last year".

It gets its speed from storing data by **column** rather than by row. A query that touches three columns out of two hundred reads three columns' worth of disk, not two hundred. Everything else about it (compression, vectorized execution, the SQL dialect) is a consequence of that one decision.

You talk to it in **SQL**, over two doors:

| Door | Port | Who uses it |
|---|---|---|
| Native protocol | 9000 | `clickhouse-client`, the official drivers |
| HTTP | 8123 | `curl`, JDBC/ODBC, BI tools, anything that can speak HTTP |

## 2. What ClickHouse Government and Langfuse are

### ClickHouse Government

ClickHouse Inc. offers the same engine in several ways:

- **Open source.** You download it and run it, and you are on your own.
- **ClickHouse Cloud.** ClickHouse Inc. runs it in its own cloud account and you get a URL.
- **ClickHouse Private.** ClickHouse Inc. gives you the core Cloud software, and **you run it in your own cloud account**, on your own Kubernetes cluster, with no connection back to ClickHouse Inc. once it is installed.
- **ClickHouse Government.** The Private product, built for US government workloads. It uses FIPS 140 validated cryptographic libraries (a claim ClickHouse makes about the product, not one this kit certifies), which changes the CPU architecture (x86_64 instead of ARM64) and the image tags, and nothing else you would notice. In this kit, `fips: true` selects it, and `fips: false` selects the standard Private build.

The word that matters is **airgapped**. The product is designed so the cluster that holds your data never needs a route to the internet. In practice, every container image is copied once from ClickHouse's registry into yours, and the cluster only ever pulls from yours:

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

This is why the setup needs a way to read ClickHouse's registry (a role in your account that can pull from theirs) as well as credentials for your own account, and why the first deployment step is copying images rather than creating servers.

### Langfuse

Langfuse is an open-source observability tool for applications that call large language models. An application sends Langfuse a *trace* for each request: what the model was asked, what it answered, how many tokens it used, how long it took, and what it cost. People then browse those traces in a web UI to find slow, expensive or wrong answers.

Langfuse is optional in this kit. Turn it on and it runs next to ClickHouse and uses your ClickHouse cluster to store its traces.

### Why Langfuse keeps its data in ClickHouse

A busy application produces a steady stream of traces that are written once and never edited. The questions people ask of them are analytics questions: "show me every generation slower than two seconds last week, grouped by model". That is exactly the workload ClickHouse is built for, so Langfuse stores its traces there. It keeps its other data elsewhere, in the store that suits it: PostgreSQL for users and settings, Valkey (a Redis-compatible store) for its work queue, and S3 for raw event payloads. Part 6 goes through all four.

### Grafana

Grafana is a dashboarding tool. It is also optional, and Part 8 covers it. In this kit it reads from ClickHouse and, if Langfuse is on, from Langfuse's tables too.

## 3. The parts, and what each one is for

The ClickHouse cluster is a handful of cooperating pieces:

```
                       ┌──────────────────────────────────────────────────┐
   clients ──► NLB ──► │  ClickHouse servers  (3 pods, one per node)      │
   8123 / 9000         │  Parse SQL, read and write data, answer queries; │
                       │  keep a hot copy of recent data on local NVMe    │
                       └───────────┬──────────────────────┬───────────────┘
                                   │ metadata, locks      │ table data
                                   ▼                      ▼
                       ┌────────────────────┐   ┌────────────────────────┐
                       │  Keeper (3 pods)   │   │  S3 bucket             │
                       │  Coordination:     │   │  Storage: every byte   │
                       │  who owns what,    │   │  of every table lives  │
                       │  what is current   │   │  here                  │
                       └────────────────────┘   └────────────────────────┘

                       ┌──────────────────────────────────────────────────┐
                       │  Operator (1 pod)  Reads the spec you wrote and  │
                       │  builds and repairs everything above             │
                       └──────────────────────────────────────────────────┘
```

**ClickHouse server.** The database process. You run three of them for scalability and redundancy. Every one can take any query. They share one set of tables (the engine that makes this possible is called SharedMergeTree), so a row inserted through server A is visible from server B within a second or two.

**Keeper.** A small coordination service, ClickHouse's modification of ZooKeeper. It holds the cluster's metadata: which parts exist, who is currently writing what, which replica is up. You run three for redundancy, and the cluster keeps a quorum (a majority that can still agree) if one fails. It is the **only** ClickHouse component with a persistent disk, and that disk is tiny (10Gi here).

**S3.** All table data lives in an S3 bucket. The servers are **stateless**: they have no data volume. Kill one and a new one comes back and carries on, because nothing was on it that is not also in S3 and Keeper. Each server does keep a read cache on its node's local NVMe SSD, so hot data does not round-trip to S3 on every query.

**The operator.** A Kubernetes controller from ClickHouse. You do not create pods yourself. You write a one-page specification (a `ClickHouseCluster` resource) saying "three servers of this size, three keepers, this bucket", and the operator creates and continuously repairs the StatefulSets, Services and ConfigMaps that make it real.

**The load balancer.** An AWS Network Load Balancer in front of the three servers, so applications get one stable address. It is optional. Without it you reach the cluster only from inside Kubernetes or through a port-forward.

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
| Laptop | aws, kubectl, helm, skopeo, jq, python, ansible, plus the `kubectl preflight` plugin | The tools the automation drives. Part 1 installs them on macOS and Linux |

Nothing here is exotic. It is a normal EKS build with two deliberate oddities: the server nodes carry a local SSD that is mounted and formatted at boot, and the node groups are **tainted** (marked so that only pods that ask for them can land there) so that only ClickHouse pods use the expensive machines.

## 5. How a deployment goes, in general

ClickHouse publishes a tutorial for this deployment, and this project follows its steps in order. The kit numbers them 1 to 12 and adds optional Steps 13 to 18 for Langfuse and Grafana. In plain terms:

| Step | What happens | What it gives you |
|---|---|---|
| 1 | Check the IAM role for reading ClickHouse's registry | Confirms you can copy ClickHouse's images |
| 2 | Copy images into your ECR | The one hop across the airgap |
| 3 | VPC, subnets, NAT, S3 endpoint | The private network everything runs in |
| 4 | EKS control plane | Kubernetes itself |
| 5 | Node groups | The machines, in three groups by job |
| 6 | S3 bucket and IAM role | Storage for the data, and permission for server pods to reach it |
| 7 | Kubernetes prerequisites (StorageClass, namespaces) | The disk type and the namespaces the software lives in |
| 8 | Install the operator | The controller that builds and repairs the cluster |
| 9 | Deploy a ClickHouseCluster | The cluster itself: you describe it, the operator builds it |
| 10 | Preflight checks | ClickHouse's own inspection of the live cluster |
| 11 | Verify | Proof that a table written on one server is readable from another |
| 12 | Load balancer | One stable address for clients |
| 13 (optional) | S3 bucket and IAM role for Langfuse | Storage for Langfuse's raw events, with its own permission |
| 14 (optional) | A database and user for Langfuse inside ClickHouse | Access to one database, not the whole cluster |
| 15 (optional) | Install Langfuse | Langfuse running next to ClickHouse and storing its traces there |
| 16 (optional) | S3 bucket and IAM role for Grafana's plugin mirror | A bucket holding one plugin file, since the cluster cannot fetch it from the internet |
| 17 (optional) | A read-only user for Grafana inside ClickHouse | Read access to your data, and no ability to change it |
| 18 (optional) | Install Grafana, pointed at that user | A dashboard UI over your ClickHouse data |

Steps 1–5 are generic AWS. Steps 6–8 are preparation that only ClickHouse cares about. Steps 9–12 are the product itself. Compute starts at Step 5, so that is where the meaningful cost begins.

### Optional: Langfuse on top

Steps 13–15 are off by default and change nothing when they are off. Switched on (`langfuse.enabled: true`), they install Langfuse on the same machines, using the ClickHouse cluster you just built as the place it keeps its traces. One script, `scripts/langfuse-smoke.sh`, posts a trace to Langfuse and reads it back out of ClickHouse, which shows the two working together. The steps, the two places Chainguard's images differ from the ones the Langfuse chart expects, the costs and the teardown rules are in **Part 6**. Langfuse's web address is plain HTTP unless you also set `langfuse.load_balancer.tls: true`, which has its load balancer encrypt the connection with a certificate the deployment makes itself. Part 6 §9 says what that does and does not give you.

### Optional: Grafana on top

Steps 16–18 are also off by default, and independent of Langfuse. Switched on (`grafana.enabled: true`), they install Grafana with one datasource already wired up: a read-only user (Step 17) reached through a plugin mirrored into your own S3 bucket (Step 16), because the cluster has no route out to fetch it live. When both options are on, that one datasource can see Langfuse's tables too, with no separate grant. Grafana's images come from DHI (Docker Hardened Images), a paid catalog that needs a login, unlike Chainguard's anonymous pulls. That is a second credential, and [Part 1 §3b](part-1-prerequisites.md#3b-persisting-your-account-ids-and-sso-portal-statedeploy-varsyml) covers it. The steps, the plugin-mirror mechanism, and the costs and teardown rules are in **Part 8**.

## 6. How to deploy it with this project

Everything above is automated as an **Ansible playbook** with one role per step, and shell scripts that run it in the right order. You do not need to know Ansible to use it.

### 6.1 One-time setup on your machine

```bash
scripts/part1-setup.sh
```

This installs and version-checks the tools, creates a project-local Python virtual environment for Ansible, and installs the Ansible collections and the preflight plugin. It is safe to rerun. On macOS it installs missing tools with Homebrew. On Linux you install the tools first, and Part 1 §2 shows how. The first script you run also creates `state/deploy-vars.yml`, the file where your account details go.

### 6.2 Give the kit AWS access

The kit needs two AWS profiles: `target_profile` (your account, default name `ch-gov-target`) and `source_ecr_profile` (a role that can read ClickHouse's registry, default name `ch-gov-ecr-pull`). The setting `aws.auth_mode` decides who creates them:

- `sso` (the default): the kit renders a project-local `.aws/config` from your IAM Identity Center details, and you log in once.
- `profile`: you already have a working AWS profile, and the kit uses it.

For SSO, fill in your account IDs and portal URL in `state/deploy-vars.yml`, then log in:

```bash
source scripts/env.sh                       # points the AWS CLI at the repo's config
aws sso login --profile "$AWS_PROFILE"
```

Tokens last hours, not days. Every script checks your credentials first and prints the exact command to run when they have expired. Part 1 §3 covers both modes, the exact keys, and the AWS permissions the deploying identity needs.

### 6.3 Look at the one config file

`ansible/group_vars/all.yml` holds the defaults for everything. Put your own values in `state/deploy-vars.yml`, which overrides only the keys you set. These are the values you are most likely to touch:

| Key | Default | What it decides |
|---|---|---|
| `aws.auth_mode` | `sso` | How the kit authenticates to AWS: `sso` or `profile` |
| `fips` | `false` | Standard ARM64 build, or the Government (FIPS) x86_64 build. Changes images, instance types, registry |
| `infrastructure.eks_version` | `"1.36"` | Kubernetes version |
| `infrastructure.nat_mode` | `single` | One NAT gateway (cheap) or one per zone (resilient) |
| `infrastructure.*.instance_type` | learning sizes | Machine shapes per node group. Sized for learning and evaluation, not production, and smaller than the tutorial's |
| `clickhouse.cluster_name` | `default-us-01` | Names everything else. Must match `^[a-z]+-[a-z]{2}-[0-9]{2}$` |
| `clickhouse.server` / `.keeper` | 3 × 4cpu/16Gi, 3 × 2cpu/4Gi | Pod sizes. Must fit the instance types |
| `clickhouse.load_balancer.type` | `internal` | `none`, `internal` (private address) or `public` |
| `clickhouse.load_balancer.allowed_cidrs` | `[]` | Who may connect. Empty means the VPC for `internal`, an error for `public` |

Every value in `all.yml` has a comment explaining why it is what it is. Nothing secret is in that file. Passwords are generated on first run and written to `state/`, which is gitignored.

### 6.4 Bring it up

```bash
scripts/up.sh
```

The script prints what it is about to do and the hourly cost, asks for a `y`, then runs Steps 1–12 in order. Expect roughly an hour the first time, and almost all of it is waiting for AWS to build the EKS control plane and the node groups. Starting again from the node groups takes much less, on the order of 15 minutes. When it finishes, it prints how to connect.

Useful variants:

```bash
scripts/up.sh --skip-images    # images already mirrored; skip Step 2
scripts/up.sh --from nodes     # start at Step 5 (typical after a down.sh)
scripts/up.sh --yes            # no prompt
```

**Every step is idempotent.** Running `up.sh` over a stack that already exists changes nothing and takes a few minutes. If a run fails halfway, fix the cause and run it again, and it picks up where it stopped. This is your main recovery tool, and it is safe to lean on.

> **Advanced: run individual steps.** To run one step at a time, pass its tag to `play.sh`:
>
> ```bash
> scripts/play.sh --tags cluster       # any of: images vpc eks nodes storage
>                                      #   prereqs operator cluster preflight verify lb
>                                      #   (+ lf-storage lf-db lf-app when Langfuse is on, see Part 6)
> ```

## 7. What exists once it is up

### In AWS

| Resource | Name | Created by |
|---|---|---|
| CloudFormation stacks | `clickhouse-private-vpc`, `-eks`, `-nodegroups`, `-irsa`, `-ebs-csi` | Steps 3, 4, 5, 6, 7 |
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
  deployment  clickhouse-operator-clickhouse-operator-helm   the operator
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
| `deploy-vars.yml` | Your account IDs and other overrides. See Part 1 §3b |
| `skopeo-auth.json` | Short-lived registry credentials from Step 2 |

Lose `state/` and you lose the admin password. Back it up somewhere
appropriate if the cluster matters.

## 8. Operating it

To *operate* the system, you connect to it, look at its state, check its health, control its cost, and tear it down. The kit gives you these tools for that: `scripts/ch-client.sh` (an SQL session, section 9), `kubectl` with the kubeconfig in `state/`, the preflight and verify checks below, `scripts/langfuse-smoke.sh` and `scripts/grafana-smoke.sh` for the optional layers, and `scripts/up.sh` and `scripts/down.sh` to start and stop. It does not include procedures beyond these.

### The meter

| State | Approx. cost | How to get there |
|---|---|---|
| Everything up | ~$2.32/hr | `scripts/up.sh` |
| Nodes down, everything else kept | ~$0.15/hr | `scripts/down.sh` |
| Everything gone except S3 data and ECR images | ~$0 | `scripts/down.sh --all` |

The $0.15/hr floor is the EKS control plane plus the NAT gateway. It is what
you pay for being able to come back in about 15 minutes instead of 45. These figures are estimates from us-east-1 list prices, the same ones `scripts/up.sh` prints, so check current AWS pricing for your Region.

### Down

```bash
scripts/down.sh                # load balancer, cluster, node groups. ~10 min
scripts/down.sh --nodes-only   # just the machines. Pods go Pending, NLB stays
scripts/down.sh --all          # everything except the S3 bucket and ECR
```

Use the script, not the console, because teardown is **not** the reverse of
bring-up. Three things point the wrong way (four with Langfuse, five with
Grafana too), and the script handles them:

- The load balancer must go before the cluster or EKS, or the NLB is
  orphaned, keeps billing, and blocks deleting the VPC.
- The ClickHouse cluster must be removed **while nodes are still running**,
  because the operator and the EBS driver do the cleanup. With no nodes the
  namespace hangs forever and the Keeper volumes are orphaned. `down.sh`
  refuses to start if it finds this state and tells you what to do.
- The IAM and storage steps read the EKS cluster, so they run before it goes.
- Langfuse (optional Steps 13–15) goes **before ClickHouse**. Its tables live
  in the ClickHouse cluster and its two disks are EBS volumes, so removing it
  needs the operator and the EBS driver alive, so the cluster and the nodes
  must still be up. `down.sh` runs it first, only when it exists, and even if you
  have already switched `langfuse.enabled` back to `false`. Part 6 §13 has
  the details, including the separate command that purges its data.
- Grafana (optional Steps 16–18) goes **after Langfuse, still before
  ClickHouse**. It has no PVC and no data dependency of its own, so its
  ordering constraint is looser than Langfuse's. `down.sh`'s default plan
  still removes both application layers before the load balancer, the
  cluster and the node groups, whether or not `grafana.enabled` is still
  `true`. Part 8 §13 has the details, including the one bucket this project
  actually deletes on teardown rather than keeping.

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
source scripts/env.sh                                   # sets AWS_PROFILE and KUBECONFIG (and AWS_CONFIG_FILE in SSO mode)
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

Nothing in the two Kubernetes namespaces (three with Langfuse, four with
Grafana too), and none of the five CloudFormation stacks (six with
Langfuse, seven with Grafana too). Use the scripts. Only delete an AWS
resource you can trace to this project: its names start with `clickhouse-private`,
and its stacks and buckets carry the tags `Project=clickhouse-private` and
`ManagedBy=ansible`.

Two things the scripts deliberately never delete, and you must:

- **The ClickHouse S3 bucket** (and Langfuse's, if you use it). It is the data. `scripts/s3-purge-cluster-data.sh` removes
  one cluster's objects by their unique prefix and confirms before it does.
- **The ECR images.** Cheap to keep, slow to recopy.

## 9. Talking to ClickHouse

### From your laptop, the direct way

```bash
brew install clickhouse                          # once, on macOS
scripts/ch-client.sh                             # interactive SQL prompt
scripts/ch-client.sh -q "SELECT version()"       # one query
```

On Linux, follow the [ClickHouse install page](https://clickhouse.com/docs/install) instead. The script accepts either a `clickhouse-client` or a `clickhouse` binary on your `PATH`.

The script opens a `kubectl port-forward` to a server pod, reads the password from
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
`allowed_cidrs`, but with `fips: false` the connection is plain TCP with
no TLS, so treat that as a setting for learning environments. With
`fips: true` the plaintext ports are closed and clients use TLS, on native port 9440.

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
| **FIPS** | The US federal cryptography standard. ClickHouse states that the Government build uses FIPS-validated libraries (a claim about the product, not one this kit certifies), which forces x86_64 |
| **Langfuse** | An open-source tool that records what an application asked a language model and what it answered. Optional, and it stores its traces in ClickHouse |
| **Deploy / operate** | Deploy: build the infrastructure and install the software (`scripts/up.sh`). Operate: connect, check health, stop, restart and tear down (section 8) |
| **DHI** | Docker Hardened Images, a paid catalog that needs a login. Only Grafana's images come from it |
| **`auth_mode`** | The `aws.auth_mode` setting: `sso` renders a project-local AWS config, `profile` uses a profile you already have |
| **state/** | The gitignored folder holding kubeconfig, passwords and reports. Back it up |

## Check your understanding

You can answer each of these from this Part. If you cannot, reread the section named in brackets before you move on.

1. Why can you delete a ClickHouse server pod without losing data? [section 3]
2. Which component holds the only persistent disk in the ClickHouse cluster, and what does it store? [section 3]
3. What does the operator do that you would otherwise do by hand? [section 3]
4. Which steps of the deployment start the meaningful AWS cost, and what does it cost to keep the cluster ready to come back? [sections 5 and 8]
5. Why must the load balancer go before the cluster or EKS at teardown? [section 8]
6. What does `aws.auth_mode` choose between, and which mode fits when you already have a working AWS profile? [section 6.2 and the glossary]
7. Which two things do the scripts never delete, so you must? [section 8]

**Where to go next:** Part 1 for tools and AWS access, Parts 2–3 for the
infrastructure, Part 4 for the cluster itself, Part 5 for the load balancer.
