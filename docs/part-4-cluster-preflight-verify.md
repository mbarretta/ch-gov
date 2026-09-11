# Part 4 — Steps 9–11: the cluster, preflight checks, and proof

Parts 2 and 3 built a Kubernetes cluster that knows what a ClickHouseCluster
*is* and has somewhere to put one. These three steps create one, ask
ClickHouse's own diagnostic tool whether it is set up correctly, and then make
it do database work across replicas.

```bash
scripts/play.sh --tags cluster      # Step 9
scripts/play.sh --tags preflight    # Step 10
scripts/play.sh --tags verify       # Step 11
```

> **Status: written and validated, not yet run against a live cluster.** The
> node groups were torn down at the end of Part 3 to stop the meter (control
> plane and NAT alone are ~$0.15/hr; with nodes it is ~$2.32/hr). Everything
> below has been checked to the extent possible without nodes — the playbook
> passes `--syntax-check`, and the cluster chart renders with these values and
> passes its own schema. The sections marked **to confirm on first run** are
> the ones that need real pods to settle. Bring the nodes back with
> `scripts/play.sh --tags nodes` first; the Pending pods from Step 7 and 8
> schedule themselves once nodes join.

---

# Step 9 — Deploy a ClickHouseCluster

## What the chart actually installs

Three objects, and only one of them is interesting:

```
$ helm template default-us-01 oci://.../helm/onprem-clickhouse-cluster -n ns-default-us-01 -f values.yaml
ResourceQuota      default-us-01-onprem-clickhouse-cluster    count/clickhouseclusters.clickhouse.com: "1"
ServiceAccount     ch-default-us-01-sa                        eks.amazonaws.com/role-arn: arn:aws:iam::...:role/clickhouse-private-irsa-ClickHouseS3Role-...
ClickHouseCluster  c-default-us-01
```

Nothing here is a pod. The chart writes a **specification**; the operator from
Step 8 reads it and builds the Keeper StatefulSet, one StatefulSet per server
replica, their Services, ConfigMaps and PVCs. This is why the role does not use
Helm's `--wait`: Helm would report success the instant the CR was accepted,
long before anything was running. The role waits on the operator's objects
instead, in the order the operator creates them.

## Everything derives from the release name

The chart takes one name and derives the rest:

| From `default-us-01` | Object |
|---|---|
| `c-default-us-01` | the ClickHouseCluster CR |
| `c-default-us-01-keeper` | the Keeper StatefulSet |
| `ch-default-us-01-sa` | the service account |
| `ns-default-us-01` | the namespace, by convention |

The service account name matters most, because Step 6 baked it into an IAM
trust policy. Rename the release and IRSA silently stops matching. The name is
also schema-constrained — `^[a-z]+-[a-z]{2}-[0-9]{2}$` — so `default-us-01`
passes and `clickhouse` would not.

## The namespace convention, and a change to Part 3

Part 3 planned to deploy into a namespace called `clickhouse`. Part 4 changed
that to `ns-default-us-01`, and re-ran Step 6 so the IRSA trust policy names
the new namespace. Three things pointed the same way:

1. The chart README recommends `ns-<name>` and says the namespace should hold
   exactly one ClickHouseCluster (the ResourceQuota enforces it).
2. The tutorial installs into `ns-$CLUSTER_NAME`.
3. The **preflight chart derives the namespace** as `ns-<clickhouseClusterName>`
   unless overridden, and one of its analyzers checks that a CR named
   `c-<name>` exists there — its failure message says the operator "derives
   the cluster name from the namespace".

A convention that three separate tools assume is not a convention you want to
be the exception to. It cost one CloudFormation update (`changed=1`, nothing
recreated) because the namespace was one variable in `group_vars`.

## The password is a hash of a hash, encoded

The tutorial passes `account.hashedPassword`. The README shows how to make it:

```bash
echo -n "$PASSWORD" | shasum -a 256 | awk '{printf $1}' | base64
```

