# Part 6 — Steps 13–15: Langfuse, with ClickHouse as its store

> **What you'll learn**
>
> - How Langfuse uses ClickHouse, and why a trace ends up in `langfuse.events_core`.
> - What Steps 13–15 add to the cluster you built in Parts 1–5, and how to switch them on and check that they worked.
> - How TLS at the load balancer works, what a self-signed certificate does and does not give you, and how to trust it from a client.
> - How to operate and tear down Langfuse with the scripts the kit provides, and what to check when something goes wrong.
>
> **Run it:** set `langfuse.enabled: true` in `state/deploy-vars.yml`, run `scripts/up.sh`, then run `scripts/langfuse-smoke.sh` to post a trace and read it back from ClickHouse. Langfuse is optional and off by default. The kit is sized for learning and workshops, not production.

Parts 1–5 end with a ClickHouse cluster behind a load balancer. Steps 13–15 put a Langfuse server next to it, on the same nodes, and point it at that cluster for its analytics tables. The result is one working example of the idea "ClickHouse Government holds Langfuse's traces." With the switch off, nothing else changes.

```bash
# in state/deploy-vars.yml:  langfuse:  {enabled: true}
scripts/up.sh                     # Steps 1-15 in order; --from lb if the cluster is already up
scripts/langfuse-smoke.sh         # post a trace, read it back from ClickHouse
```

---

## 1. What Langfuse is, and how it uses ClickHouse

Langfuse is an open-source observability server for applications that call language models. An application sends it *traces*, one per request. A trace is made of *spans* and *generations*, which are the individual model calls with their prompt, completion, token counts and latency. The application sends them over an SDK or plain OpenTelemetry. People then browse the traces in a web UI to see what the model was asked, what it said, what it cost and where the time went.

Langfuse keeps its data in four stores, each chosen for the job:

| Store | What Langfuse keeps there | In this kit |
|---|---|---|
| **ClickHouse** | The traces themselves | Your ClickHouse Government cluster, in a database named `langfuse` |
| **PostgreSQL** | Users, projects and settings | A single pod inside the cluster |
| **Valkey** (Redis-compatible) | The work queue and cache | A single pod inside the cluster |
| **S3** | Raw event payloads, batch exports and media | A bucket in your account, reached through an IAM role |

Traces are written once and never edited, and the questions people ask of them are analytics questions: "show me every generation over two seconds last week, grouped by model." That is the workload ClickHouse is built for, so the traces go there.

Two facts about how Langfuse uses ClickHouse shape the install steps:

- **Langfuse creates its own tables.** When the web pod starts, it runs a series of schema migrations against ClickHouse. It needs a database and a user with enough rights to create tables, which is what Step 14 provides.
- **Langfuse 4.x stores every event as an OpenTelemetry span.** Each span becomes one row in `langfuse.events_core`. The older tables `traces`, `observations` and `scores` are still created by the migrations, but they stay empty. This is why the smoke test in section 10 reads `events_core`.

Langfuse runs its migrations `ON CLUSTER default`, so each table is created on every replica. On ClickHouse Government, tables declared as `ReplacingMergeTree` are realized as `SharedReplacingMergeTree`, the engine that keeps data in S3 and coordinates through Keeper. You can see this yourself once the install finishes (section 7).

## 2. From the Terraform module to this repo

Langfuse publishes a reference deployment for AWS, `langfuse/langfuse-terraform-aws`. It installs the same Helm chart this project uses (chart `2.1.0`, app `4.25.0`), builds its own VPC and an EKS-on-Fargate cluster, and buys managed services for the stores. This kit keeps the *shape*: the same chart, the same value keys, `clickhouse.deploy: false` with an external ClickHouse, and S3 reached through an IAM role for the pod's service account (IRSA). It replaces each managed piece with something Parts 1–5 already built.

| Terraform module | This kit | Why |
|---|---|---|
| Aurora Serverless v2 (PostgreSQL) | The chart's bundled PostgreSQL subchart, in-cluster, on Chainguard's `postgres` image, one 20Gi EBS volume | No new AWS service, and the image is already in the airgap hop. See the first workaround in section 7 |
| ElastiCache (Redis) | The chart's bundled Valkey subchart, in-cluster, on Chainguard's `valkey` image, one 8Gi EBS volume | Same reasons. See the second workaround in section 7 |
| EKS on Fargate | The **operator** node group from Step 5 | It is untainted and has the headroom (about 4.75 CPU and 9.5Gi requested in total), so there is no new node group |
| ALB, ACM certificate and Route 53 record | An NLB from the built-in cloud controller. Plain HTTP by default, or TLS terminated at the NLB with a self-signed certificate that the role generates and imports into ACM (`langfuse.load_balancer.tls`, section 9). No domain either way | The same `none \| internal \| public` switch and the same source-range rules as Step 12 |
| `external_clickhouse` | Your ClickHouse cluster from Step 9, over its in-cluster `c-<cluster>-server-any` Service | This is the point of the exercise |
| S3 bucket and IRSA | The same, with its own bucket and its own IRSA role (Step 13) | No access keys anywhere, as in Step 6 |
| Images from `docker.langfuse.com` and `cgr.dev` | Mirrored into your ECR by Step 2 | The cluster pulls only from your account |
| Chart from `langfuse.github.io` | Pushed into your ECR as an OCI artifact by Step 2 | Same reason |

Nothing new is created at the AWS compute or edge layer: no node group, VPC, EKS cluster, ALB or DNS record. You get a certificate only if you turn on TLS, which imports one self-signed certificate into ACM. The one extra AWS resource that bills by the hour is the second NLB.

## 3. The switch, and what it changes

Everything hangs off one block in the configuration. Its defaults live in `ansible/group_vars/all.yml`, and your overrides go in `state/deploy-vars.yml`, which changes only the keys you set (Part 1 section 3b). The defaults are:

```yaml
langfuse:
  enabled: false            # the switch. false = Steps 13-15 do nothing
  namespace: "langfuse"
  release: "langfuse"       # the chart's fullnameOverride, so also the ServiceAccount name IRSA trusts
  clickhouse_database: "langfuse"
  clickhouse_user: "langfuse"
  bucket_name: "langfuse-{{ aws.target_account_id }}-{{ aws.target_region }}"
  url: ""                   # NEXTAUTH_URL override; empty derives it from the NLB
  load_balancer:
    type: "internal"        # none | internal | public, exactly as clickhouse.load_balancer
    allowed_cidrs: []
    port: 80                # 443 when tls is true, so the address carries no port
    cross_zone: true
    tls: false              # true = the NLB terminates TLS with a self-signed certificate (section 9)
    tls_cert_days: 825
  web:    {replicas: 1, cpu: "2", memory: "4Gi"}
  worker: {replicas: 1, cpu: "2", memory: "4Gi"}
  postgres: {disk: "20Gi", cpu: "500m", memory: "1Gi"}
  valkey:   {disk: "8Gi",  cpu: "250m", memory: "512Mi"}
  init: {org_id: demo, org_name: Demo, project_id: demo, project_name: Demo,
         user_email: admin@example.com, user_name: Admin}
  telemetry_enabled: false  # no phone-home
  signup_disabled: true     # no self-service accounts on a server that may be public
```

To turn it on, put this in `state/deploy-vars.yml`:

```yaml
langfuse:
  enabled: true
```

**With `enabled: false`**, the default, nothing observable changes for Steps 1–12. Step 2 mirrors only the seven ClickHouse artifacts, `up.sh` runs Steps 1–12, and `scripts/play.sh --tags langfuse` prints its banner and skips every Langfuse task.

**With `enabled: true`**, three things happen:

- Step 2 mirrors four more images and one chart (section 4).
- `up.sh` appends `lf-storage lf-db lf-app` after `lb` and prints the Langfuse URL at the end.
- `down.sh` removes Langfuse first (section 13).

The three steps are:

| Step | Tag | What it does |
|---|---|---|
| 13 | `lf-storage` | The S3 bucket and the IAM role (section 5) |
| 14 | `lf-db` | The database and user inside ClickHouse (section 6) |
| 15 | `lf-app` | The Helm release, the NLB, PostgreSQL and Valkey (section 7) |

> **Advanced: run individual steps.** `scripts/up.sh` is the normal way to run them. To run one step or one group on its own, pass its tag to `scripts/play.sh`, for example `scripts/play.sh --tags lf-db`. The tag `langfuse` runs Steps 13, 14 and 15 together.

## 4. Step 2 again: four images and a chart

When you switch Langfuse on, `scripts/up.sh` re-runs the image hop and copies what is new. Every step is idempotent, so the ClickHouse images that are already present are skipped:

```
TASK [image_sync : Copy each artifact that is not already present] *************
changed: [localhost] => (item=langfuse/langfuse:4.25.0)
changed: [localhost] => (item=langfuse/langfuse-worker:4.25.0)
changed: [localhost] => (item=chainguard/postgres:pg18-cg)
changed: [localhost] => (item=chainguard/valkey:valkey9-cg-dev)
TASK [image_sync : Push each pulled chart to ECR] ******************************
changed: [localhost] => (item=helm/langfuse:2.1.0)
```

Two things are new compared with the ClickHouse images.

**Chainguard's free tier publishes only `latest`.** You cannot pin `postgres:18.6` on `cgr.dev`. There is `latest` and, for images with a shell, `latest-dev`. So the artifact list carries a `source_tag` (`latest` or `latest-dev`) that is separate from the tag the image lands under in ECR (`pg18-cg` or `valkey9-cg-dev`, from `versions.chainguard_postgres_tag` and `versions.chainguard_valkey_tag`). ECR tags are immutable and the sync skips tags that already exist. Whatever digest `latest` resolved to on the first copy is therefore what that tag means until someone bumps it in `versions`. The version in the tag is a major number only, because that is all the image promises. Step 15 checks the real version in the running pods (section 7).

**The chart comes from a plain Helm HTTP repository**, not an OCI registry, so skopeo cannot copy it. The role runs `helm pull` from `https://langfuse.github.io/langfuse-k8s` into `state/charts/` and `helm push` into `oci://<your ecr>/helm/langfuse`. The packaged chart contains its subcharts, so nothing else needs mirroring. Your machine must reach `cgr.dev`, `docker.langfuse.com` and `langfuse.github.io` during this step, anonymously and with no new credentials. `scripts/part1-setup.sh` names them in its network check for that reason.

To see what landed and its digest, list the repositories in your registry:

```bash
source scripts/env.sh
aws ecr describe-images --repository-name chainguard/postgres --profile "$AWS_PROFILE" \
  --query 'imageDetails[].[imageTags[0],imageDigest]' --output text
```

You should see the tag `pg18-cg` and a `sha256:` digest. Because the digest depends on the day `latest` was first copied, two people who deploy on different days can see different digests for the same tag. That is expected, and it is the reason to read the digest from your own registry instead of assuming it.

## 5. Step 13 — a bucket and an IRSA role (`lf-storage`)

Step 13 is a smaller Step 6: one bucket, one role, one CloudFormation stack.

- **The bucket** `langfuse-<account>-<region>` (`langfuse.bucket_name`) is created with the `s3_bucket` module, AES256 default encryption, all four public-access blocks on and versioning off. These are the same three decisions Part 3 made for the ClickHouse bucket, for the same reasons. Langfuse keeps its raw event uploads under `events/`, batch exports under `exports/` and media under `media/`.
- **The stack** `clickhouse-private-langfuse-irsa` (`{{ infrastructure.environment_name }}-langfuse-irsa`) holds one IAM role with a federated trust on the cluster's OIDC provider, restricted to `system:serviceaccount:langfuse:langfuse`, which is the namespace and the release name. The chart names its ServiceAccount after the release only when the release name contains `langfuse`, and `<release>-langfuse` otherwise. Step 15 passes the release as the chart's `fullnameOverride`, so the name is the release whatever you set it to, and this trust policy matches it. The role may `PutObject`, `GetObject`, `ListBucket` and `DeleteObject` on that one bucket (`DeleteObject` because Langfuse expires its own exports and media). The stack outputs `LangfuseS3RoleArn`, which Step 15 reads.

The step ends with a report of the wiring:

```
TASK [langfuse_storage : Report the IRSA wiring] *******************************
ok: [localhost] => {
    "msg": [
        "langfuse role: arn:aws:iam::<account>:role/clickhouse-private-langfuse-irsa-LangfuseS3Role-…",
        "  assumable only by system:serviceaccount:langfuse:langfuse",
        "  may PutObject, GetObject, ListBucket, DeleteObject on langfuse-<account>-<region> only",
        "note: the bucket is never deleted by teardown -- it holds data."
    ]
}
```

There are no S3 access keys in this kit and nowhere to put any. The chart's `s3.deploy: false` block is given a bucket and a region and no credentials, so the AWS SDK inside the pods falls through to the web identity token that the ServiceAccount annotation provides. Once Step 15 has run, you can confirm this from the web pod's environment:

```bash
kubectl exec -n langfuse deploy/langfuse-web -- env | grep -E 'AWS_ROLE_ARN|AWS_WEB_IDENTITY_TOKEN_FILE|ACCESS_KEY'
```

You should see `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`, and no line containing `ACCESS_KEY`.

## 6. Step 14 — a database and a user inside ClickHouse (`lf-db`)

Langfuse could be handed the `default` admin account. It is not. Step 14 creates a database `langfuse` and a user `langfuse` that holds exactly the grants Langfuse documents for an external ClickHouse. The grants are scoped to that database plus the handful of `system` tables its migrations and health checks read.

**How the password travels.** The role generates `state/langfuse-clickhouse-password` (32 characters, mode 0600) and hashes it with SHA-256 in Ansible. It then runs every statement through `kubectl exec -i` in one server pod, with the admin password on stdin, which is the same pattern as Step 11. The SQL that reaches ClickHouse says `IDENTIFIED WITH sha256_hash BY '<hex>'`. The plaintext exists only in `state/`, where Step 15 reads it into a Kubernetes Secret, and in Langfuse's pods.

**The grants.** You can list them with `scripts/ch-client.sh -q "SHOW GRANTS FOR langfuse"`. ClickHouse folds `CREATE` into its four parts and backtick-quotes `table`:

```
GRANT CLUSTER ON *.* TO langfuse
GRANT READ ON REMOTE TO langfuse
GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE, ALTER ADD COLUMN, ALTER MODIFY COLUMN, ALTER ADD INDEX, ALTER DROP INDEX, ALTER MATERIALIZE INDEX, ALTER VIEW MODIFY QUERY, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW ON langfuse.* TO langfuse
GRANT SELECT(database, is_done, `table`) ON system.mutations TO langfuse
GRANT SELECT(active, database, name, partition, partition_id, rows, `table`) ON system.parts TO langfuse
GRANT SELECT ON system.processes TO langfuse
GRANT SELECT ON system.query_log* TO langfuse
GRANT SELECT(database, engine, name) ON system.tables TO langfuse
```

**No `ON CLUSTER` anywhere.** The cluster's user directory is replicated through Keeper, so a user created on one replica exists on all three. That is also why the role can run against any one server pod.

**`GRANT CLUSTER`.** Langfuse lists `CLUSTER ON *.*` among the grants for clustered deployments. Whether the `default` admin is allowed to pass that grant on depends on the server, so the role attempts it with `failed_when: false`, records the result, and hands it to Step 15. The Step 14 report prints `cluster: granted` or `cluster: already granted` when it worked. Section 7 explains what Step 15 does with the answer.

**Idempotency, done by authenticating.** `system.users.auth_params` does not expose password hashes, so the question "is the stored hash still ours?" is answered by an HTTP `SELECT 1` as the Langfuse user, using the password from `state/`. If that succeeds, there is nothing to do. If it fails, the role runs `ALTER USER ... IDENTIFIED WITH sha256_hash BY '<hex>'`. Every statement prints `created`, `exists` or `updated`, and `changed_when` keys off it, so a second run reports:

