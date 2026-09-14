# Part 6 — Steps 13–15: Langfuse, with ClickHouse Private as its store

Parts 1–5 end with a ClickHouse cluster behind a load balancer. These three
steps are optional and off by default: they put a Langfuse server next to it,
on the same nodes, and point it at that cluster for its analytics tables. The
result is one demo — "ClickHouse Government holds Langfuse's traces" — and
nothing else changes when the switch is off.

```bash
# in ansible/group_vars/all.yml:  langfuse.enabled: true
scripts/up.sh                     # Steps 1-15 in order; --from lb if the cluster is already up
scripts/langfuse-smoke.sh         # post a trace, read it back from ClickHouse
```

> **Status: run end to end on 2026-09-11** against the real stack, twice
> (once from a running cluster, once from nodes up through the smoke test in
> one `up.sh`). Three defects in the roles and one in the demo script showed
> up only live; each is described below at the point where you would meet
> it. The commands, the outputs and the digests quoted here come from
> [`docs/part-6-langfuse-live-run.md`](part-6-langfuse-live-run.md), which is
> the evidence for every claim of the form "this works".

---

## 1. What Langfuse is, in one paragraph

Langfuse is an open-source observability server for applications that call
language models. An application sends it *traces* — one per request, made of
spans and "generations" (the individual model calls, with prompt, completion,
token counts and latency) — over an SDK or plain OpenTelemetry, and people
browse them in a web UI: what the model was asked, what it said, what it
cost, where the time went. Under the hood it is four stores: PostgreSQL for
users, projects and settings; Redis (here Valkey) for its work queue and
cache; S3 for the raw event payloads and media; and ClickHouse for the
traces themselves, because that is where "show me every generation over 2 s
last week" has to be fast. Langfuse 4.x stores everything as OpenTelemetry
spans, which matters for the smoke test in §9.

## 2. From the Terraform module to this repo

Langfuse publishes a reference deployment for AWS, `langfuse/langfuse-terraform-aws`,
that installs the same Helm chart this project uses (chart `2.1.0`, app
`4.25.0`). It builds its own VPC and EKS-on-Fargate cluster, and buys
managed services for the stores. Here the *shape* is kept — same chart, same
value keys, `clickhouse.deploy: false` with an external ClickHouse, S3
reached through IRSA — and each managed piece is replaced by what Parts 1–5
already built:

| Terraform module | This project | Why |
|---|---|---|
| Aurora Serverless v2 (PostgreSQL) | The chart's bundled PostgreSQL subchart, in-cluster, on Chainguard's `postgres` image, one 20Gi EBS volume | No new AWS service; the image is already in the airgap hop. See the trap in §7 |
| ElastiCache (Redis) | The chart's bundled Valkey subchart, in-cluster, on Chainguard's `valkey` image, one 8Gi EBS volume | Same. See the other trap in §7 |
| EKS on Fargate | The **operator** node group from Step 5 | It is untainted and has the headroom (about 4.75 CPU / 9.5 Gi requested in total). No new node group |
| ALB + ACM certificate + Route 53 record | An NLB from the built-in cloud controller, plain HTTP, no domain | Same `none \| internal \| public` switch and the same source-range rules as Step 12 |
| `external_clickhouse` | The ClickHouse Private cluster from Step 9, over its in-cluster `c-<cluster>-server-any` Service | This is the point of the exercise |
| S3 bucket + IRSA | The same, with its own bucket and its own IRSA role (Step 13) | No access keys anywhere, as in Step 6 |
| Images from `docker.langfuse.com` and `cgr.dev` | Mirrored into your ECR by Step 2 | The cluster pulls only from your account |
| Chart from `langfuse.github.io` | Pushed into your ECR as an OCI artifact by Step 2 | Same |

Nothing new is created at the AWS compute or edge layer: no node group, no
VPC, no EKS, no ALB, no certificate, no DNS. The one extra AWS resource that
bills by the hour is the second NLB.

## 3. The switch, and what it changes

Everything hangs off one key at the **end** of `ansible/group_vars/all.yml`:

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
    port: 80
    cross_zone: true
  web:    {replicas: 1, cpu: "2", memory: "4Gi"}
  worker: {replicas: 1, cpu: "2", memory: "4Gi"}
  postgres: {disk: "20Gi", cpu: "500m", memory: "1Gi"}
  valkey:   {disk: "8Gi",  cpu: "250m", memory: "512Mi"}
  init: {org_id: demo, org_name: Demo, project_id: demo, project_name: Demo,
         user_email: admin@example.com, user_name: Admin}
  telemetry_enabled: false  # no phone-home
  signup_disabled: true     # no self-service accounts on a server that may be public
