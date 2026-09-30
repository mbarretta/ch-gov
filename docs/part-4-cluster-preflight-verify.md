# Part 4 — Steps 9–11: the cluster, preflight checks, and proof

> **What you'll learn**
>
> - How the operator turns one `ClickHouseCluster` specification into Keeper and server pods, and how names, namespaces and IRSA all derive from a single release name.
> - How to read ClickHouse's own preflight report, and what the expected warnings mean.
> - How to prove you have a real cluster, not three separate databases, by writing on one replica and reading from another.
>
> **Run it:** `scripts/up.sh` runs every step in order, including these three, and asks before it starts. To resume from this point after a `scripts/down.sh`, run `scripts/up.sh --from cluster`. Then connect with `scripts/ch-client.sh`.

Parts 2 and 3 built a Kubernetes cluster that knows what a ClickHouseCluster *is* and has somewhere to put one. These three steps create one, ask ClickHouse's own diagnostic tool whether it is set up correctly, and then make it do database work across replicas.

> **Cost while running:** about $2.32/hr with the default sizing, all of it node groups. Stop the meter with `scripts/down.sh --nodes-only`. Everything in Kubernetes survives as Pending pods and comes back when you run `scripts/up.sh --from nodes`.

> **Advanced: run individual steps.** To run one step at a time, or to re-run a step after fixing a problem, pass its tag to `scripts/play.sh`:
>
> ```bash
> scripts/play.sh --tags cluster      # Step 9
> scripts/play.sh --tags preflight    # Step 10
> scripts/play.sh --tags verify       # Step 11
> ```
>
> Section 5 of [Part 1](part-1-prerequisites.md) explains what `play.sh` sets up for you.

---

## Step 9 — Deploy a ClickHouseCluster

### What the chart actually installs

The `onprem-clickhouse-cluster` chart renders three objects, and only one of them is interesting:

```
$ helm template default-us-01 oci://.../helm/onprem-clickhouse-cluster -n ns-default-us-01 -f values.yaml
ResourceQuota      default-us-01-onprem-clickhouse-cluster    count/clickhouseclusters.clickhouse.com: "1"
ServiceAccount     ch-default-us-01-sa                        eks.amazonaws.com/role-arn: arn:aws:iam::...:role/clickhouse-private-irsa-ClickHouseS3Role-...
ClickHouseCluster  c-default-us-01
```

Nothing here is a pod. The chart writes a **specification**. The operator from Step 8 reads it and builds the Keeper StatefulSet, one StatefulSet per server replica, and their Services, ConfigMaps and PVCs.

This is why the `clickhouse_cluster` role does not use Helm's `--wait`. Helm would report success the instant the custom resource was accepted, long before anything was running. The role waits on the operator's objects instead, in the order the operator creates them.

### Everything derives from the release name

The chart takes one name and derives the rest:

| From `default-us-01` | Object |
|---|---|
| `c-default-us-01` | the ClickHouseCluster CR |
| `c-default-us-01-keeper` | the Keeper StatefulSet |
| `ch-default-us-01-sa` | the service account |
| `ns-default-us-01` | the namespace, by convention |

The service account name matters most, because Step 6 wrote it into an IAM trust policy. Rename the release and IRSA silently stops matching. The name is also schema-constrained (`^[a-z]+-[a-z]{2}-[0-9]{2}$`), so `default-us-01` passes and `clickhouse` does not. You set it with `clickhouse.cluster_name`.

### The namespace convention

The kit deploys into a namespace called `ns-<cluster name>`, which is `ns-default-us-01` by default. Three things point the same way:

1. The chart README recommends `ns-<name>` and says the namespace should hold exactly one ClickHouseCluster. The ResourceQuota enforces that.
2. The tutorial installs into `ns-$CLUSTER_NAME`.
3. The **preflight chart derives the namespace** as `ns-<clickhouseClusterName>` unless you override it. One of its analyzers checks that a CR named `c-<name>` exists there, and its failure message says the operator "derives the cluster name from the namespace".