```
"database:  langfuse -- already existed",
"user:      langfuse -- existed, hash already matched the password file",
"grants:    unchanged (8 GRANT lines, listed above)",
"cluster:   cluster: already granted",
```

**Teardown is the "purge Langfuse data" switch.** Setting `langfuse_db_state=absent` for the `lf-db` step runs `DROP DATABASE langfuse SYNC; DROP USER langfuse;` and keeps the password file. A later run of the step recreates both with the same hash, so the Secret that Step 15 already wrote stays valid. Step 15's own teardown deliberately leaves the database alone. Section 13 has the whole story and the command.

## 7. Step 15 — Langfuse itself (`lf-app`)

Order matters in this role more than in any other. `NEXTAUTH_URL` is baked into the web pods, and the browser is redirected to it after login, so it must equal the address people type. That means the load balancer has to exist and have a hostname *before* the Helm release. The role therefore runs in this order:

1. Validate `langfuse.load_balancer.type` and decide cluster mode. Neither needs anything created yet.
2. Create the namespace and the three Secrets.
3. Create the NLB Service `langfuse-lb`.
4. With `tls`, create the certificate, import it into ACM and switch the listener (section 9).
5. Settle the URL.
6. Log in to ECR and install the chart.
7. Repair PostgreSQL.
8. Wait, assert, and report.

### The Secrets, and the name the chart owns

Ansible writes three Secrets from files it generates under `state/`, with the same `password` lookup Step 9 uses. A re-run reads them back instead of rotating them.

| Secret | Keys | From |
|---|---|---|
| `langfuse-app-auth` | `nextauth-secret`, `salt`, `encryption-key` | `state/langfuse-nextauth-secret`, `-salt`, `-encryption-key` |
| `langfuse-clickhouse` | `password` | `state/langfuse-clickhouse-password` (Step 14) |
| `langfuse-init` | `LANGFUSE_INIT_ORG_ID` … `LANGFUSE_INIT_USER_PASSWORD` (9 keys) | `langfuse.init` plus `state/langfuse-admin-password`, `-public-key`, `-secret-key` |

`langfuse-init` is Langfuse's headless bootstrap. On first boot it creates the organization, the project, the admin user and one API key pair, so you have credentials without clicking through sign-up, which is disabled anyway. The key pair (`pk-lf-…` and `sk-lf-…`) is what the smoke test reads.

The first Secret is `langfuse-app-auth`, not `langfuse-app`, on purpose. Chart 2.1.0 renders a Secret named exactly `<fullname>-app` to hold whichever of the three values it has to generate itself, and Helm refuses to install over an object it does not own. The kit follows the chart's own `-auth` suffix for credential Secrets (as in `langfuse-postgresql-auth`), and the chart's `langfuse-app` is created empty because every value is provided. The chart also generates `langfuse-postgresql-auth` and `langfuse-redis-auth` for its subcharts.

### Why cluster mode stays on

Langfuse runs its ClickHouse migrations `ON CLUSTER default` when `CLICKHOUSE_CLUSTER_ENABLED` is true, which is its default. That fits ClickHouse Government: the cluster is named `default`, `cloud_mode` is `1`, and `ReplacingMergeTree` tables are realized on the shared S3 engine. The one way this could fail is a server that *requires* the `CLUSTER` grant for `ON CLUSTER` statements (the `on_cluster_queries_require_cluster_grant` setting) for a user that could not be given it. So the role checks both inputs before installing and reports its decision:

```
TASK [langfuse : Report the cluster-mode decision] *****************************
ok: [localhost] => {
    "msg": [
        "CLUSTER granted to langfuse:        True",
        "on_cluster_queries_require_cluster_grant: not reported",
        "clickhouse.cluster.enabled:               True"
    ]
}
```

The role reads the setting with `SELECT value FROM system.settings ... UNION ALL SELECT value FROM system.server_settings WHERE name = 'on_cluster_queries_require_cluster_grant'`. If the setting is in neither table, the query returns no rows, and the role reports `not reported` and treats the setting as not enforced. Either input alone keeps `clickhouse.cluster.enabled: true`. A `cluster.enabled: false` fallback exists in the role for a server where both inputs go the other way. It is not the default.

When the install finishes, list the tables the migrations created:

```bash
scripts/ch-client.sh -q "SELECT name, engine FROM system.tables WHERE database = 'langfuse' ORDER BY name"
```

You should see 13 tables for app `4.25.0`: the views (`analytics_*`) and the materialized view `events_core_mv`, and every other table on a `Shared*MergeTree` engine:

```
analytics_observations       View                       events_core_mv     MaterializedView
analytics_scores             View                       events_full        SharedReplacingMergeTree
analytics_traces             View                       observations       SharedReplacingMergeTree
blob_storage_file_log        SharedReplacingMergeTree   observations_batch_staging  SharedReplacingMergeTree
dataset_run_items_rmt        SharedReplacingMergeTree   schema_migrations  SharedMergeTree
events_core                  SharedReplacingMergeTree   scores             SharedReplacingMergeTree
                                                        traces             SharedReplacingMergeTree
```

### Two Chainguard workarounds

Both subcharts assume the upstream Docker images. Chainguard's images differ in two places, and the role handles each.

**PostgreSQL: the init script is ignored.** The bundled subchart ships a first-boot script that creates the `langfuse` PostgreSQL role and hands it the database. The subchart mounts the script at `/docker-entrypoint-initdb.d`, where the Docker image's entrypoint looks. Chainguard's entrypoint reads `/var/lib/postgres/initdb/` instead, so the script is silently ignored and the role never exists. Without a fix, web and worker would crash-loop on `password authentication failed`. So once the PostgreSQL pod is Ready, the role does what the script would have done. It runs `kubectl exec -i` into the pod and pipes `psql -h localhost -U postgres` a heredoc that creates the role if missing, grants it the database and makes it the owner. Neither password touches a command line: the superuser's rides `PGPASSWORD` from the pod's `POSTGRES_PASSWORD`, and the role's is read by `\getenv` from `USERDB_PASSWORD`. The subchart wires both from `langfuse-postgresql-auth`. The step prints `role: created` the first time and `role: exists` after that.

```
TASK [langfuse : Create the langfuse PostgreSQL role (what the skipped init script would have done)] ***
changed: [localhost]
```

Chainguard's image also runs as uid `postgres=70` (the Docker image uses 999). The role sets `podSecurityContext.fsGroup: 70` and `securityContext.runAsUser/runAsGroup: 70`. PGDATA is the `pg` subdirectory, so the volume's `lost+found` is no obstacle. The pod runs under the subchart's `readOnlyRootFilesystem: true` and writes only to the emptyDirs the subchart already mounts.

**Valkey: no `/bin/sh`.** `cgr.dev/chainguard/valkey:latest` contains exactly the server and nothing else, and the subchart's init container runs a `#!/bin/sh` script from that same image. The fix is the `latest-dev` variant, which adds busybox. That is why the tag is `valkey9-cg-dev` and the artifact list has `source_tag: latest-dev`. The role also sets uid, gid and fsGroup to Chainguard's `65532` (the subchart assumes 1000). It restates `maxmemory-policy noeviction` in the values because Langfuse requires it.

### A liveness probe with room for the migrations

The web container applies every ClickHouse migration before its HTTP server listens. On ClickHouse Government each `ON CLUSTER` DDL statement on a shared-engine table takes between a fraction of a second and about ten seconds. The chart's default liveness probe (20 seconds of initial delay, then five failures 10 seconds apart) would restart the container after roughly 70 seconds, in the middle of a migration. `golang-migrate` then records `schema_migrations` as dirty, and every later start fails with `Dirty database version N`.

The chart has no `startupProbe` for web, so the role relaxes the liveness probe in its values to `initialDelaySeconds: 60`, `periodSeconds: 10` and `failureThreshold: 90`. That is about fifteen minutes of grace before a first restart. The unchanged readiness probe keeps traffic off the pod until it is actually ready. If you ever see the dirty-version error anyway, the Troubleshooting section has the recovery.