```

The block is last in the file for a reason that is easy to trip over later:
`up.sh`, `down.sh` and `ch-client.sh` read `all.yml` with first-match `awk`
scrapes of `  namespace:` and `    type:`, and those must keep hitting the
`clickhouse:` block. The Langfuse scripts use a block-scoped form that first
matches `^langfuse:`. If you ever add a key to this file, keep this block at
the bottom.

**With `enabled: false`** — the committed default — nothing observable
changes for Steps 1–12. `all_artifacts` still has the seven ClickHouse
entries, `up.sh` runs Steps 1–12 and its `--help` is byte-identical to the
pre-Langfuse version, and `scripts/play.sh --tags langfuse` prints the
banner and skips 97 tasks:

```
PLAY RECAP *********************************************************************
localhost                  : ok=1    changed=0    unreachable=0    failed=0    skipped=97   rescued=0    ignored=0
```

**With `enabled: true`**, three things happen: Step 2 mirrors four more
images and one chart (§4); `up.sh` appends `lf-storage lf-db lf-app` after
`lb` and prints the Langfuse URL at the end; `down.sh` removes Langfuse
first. Each step has its own tag, and `langfuse` runs all three:

```bash
scripts/play.sh --tags langfuse       # Steps 13, 14, 15
scripts/play.sh --tags lf-storage     # Step 13: bucket and IRSA role
scripts/play.sh --tags lf-db          # Step 14: database and user in ClickHouse
scripts/play.sh --tags lf-app         # Step 15: the Helm release, NLB, PostgreSQL, Valkey
```

## 4. Step 2 again: four images and a chart

Flip the switch and re-run the image hop:

```bash
scripts/play.sh --tags images
```

```
TASK [image_sync : Copy each artifact that is not already present] *************
changed: [localhost] => (item=langfuse/langfuse:4.25.0)
changed: [localhost] => (item=langfuse/langfuse-worker:4.25.0)
changed: [localhost] => (item=chainguard/postgres:pg18-cg)
changed: [localhost] => (item=chainguard/valkey:valkey9-cg-dev)
TASK [image_sync : Report what was copied vs already present] ******************
ok: [localhost] => { "msg": "4 copied, 7 already present (standard build); 1 chart(s) to push with helm" }
TASK [image_sync : Push each pulled chart to ECR] ******************************
changed: [localhost] => (item=helm/langfuse:2.1.0)
```

Two things are new compared with the ClickHouse images.

**Chainguard's free tier publishes only `latest`.** You cannot pin
`postgres:18.6` on `cgr.dev`; there is `latest` and, for images with a shell,
`latest-dev`. So the artifact list carries a `source_tag` (`latest` /
`latest-dev`) separate from the tag it lands under in ECR (`pg18-cg` /
`valkey9-cg-dev`, from `versions.chainguard_postgres_tag` and
`versions.chainguard_valkey_tag`). ECR tags are immutable and the sync skips
tags that already exist, so whatever digest `latest` resolved to on the first
copy is what that tag means until someone bumps it in `versions`. The
version claim in the tag is a major only, because that is all the image
promises; Step 15 checks the real version in the running pods (§7).

**The chart comes from a plain Helm HTTP repository**, not an OCI registry,
so skopeo cannot copy it. The role does `helm pull` from
`https://langfuse.github.io/langfuse-k8s` into `state/charts/` and `helm push`
into `oci://<your ecr>/helm/langfuse`. The packaged chart contains its
subcharts, so nothing else needs mirroring. Your laptop therefore has to
reach `cgr.dev`, `docker.langfuse.com` and `langfuse.github.io` during this
step — anonymously, no new credentials — and `scripts/part1-setup.sh` names
them in its step 6 for that reason.

What landed, on 2026-09-11:

| Repository | Tag | Digest (immutable) | Contents |
|---|---|---|---|
| `chainguard/postgres` | `pg18-cg` | `sha256:0962bea4e3dd11047726890b8e7242ae616215ea2a50ffbcae22654f06184f1b` | PostgreSQL 18.6, 143 MB |
| `chainguard/valkey` | `valkey9-cg-dev` | `sha256:6a846484cd4e261ad31ca380936d39072e5100bee17a5596da4faa87c8b6e548` | Valkey 9.1.2 with busybox `sh`, 29 MB |
| `langfuse/langfuse` | `4.25.0` | `sha256:12654de5ffb20722cf6b2d7df51b3099eb2d92bd92f5aef20e095b16a840ca8d` | web, 352 MB |
| `langfuse/langfuse-worker` | `4.25.0` | `sha256:638a46341ead4f68103f2b800a14b5d75f7c352b975f2b63a43697c577233a4c` | worker, 357 MB |
| `helm/langfuse` | `2.1.0` | `sha256:35c218270f1d6c8e1e6c3249db548180b5d0bfbe83a573ac9edecf766ae7c6a0` | the chart, 135 KB |

If your `pg18-cg` shows a different digest, it was mirrored on a different
day; that is expected, and it is exactly why the digest is recorded here.