Read that carefully: it base64-encodes the **hex string** of the digest, not
the digest's raw bytes. The chart's own fallback for a plain-text password does
the same thing — `sha256sum | b64enc` — so this is the format the operator
expects, and a "correct" base64 of the raw 32 bytes would be rejected at login.
In Ansible:

```yaml
hashedPassword: "{{ _cl_admin_pw | hash('sha256') | b64encode }}"
```

The password itself is generated once by the `password` lookup, into
`state/clickhouse-admin-password` (gitignored, mode 0600), and read back on
every later run so the hash — and therefore the release — does not change.
Losing the file does not lose the cluster: set a new one with `helm upgrade`.

## Two settings the tutorial sets and one it omits

**`region` and `endpoint`, both.** The chart's AWS defaults are `us-west-2` for
each. Part 3 already flagged the endpoint; the region is the same trap, and the
IRSA role would not save you — it is scoped to a bucket ARN, which has no region
in it. Both are set from `aws.target_region`.

**Image tags, pinned.** The chart says to leave `image.tag` unset and take its
own validated pin. Its pins happen to equal what Step 2 mirrored
(`26.2.1.525` server, `26.2.1.258` keeper — the chart even overrides its own
base configuration's Keeper `26.6` down to `26.2` with a comment about a
postponed release). We set them explicitly anyway: what runs should be what
`group_vars` says was mirrored, and the chart cannot know about the `-fips`
suffix.

**The Prometheus user.** Not in the tutorial. `server.prometheus.user.create`
defaults to `true` with an **empty password**, which renders as
`password_sha256_hex: <sha256 of "">`. There is no Prometheus in this
deployment, but the user exists either way, so the role generates a password
for it too (`state/clickhouse-prometheus-password`).

## Tolerations: the README and the base configuration disagree with our taints

Step 5 tainted the keeper and server node groups
`clickhouse.com/do-not-schedule=true:NoSchedule`, following the tutorial, and
noted that "the operator adds the matching toleration itself". Rendering the
chart shows what the *chart* thinks:

- The AWS base configuration inside the chart carries tolerations for
  `clickhouse.com/clickhouse-server-only` and
  `clickhouse.com/clickhouse-keeper-only` — different keys, from ClickHouse
  Cloud's own node pools.