### What the role verifies before calling it done

After the waits (PostgreSQL and Valkey Ready, then the web Deployment available, then the worker), the role runs a series of assertions. If any wait fails, its `rescue` block dumps the pods, the Warning events and the web and worker log tails before failing:

```
TASK [langfuse : Assert no container pulls from outside your registry] *********
ok: [localhost] => { "msg": "all 6 containers in langfuse pull from <account>.dkr.ecr.us-east-1.amazonaws.com" }
TASK [langfuse : The data stores are the major versions the images were mirrored for] ***
ok: [localhost] => { "msg": "postgres (PostgreSQL) 18.6 / Valkey server v=9.1.2 ..." }
TASK [langfuse : The migrations landed, on the shared engine] ******************
ok: [localhost] => { "msg": "database langfuse: 13 tables, events_core=SharedReplacingMergeTree, observations=SharedReplacingMergeTree, scores=SharedReplacingMergeTree, traces=SharedReplacingMergeTree" }
TASK [langfuse : Wait for the web node(s) to pass the NLB health check] ********
ok: [localhost]
TASK [langfuse : Langfuse must answer through its Service] *********************
ok: [localhost] => { "msg": "GET http://langfuse-web:3000/api/public/health -> 200" }
```

There are six containers because both subcharts run an init container from the same mirrored image. The health check through the ClusterIP Service `langfuse-web` is the hard assertion. The NLB path is probed from a pod placed on a node without a web pod (the Step 12 hairpin, again). That probe is retried rather than failed, and the target group must show one healthy target per web replica.

### What a passing run reports

The closing report looks like this:

```
url:        http://<hostname>.elb.us-east-1.amazonaws.com
exposure:   internal NLB <hostname>.elb.us-east-1.amazonaws.com, allowed from 10.20.0.0/16; 1 healthy target(s); answers 200 from inside the VPC
login:      admin@example.com -- password in .../state/langfuse-admin-password
api keys:   .../state/langfuse-public-key (public), .../state/langfuse-secret-key (secret) -- project demo
clickhouse: database langfuse at c-default-us-01-server-any.ns-default-us-01.svc.cluster.local:8123 (plaintext) as langfuse, 13 tables, cluster mode on
smoke test: scripts/langfuse-smoke.sh   (posts a trace and reads it back from ClickHouse)
```

## 8. Reaching it from a browser

The default exposure is an **internal** NLB, so the same three options as Part 5 apply, with one twist. NextAuth redirects the browser to `NEXTAUTH_URL` after login, so the address you type must be the one the role baked in.

1. A VPN or peering into the VPC. The URL in the report works as printed.
2. `type: none` in `langfuse.load_balancer`, then `kubectl port-forward -n langfuse svc/langfuse-web 3000:3000` and open `http://localhost:3000`. The port must be exactly 3000, because that is the `NEXTAUTH_URL` the role sets for this mode.
3. `type: public` with `allowed_cidrs: ["<your egress IP>/32"]`. This uses plain HTTP by default, which is fine for a lab and for nothing else. Turn on `langfuse.load_balancer.tls` (section 9) before you expose it this way, and read there what a self-signed certificate does and does not give you. `0.0.0.0/0` is refused unless you also pass `-e allow_open_internet=true`, as in Step 12. The kit is built around the `internal` type; [Scope and boundaries](limitations.md) lists what the kit covers and what it leaves out.

If people reach Langfuse by a name the role cannot discover (a VPN alias, or a DNS record you put in front of the NLB), set `langfuse.url` and re-run `scripts/up.sh`. Log in as `admin@example.com` with the password in `state/langfuse-admin-password`. Sign-up is disabled and telemetry is off.

## 9. TLS at the load balancer

Plain HTTP is the default because the NLB the cloud controller builds is a TCP pass-through, and there is no domain to get a certificate for. On that default, every SDK request carries the `pk:sk` API key pair as Basic auth, and every browser session carries its login cookie, in clear text. They cross whatever sits between the client and the NLB: the VPC for `internal`, the internet for `public`. One switch closes that:

```yaml
langfuse:
  load_balancer:
    tls: true               # the NLB terminates TLS
    port: 443               # so the address is https://<hostname>, no port
    tls_cert_days: 825      # validity of the self-signed certificate
```

Put that in `state/deploy-vars.yml` and run `scripts/up.sh`. The role needs OpenSSL 3 on `PATH`. On macOS that means `brew install openssl@3` with `/opt/homebrew/bin` first, and the role fails with that instruction if it finds macOS's LibreSSL instead.

**`fips: true` turns this on for you.** The repo has a single `fips` boolean, and you should not also have to flip a second switch. So the role computes an *effective* TLS state: `tls` OR `fips`, whenever `load_balancer.type` is not `none`. With `fips: false`, `tls` alone decides, exactly as above. With `fips: true` and a `type` of `internal` or `public`, the NLB terminates TLS whether or not you also set `tls: true`. `load_balancer.type: none` has no NLB at all, so there is nothing to terminate TLS on. A `none` deployment stays `http://localhost:3000` through the port-forward regardless of `fips`. Two more `fips: true` changes ride along with the same certificate:

- The NLB's TLS security policy (the `aws-load-balancer-ssl-negotiation-policy` annotation and the listener's own `--ssl-policy`) becomes `ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04` instead of the default `ELBSecurityPolicy-TLS13-1-2-2021-06`. Both allow TLS 1.2 and 1.3.
- The self-signed key becomes RSA `tls_rsa_bits` (set in `ansible/group_vars/all.yml`): 3072 bits under `fips: true` and 2048 otherwise. A certificate already at or above the required strength is reused untouched on the next run. One still below it, left over from a `fips: false` run, is regenerated even though its SAN still names the current hostname.

**What `fips: true` does *not* buy here.** The certificate is still generated by OpenSSL on the machine that runs Ansible. It is the same self-signed certificate described below, at a larger key size and behind a FIPS listener policy. The kit does not make that machine's OpenSSL build FIPS 140-3 validated. Whether that matters for your compliance target is a question this repo does not answer for you, and [Learning setup vs. production](limitations.md) lists the boundaries.

**What you get, and what you do not.** The certificate is self-signed. The role generates it, nobody vouches for it, and no browser or SDK trusts it until you hand them the file. That buys **encryption**: the key pair and the session never cross the network in clear text. It does **not** buy identity. Anyone can mint a certificate that says `CN=langfuse` and names an NLB hostname. What makes yours trustworthy is that it came out of your `state/` directory, not that a CA signed it. There is no domain, no DNS record and no publicly trusted certificate in this kit. A browser warns once and asks you to proceed, and that warning is the honest price of a certificate no CA has seen.

### What the role does, in order

The certificate must name the NLB hostname as a subject alternative name (SAN), and the hostname exists only once the Service does. So the TLS work slots between the hostname wait and the URL:

1. **The Service** `langfuse-lb` is created as before, and the role waits for its hostname.
2. **Key and certificate** go into `state/`. `openssl req -x509 -newkey rsa:{{ tls_rsa_bits }} -noenc` writes `state/langfuse-tls-key.pem` (mode 0600) and `state/langfuse-tls-cert.pem` with `CN=langfuse` and `subjectAltName=DNS:<hostname>`, valid `tls_cert_days`. The role regenerates them when either file is missing, when the certificate's SAN does not name the current hostname (`openssl x509 -noout -ext subjectAltName`), or, under `fips: true` only, when the existing key is below `tls_rsa_bits` (the `Public-Key: (N bit)` line of `openssl x509 -noout -text`). Expiry does not trigger regeneration.
3. **The ACM import** uses `community.aws.acm_certificate` under the Name tag `clickhouse-private-langfuse-lb` (`{{ infrastructure.environment_name }}-langfuse-lb`). The same body maps to the same ARN and reports `ok`, and a regenerated certificate is re-imported under that ARN.
4. **The Service is patched** with the three annotations the cloud controller reads: `service.beta.kubernetes.io/aws-load-balancer-ssl-cert` (the ARN), `aws-load-balancer-ssl-ports` (the listener port, `443`) and `aws-load-balancer-ssl-negotiation-policy`. The policy is `ELBSecurityPolicy-TLS13-1-2-2021-06`, AWS's recommended TLS 1.2/1.3 policy for NLBs, or `ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04` under `fips: true`. The target stays plain TCP to the web pod's port 3000.
5. **The role switches the listener itself.** It runs `aws elbv2 modify-listener --protocol TLS` with that certificate and policy, because the cloud controller cannot (see the next subsection). The role skips this when the listener is already TLS with this certificate, which is every re-run.
6. **The URL settles** to `https://<hostname>`, and the release is installed with it as `NEXTAUTH_URL`. In the role's final verification, before the NLB health-check wait and the in-cluster probe, the task `Wait for the listener to terminate TLS` reads the listener back.