## 5. Step 13 — a bucket and an IRSA role (`lf-storage`)

```bash
scripts/play.sh --tags lf-storage        # ~30 s
```

A smaller Step 6: one bucket, one role, one CloudFormation stack.

- **The bucket** `langfuse-<account>-<region>` (`langfuse.bucket_name`) is
  created with the `s3_bucket` module, AES256 default encryption, all four
  public-access blocks on, versioning off — the same three decisions Part 3
  made for the ClickHouse bucket, for the same reasons. Langfuse keeps its
  raw event uploads under `events/`, batch exports under `exports/` and
  media under `media/`.
- **The stack** `clickhouse-private-langfuse-irsa`
  (`{{ infrastructure.environment_name }}-langfuse-irsa`) holds one IAM role
  with a federated trust on the cluster's OIDC provider, restricted to
  `system:serviceaccount:langfuse:langfuse` — the namespace and the release
  name. Left alone, the chart would name its ServiceAccount (and its
  Deployments and Services) after the release only when the release name
  contains `langfuse`, and `<release>-langfuse` otherwise; Step 15 passes the
  release as the chart's `fullnameOverride`, so the name is the release
  whatever you set it to and this trust policy matches it. The
  role may `PutObject`, `GetObject`, `ListBucket` and `DeleteObject` on that
  one bucket (`DeleteObject` because Langfuse expires its own exports and
  media). The stack outputs `LangfuseS3RoleArn`, which Step 15 reads.

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

There are no S3 access keys in this design and there is nowhere to put any:
the chart's `s3.deploy: false` block is given a bucket and a region and no
credentials, so the AWS SDK inside the pods falls through to the web
identity token the ServiceAccount annotation provides. In the live run the
web pod's environment held `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`
and nothing matching `*_ACCESS_KEY*`, and the smoke test's OTLP batch turned
up in the bucket under `events/otel/demo/`.

## 6. Step 14 — a database and a user inside ClickHouse (`lf-db`)

```bash
scripts/play.sh --tags lf-db             # ~7 s
```

Langfuse could be handed the `default` admin account. It is not. Step 14
creates a database `langfuse` and a user `langfuse` that holds exactly the
grants Langfuse documents for an external ClickHouse, scoped to that
database plus the handful of `system` tables its migrations and health
checks read.

**How the password travels.** The role generates
`state/langfuse-clickhouse-password` (32 characters, mode 0600), hashes it
with SHA-256 in Ansible, and runs every statement through `kubectl exec -i`
in one server pod with the admin password on stdin — the Step 11 pattern.
The SQL that reaches ClickHouse says `IDENTIFIED WITH sha256_hash BY '<hex>'`;
the plaintext exists only in `state/`, where Step 15 reads it into a
Kubernetes Secret, and in Langfuse's pods.

**The grants**, as `SHOW GRANTS FOR langfuse` renders them on the live
server (ClickHouse folds `CREATE` into its four parts and backtick-quotes
`table`):

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

**No `ON CLUSTER` anywhere.** The cluster's user directory is replicated
through Keeper, so a user created on one replica exists on all three. That
is also why the role can run against any one server pod.

**`GRANT CLUSTER` — the outcome the design could not predict.** Langfuse
lists `CLUSTER ON *.*` among the grants for clustered deployments, and the
design expected the `default` admin to be refused it (`SHOW GRANTS FOR
default_role` does not list `CLUSTER`), so the role attempts the grant with
`failed_when: false`, records the result, and hands it to Step 15. Live, on
server 26.2.1, **the grant succeeded**: the first line above is the proof,
and the Step 14 report prints `cluster:   cluster: granted`. What that
decides is in §7.

**Idempotency, done by authenticating.** `system.users.auth_params` does not
expose password hashes (it renders `['{}']` for the langfuse user), so "is
the stored hash still ours?" is answered by an HTTP `SELECT 1` as the
Langfuse user with the password from `state/`. Success: nothing to do.
Failure: `ALTER USER ... IDENTIFIED WITH sha256_hash BY '<hex>'`. Every exec
prints `created`/`exists`/`updated` and `changed_when` keys off it, so the
second run is:

```
"database:  langfuse -- already existed",
"user:      langfuse -- existed, hash already matched the password file",
"grants:    unchanged (8 GRANT lines, listed above)",
"cluster:   cluster: already granted",
PLAY RECAP *********************************************************************
localhost                  : ok=25   changed=0    unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```

**Teardown is the "purge Langfuse data" switch.** `--tags lf-db -e langfuse_db_state=absent`
runs `DROP DATABASE langfuse SYNC; DROP USER langfuse;` and keeps the
password file, so a later `--tags lf-db` recreates both with the same hash
and the Secret Step 15 already wrote stays valid. Step 15's own teardown
deliberately leaves the database alone; §12 has the whole story.

## 7. Step 15 — Langfuse itself (`lf-app`)