A convention that three separate tools assume is not one you want to be the exception to. The namespace lives in one variable, `clickhouse.namespace`, and the IRSA trust policy from Step 6 names it. If you change it, run `scripts/play.sh --tags storage` again so the trust policy matches.

### The password is a hash of a hash, encoded

The tutorial passes `account.hashedPassword`. The chart README shows how to make it:

```bash
echo -n "$PASSWORD" | shasum -a 256 | awk '{printf $1}' | base64
```

Read that carefully: it base64-encodes the **hex string** of the digest, not the digest's raw bytes. The chart's own fallback for a plain-text password does the same thing (`sha256sum | b64enc`), so this is the format the operator expects. A "correct" base64 of the raw 32 bytes would be rejected at login. In Ansible:

```yaml
hashedPassword: "{{ _cl_admin_pw | hash('sha256') | b64encode }}"
```

The password itself is generated once by the `password` lookup, into `state/clickhouse-admin-password` (gitignored, mode 0600), and read back on every later run so the hash, and therefore the release, does not change. Losing the file does not lose the cluster: set a new password with `helm upgrade`.

### Two settings the tutorial sets and one it omits

**`region` and `endpoint`, both.** The chart's AWS defaults are `us-west-2` for each. Part 3 already flagged the endpoint. The region is the same trap, and the IRSA role would not save you, because it is scoped to a bucket ARN, which has no region in it. The kit sets both from `aws.target_region`.

**Image tags, pinned.** The chart says to leave `image.tag` unset and take its own validated pin. Those pins happen to equal what Step 2 mirrored (`versions.server` and `versions.keeper` in `ansible/group_vars/all.yml`). The kit sets the tags explicitly anyway. What runs should be what your configuration says was mirrored, and the chart cannot know about the `-fips` suffix.

**The Prometheus user.** This one is not in the tutorial. `server.prometheus.user.create` defaults to `true` with an **empty password**, which renders as `password_sha256_hex: <sha256 of "">`. There is no Prometheus in this deployment, but the user exists either way, so the role generates a password for it too (`state/clickhouse-prometheus-password`).

### Tolerations and node selectors

Step 5 taints the keeper and server node groups with `clickhouse.com/do-not-schedule=true:NoSchedule`, following the tutorial, so nothing else lands on them. A pod needs a matching *toleration* to run there. Rendering the chart shows what the chart itself assumes:

- The AWS base configuration inside the chart carries tolerations for `clickhouse.com/clickhouse-server-only` and `clickhouse.com/clickhouse-keeper-only`. These are different keys, from ClickHouse Cloud's own node pools.
- Setting `server.tolerations` **replaces** that list rather than appending to it, because Helm's `mergeOverwrite` treats lists as scalars.
- With `arm64: true` the chart appends a toleration for `clickhouse.com/arch=arm64`, which matches the second taint Step 5 puts on Graviton keeper nodes.

So the role sets the `do-not-schedule` toleration explicitly on both server and keeper, as the chart README recommends. The rendered result looks like this:

```yaml
tolerations:
  - {key: clickhouse.com/do-not-schedule, operator: Exists, effect: NoSchedule}
  - {key: clickhouse.com/arch, operator: Equal, value: arm64, effect: NoSchedule}
```

If the operator also injects one, the duplicate is harmless. If it does not, this is the setting that keeps every pod out of `Pending`.

### The arm64 suffix: nothing appends it

In the default (non-FIPS) build, Step 5 labels the nodes `clickhouseGroup: server-arm64` and `keeper-arm64`, while the chart's selector says plain `server` and `keeper`. The tutorial relies on a mutating webhook to bridge the two. Step 8 disables webhooks, as the tutorial says, and the operator does not touch the selector either. Nothing appends the suffix.