### Why the role switches the listener itself

You might expect that annotating the Service is enough, and that `kubernetes/cloud-provider-aws` then rebuilds the listener as TLS. It does not. The controller indexes the listeners it finds by port *and* protocol, and it handles additions before deletions. After the patch it wants `(443, TLS)`. It does not match that against the existing `(443, TCP)`, so it calls `CreateListener` on a port that already has one. That fails, on every retry, and the controller never reaches the deletion that would have made room. `ModifyListener` is the call it would need, and it only makes that call when the port and protocol already match. So the role makes the call once, right after the patch.

The patch also names the negotiation policy for a reason that only shows up here. The controller compares the listener's policy with that annotation on every sync. With both present and equal, its next sync finds nothing to change.

If the switch has not happened yet, the Service's events show the controller's failure, and the Troubleshooting section explains how to read it.

### The address, with and without TLS

`NEXTAUTH_URL` is baked into the web pods, so the role and the scripts must derive the same address. The rule lives in the role and in `lf_url()` in `scripts/lib/common.sh`:

| `langfuse.url` | `type` | `tls` *(effective: `tls` OR `fips`)* | Address |
|---|---|---|---|
| set | any | any | `langfuse.url`, as given |
| empty | `none` | — | `http://localhost:3000` (the fixed port-forward, regardless of `fips`) |
| empty | `internal` / `public` | `false` | `http://<hostname>`, with `:<port>` unless `port` is 80 |
| empty | `internal` / `public` | `true` | `https://<hostname>`, with `:<port>` unless `port` is 443 |

The `tls` column is the *effective* state: `fips: true` makes it `true` even when `langfuse.load_balancer.tls` is left `false`, for any `type` other than `none`. Set `port: 443` with `tls: true` (or `fips: true`). The rule is honest about any other value: `port: 8443` gives `https://<hostname>:8443`. But effective-`tls: true` with the default `port: 80` gives `https://<hostname>:80`, which works and looks wrong to everyone who reads it.

### Check TLS yourself

With `tls: true`, `port: 443` and an `internal` NLB, run these after `scripts/up.sh` finishes. The role's report ends with an `exposure:` line that includes `TLS terminated at the NLB with a self-signed certificate`.

**The Service carries the three annotations.**

```bash
kubectl get service langfuse-lb -n langfuse -o jsonpath='{.metadata.annotations}'
```

You should see `aws-load-balancer-ssl-cert` with an ACM ARN, `aws-load-balancer-ssl-negotiation-policy` with `ELBSecurityPolicy-TLS13-1-2-2021-06` (or the FIPS policy), and `aws-load-balancer-ssl-ports` with `443`.

**The certificate names the NLB.**

```bash
openssl x509 -in state/langfuse-tls-cert.pem -noout -ext subjectAltName -subject -issuer -dates
```

You should see a `DNS:` entry with your NLB hostname, `subject=CN=langfuse`, and the same value for `issuer`, because the certificate is self-signed. `notAfter` is `tls_cert_days` after `notBefore`.

**The web pods use the https address.**

```bash
kubectl exec -n langfuse deploy/langfuse-web -- sh -c 'echo $NEXTAUTH_URL'
```

You should see `https://<hostname>` with no port.

**The certificate is imported into ACM.**

```bash
aws acm list-certificates --profile "$AWS_PROFILE" --query 'CertificateSummaryList[].CertificateArn' --output text
```

`list-certificates` does not return tags. Run `aws acm list-tags-for-certificate --certificate-arn <arn> --profile "$AWS_PROFILE"` on each ARN until you find the one tagged `Name=clickhouse-private-langfuse-lb`, then run `aws acm describe-certificate` on it. You should see `Status ISSUED`, `Type IMPORTED`, `Subject CN=langfuse`, your NLB hostname in the SAN list, and the NLB in `InUseBy`.

**The client side works with the CA and fails without it.** An `internal` NLB does not answer a laptop outside the VPC, so run this from a pod inside the cluster. The ClickHouse Keeper pods never carry a web pod, so there is no hairpin. This example uses the default cluster name; substitute your namespace and pod name if you changed it. It copies the certificate in over `kubectl exec` stdin:

```
$ kubectl exec -i -n ns-default-us-01 c-default-us-01-keeper-0 -- sh -c 'cat > /tmp/langfuse-ca.pem' < state/langfuse-tls-cert.pem
$ kubectl exec -n ns-default-us-01 c-default-us-01-keeper-0 -- \
    curl --cacert /tmp/langfuse-ca.pem --write-out '\nHTTP %{http_code}  ssl_verify_result=%{ssl_verify_result}\n' \
    https://<hostname>.elb.us-east-1.amazonaws.com/api/public/health
{"status":"OK","version":"4.25.0"}
HTTP 200  ssl_verify_result=0

$ kubectl exec -n ns-default-us-01 c-default-us-01-keeper-0 -- \
    curl https://<hostname>.elb.us-east-1.amazonaws.com/api/public/health
curl: (60) SSL certificate problem: self-signed certificate
command terminated with exit code 60
```

With the CA, the request returns 200. Without it, curl refuses. That pair is the whole claim: the connection is encrypted, and it is trusted only by clients you gave the file to.

### Trusting it from a client

The certificate is its own CA, and the CA file is the certificate: `state/langfuse-tls-cert.pem`. It is public (no key material, mode 0644) and safe to copy wherever a client runs.

- **curl:** `curl --cacert state/langfuse-tls-cert.pem https://<hostname>/api/public/health`. Without `--cacert`, curl exits 60 with `SSL certificate problem: self-signed certificate`. That failure is the proof the certificate is not publicly trusted, not a bug to route around. Do not reach for `-k` or `--insecure`: it turns verification off and leaves you with an encrypted connection to whoever answered, which is the one thing this section exists to avoid.
- **A browser:** expect the self-signed warning once, then proceed. Log in as `admin@example.com` with the password in `state/langfuse-admin-password`, as before.
- **An SDK or OTLP exporter:** give its runtime the same file through whatever that runtime uses to add a CA (Node and Python each read one environment variable naming an extra CA file). Then point it at `https://<hostname>/api/public/otel/v1/traces` with Basic auth `pk:sk`, exactly as in section 10.

**The smoke test knows the rule too.** `scripts/langfuse-smoke.sh` passes `--cacert state/langfuse-tls-cert.pem` only when the address it is using came from the `langfuse-lb` hostname with TLS on (`lf_cacert()` in `scripts/lib/common.sh`), because that hostname is the only name the certificate carries. A `LANGFUSE_URL` or `langfuse.url` alias is verified against the system trust store instead, unless you supply `LANGFUSE_CACERT=<pem>`, which then wins everywhere. The port-forward fallback is plain `http://localhost:3000` and drops the CA. Nothing in the script passes `-k`.