```bash
scripts/play.sh --tags lf-app            # ~3 min the first time, most of it ClickHouse migrations
```

Order matters in this role more than in any other, because `NEXTAUTH_URL` is
baked into the web pods and the browser is redirected to it after login: it
must equal the address people type, which means the load balancer has to
exist and have a hostname *before* the Helm release. The role therefore goes:
validate `langfuse.load_balancer.type` and decide cluster mode (both need
nothing created yet) → namespace → the three Secrets → the NLB Service
`langfuse-lb` → settle the URL → log in to ECR and install the chart →
repair PostgreSQL → wait → assert → report.

### The Secrets, and the name the chart owns

Ansible writes three Secrets from files it generates under `state/` with the
same `password` lookup Step 9 uses, so a re-run reads them back rather than
rotating them:

| Secret | Keys | From |
|---|---|---|
| `langfuse-app-auth` | `nextauth-secret`, `salt`, `encryption-key` | `state/langfuse-nextauth-secret`, `-salt`, `-encryption-key` |
| `langfuse-clickhouse` | `password` | `state/langfuse-clickhouse-password` (Step 14) |
| `langfuse-init` | `LANGFUSE_INIT_ORG_ID` … `LANGFUSE_INIT_USER_PASSWORD` (9 keys) | `langfuse.init` plus `state/langfuse-admin-password`, `-public-key`, `-secret-key` |

`langfuse-init` is Langfuse's headless bootstrap: on first boot it creates
the organisation, the project, the admin user and one API key pair, so the
demo has credentials without anyone clicking through sign-up (which is
disabled anyway). The key pair (`pk-lf-…` / `sk-lf-…`) is what the smoke test
reads.

**Defect 1 from the live run.** The design named the first Secret
`langfuse-app`. Chart 2.1.0 renders a Secret of exactly that name
(`<fullname>-app`) to hold whichever of the three values it has to generate
itself, and Helm refuses to install over an object it does not own:

```
Error: unable to continue with install: Secret "langfuse-app" in namespace "langfuse" exists and cannot be
imported into the current release: invalid ownership metadata; label validation error:
key "app.kubernetes.io/managed-by" must equal "Helm": current value is "clickhouse-private-ansible"
```

So the Ansible Secret is `langfuse-app-auth`, following the chart's own
`-auth` suffix for credential Secrets, and the chart's `langfuse-app` is
created empty because every value is provided. The chart also generates
`langfuse-postgresql-auth` and `langfuse-redis-auth` for its subcharts.

### Why cluster mode stays on

Langfuse runs its ClickHouse migrations `ON CLUSTER default` when
`CLICKHOUSE_CLUSTER_ENABLED` is true, which is its default. That fits
ClickHouse Private as Part 4 found it: the cluster is named `default`,
`cloud_mode=1`, and tables declared as `ReplacingMergeTree` are realised as
`SharedReplacingMergeTree` on the shared S3 engine. The one way this could
fail is a server that *requires* the `CLUSTER` grant for `ON CLUSTER`
statements (`on_cluster_queries_require_cluster_grant`) on a user that could
not be given it. The role checks both before installing:

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

The recorded outcome: `CLUSTER` was granted (§6), and the query
`SELECT value FROM system.settings ... UNION ALL SELECT value FROM system.server_settings WHERE name = 'on_cluster_queries_require_cluster_grant'`
returns no rows on 26.2.1 — the setting is in neither table — which the role
reports as `not reported` and treats as not enforced. Either input alone
keeps `clickhouse.cluster.enabled: true`. The 46 migrations of app 4.25.0
ran `ON CLUSTER default`, and every table came out on the shared engine:

```
analytics_observations       View                       events_core_mv     MaterializedView
analytics_scores             View                       events_full        SharedReplacingMergeTree
analytics_traces             View                       observations       SharedReplacingMergeTree
blob_storage_file_log        SharedReplacingMergeTree   observations_batch_staging  SharedReplacingMergeTree
dataset_run_items_rmt        SharedReplacingMergeTree   schema_migrations  SharedMergeTree
events_core                  SharedReplacingMergeTree   scores             SharedReplacingMergeTree
                                                        traces             SharedReplacingMergeTree
```

The `cluster.enabled: false` fallback the design kept in reserve is still in
the role, for a server where both inputs go the other way. It was not needed
and is not the default.

### The two Chainguard traps

Both subcharts assume the upstream Docker images. Chainguard's differ in two
places that each cost a crash loop to find.