- Setting `server.tolerations` **replaces** that list rather than appending to
  it (Helm's `mergeOverwrite` treats lists as scalars).
- With `arm64: true` the chart appends a toleration for
  `clickhouse.com/arch=arm64`, which matches the second taint Step 5 put on
  Graviton keeper nodes.

So the role sets the `do-not-schedule` toleration explicitly on both server and
keeper, exactly as the chart README recommends. Rendered result:

```yaml
tolerations:
  - {key: clickhouse.com/do-not-schedule, operator: Exists, effect: NoSchedule}
  - {key: clickhouse.com/arch, operator: Equal, value: arm64, effect: NoSchedule}
```

If the operator also injects one, the duplicate is harmless. If it does not,
this is the line that keeps every pod out of `Pending`.

## The arm64 suffix — to confirm on first run

Part 2 explained why nodes are labelled `clickhouseGroup: server-arm64` while
the chart's selector says `server`, and attributed the bridging to the
operator. The chart README attributes it to the
`clickhouse-server-configuration-webhook` — and Step 8 disabled webhooks, per
the tutorial. The chart still labels the CR `clickhouse.com/arm64-preferred:
"true"`, which is presumably what the operator itself keys on; the tutorial's
own sequence (suffixed labels, bare selector, webhooks off) cannot work
otherwise.

The role does not assume. Every wait is inside a `block` whose `rescue` prints
the pod table, the namespace's Warning events sorted by time, and the last 40
lines of the operator log, then fails. A selector mismatch reads like this in
the events and nowhere else:

```
0/8 nodes are available: 3 node(s) didn't match Pod's node affinity/selector,
3 node(s) had untolerated taint {clickhouse.com/do-not-schedule: true}, ...
```

If that appears, the fix is one line — set the selector to `server-arm64` /
`keeper-arm64` in the role — and Part 2's explanation needs correcting.

## Sizing, and where the cache number comes from

| | Node | Pod request = limit | Why |
|---|---|---|---|
| server | `m7gd.2xlarge` (8 vCPU, 32Gi, 442Gi NVMe) | 4 CPU / **16Gi** | The chart's default is 8Gi; 16Gi is the AWS base configuration's own value, the node has room, and the cache scales with RAM (below). |
| keeper | `m7g.xlarge` (4 vCPU, 16Gi) | 2 CPU / 4Gi | Chart default. |

The SSD read cache is specified as `cacheDiskSize: 300Gi` and the chart
converts it: **`bytesPerGiRAM = cacheDiskSize / memory limit`** = 300Gi / 16 =
`18Gi`, which is what lands in the CR. 300Gi is ~68% of the 442Gi disk Step 5
mounted at `/nvme/disk`. Two constraints set that: the preflight check fails at
80% or more, and ClickHouse can briefly exceed the cache limit during merges.
Change the memory limit and the cache ratio changes with it — that is why it is
expressed as a size here and not as the raw ratio.

Servers get **no EBS volume**. `featureFlags.disableMetadataPersistentVolumes`
defaults to `true`, which sets `disableServerStorageVolumes` and
`enableDatabaseDisk` on the CR: data in S3, table metadata in Keeper via the
Shared Catalog, nothing on local disk except the cache. Keeper keeps its 10Gi
`gp3-encrypted` volume per replica — it is the only persistent state in the
cluster, and the only thing teardown has to clean up.

Log level is `information` for both, not the chart's `trace`. Servers have no
volume, so logs go to stdout and the node's rotation; `trace` would make
`kubectl logs` unusable.

## What the role verifies before calling it done

1. **Airgap.** Every container image in the namespace — init containers
   included, because the operator generates those from
   `IMAGE_REGISTRY_BASE_PATH` (Step 8), not from any chart value — pulls from
   your ECR. Asserted, as in Step 8.
2. **IRSA reached the pods.** Each server pod runs as `ch-default-us-01-sa`
   and has `AWS_ROLE_ARN` set to the Step 6 role. The kubelet injects that
   from the service account annotation; if it is missing, the failure would
   otherwise surface as an `AccessDenied` inside ClickHouse's logs.
3. **Objects exist in S3 under the key prefix.** The end-to-end proof: a
   token was minted, exchanged at STS, and accepted by S3. On a fresh cluster
   this is metadata and system tables, visible within a minute.

## Teardown

```bash
scripts/play.sh --tags cluster -e cluster_state=absent
```

`helm uninstall` removes the CR; the operator deletes the StatefulSets; the
role then waits for the pods to go and deletes the **namespace**, which takes
the Keeper PVCs (and, via the StorageClass's `Delete` reclaim policy, the EBS
volumes) with it. **S3 is never touched.** The data under
`ch-s3-4f6a1d2e-…/` survives, which is what you want for a database and what
you must remember for a learning cluster:

```bash
aws s3 rm s3://clickhouse-private-<YOUR_ACCOUNT_ID>-us-east-1/ch-s3-4f6a1d2e-8b3c-4a5d-9e7f-1c2b3a4d5e6f --recursive --profile sa
```

---

# Step 10 — Preflight checks

## What it is

ClickHouse ships a [Troubleshoot](https://troubleshoot.sh) **Preflight** spec
as a Helm chart. The chart is a template and nothing more: `helm template`
renders a `troubleshoot.sh/v1beta2 Preflight` document, and the
`kubectl preflight` plugin runs it — collecting cluster info, the resources in
the cluster and operator namespaces, and the output of two shell scripts it
execs inside a server pod — then grades everything against about thirty
analyzers.

Two consequences:

- It has to run **after** Step 9. Half the analyzers look at the live CR, the
  Keeper StatefulSet and a server pod's cache mount. Run it earlier and those
  are failures, not skips.
- Nothing is installed in the cluster. The plugin runs on your laptop, so it
  needs no mirrored image. `part1-setup.sh` now installs it via `krew`
  (there is no Homebrew formula), and `scripts/lib/common.sh` adds
  `~/.krew/bin` to `PATH`.

## Reading the result without parsing it

`--interactive=false` prints a plain report and encodes the verdict in the exit
code: `0` all pass, `4` warnings only, `3` at least one failure, `1` the run
itself broke. The role reads the code, prints the report, saves both the
rendered spec and the report under `state/preflight/`, and fails only on `3`
or `1`.

## Warnings to expect — to confirm on first run

The chart's analyzers and its base configuration are not perfectly in step.
The preflight flags seven feature flags as *obsolete* and warns if they are
`true`; the chart's own AWS base configuration sets all seven `true`
(`pinAvailabilityZones`, `enableHotReloadableServerSettings`,
`createMissingLogSystemTables`, `flushTextLogOnCrash`,
`addPrestopConfigAsVolume`, `enableReadinessGateReplicaReady`,
`removeDatadogAnnotations`). Expect seven yellow lines that are about
ClickHouse's chart, not your cluster. The deprecated-flag checks (expected
values pinned) should all pass; the chart pins them to what the preflight
expects.

The two exec'd scripts are the ones worth watching: **cache disk must be local
NVMe** (it reads the block device model behind `/mnt/clickhouse-cache` and
fails on `Amazon Elastic Block Store`) and **cache ratio under 80%** (which the
300Gi choice above was made to satisfy).

---

# Step 11 — Verify

## Prove it is a cluster, not three databases

The tutorial port-forwards 9000 and runs `SELECT 1`. That proves a process is
listening. The role goes one round trip further: it creates a
`SharedMergeTree` table and inserts three rows on **replica A**, then reads
them back from **replica B**. For that to return `3`, the following must all
have worked at once:

- the write went to S3 (data) — IRSA credentials, bucket policy, endpoint;
- the part's metadata went through Keeper — quorum, and the Shared Catalog
  the chart enables by default;
- replica B saw it — Keeper watch propagation.

It then shows `system.parts` grouped by disk (the answer should be the S3
disk, not local), drops the test database, and prints the version and host from
each replica. The client runs inside the pod via `kubectl exec`, with the
password in the environment rather than on argv, so it never appears in `ps`
on the node.

## From your laptop

```bash
scripts/ch-client.sh                          # interactive
scripts/ch-client.sh -q "SELECT version()"    # one-off
```

The script does the tutorial's port-forward, reads the admin password from
`state/`, waits for the tunnel to actually accept connections instead of
sleeping a guess, and closes the tunnel on exit. It needs a local
`clickhouse-client` (`brew install clickhouse`).

---

# Cost check

Steps 9–11 add nothing to the hourly rate: the pods fit on the node groups
Step 5 already pays for, servers have no volume, and Keeper's three 10Gi gp3
volumes are pennies. Still ~**$2.32/hr** with nodes up, ~$0.15/hr with them
down. The S3 data is billed by the GB and survives everything except a
deliberate `aws s3 rm`.

# Checkpoint

- [x] Step 9 role: preconditions, IRSA lookup, generated secrets, install, ordered waits with diagnostics, airgap/IRSA/S3 assertions, teardown
- [x] Step 10 role: render, run, save, grade by exit code
- [x] Step 11 role: cross-replica write/read, parts-by-disk, cleanup; `scripts/ch-client.sh`
- [x] Namespace convention `ns-<name>` adopted; IRSA trust policy re-issued (`changed=1`)
- [x] Playbook syntax-checked; cluster chart renders and passes its schema with these values
- [ ] **First run** — bring nodes back, then `--tags cluster`, `--tags preflight`, `--tags verify`
- [ ] Settle the two "to confirm" items above: arm64 selector bridging, preflight warning set
- [ ] Record the real outputs here, as Parts 2 and 3 did