So the role puts the suffix in the selector itself, from the same `node_label_suffix` variable Step 5 uses for the labels:

```yaml
nodeSelector:
  clickhouseGroup: "keeper{{ node_label_suffix }}"     # keeper-arm64 by default, keeper with fips: true
```

The tutorial's Step 5 and Step 9, followed literally with webhooks off, cannot schedule a pod. See Troubleshooting if you see Pending Keeper pods.

### OnDelete: a fixed template does not fix a Pending pod

The operator creates its StatefulSets with `updateStrategy: OnDelete`, which means it manages pod replacement itself. A changed pod template is therefore not rolled out to existing pods. Worse, the operator *defers* its own evictions while a Keeper volume is unbound:

```
a keeper pod has an unbound PVC; deferring eviction until all keeper volumes are bound
```

A Pending pod's `WaitForFirstConsumer` PVC never binds, so that is a deadlock. The role breaks it. After every install it deletes any **Pending** pod whose `controller-revision-hash` is not its StatefulSet's `updateRevision`. Running pods are never touched, and when nothing is stale the task finds nothing.

The same `OnDelete` strategy rules out `kubectl rollout status`, which refuses with `rollout status is only available for RollingUpdate strategy type`. The role watches `.status.readyReplicas` with `kubectl wait --for=jsonpath` instead.

### Helm 4 and an operator sharing one object

Helm 4 applies changes server-side. The operator writes to the same ClickHouseCluster object under its own field manager (`manager`), and server-side apply treats that as a conflict on the next `helm upgrade`:

```
Upgrade "default-us-01" failed: conflict occurred while applying object
ns-default-us-01/c-default-us-01 clickhouse.com/v1, Kind=ClickHouseCluster:
Apply failed with 1 conflict: conflict with "manager" using clickhouse.com/v1:
.spec.featureFlags.enableSecurePorts
```

This is the Helm 4 with an operator case that [Part 1](part-1-prerequisites.md) warns about in general terms. The answer is `--force-conflicts`, which `kubernetes.core` 6.5 and later exposes as `force_conflicts: true`. The chart is the source of truth for the fields it renders, so it takes them back.

Two related tools help when a task fails. The role hides its output with `no_log: true` because the values carry password hashes, so pass `-e show_secrets=true` to lift that (`scripts/play.sh --tags cluster -e show_secrets=true`). And `helm history <release> -n <namespace>` shows the error that Helm's Ansible module does not.

### Sizing, and where the cache number comes from

The default sizes are for learning and workshops, not production. [Learning setup vs. production](limitations.md) lists what to change before you rely on a deployment.

| | Node | Pod request = limit | Why |
|---|---|---|---|
| server | `m7gd.2xlarge` (8 vCPU, 32Gi, 442Gi NVMe) | 4 CPU / **16Gi** | The chart's default is 8Gi. 16Gi is the AWS base configuration's own value, the node has room, and the cache scales with RAM (below). |
| keeper | `m7g.xlarge` (4 vCPU, 16Gi) | 2 CPU / 4Gi | The chart's default. |

With `fips: true` the kit uses x86_64 instance types instead (`m6id.2xlarge` for servers and `m7i.xlarge` for Keeper).

The SSD read cache is specified as `cacheDiskSize: 300Gi`, and the chart converts it: **`bytesPerGiRAM = cacheDiskSize / memory limit`**, so 300Gi / 16 = `18Gi`, which is what lands in the CR. 300Gi is about 68% of the 442Gi disk that Step 5 mounts at `/nvme/disk`. Two constraints set that number: the preflight check fails at 80% or more, and ClickHouse can briefly exceed the cache limit during merges. If you change the memory limit, the cache ratio changes with it. That is why the kit expresses the cache as a size and not as the raw ratio.