**PostgreSQL: the init script never runs.** The bundled subchart ships a
first-boot script that creates the `langfuse` PostgreSQL role and hands it
the database, mounted at `/docker-entrypoint-initdb.d` where the Docker
image's entrypoint looks. Chainguard's entrypoint reads
`/var/lib/postgres/initdb/` instead, so the script is silently ignored, the
role never exists, and web and worker crash-loop on `password authentication
failed`. The role does what the script would have done once the PostgreSQL
pod is Ready: `kubectl exec -i` into it and run `psql -h localhost -U postgres`
with a heredoc that creates the role if missing, grants it the database and
makes it the owner. Neither password touches argv: the superuser's rides
`PGPASSWORD` from the pod's `POSTGRES_PASSWORD`, and the role's is read by
`\getenv` from `USERDB_PASSWORD`, both wired by the subchart from
`langfuse-postgresql-auth`. It prints `role: created` the first time and
`role: exists` after that.

```
TASK [langfuse : Create the langfuse PostgreSQL role (what the skipped init script would have done)] ***
changed: [localhost]
```

While there, the other PostgreSQL question the design left open: Chainguard's
image runs as uid `postgres=70` (the Docker image uses 999). With
`podSecurityContext.fsGroup: 70` and `securityContext.runAsUser/runAsGroup: 70`
on a fresh gp3 volume it works — PGDATA is the `pg` subdirectory, so the
volume's `lost+found` is no obstacle — and it runs under the subchart's
`readOnlyRootFilesystem: true`, writing only to the emptyDirs the subchart
already mounts. `postgres --version` in the pod reported 18.6.

**Valkey: no `/bin/sh`.** `cgr.dev/chainguard/valkey:latest` contains
exactly the server and nothing else, and the subchart's init container runs
a `#!/bin/sh` script from that same image. The fix is the `latest-dev`
variant, which adds busybox — hence `valkey9-cg-dev` and the `source_tag:
latest-dev` in the artifact list — with uid/gid/fsGroup set to Chainguard's
`65532` (the subchart assumes 1000). `maxmemory-policy noeviction` is
restated in the values because Langfuse requires it. `valkey-server --version`
reported 9.1.2.

### A liveness probe that killed the migrations

**Defect 3 from the live run**, and the one most likely to bite a slower
cluster. The web container applies every ClickHouse migration before its
HTTP server listens. On ClickHouse Private each `ON CLUSTER` DDL statement on
a shared-engine table takes between 0.15 and 10 s, and the chart's default
liveness probe (20 s initial delay, five failures 10 s apart) killed the
container after about 70 s, mid-migration, leaving `schema_migrations` dirty
at version 16:

```
langfuse-web-95d5fb95-ccd65        0/1     CrashLoopBackOff   6 (66s ago)   7m24s
Killing    Container langfuse-web failed liveness probe, will be restarted
error: Dirty database version 16. Fix and force version.
```

The chart has no `startupProbe` for web, so the role relaxes the liveness
probe in its values to `initialDelaySeconds: 60, periodSeconds: 10,
failureThreshold: 90` — about fifteen minutes of grace before a first
restart, while the unchanged readiness probe keeps traffic off the pod until
it is actually ready. If you ever see the dirty-version error on a fresh
install, the recovery is the Step 14 purge and a re-run (§12); on a database
that already holds data, golang-migrate's `force` is the alternative.

(Defect 2, for completeness: the role's first wait matched Deployments by
a label the chart puts only on pods, so it returned in 53 s having waited
for nothing. It now waits on `deployment/langfuse-web` and
`deployment/langfuse-worker` by name.)

### What the role verifies before calling it done

After the waits — PostgreSQL and Valkey Ready, then the web Deployment
available, then the worker — in a block whose rescue dumps the pods, the
Warning events and the web and worker logs before failing:

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

Six containers, because both subcharts run an init container from the same
mirrored image. The health check through the ClusterIP Service
`langfuse-web` is the hard assertion; the NLB path is probed from a pod
placed on a node without a web pod (the Step 12 hairpin, again) and is
retried rather than failed, and the target group must show one healthy
target per web replica.

### What a passing run reports

```
url:        http://<hostname>.elb.us-east-1.amazonaws.com
exposure:   internal NLB <hostname>.elb.us-east-1.amazonaws.com, allowed from 10.20.0.0/16; 1 healthy target(s); answers 200 from inside the VPC
login:      admin@example.com -- password in .../state/langfuse-admin-password
api keys:   .../state/langfuse-public-key (public), .../state/langfuse-secret-key (secret) -- project demo
clickhouse: database langfuse at c-default-us-01-server-any.ns-default-us-01.svc:8123 as langfuse, 13 tables, cluster mode on
smoke test: scripts/langfuse-smoke.sh   (posts a trace and reads it back from ClickHouse)
teardown:   ansible-playbook deploy.yml --tags lf-app -e langfuse_state=absent   (keeps the ClickHouse data; --tags lf-db -e langfuse_db_state=absent purges it)

PLAY RECAP *********************************************************************
localhost                  : ok=52   changed=1    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```

## 8. Reaching it from a browser