One consequence to know before you run it: an `internal` NLB does not answer a laptop outside the VPC. From there the script prints its `TLS: trusting the role's self-signed certificate` line, warns that the NLB does not answer, and falls back to the tunnel. Its https path runs only where the NLB answers, which means from inside the VPC or over a VPN with `LANGFUSE_URL` and `LANGFUSE_CACERT` set to whatever reaches it from where you are. [Scope and boundaries](limitations.md) lists this among the paths outside what the kit is built around.

### Teardown, with TLS

`down.sh` removes Langfuse's TLS pieces in this order: delete Service `langfuse-lb` and wait for it, delete the ACM certificate by its Name tag, uninstall the release, then delete the namespace. The certificate comes second because ACM refuses to delete one that a listener still uses, and the NLB goes a little after the Service's finalizer clears. The role retries exactly that error (`ResourceInUseException`) up to 18 times, 10 seconds apart, and stops on anything else. It stops before the release and namespace go, so `down.sh` still finds Langfuse installed and a re-run tries again. While the wait runs, you see output like this:

```
==> down: lf-app
TASK [langfuse : Remove the load balancer Service] *****************************
changed: [localhost]
FAILED - RETRYING: [localhost]: langfuse : Delete the ACM certificate (17 retries left).
...
TASK [langfuse : Delete the ACM certificate] ***********************************
changed: [localhost]
TASK [langfuse : Uninstall the release] ****************************************
changed: [localhost]
TASK [langfuse : Remove the namespace and everything left in it] ***************
changed: [localhost]
TASK [langfuse : Teardown summary] *********************************************
    "... the ACM certificate clickhouse-private-langfuse-lb is deleted, the TLS key and certificate under state/
     are kept and re-imported by the next --tags lf-app"
```

The `FAILED - RETRYING` lines are expected, not a problem. They are the role waiting for the NLB to release the certificate.

Two rules follow from how the deletion is gated:

- **It runs only when the effective TLS state (`tls`, or `fips`, per above) is still true at teardown time.** Flip `enabled` off if you like, because teardown works with the switch already off (section 13). But leave `tls` and `fips` alone until Langfuse is gone, or the certificate stays in ACM with nothing pointing at it.
- **`tls: true` → `false` without a teardown does not undo TLS.** The role applies the three ssl annotations as a patch, and a plain re-run keeps annotations it did not apply. The listener stays TLS while the `NEXTAUTH_URL` the role bakes in goes back to `http://`. The clean way back is a teardown and a re-run with `tls: false`. The by-hand route is removing the three `aws-load-balancer-ssl-*` annotations from Service `langfuse-lb` AND switching the listener back yourself, because the cloud controller cannot change a listener protocol: `aws elbv2 modify-listener --listener-arn <listener-arn> --protocol TCP`, with no `--certificates` or `--ssl-policy`, since AWS removes those TLS properties when the protocol changes to TCP.

The key and certificate under `state/` are kept like every other generated secret. The next `scripts/up.sh` re-imports the same certificate if the new NLB gets the same hostname, and regenerates it (the SAN check) if not, so nothing has to be cleaned up by hand. One thing does not survive a fresh `state/`: `--check` with `tls: true` and no key or certificate there yet fails at the chmod and the ACM import's file lookup, because check mode skips the OpenSSL generation. A `--check` after one real run is fine.

## 10. The smoke test

The reason the whole thing exists is to show a trace landing in ClickHouse Government. One script proves it end to end and is safe to run at any time:

```bash
scripts/langfuse-smoke.sh            # ClickHouse queries via a pod port-forward
scripts/langfuse-smoke.sh --lb       # ClickHouse queries via the Step 12 NLB (when its address is reachable)
```

It needs `curl`, `jq`, `kubectl` and whatever `scripts/ch-client.sh` needs (`brew install clickhouse` on macOS). What it does, in order:

1. **Finds a URL that answers.** It uses `LANGFUSE_URL` if you set it, else `langfuse.url` from the configuration, else the `langfuse-lb` hostname. If that does not answer `/api/public/health`, it opens `kubectl port-forward svc/langfuse-web 3000:3000` itself, waits for the port to accept connections, and tears it down on exit. An internal NLB never answers from a laptop outside the VPC, so this fallback is the normal path there. When the hostname came with TLS on, curl is given `--cacert state/langfuse-tls-cert.pem` for it and for nothing else (section 9). The tunnel is plain http.
2. **Posts a trace.** It sends one OTLP/JSON request to `/api/public/otel/v1/traces`: a root span named after the run plus a `generation` child carrying `gen_ai.*` attributes, authenticated with the API key pair from `state/langfuse-public-key` and `state/langfuse-secret-key`. Then it polls `GET /api/public/v2/observations?traceId=<id>` until both spans are listed.
3. **Reads it back from ClickHouse** through `scripts/ch-client.sh -q`, as the `default` admin: `SELECT trace_id, span_id, name, type FROM langfuse.events_core WHERE trace_id = '<id>'` and `SELECT hostName(), count() FROM langfuse.events_core GROUP BY 1`.

The secret key never enters a shell variable or a command line. The `pk:sk` credential is assembled from the two files straight into a mode-0600 curl config under a private temp directory and handed to curl as `--config -` on stdin. `bash -x` shows only file paths.

A passing run looks like this (the trace and span IDs differ every time):

```
==> Reaching Langfuse
  load balancer (internal NLB): http://<hostname>.elb.us-east-1.amazonaws.com
  [warn] http://<hostname>.elb.us-east-1.amazonaws.com does not answer /api/public/health from here (VPN? security group?)
  forwarding localhost:3000 -> svc/langfuse-web:3000 in langfuse
  [ ok ] health check passed through the port-forward

==> Posting a trace
  [ ok ] accepted trace <trace-id> (name smoke-<timestamp>) with one generation
  waiting for GET /api/public/v2/observations?traceId=<trace-id> to list both spans
  [ ok ] API returns the trace: traceId=<trace-id> observations=2 (SPAN, GENERATION)

==> Reading it back from ClickHouse (langfuse database)
  SELECT trace_id, span_id, name, type FROM langfuse.events_core WHERE trace_id = '<trace-id>'
   ┌─trace_id─────────────────────────┬─span_id──────────┬─name──────────────────┬─type───────┐
1. │ <trace-id>                       │ <span-id>        │ answer                │ GENERATION │
2. │ <trace-id>                       │ <span-id>        │ smoke-<timestamp>     │ SPAN       │
   └──────────────────────────────────┴──────────────────┴───────────────────────┴────────────┘
  SELECT hostName(), count() FROM langfuse.events_core GROUP BY 1
   ┌─hostName()────────────────────────┬─count()─┐
1. │ c-default-us-01-server-<suffix>-0 │     <n> │
   └───────────────────────────────────┴─────────┘

==> Done
  [ ok ] trace <trace-id> went in through the API and came back out of ClickHouse Private
```

**What the smoke test covers.** It proves the write path (an OTLP request accepted by the API), the read path (the API lists both spans) and storage (the same trace is a pair of rows in `langfuse.events_core` in your ClickHouse cluster). It does not cover the Langfuse UI, SDK ingestion from your own application, prompts or evaluations, or load. [Scope and boundaries](limitations.md) collects these boundaries in one place.

### Why `events_core`, and not `traces`

Langfuse 3.x accepted batch events (`trace-create`, `generation-create`) at `/api/public/ingestion`, and its read endpoints and tables were `traces` and `observations`. Langfuse 4.x, in its default `events_only` write mode, stores everything as OpenTelemetry spans and refuses those older paths:

| | Langfuse 3.x | Langfuse 4.25.0, `events_only` (what this kit runs) |
|---|---|---|
| Write | `POST /api/public/ingestion` with `trace-create` / `generation-create` | `POST /api/public/otel/v1/traces`. The ingestion endpoint answers 400 `Event type "trace-create" is not accepted ... when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only` |
| Read | `GET /api/public/traces/{id}` | `GET /api/public/v2/observations?traceId={id}`. The v3 read endpoints answer 404 `not available on deployments running in Langfuse v4 events_only mode` |
| ClickHouse | `langfuse.traces`, `langfuse.observations` | `langfuse.events_core` (one row per span) and `events_full`. `traces`, `observations` and `scores` are created by the migrations but stay **empty** |