Servers get **no EBS volume**. `featureFlags.disableMetadataPersistentVolumes` defaults to `true`, which sets `disableServerStorageVolumes` and `enableDatabaseDisk` on the CR. Data lives in S3, table metadata lives in Keeper through the Shared Catalog, and nothing sits on local disk except the cache. Keeper keeps a 10Gi `gp3-encrypted` volume per replica. It is the only persistent state in the cluster, and the only thing teardown has to clean up.

Log level is `information` for both, not the chart's `trace`. Servers have no volume, so logs go to stdout and the node's rotation, and `trace` would make `kubectl logs` unusable.

### What the role verifies before it finishes

1. **Airgap.** Every container image in the namespace pulls from your ECR. That includes init containers, because the operator generates them from `IMAGE_REGISTRY_BASE_PATH` (Step 8), not from any chart value. The role asserts this, as it does in Step 8.

2. **IRSA reached the pods.** Each server pod runs as `ch-default-us-01-sa` and has `AWS_ROLE_ARN` set to the Step 6 role. The kubelet injects that from the service account annotation. If it is missing, the failure would otherwise surface as an `AccessDenied` deep inside ClickHouse's logs.

   One detail matters if you write your own check: the pod's label says `app.kubernetes.io/name=clickhouse-server`, but its container is named **`c-default-us-01-server`**. A jsonpath filter on `@.name=="clickhouse-server"` matches nothing. Select the container by index instead. It is the only container.

3. **Objects exist in S3.** This is the end-to-end proof: a token was minted, exchanged at STS, and accepted by S3. But the objects are not where you would first look:

   ```
   ch-s3-<3 hex>/<uuid>/system/<pod name>/...
   ch-s3-<3 hex>/<uuid>/mergetree/...
   ```

   `enableKeyTemplate` (on by default) shards keys for S3 request throughput. The layout is `ch-s3-<3 hex>/<uuid>/…`, with hundreds of top-level prefixes and the cluster's uuid one level down. **Nothing lives under `ch-s3-<uuid>/` itself**, so the obvious check returns zero, and the obvious `aws s3 rm --recursive` of that prefix deletes nothing while reporting success. The role filters on the uuid segment. A fresh cluster writes hundreds of small system-table and metadata objects within minutes.

When the step finishes, the role prints a summary in this shape:

```
cluster:   c-default-us-01 in ns-default-us-01
server:    3 x <server version>  (4 CPU / 16Gi, cache 300Gi)
keeper:    3 x <keeper version>  (2 CPU / 4Gi, 10Gi EBS each)
s3:        <N>+ objects in s3://<BUCKET_NAME> under ch-s3-*/<uuid>/
admin:     user 'default', password in state/clickhouse-admin-password
```

It then lists the pods, StatefulSets, Services and PVCs. You should see three Keeper pods in one StatefulSet, one StatefulSet per server replica, and PVCs only for Keeper. Keeper pods land one per availability zone on the keeper nodes, and server pods land one per zone on the `m7gd` nodes.

### Teardown

`scripts/down.sh` removes the cluster for you, in the right order, and Part 1 (section 5b) explains why the order matters. To remove only the cluster, use the `scripts/play.sh` form:

```bash
scripts/play.sh --tags cluster -e cluster_state=absent
```

`helm uninstall` removes the CR, and the operator deletes the StatefulSets. The role then waits for the pods to go and deletes the **namespace**, which takes the Keeper PVCs with it. Via the StorageClass's `Delete` reclaim policy, the EBS volumes go too. **S3 is never touched.** The data survives, which is what you want for a database and what you must remember for a learning cluster. Because of the sharded key layout described earlier, deleting the data is a script, not a one-liner:

```bash
scripts/s3-purge-cluster-data.sh --dry-run   # lists this cluster's objects
scripts/s3-purge-cluster-data.sh             # asks for the uuid, then deletes in batches
```

---

## Step 10 — Preflight checks

### What it is