The default exposure is an **internal** NLB, so the same three options as
Part 5 apply, with one twist: NextAuth redirects the browser to
`NEXTAUTH_URL` after login, so the address you type must be the one the role
baked in.

1. A VPN or peering into the VPC — the URL above works as printed.
2. `type: none` in `langfuse.load_balancer`, then
   `kubectl port-forward -n langfuse svc/langfuse-web 3000:3000` and open
   `http://localhost:3000`. The port must be exactly 3000, because that is
   the `NEXTAUTH_URL` the role sets for this mode.
3. `type: public` with `allowed_cidrs: ["<your egress IP>/32"]`. Plain HTTP,
   no certificate: fine for a lab, not for anything else. `0.0.0.0/0` is
   refused unless you also pass `-e allow_open_internet=true`, as in Step 12.

If people reach Langfuse by a name the role cannot discover (a VPN alias, a
DNS record you put in front of the NLB), set `langfuse.url` and re-run
`--tags lf-app`. Log in as `admin@example.com` with the password in
`state/langfuse-admin-password`. Sign-up is disabled and telemetry is off.

## 9. The smoke test

The reason the whole thing exists is to show a trace landing in ClickHouse
Government, so one script proves it end to end and is safe to run at any
time:

```bash
scripts/langfuse-smoke.sh            # ClickHouse queries via a pod port-forward
scripts/langfuse-smoke.sh --lb       # ClickHouse queries via the Step 12 NLB (when its address is reachable)
```

It needs `curl`, `jq`, `kubectl` and whatever `scripts/ch-client.sh` needs
(`brew install clickhouse`). What it does, in order:

1. **Finds a URL that answers.** `LANGFUSE_URL` if you set it, else
   `langfuse.url` from `group_vars`, else the `langfuse-lb` hostname. If that
   does not answer `/api/public/health` — an internal NLB never will from a
   laptop outside the VPC — it opens `kubectl port-forward svc/langfuse-web 3000:3000`
   itself, waits for the port to accept connections, and tears it down on
   exit.
2. **Posts a trace.** One OTLP/JSON request to `/api/public/otel/v1/traces`:
   a root span named after the run plus a `generation` child carrying
   `gen_ai.*` attributes, authenticated with the API key pair from
   `state/langfuse-public-key` and `state/langfuse-secret-key`. Then it polls
   `GET /api/public/v2/observations?traceId=<id>` until both spans are
   listed.
3. **Reads it back from ClickHouse** through `scripts/ch-client.sh -q`, as
   the `default` admin:
   `SELECT trace_id, span_id, name, type FROM langfuse.events_core WHERE trace_id = '<id>'`
   and `SELECT hostName(), count() FROM langfuse.events_core GROUP BY 1`.

The secret key never enters a shell variable or argv: the `pk:sk` credential
is assembled from the two files straight into a mode-0600 curl config under
a private temp directory and handed to curl as `--config -` on stdin.
`bash -x` shows only file paths.

```
==> Reaching Langfuse
  load balancer (internal NLB): http://<hostname>.elb.us-east-1.amazonaws.com
  [warn] http://<hostname>.elb.us-east-1.amazonaws.com does not answer /api/public/health from here (VPN? security group?)
  forwarding localhost:3000 -> svc/langfuse-web:3000 in langfuse
  [ ok ] health check passed through the port-forward

==> Posting a trace
  [ ok ] accepted trace 392e04de3367de01095af8f81f987ea1 (name smoke-20260911-220101) with one generation
  waiting for GET /api/public/v2/observations?traceId=392e04de3367de01095af8f81f987ea1 to list both spans
  [ ok ] API returns the trace: traceId=392e04de3367de01095af8f81f987ea1 observations=2 (SPAN, GENERATION)

==> Reading it back from ClickHouse (langfuse database)
  SELECT trace_id, span_id, name, type FROM langfuse.events_core WHERE trace_id = '392e04de3367de01095af8f81f987ea1'
   ┌─trace_id─────────────────────────┬─span_id──────────┬─name──────────────────┬─type───────┐
1. │ 392e04de3367de01095af8f81f987ea1 │ 806d2cd0bf904d95 │ answer                │ GENERATION │
2. │ 392e04de3367de01095af8f81f987ea1 │ bb2c7c890fdb859e │ smoke-20260911-220101 │ SPAN       │
   └──────────────────────────────────┴──────────────────┴───────────────────────┴────────────┘
  SELECT hostName(), count() FROM langfuse.events_core GROUP BY 1
   ┌─hostName()───────────────────────┬─count()─┐
1. │ c-default-us-01-server-5jukk4d-0 │       4 │
   └──────────────────────────────────┴─────────┘

==> Done
  [ ok ] trace 392e04de3367de01095af8f81f987ea1 went in through the API and came back out of ClickHouse Private
```

### Why `events_core`, and not `traces`