The error message mentions `LANGFUSE_MIGRATION_V4_WRITE_MODE=dual`, which is a bridge for migrating from v3. The kit does not use it, because it targets a fresh v4 deployment. So the `traces` table in ClickHouse is real and empty, by design. If you are looking for the data in the UI's terms, it is in `events_core`. Any OpenTelemetry-speaking application can do what the script does: point an OTLP/HTTP exporter at `<url>/api/public/otel/v1/traces` with Basic auth `pk:sk`.

## 11. Idempotency and check mode

With everything deployed, running the three steps again changes nothing. The bucket and stack converge. The ClickHouse user authenticates with the stored hash, so no `ALTER USER` runs. The `GRANT`s compare equal. The Secrets are written as `data:` and converge. Helm sees identical values, and the PostgreSQL role step prints `role: exists`. `scripts/up.sh` is safe to run again for the same reason.

> **Advanced: run individual steps.** To confirm it for the Langfuse steps alone, run `scripts/play.sh --tags langfuse`. The final `PLAY RECAP` should show `changed=0` and `failed=0`.

`scripts/play.sh --check --tags lf-app` renders the chart without a `validations.yaml` failure and runs every read, wait and probe for real. When `tls` is true, run it after at least one real run, for the reason at the end of section 9. Secrets are hidden from all of this output. Re-run with `-e show_secrets=true` when something in that area fails and you need to see the objects.

## 12. Cost

Langfuse adds no instances. Everything lands on the operator node group that Step 5 already pays for. Its own line items are:

- The second NLB, about $0.0225/hr (~$17/mo).
- Two small gp3 volumes (20Gi and 8Gi), about $2/mo.
- S3, by the GB.

With `tls`, the imported ACM certificate has no charge of its own. `scripts/up.sh` prints the same NLB estimate when Langfuse is enabled. The base hourly figures are in the meter table in Part 0 section 8, and they are estimates from us-east-1 list prices, so check current AWS pricing for your Region. A default `down.sh` keeps the Langfuse IRSA stack and bucket the way it keeps ClickHouse's, and both cost nothing while idle.

## 13. Teardown order: Langfuse before ClickHouse

Langfuse's tables live in the ClickHouse cluster, and its PostgreSQL and Valkey volumes are EBS PVCs. Removing it therefore needs the operator and the EBS CSI driver alive, which means the cluster and the nodes are still up. That puts Langfuse **first**, before the Step 12 load balancer, the cluster and the node groups. `scripts/down.sh` knows this:

```bash
scripts/down.sh          # lf-app, lb, cluster, nodes
scripts/down.sh --all    # lf-app lf-db lb cluster operator prereqs lf-storage nodes storage eks vpc
```

Four details worth knowing:

- **Only what exists is torn down.** `down.sh` keeps `lf-app` only if `helm status`, the `langfuse-lb` Service or the `langfuse` namespace says there is something to remove. It keeps `lf-db` only if the namespace exists, and `lf-storage` only if the `clickhouse-private-langfuse-irsa` stack does. A ClickHouse-only stack runs exactly the pre-Langfuse steps.
- **It works with the switch already off.** `deploy.yml` gates each Langfuse role with `when: (langfuse.enabled | bool) or (<state var>) == 'absent'`. Flipping `enabled` back to `false` with Langfuse still deployed therefore does not orphan it, and `down.sh` still runs `lf-app` first. Afterwards no Langfuse NLB, namespace, PVC or EBS volume remains.
- **The zero-nodes guard covers Langfuse too.** `down.sh` refuses to start if it finds the `langfuse` namespace with no nodes, for the same reason it refuses for the ClickHouse namespace.
- **With `tls`, the ACM certificate goes between the Service and the release**, and only when `tls` is still `true` at teardown time. Section 9 has both rules.

`lf-db` is the data-purge switch, and it is *not* in the default `down.sh` plan. A default teardown removes the whole ClickHouse cluster anyway, and "keep the cluster, drop only Langfuse's tables" should be an explicit command, not a side effect. `lf-app` alone leaves the database, so you can remove the application and keep the traces, or the reverse. As with ClickHouse's bucket, nothing in either script deletes the Langfuse bucket. `down.sh --all` ends by naming it and reminding you to empty it and run `aws s3 rb` on it yourself, if you mean it.

> **Advanced: run individual steps.** By hand, the three teardowns are independent, and the split is deliberate. Run them with `scripts/play.sh`:
>
> ```bash
> scripts/play.sh --tags lf-app -e langfuse_state=absent              # NLB Service, (with tls) the ACM certificate, release, namespace and its PVCs. Keeps the ClickHouse data
> scripts/play.sh --tags lf-db -e langfuse_db_state=absent            # DROP DATABASE langfuse SYNC; DROP USER langfuse. The data purge
> scripts/play.sh --tags lf-storage -e langfuse_storage_state=absent  # the IRSA stack. The bucket stays; it holds data
> ```

## 14. What exists once it is up

```
namespace langfuse
  deployment    langfuse-web                 1 pod, the UI and API, NEXTAUTH_URL baked in
  deployment    langfuse-worker              1 pod, ingestion from S3 into ClickHouse
  statefulset   langfuse-postgresql          1 pod, 20Gi PVC, Chainguard PostgreSQL 18 as uid 70
  deployment    langfuse-redis               1 pod, 8Gi PVC, Chainguard Valkey 9 as uid 65532
  service       langfuse-web                 ClusterIP :3000 -- the port-forward target
  service       langfuse-lb                  type LoadBalancer -> the NLB (absent when type is none; three ssl annotations when tls is true)
  serviceaccount langfuse                    carries the IRSA role annotation
  secrets       langfuse-app-auth, langfuse-clickhouse, langfuse-init          (Ansible)
                langfuse-app (empty), langfuse-postgresql-auth, langfuse-redis-auth   (chart)

ClickHouse, database langfuse           13 tables, Shared*MergeTree, owned by user langfuse
AWS                                     bucket langfuse-<account>-<region>; stack clickhouse-private-langfuse-irsa; one NLB; with tls, one ACM certificate tagged Name=clickhouse-private-langfuse-lb
```

And in `state/`, alongside the ClickHouse files from Part 0 section 7:

| File | What |
|---|---|
| `langfuse-clickhouse-password` | The `langfuse` ClickHouse user's password (Step 14) |
| `langfuse-nextauth-secret`, `langfuse-salt`, `langfuse-encryption-key` | Langfuse's own secrets. Lose the encryption key and stored API credentials become unreadable |
| `langfuse-admin-password` | The `admin@example.com` login |
| `langfuse-public-key`, `langfuse-secret-key` | The seeded project's API key pair, which the smoke test and any SDK use |
| `langfuse-tls-key.pem`, `langfuse-tls-cert.pem` | With TLS: the NLB's private key (mode 0600) and its self-signed certificate, which is also the CA file clients trust (section 9). Regenerated only when the NLB hostname changes |

The same rule as Part 0 applies: lose `state/` and you lose these. A `down.sh` and `up.sh --from nodes` round trip reuses them, so the rebuilt Langfuse accepts the same login and API keys.

## 15. Operate it

The kit gives you a small set of tools for running Langfuse. It does not include procedures beyond these.

- **Check that it works:** `scripts/langfuse-smoke.sh` (section 10). Run it whenever you want proof that a trace goes in through the API and comes back out of ClickHouse.
- **Look at the data:** `scripts/ch-client.sh` opens a ClickHouse session as the `default` admin. For example, `scripts/ch-client.sh -q "SELECT name, type, start_time FROM langfuse.events_core ORDER BY start_time DESC LIMIT 10"` shows the newest spans. Add `--lb` to connect through the Step 12 load balancer.
- **Look at the pods:** run `source scripts/env.sh`, then `kubectl get pods -n langfuse` and `kubectl logs -n langfuse deploy/langfuse-web`.
- **Stop paying for it:** `scripts/down.sh` removes Langfuse first, then the load balancer, the cluster and the nodes (section 13). `scripts/up.sh --from nodes` brings the stack back with the same logins and API keys, because it reuses `state/`.
- **Remove only Langfuse's data:** the `lf-db` teardown in the "Advanced" note in section 13.