ClickHouse ships a [Troubleshoot](https://troubleshoot.sh) **Preflight** spec as a Helm chart. The chart is a template and nothing more. `helm template` renders a `troubleshoot.sh/v1beta2 Preflight` document, and the `kubectl preflight` plugin runs it. The plugin collects cluster info, the resources in the cluster and operator namespaces, and the output of two shell scripts it runs inside a server pod. It then grades everything against about thirty analyzers.

Two consequences follow:

- It has to run **after** Step 9. Half the analyzers look at the live CR, the Keeper StatefulSet and a server pod's cache mount. Run it earlier and those checks fail instead of skipping.
- Nothing is installed in the cluster. The plugin runs on your machine, so it needs no mirrored image. `scripts/part1-setup.sh` installs it with `krew` (there is no Homebrew formula), and `scripts/lib/common.sh` adds `~/.krew/bin` to `PATH` for the scripts.

### Reading the result without parsing it

`--interactive=false` prints a plain report and encodes the verdict in the exit code:

| Exit code | Meaning |
|---|---|
| `0` | All checks pass. |
| `4` | Warnings only. |
| `3` | At least one check failed. |
| `1` | The run itself broke. |

The `clickhouse_preflight` role reads the code, prints the report, and saves both the rendered spec and the report under `state/preflight/`. It fails the step only on `3` or `1`.

### The expected warnings

The chart's analyzers and its base configuration are not perfectly in step. With the chart versions the kit pins (`versions.preflight_chart` and `versions.cluster_chart`), the preflight flags seven feature flags as *obsolete* and warns if they are `true`, while the chart's own AWS base configuration sets all seven `true`: `pinAvailabilityZones`, `enableHotReloadableServerSettings`, `createMissingLogSystemTables`, `flushTextLogOnCrash`, `addPrestopConfigAsVolume`, `enableReadinessGateReplicaReady` and `removeDatadogAnnotations`. Different chart versions can change the count. The report looks like this (abridged):

```
   --- PASS Required Kubernetes Version
   --- PASS Kubernetes Distribution                       EKS is a supported distribution.
   --- PASS Nodes must use a topology label ...
   --- PASS Custom resource definition clickhouseclusters.clickhouse.com
   --- PASS Storage Class for Operator must be available   gp3-encrypted
   --- PASS ClickHouseCluster must live in the namespace derived from its name
   --- PASS c-default-us-01-keeper Status                  healthy with multiple replicas ready
   --- PASS PVCs for ClickHouse cluster must have node affinity ...
   --- WARN: Check for obsolete featureFlag ...            (x7, all from the chart's base configuration)
   --- PASS ClickHouse cache disk must be a local NVMe SSD
   --- PASS SSD cache ratio should not exceed 80% of cache disk
--- PASS   clickhouse-preflight-bundle
```

The exit code is 4: pass with warnings. The seven warnings are about ClickHouse's chart, not your cluster.

The two scripts that run inside the server pod are the ones worth watching. **Cache disk must be local NVMe** reads the block device model behind `/mnt/clickhouse-cache` and fails on `Amazon Elastic Block Store`. **Cache ratio under 80%** is the check that the 300Gi cache choice was made to satisfy.

---

## Step 11 — Verify

### Prove it is a cluster, not three databases

The tutorial port-forwards 9000 and runs `SELECT 1`. That proves a process is listening. The `clickhouse_verify` role goes one round trip further. It creates a `SharedMergeTree` table and inserts three rows on **replica A**, then reads them back from **replica B**. For that read to return `3`, all of the following must have worked at once:

- The write went to S3 (data), which exercises the IRSA credentials, the bucket policy and the endpoint.
- The part's metadata went through Keeper, which exercises the quorum and the Shared Catalog the chart enables by default.
- Replica B saw it, which exercises Keeper watch propagation.

The role then shows `system.parts` grouped by disk, drops the test database, and prints the version and host from each replica. The client runs inside the pod through `kubectl exec`, so no port-forward is needed. The output looks like this:

```
replica A (c-default-us-01-server-<suffix A>-0): <server version>
wrote 3 rows on A, read from B (c-default-us-01-server-<suffix B>-0): count/max/host = 3  3  c-default-us-01-server-<suffix B>-0
active parts by disk: s3WithKeeperDiskWithCache  3 rows  1 part
```

`s3WithKeeperDiskWithCache` is the answer that matters. The part is in S3, fronted by the NVMe cache from Step 5, with its metadata in Keeper.

### How the password reaches the pod

The role needs the admin password inside the pod without exposing it. Two details of `kubectl exec` shape how it does that:

- **`environment:` does not cross `kubectl exec`.** Setting `CH_PASSWORD` in a task's `environment:` sets the environment of the *local* `kubectl` process, and `exec` does not forward it. The pod would see an empty password. The role uses `kubectl exec -i` and sends the password as the first line of stdin, which the pod's shell reads with `read -r pw`. The password never appears on the command line, where `ps` on the node would show it.
- **An open stdin is data to an INSERT.** `kubectl exec -i` keeps the stream attached after the password line is read, and `clickhouse-client` treats an open stdin on an INSERT as external data. Async inserts, which are on by default, refuse that. The shell therefore redirects the client's stdin from `/dev/null` after reading the password.

Two smaller details: the container is named `c-default-us-01-server`, not `clickhouse-server` (see Step 9), and the role drops the test database *before* it starts as well as after. An interrupted earlier run cannot leave rows behind that make the exact-count check of 3 fail for the wrong reason.

### From your machine

```bash
scripts/ch-client.sh                          # interactive
scripts/ch-client.sh -q "SELECT version()"    # one-off
```

The script does the tutorial's port-forward, reads the admin password from `state/`, waits for the tunnel to accept connections instead of sleeping a guess, and closes the tunnel on exit. It needs a local `clickhouse-client` (on macOS, `brew install clickhouse`). With `fips: true` it connects over TLS on port 9440 and verifies the certificate against the CA the kit generated.

---

## Troubleshooting

**Keeper or server pods stay `Pending`, and the failure output says `8 node(s) didn't match Pod's node affinity/selector`**

- *Cause:* the pod's `nodeSelector` does not match the node labels. On the default build the nodes are labeled `keeper-arm64` and `server-arm64`, and nothing appends that suffix when webhooks are off, so a plain `keeper` selector matches no node.
- *Fix:* the kit builds the selector from `node_label_suffix`, so this appears only if you override `nodeSelector` yourself. Make the selector say what the nodes say. Check the labels with `kubectl get nodes -L clickhouseGroup`.

**A corrected pod template does not fix pods that are already `Pending`**

- *Cause:* the operator's StatefulSets use `updateStrategy: OnDelete`, so existing pods keep their old template, and the operator defers evictions until every Keeper volume is bound.
- *Fix:* run `scripts/play.sh --tags cluster` again. The role deletes Pending pods that sit on a stale revision so the StatefulSet recreates them.

**A `helm upgrade` fails with `conflict with "manager"`, or a Helm task fails with no visible reason**

- *Cause:* Helm 4 server-side apply conflicts with the operator's field manager, and the role hides task output because the values include password hashes.
- *Fix:* the role already passes `force_conflicts: true`, which needs `kubernetes.core` 6.5 or later. Run `scripts/part1-setup.sh` to update the collections. To see the hidden error, add `-e show_secrets=true`, or run `helm history <release> -n <namespace>`.

**Step 9 fails with `status unknown for quota`**

- *Cause:* on a fresh cluster, the Kubernetes controller manager takes several minutes to fill in the ResourceQuota's usage for a newly created CRD, and the API server rejects the ClickHouseCluster until it does.
- *Fix:* wait. The role retries on that error for about twelve minutes. If it still fails, run `kubectl get resourcequota -n ns-default-us-01 -o yaml` and check that `status.used` is populated.

**Step 11 fails with `Code: 48 ... Processing async inserts with both inlined and external data ... is not supported`**

- *Cause:* `clickhouse-client` inherited an open stdin from `kubectl exec -i` and treated it as external data for the INSERT.
- *Fix:* redirect the client's stdin from `/dev/null` after reading the password, as the role does. This appears only if you copy the exec pattern into your own commands.

**A count or path check in S3 returns zero for a cluster that is clearly writing data**

- *Cause:* you filtered on `ch-s3-<uuid>/`, but with `enableKeyTemplate` the uuid sits one level below a three-character shard prefix.
- *Fix:* filter on the uuid segment, as `scripts/s3-purge-cluster-data.sh --dry-run` does.

---

## Cost check

Steps 9–11 add nothing to the hourly rate. The pods fit on the node groups that Step 5 already pays for, servers have no volume, and Keeper's three 10Gi gp3 volumes cost pennies. With the default sizing the rate stays at about **$2.32/hr** with nodes up and about $0.15/hr with them down. S3 data is billed by the GB and survives everything except a deliberate delete.

## Self-checks

Run these in order. Each gives a command and what you should see, and they double as workshop exercises. Start with `source scripts/env.sh`, and set the namespace once (use your `clickhouse.namespace` if you changed it):

```bash
source scripts/env.sh
NS=ns-default-us-01
```

1. **The cluster's pods are running.**

   ```bash
   kubectl get pods -n "$NS" -o wide
   ```

   You should see three Keeper pods and three server pods, all `Running` and `Ready`, spread across three availability zones.

   **Exercise:** the chart installed no pods. Which component created these, and what did it read to do so?

2. **Only Keeper has volumes.**

   ```bash
   kubectl get pvc -n "$NS"
   ```

   You should see three `Bound` claims of `10Gi` on `gp3-encrypted`, all for Keeper, and none for servers.

3. **Every container, init containers included, pulls from your registry.**

   ```bash
   kubectl get pods -n "$NS" \
     -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
   ```

   Every line should start with your ECR hostname.

4. **IRSA reached the server pods.**

   ```bash
   kubectl get pods -n "$NS" -l app.kubernetes.io/name=clickhouse-server \
     -o jsonpath='{range .items[*]}{.metadata.name}{" sa="}{.spec.serviceAccountName}{"\n"}{end}'
   ```

   You should see three lines that end `sa=ch-default-us-01-sa`.

5. **Data is landing in S3.**

   ```bash
   scripts/s3-purge-cluster-data.sh --dry-run
   ```

   You should see a line such as `N object(s) belong to this cluster`, where `N` is greater than zero, and no deletion prompt. The `--dry-run` flag only lists.

6. **Preflight passes with warnings.**

   ```bash
   scripts/play.sh --tags preflight
   ```

   You should see `preflight: PASS with warnings` and seven obsolete-feature-flag warnings from the chart's base configuration. The report is saved in `state/preflight/report.txt`.

7. **The cluster replicates.**

   ```bash
   scripts/play.sh --tags verify
   ```

   You should see `wrote 3 rows on A, read from B` with a count of `3`, and the active part on the disk `s3WithKeeperDiskWithCache`.

   **Exercise:** which three components must work for the read on replica B to succeed?

8. **You can connect from your machine.**

   ```bash
   scripts/ch-client.sh -q "SELECT hostName(), version()"
   ```

   You should see one server pod name and the ClickHouse version.

9. **The step is idempotent.**

   ```bash
   scripts/play.sh --tags cluster
   ```

   On a healthy cluster nothing needs to change, so the play recap should report `changed=0`.

10. **You know how to stop the meter.** Run `scripts/down.sh --nodes-only` when you finish for the day, and `scripts/up.sh --from nodes` to resume.

**Next:** [Part 5](part-5-load-balancer.md) puts a load balancer in front of the servers.