**Defect 4 from the live run, in the demo script.** The design had the
script post Langfuse's v3 batch events (`trace-create`, `generation-create`)
to `/api/public/ingestion` and query `langfuse.traces`. Langfuse 4.x stores
everything as OpenTelemetry spans and, in its default `events_only` write
mode, refuses those event types and answers 404 on the v3 read endpoints:

| | Langfuse v3 (the design's assumption) | Langfuse 4.25.0, `events_only` (observed) |
|---|---|---|
| Write | `POST /api/public/ingestion` with `trace-create` / `generation-create` | 400 `Event type "trace-create" is not accepted ... when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only`; `POST /api/public/otel/v1/traces` → 200 |
| Read | `GET /api/public/traces/{id}` | 404 `not available on deployments running in Langfuse v4 events_only mode`; `GET /api/public/v2/observations?traceId={id}` → 200 |
| ClickHouse | `langfuse.traces`, `langfuse.observations` | `langfuse.events_core` (one row per span) and `events_full`; `traces`, `observations` and `scores` are created by the migrations but stay **empty** |

The alternative Langfuse's error message offers —
`LANGFUSE_MIGRATION_V4_WRITE_MODE=dual` — is described by Langfuse itself as
a temporary v3-to-v4 migration bridge, and was rejected for a greenfield v4
deployment. So the `traces` table in ClickHouse is real and empty, by
design; if you are looking for the data in the UI's terms, it is in
`events_core`. Any OpenTelemetry-speaking application can do what the script
does: point an OTLP/HTTP exporter at `<url>/api/public/otel/v1/traces` with
Basic auth `pk:sk`.

## 10. Idempotency and check mode

With everything deployed, all three steps in one run change nothing:

```bash
scripts/play.sh --tags langfuse          # 33 s
```

```
PLAY RECAP *********************************************************************
localhost                  : ok=85   changed=0    unreachable=0    failed=0    skipped=13   rescued=0    ignored=0
```

The bucket and stack converge; the ClickHouse user authenticates with the
stored hash so no `ALTER USER` runs; the `GRANT`s compare equal; the Secrets
are written as `data:` and converge; Helm sees identical values; the
PostgreSQL role fix prints `role: exists`. `scripts/play.sh --check --tags lf-app`
renders the chart without a `validations.yaml` failure and runs every read,
wait and probe for real (`ok=52 changed=0`). Secrets are hidden from all of
this output; re-run with `-e show_secrets=true` when something in that area
fails and you need to see the objects.

## 11. Cost

Langfuse adds no instances: everything lands on the operator node group Step
5 already pays for. Its own line items are the second NLB (~$0.0225/hr,
~$17/mo), two small gp3 volumes (20Gi + 8Gi, about $2/mo), and S3 by the GB.
Call it **~$2.36/hr** with nodes up instead of ~$2.34/hr, and unchanged at
~$0.15/hr with them down — a default `down.sh` keeps the Langfuse IRSA stack
and bucket the way it keeps ClickHouse's, and both cost nothing idle.

## 12. Teardown order: Langfuse before ClickHouse

Langfuse's tables live in the ClickHouse cluster and its PostgreSQL and
Valkey volumes are EBS PVCs. Removing it therefore needs the operator and the
EBS CSI driver alive — the cluster and the nodes still up — which puts it
**first**, before the Step 12 load balancer, the cluster and the node groups.
`scripts/down.sh` knows this:

```bash
scripts/down.sh          # lf-app, lb, cluster, nodes            (~12 min with Langfuse)
scripts/down.sh --all    # lf-app lf-db lb cluster operator prereqs lf-storage nodes storage eks vpc
```

Three details worth knowing:

- **Only what exists is torn down.** `down.sh` keeps `lf-app` only if
  `helm status`, the `langfuse-lb` Service or the `langfuse` namespace says
  there is something to remove; `lf-db` only if the namespace exists;
  `lf-storage` only if the `clickhouse-private-langfuse-irsa` stack does. A
  ClickHouse-only stack runs exactly the pre-Langfuse steps.
- **It works with the switch already off.** `deploy.yml` gates each Langfuse
  role with `when: (langfuse.enabled | bool) or (<state var>) == 'absent'`,
  so flipping `enabled` back to `false` with Langfuse still deployed does not
  orphan it; the live run did exactly that and `down.sh` still ran `lf-app`
  first. Afterwards no Langfuse NLB, namespace, PVC or EBS volume remained.
- **The zero-nodes guard covers Langfuse too.** `down.sh` refuses to start if
  it finds the `langfuse` namespace with no nodes, for the same reason it
  refuses for the ClickHouse namespace.

By hand, the three teardowns are independent, and the split is deliberate:

```bash
scripts/play.sh --tags lf-app -e langfuse_state=absent            # NLB Service, release, namespace and its PVCs. Keeps the ClickHouse data
scripts/play.sh --tags lf-db -e langfuse_db_state=absent          # DROP DATABASE langfuse SYNC; DROP USER langfuse. The data purge
scripts/play.sh --tags lf-storage -e langfuse_storage_state=absent  # the IRSA stack. The bucket stays; it holds data
```

**`lf-db` is the data-purge switch** and it is *not* in the default
`down.sh` plan: a default teardown removes the whole ClickHouse cluster
anyway, and "keep the cluster, drop only Langfuse's tables" should be an
explicit command, not a side effect. `lf-app` alone leaves the database, so
an operator can remove the application and keep the traces, or the reverse.
As with ClickHouse's bucket, nothing in either script deletes the Langfuse
bucket; `down.sh --all` ends by naming it and reminding you to empty it and
`aws s3 rb` it yourself, if you mean it.

## 13. What exists once it is up

```
namespace langfuse
  deployment    langfuse-web                 1 pod, the UI and API, NEXTAUTH_URL baked in
  deployment    langfuse-worker              1 pod, ingestion from S3 into ClickHouse
  statefulset   langfuse-postgresql          1 pod, 20Gi PVC, Chainguard PostgreSQL 18 as uid 70
  deployment    langfuse-redis               1 pod, 8Gi PVC, Chainguard Valkey 9 as uid 65532
  service       langfuse-web                 ClusterIP :3000 -- the port-forward target
  service       langfuse-lb                  type LoadBalancer -> the NLB (absent when type is none)
  serviceaccount langfuse                    carries the IRSA role annotation
  secrets       langfuse-app-auth, langfuse-clickhouse, langfuse-init          (Ansible)
                langfuse-app (empty), langfuse-postgresql-auth, langfuse-redis-auth   (chart)

ClickHouse Private, database langfuse   13 tables, Shared*MergeTree, owned by user langfuse
AWS                                     bucket langfuse-<account>-<region>; stack clickhouse-private-langfuse-irsa; one NLB
```

And in `state/`, alongside the ClickHouse files from Part 0 §7:

| File | What |
|---|---|
| `langfuse-clickhouse-password` | The `langfuse` ClickHouse user's password (Step 14) |
| `langfuse-nextauth-secret`, `langfuse-salt`, `langfuse-encryption-key` | Langfuse's own secrets. Lose the encryption key and stored API credentials become unreadable |
| `langfuse-admin-password` | The `admin@example.com` login |
| `langfuse-public-key`, `langfuse-secret-key` | The `demo` project's API key pair; what the smoke test and any SDK use |

The same rule as Part 0: lose `state/` and you lose these. A `down.sh` /
`up.sh --from nodes` cycle reuses them, so the rebuilt Langfuse accepts the
same login and API keys — the live run confirmed that.

## 14. Where the evidence is

Every output quoted in this Part is taken from
[`docs/part-6-langfuse-live-run.md`](part-6-langfuse-live-run.md), the
record of the 2026-09-11 run: disabled mode, the ECR digests, the IRSA and
grant outputs, the three `lf-app` attempts and their fixes, the smoke test
before and after its rewrite, idempotency, the down/up cycle with the switch
off, and check mode. Where this Part and the design notes disagree — the
Secret name, `GRANT CLUSTER`, `events_core` — the live run is what happened.

# Checkpoint

- [x] `langfuse.enabled: false` (the default) changes nothing: 7 artifacts, `up.sh --help` identical, `--tags langfuse` skips 97 tasks
- [x] Step 2 mirrors four images and pushes the chart; Chainguard's `latest` frozen under immutable ECR tags with the digests recorded above
- [x] Step 13: bucket encrypted and blocked; IRSA role trusted for `langfuse:langfuse` only; no access keys anywhere in the pods
- [x] Step 14: database and least-privilege user; SQL carries a hash, password on stdin; `GRANT CLUSTER` succeeded on 26.2.1; second run `changed=0`
- [x] Step 15: cluster mode on, 46 migrations `ON CLUSTER default`, 13 tables on `Shared*MergeTree`; all 6 containers from your ECR; PostgreSQL 18.6 as uid 70, Valkey 9.1.2 as uid 65532; health 200 via Service and NLB
- [x] The Secret is `langfuse-app-auth` (the chart owns `langfuse-app`); the web liveness probe has room for first-boot migrations
- [x] `scripts/langfuse-smoke.sh`: OTLP in at `/api/public/otel/v1/traces`, the same trace id out of `langfuse.events_core` through `ch-client.sh` — twice, on two builds
- [x] `--tags langfuse` re-run `ok=85 changed=0`; `--check --tags lf-app` renders
- [x] `down.sh` removes Langfuse first, even with the switch already off; nothing orphaned; `up.sh --from nodes` brings it back with the same secrets
- [ ] `type: public` not exercised (no safe CIDR to allow from here); the path differs from Step 12's by nothing new
- [ ] TLS in front of the NLB before any real public exposure — the same prerequisite as Part 5's