## 16. Troubleshooting

Each entry gives a symptom, its cause and the fix.

**Web and worker pods crash-loop with `password authentication failed`**

- *Cause:* the `langfuse` PostgreSQL role does not exist. Chainguard's PostgreSQL image ignores the subchart's first-boot script (section 7), and the role step was skipped, usually because the install stopped before it.
- *Fix:* run `scripts/up.sh` again. The role step creates the role (`role: created`) and the pods recover on the kubelet's next restart.

**The web pod restarts with `Dirty database version N. Fix and force version.`**

- *Cause:* a ClickHouse migration was interrupted, and `golang-migrate` left `schema_migrations` marked dirty. The role's relaxed liveness probe (section 7) prevents the usual trigger, a probe killing the pod mid-migration, but anything that interrupts a first start, such as a node replacement, can leave the same mark.
- *Fix:* on a fresh install with no data worth keeping, purge Langfuse's database and let it rebuild. Run `scripts/play.sh --tags lf-db -e langfuse_db_state=absent`, then run `scripts/up.sh`. It recreates the database and user, and the crash-looping pod recovers on its next restart. On a database that already holds data, use `golang-migrate`'s `force` instead.

**A Valkey or PostgreSQL pod fails to start with `/bin/sh` not found or a permission error on its volume**

- *Cause:* the mirrored image or the security context does not match the Chainguard variant the role expects (section 7). Valkey needs the `latest-dev` variant because the subchart's init container runs a shell script, and both stores run as Chainguard's uids (`65532` for Valkey, `70` for PostgreSQL).
- *Fix:* keep `versions.chainguard_valkey_tag` and `versions.chainguard_postgres_tag` at their defaults, or if you bump them, keep the same variants and uids. Re-run `scripts/up.sh`.

**Helm fails with `Secret "langfuse-app" ... invalid ownership metadata`**

- *Cause:* an object named `langfuse-app` already exists in the namespace that Helm did not create. The chart owns that name (section 7).
- *Fix:* delete the object you created (`kubectl delete secret langfuse-app -n langfuse`) and re-run `scripts/up.sh`. Keep the kit's Secret names.

**`lf-app` fails and prints pods, events and logs**

- *Cause:* one of the waits or assertions failed. The role's rescue block prints every pod, the newest Warning events and the last lines of the web and worker logs before it stops.
- *Fix:* read those three blocks. They show the actual cause, such as an image that cannot be pulled, a volume that will not attach or a probe that keeps failing. The release stays installed, so fix the cause and re-run `scripts/up.sh`, or tear Langfuse down (section 13).

**With TLS on, the Service events show `SyncLoadBalancerFailed ... DuplicateListener`, or `Wait for the listener to terminate TLS` times out with `TCP`**

- *Cause:* the cloud controller cannot change a listener's protocol (section 9). The role does that itself with `aws elbv2 modify-listener`, right after it patches the Service. If the switch is still pending, or its task failed, the listener stays `TCP` and the controller keeps retrying the impossible `CreateListener`.
- *Fix:* re-run `scripts/up.sh`. The listener switch task runs when the listener is not yet TLS with the current certificate. If the task fails again, its error message (usually a missing AWS permission for `elasticloadbalancing:ModifyListener`) is the next thing to read. The `SyncLoadBalancerFailed` events from before the switch stay in the namespace for about an hour. They are history, not a current problem.

**`curl` exits 60 with `SSL certificate problem: self-signed certificate`**

- *Cause:* the client does not trust the role's certificate. This is expected without the CA file.
- *Fix:* pass `--cacert state/langfuse-tls-cert.pem` (section 9). Do not use `-k`.

**The browser lands on the wrong address after login**

- *Cause:* `NEXTAUTH_URL` is baked into the web pods and is the address the role derived, which is not the name you typed.
- *Fix:* set `langfuse.url` to the address people use and re-run `scripts/up.sh`.

**The role fails with an OpenSSL instruction when `tls` is on**

- *Cause:* the `openssl` on your `PATH` is LibreSSL (the macOS default), not OpenSSL 3.
- *Fix:* install OpenSSL 3 and put it first on `PATH` (section 9).

**The smoke test warns that the NLB does not answer**

- *Cause:* an `internal` NLB is not reachable from outside the VPC.
- *Fix:* none needed. The script falls back to a port-forward tunnel and continues. To test the https path itself, run the script from inside the VPC or over a VPN, with `LANGFUSE_URL` and `LANGFUSE_CACERT` set.

**`down.sh` prints `FAILED - RETRYING` while deleting the ACM certificate**

- *Cause:* ACM refuses to delete a certificate while the NLB listener still uses it, and the NLB disappears a little after the Service.
- *Fix:* wait. The role retries up to 18 times, 10 seconds apart. If it still fails, run `scripts/down.sh` again.

## Check yourself

Run these in order after Langfuse is up, from a shell where you ran `source scripts/env.sh`. Each gives a command and the result you should see, and they double as workshop exercises.

1. **You know what the switch changes.** Without looking, name the three things `langfuse.enabled: true` adds when you run `scripts/up.sh` (section 3). You should be able to say that Step 2 mirrors four more images and a chart, that `up.sh` appends `lf-storage lf-db lf-app`, and that `down.sh` removes Langfuse first.

2. **The images and chart are in your registry.**

   ```bash
   aws ecr describe-images --repository-name langfuse/langfuse --profile "$AWS_PROFILE" --query 'imageDetails[].imageTags' --output text
   ```

   You should see `4.25.0`. Repeat with `langfuse/langfuse-worker`, `chainguard/postgres` (tag `pg18-cg`), `chainguard/valkey` (tag `valkey9-cg-dev`) and `helm/langfuse` (tag `2.1.0`).

3. **Nothing pulls from outside your registry.**

   ```bash
   kubectl get pods -n langfuse -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
   ```

   You should see only image names that begin with your ECR hostname.

4. **The role has no access keys.** Run the `kubectl exec ... env | grep` command from section 5. You should see `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`, and no `ACCESS_KEY`.

5. **The ClickHouse user is least-privilege.** Run `scripts/ch-client.sh -q "SHOW GRANTS FOR langfuse"`. You should see the eight `GRANT` lines from section 6, with the wide grant scoped to `langfuse.*`.

6. **The migrations landed on the shared engine.** Run the `system.tables` query from section 7. You should see 13 tables, and every table that is not a view on a `Shared*MergeTree` engine.

7. **The pods are available.**

   ```bash
   kubectl get deployment -n langfuse langfuse-web langfuse-worker
   ```

   You should see `1/1` under `READY` for both. The role's own check of the health endpoint through the `langfuse-web` Service is the `Langfuse must answer through its Service` task in section 7.

8. **A trace makes the round trip.** Run `scripts/langfuse-smoke.sh`. You should see `API returns the trace: ... observations=2 (SPAN, GENERATION)`, two rows from `langfuse.events_core` with the same `trace_id`, and a final `[ ok ]` line.

9. **The traces are in `events_core`, not `traces`.** Run `scripts/ch-client.sh -q "SELECT (SELECT count() FROM langfuse.events_core), (SELECT count() FROM langfuse.traces)"`. You should see a positive number, then `0`. Explain why, using section 10.

10. **Rerunning changes nothing.** Run `scripts/play.sh --tags langfuse` (the individual-steps form from section 3). The final `PLAY RECAP` should show `changed=0` and `failed=0`.

11. **You can explain the teardown order.** Say why `down.sh` removes Langfuse before the load balancer, the cluster and the nodes (section 13), and which command removes only Langfuse's data.

12. **If TLS is on:** run the checks in "Check TLS yourself" (section 9). The `curl --cacert` request should return `HTTP 200`, and the same request without `--cacert` should exit 60.
