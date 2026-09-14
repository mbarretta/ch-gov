# Part 6 (live run) — Langfuse on ClickHouse Private, verified against the stack

**Date: 2026-09-11.** This is the record of running the Langfuse design's
verification runbook (Steps 13–15 and the operator scripts) against the real
deployment: account `<YOUR_ACCOUNT_ID>`, `us-east-1`, EKS `clickhouse-private-eks`
(Kubernetes 1.36), ClickHouse Private `default-us-01` on server 26.2.1.525,
Langfuse chart 2.1.0 / app 4.25.0. Every command below was run from this repo
with `scripts/play.sh`, `scripts/up.sh`, `scripts/down.sh` and
`scripts/langfuse-smoke.sh`; outputs are quoted with secrets removed. Part 6
proper (`docs/part-6-langfuse.md`) is the operator's guide and cites this file
as its evidence.

Three defects in the roles and one in the demo script only showed up live.
Each was fixed and committed on its own; they are listed under
[Application](#4-application) and [Smoke test](#5-smoke-test). One
pre-existing Step 2 issue was observed and is recorded under
[Observed, not fixed](#observed-not-fixed).

**`langfuse.enabled` is committed as `false`.** The plan's default (AC9) was
confirmed by the user before this unattended run; no user was present to
re-confirm at the end, so the default stands. The switch was `true` only for
the live steps below and was set back before the final commit.

The eight sections follow the runbook order. A second live run, on
2026-09-14, verified TLS termination at the Langfuse NLB; it is recorded
at the end, under [Live run 2](#live-run-2--2026-09-14-tls-at-the-langfuse-nlb).

---

## 1. Disabled mode

With the committed default (`langfuse.enabled: false`) the Langfuse tag runs
nothing but the banner, and the operator scripts are the ones from before the
feature.

```bash
scripts/play.sh --tags langfuse
```

```
TASK [Show what this run will do] **********************************************
ok: [localhost] => {
    "msg": [
        "build:           standard (arm64)",
        ...
        "artifacts:       clickhouse-server, clickhouse-keeper, clickhouse-operator, helm/clickhouse-operator-helm, helm/onprem-clickhouse-cluster, helm/preflight-check, kubebuilder/kube-rbac-proxy"
    ]
}

PLAY RECAP *********************************************************************
localhost                  : ok=1    changed=0    unreachable=0    failed=0    skipped=97   rescued=0    ignored=0
```

All 97 tasks of the three roles skipped; `all_artifacts` is the 7-entry
ClickHouse list.

```bash
# base = the commit before this feature (a4fd209)
diff <(bash base/scripts/up.sh --help)   <(scripts/up.sh --help)     # no output: identical
diff <(bash base/scripts/down.sh --help) <(scripts/down.sh --help)
```

```
23a24,28
>   * Langfuse (optional Steps 13-15) goes BEFORE ClickHouse. Its tables live
>     in the ClickHouse cluster and its PostgreSQL and Valkey volumes are EBS
>     PVCs, so removing it needs the operator and the EBS CSI driver alive --
>     i.e. the cluster and the nodes still up. Only what exists is torn down;
>     a ClickHouse-only stack runs none of these steps.
```

`up.sh --help` is byte-identical to the pre-feature version; `down.sh --help`
differs by the one new ordering rule.

## 2. ECR tags and digests

`langfuse.enabled` set to `true`, then the Step 2 image hop:

```bash
scripts/play.sh --tags images        # 2m25s
```

```
TASK [image_sync : Copy each artifact that is not already present] *************
changed: [localhost] => (item=langfuse/langfuse:4.25.0)
changed: [localhost] => (item=langfuse/langfuse-worker:4.25.0)
changed: [localhost] => (item=chainguard/postgres:pg18-cg)
changed: [localhost] => (item=chainguard/valkey:valkey9-cg-dev)
TASK [image_sync : Report what was copied vs already present] ******************
ok: [localhost] => {
    "msg": "4 copied, 7 already present (standard build); 1 chart(s) to push with helm"
}
TASK [image_sync : Pull each missing chart from its Helm repository] ***********
ok: [localhost] => (item=helm/langfuse:2.1.0)
TASK [image_sync : Push each pulled chart to ECR] ******************************
changed: [localhost] => (item=helm/langfuse:2.1.0)
PLAY RECAP *********************************************************************
localhost                  : ok=18   changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

The four images went registry-to-registry with skopeo (`cgr.dev` from the
floating `latest` / `latest-dev` source tags into our frozen tags;
`docker.langfuse.com` as-is); the chart went `helm pull` → `helm push` into
`oci://<ecr>/helm/langfuse`.

```bash
for spec in chainguard/postgres:pg18-cg chainguard/valkey:valkey9-cg-dev \
            langfuse/langfuse:4.25.0 langfuse/langfuse-worker:4.25.0 helm/langfuse:2.1.0; do
  aws ecr describe-images --repository-name "${spec%%:*}" --image-ids imageTag="${spec##*:}" \
    --query 'imageDetails[0].[repositoryName,imageTags[0],imageDigest,imageSizeInBytes,artifactMediaType]' --output text
done
```

| Repository | Tag | Digest (immutable) | Size | Type |
|---|---|---|---|---|
| `chainguard/postgres` | `pg18-cg` | `sha256:0962bea4e3dd11047726890b8e7242ae616215ea2a50ffbcae22654f06184f1b` | 143 MB | image (PostgreSQL 18.6) |
| `chainguard/valkey` | `valkey9-cg-dev` | `sha256:6a846484cd4e261ad31ca380936d39072e5100bee17a5596da4faa87c8b6e548` | 29 MB | image (Valkey 9.1.2) |
| `langfuse/langfuse` | `4.25.0` | `sha256:12654de5ffb20722cf6b2d7df51b3099eb2d92bd92f5aef20e095b16a840ca8d` | 352 MB | image |
| `langfuse/langfuse-worker` | `4.25.0` | `sha256:638a46341ead4f68103f2b800a14b5d75f7c352b975f2b63a43697c577233a4c` | 357 MB | image |
| `helm/langfuse` | `2.1.0` | `sha256:35c218270f1d6c8e1e6c3249db548180b5d0bfbe83a573ac9edecf766ae7c6a0` | 135 KB | `application/vnd.cncf.helm.config.v1+json` |

Both repositories checked report `imageTagMutability: IMMUTABLE`, so the
Chainguard digests above are what `pg18-cg` and `valkey9-cg-dev` will mean
until someone bumps the tag in `versions`.

## 3. IRSA and grants

### Step 13 — `lf-storage`

```bash
scripts/play.sh --tags lf-storage    # 30s
```

```
TASK [langfuse_storage : Create the Langfuse bucket] ***************************
changed: [localhost]
TASK [langfuse_storage : Fail clearly if IRSA was never set up] ****************
ok: [localhost] => { "msg": "OIDC provider present for oidc.eks.us-east-1.amazonaws.com/id/168697C932A4ED501BF7EB85D199193C" }
TASK [langfuse_storage : Deploy the Langfuse IRSA role stack] ******************
changed: [localhost]
TASK [langfuse_storage : Report the IRSA wiring] *******************************
ok: [localhost] => {
    "msg": [
        "langfuse role: arn:aws:iam::<YOUR_ACCOUNT_ID>:role/clickhouse-private-langfuse-irsa-LangfuseS3Role-jbilFyYm63w9",
        "  assumable only by system:serviceaccount:langfuse:langfuse",
        "  may PutObject, GetObject, ListBucket, DeleteObject on langfuse-<YOUR_ACCOUNT_ID>-us-east-1 only",
        "note: the bucket is never deleted by teardown -- it holds data."
    ]
}
PLAY RECAP *********************************************************************
localhost                  : ok=10   changed=2    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0
```

Confirmed from the AWS side:

```
$ aws cloudformation describe-stacks --stack-name clickhouse-private-langfuse-irsa \
    --query 'Stacks[0].[StackName,StackStatus,Outputs[0].OutputKey,Outputs[0].OutputValue]' --output text
clickhouse-private-langfuse-irsa  CREATE_COMPLETE  LangfuseS3RoleArn  arn:aws:iam::<YOUR_ACCOUNT_ID>:role/clickhouse-private-langfuse-irsa-LangfuseS3Role-jbilFyYm63w9
$ aws s3api get-bucket-encryption --bucket langfuse-<YOUR_ACCOUNT_ID>-us-east-1 ...   -> AES256
$ aws s3api get-public-access-block --bucket langfuse-<YOUR_ACCOUNT_ID>-us-east-1 ...
{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}
$ aws iam get-role --role-name clickhouse-private-langfuse-irsa-LangfuseS3Role-jbilFyYm63w9 \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
{"StringEquals":{"oidc.eks.us-east-1.amazonaws.com/id/168697C932A4ED501BF7EB85D199193C:sub":"system:serviceaccount:langfuse:langfuse",
                 "oidc.eks.us-east-1.amazonaws.com/id/168697C932A4ED501BF7EB85D199193C:aud":"sts.amazonaws.com"}}
```

The IRSA path was later proven by Langfuse itself: the web pod received
`AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` from the ServiceAccount
annotation (no `*_ACCESS_KEY*` variables anywhere in its environment) and
wrote the smoke test's OTLP batch to `s3://langfuse-<YOUR_ACCOUNT_ID>-us-east-1/events/otel/demo/…`.

### Step 14 — `lf-db`

```bash
scripts/play.sh --tags lf-db         # 7s
```

```
TASK [langfuse_clickhouse : Create the database and the user] ******************
changed: [localhost]
TASK [langfuse_clickhouse : Grant the privilege set Langfuse documents] ********
changed: [localhost]
TASK [langfuse_clickhouse : Try to grant CLUSTER] ******************************
changed: [localhost]
TASK [langfuse_clickhouse : The grants must cover the documented set] **********
ok: [localhost] => { "msg": "All assertions passed" }
TASK [langfuse_clickhouse : SELECT 1 as the Langfuse user must succeed] ********
ok: [localhost] => { "msg": "All assertions passed" }
TASK [langfuse_clickhouse : Grants held by the Langfuse user] ******************
ok: [localhost] => {
    "msg": [
        "GRANT CLUSTER ON *.* TO langfuse",
        "GRANT READ ON REMOTE TO langfuse",
        "GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE, ALTER ADD COLUMN, ALTER MODIFY COLUMN, ALTER ADD INDEX, ALTER DROP INDEX, ALTER MATERIALIZE INDEX, ALTER VIEW MODIFY QUERY, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW ON langfuse.* TO langfuse",
        "GRANT SELECT(database, is_done, `table`) ON system.mutations TO langfuse",
        "GRANT SELECT(active, database, name, partition, partition_id, rows, `table`) ON system.parts TO langfuse",
        "GRANT SELECT ON system.processes TO langfuse",
        "GRANT SELECT ON system.query_log* TO langfuse",
        "GRANT SELECT(database, engine, name) ON system.tables TO langfuse"
    ]
}
TASK [langfuse_clickhouse : Report] ********************************************
ok: [localhost] => {
    "msg": [
        "database:  langfuse -- created",
        "user:      langfuse -- created",
        "before:    system.users auth_type / auth_params = (no such user)",
        "grants:    updated (8 GRANT lines, listed above)",
        "cluster:   cluster: granted",
        "verified:  SELECT 1 as langfuse over http://c-default-us-01-server-any.ns-default-us-01.svc:8123 from c-default-us-01-server-5jukk4d-0",
        ...
    ]
}
PLAY RECAP *********************************************************************
localhost                  : ok=24   changed=3    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
```

Two things to note against the design:

- **`GRANT CLUSTER ON *.* TO langfuse` succeeded.** The design expected the
  `default` admin to be refused. It was not: the Langfuse user holds
  `CLUSTER`, so Step 15's cluster-mode decision is `true` on this ground
  alone (see [Application](#4-application)).
- ClickHouse folds `CREATE` into `CREATE DATABASE, CREATE TABLE, CREATE VIEW,
  CREATE DICTIONARY` and backtick-quotes the `table` column in `SHOW GRANTS`;
  the role's by-name assertion handles both, as it was written to.

The second run, for the follow-ups the offline evaluators could not settle:

```bash
scripts/play.sh --tags lf-db
```

```
        "database:  langfuse -- already existed",
        "user:      langfuse -- existed, hash already matched the password file",
        "before:    system.users auth_type / auth_params = ['sha256_password'] / ['{}']",
        "grants:    unchanged (8 GRANT lines, listed above)",
        "cluster:   cluster: already granted",
PLAY RECAP *********************************************************************
localhost                  : ok=25   changed=0    unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```

`auth_params` renders as `{}` (inside an array: on 26.2.1 `auth_type` and
`auth_params` are `Array` columns, one element per authentication method), so
the role's decision to detect a stale hash by *authenticating* rather than by
comparing `auth_params` is the right one. The `wget` in the mirrored
`clickhouse-server` image accepted `-qO- --timeout= --header=` (the HTTP
`SELECT 1` passed), and later `-qS -O /dev/null --timeout=5 --tries=1` in the
Step 15 probe pod — it is GNU wget, as the Part 5 probe already relied on.

The teardown half of Step 14 was exercised once during recovery (see the
second Step 15 attempt below): `--tags lf-db -e langfuse_db_state=absent`
reported `ok=7 changed=1`, dropped the database `SYNC` and the user, kept
`state/langfuse-clickhouse-password`, and the following `--tags lf-db`
recreated both with the same hash, so the `langfuse-clickhouse` Secret Step 15
had already written stayed valid.

## 4. Application

```bash
scripts/play.sh --tags lf-app
```

It took three attempts. The first two found defects in the role; each was
fixed and committed before the next attempt.

### Attempt 1 — Secret name owned by the chart

```
TASK [langfuse : Report the cluster-mode decision] *****************************
ok: [localhost] => {
    "msg": [
        "CLUSTER granted to langfuse:        True",
        "on_cluster_queries_require_cluster_grant: not reported",
        "clickhouse.cluster.enabled:               True"
    ]
}
...
TASK [langfuse : Report the address] *******************************************
ok: [localhost] => { "msg": "NEXTAUTH_URL: http://a84b396aee3e34772bd93d0e1e0b8a0b-fb2db62407b0e15d.elb.us-east-1.amazonaws.com" }
...
TASK [langfuse : Install or upgrade Langfuse] **********************************
fatal: [localhost]: FAILED! => ... Error: unable to continue with install: Secret "langfuse-app" in namespace "langfuse"
  exists and cannot be imported into the current release: invalid ownership metadata; label validation error:
  key "app.kubernetes.io/managed-by" must equal "Helm": current value is "clickhouse-private-ansible" ...
```

**Cluster-mode decision, with its inputs:** `CLUSTER` is granted (Step 14),
and the query `SELECT value FROM system.settings ... UNION ALL SELECT value
FROM system.server_settings WHERE name = 'on_cluster_queries_require_cluster_grant'`
returns **no rows** on 26.2.1 (checked by hand as well: neither table lists
the setting), which the role reports as `not reported` and treats as "not
enforced". Either input alone yields `clickhouse.cluster.enabled: true`;
Langfuse ran its migrations `ON CLUSTER default` against the `Shared`-engine
database, and every table came out `Shared*MergeTree` (below). Cluster mode
stays on; the `false` fallback the design kept in reserve was not needed.

**Defect 1.** Chart 2.1.0 renders a Secret named `<fullname>-app`
(`templates/langfuse-app-secret.yaml`) to hold whichever of `NEXTAUTH_SECRET`,
`SALT` and `ENCRYPTION_KEY` it has to generate itself — with release name
`langfuse` that is exactly `langfuse-app`, the name the design chose for the
Ansible-created Secret, and Helm refuses to install over an object it does
not own. Fix: the Ansible Secret is now `langfuse-app-auth` (the chart's own
`-auth` convention for credential Secrets), referenced by the three
`secretKeyRef`s; the chart's `langfuse-app` is created empty because every
value is provided. Commit `a921720`. The stale Ansible-labelled `langfuse-app`
from this attempt was deleted by hand before attempt 2 (nothing in the role
needs to handle it: only a pre-fix run could have created it).

### Attempt 2 — a wait that did not wait, and a liveness probe that killed the migrations

```
TASK [langfuse : Create the langfuse PostgreSQL role (what the skipped init script would have done)] ***
changed: [localhost]
TASK [langfuse : Wait for the web, then the worker Deployment to be available] ***
ok: [localhost] => (item=web)          # 53 s after the Helm install -- too fast
ok: [localhost] => (item=worker)
...
TASK [langfuse : The migrations landed, on the shared engine] ******************
fatal: [localhost]: FAILED! => database langfuse: 0 table(s); missing: observations, scores, traces
```

**Defect 2.** The chart labels its Deployments with
`app.kubernetes.io/component=web|worker` and puts `app: web|worker` only on
the pod templates, so `kubectl rollout status deployment --selector=...,app=web`
matched nothing, printed `No resources found in langfuse namespace.` and
exited 0. The play went straight to the assertions while the web pod was
still starting. Fix: wait on `deployment/<fullname>-web` and
`deployment/<fullname>-worker` by name (a missing Deployment now fails loudly
with "not found"). Commit `0f21d2c`.

**Defect 3**, found while the pod from attempt 2 was left to run:

```
$ kubectl get pods -n langfuse
langfuse-web-95d5fb95-ccd65        0/1     CrashLoopBackOff   6 (66s ago)   7m24s
$ kubectl get events -n langfuse ... | grep web
21:39:46Z  langfuse-web-95d5fb95-ccd65  Killing    Container langfuse-web failed liveness probe, will be restarted
21:39:46Z  langfuse-web-95d5fb95-ccd65  Unhealthy  Liveness probe failed: Get "http://10.20.0.100:3000/api/public/health": dial tcp ...: connect: connection refused
$ kubectl logs -n langfuse deploy/langfuse-web --previous | tail
No pending migrations to apply.                       # PostgreSQL (Prisma): done
error: Dirty database version 16. Fix and force version.
Applying clickhouse migrations failed. ...
```

The web container applies every ClickHouse migration before its HTTP server
listens. On ClickHouse Private each `ON CLUSTER` statement on a
`Shared*MergeTree` table takes between 0.15 and 10 s (15 migrations in
26.5 s, read from `schema_migrations.sequence`), and the chart's default
liveness probe (`initialDelaySeconds: 20`, 5 failures 10 s apart) killed the
container after ~70 s, mid-migration. golang-migrate left `schema_migrations`
dirty at version 16 and every restart after that exited immediately. The
chart has no `startupProbe` for web, so the fix relaxes the liveness probe in
the Helm values: `initialDelaySeconds: 60, periodSeconds: 10,
failureThreshold: 90` (about 15 minutes of grace before the first restart;
the chart's default readiness probe still keeps traffic off the pod until it
is ready). Commit `4c87515`.

Recovery of the dirty schema, on a fresh install, is the Step 14 purge:

```bash
kubectl scale deploy/langfuse-web -n langfuse --replicas=0        # stop the crash loop re-dirtying it
scripts/play.sh --tags lf-db -e langfuse_db_state=absent          # DROP DATABASE langfuse SYNC; DROP USER langfuse
scripts/play.sh --tags lf-db                                       # recreate, same password file, same hash
scripts/play.sh --tags lf-app                                      # helm upgrade scales web back to 1
```

On a database that already holds data the golang-migrate `force` command is
the alternative; that was not needed here.

### Attempt 3 — green

```
TASK [langfuse : Install or upgrade Langfuse] **********************************
changed: [localhost]                                   # the probe values
TASK [langfuse : Create the langfuse PostgreSQL role (what the skipped init script would have done)] ***
ok: [localhost]                                        # role: exists (idempotent)
TASK [langfuse : Wait for the web, then the worker Deployment to be available] ***
ok: [localhost] => (item=web)                          # ~3 min: the migrations
ok: [localhost] => (item=worker)
TASK [langfuse : Assert no container pulls from outside your registry] *********
ok: [localhost] => { "msg": "all 6 containers in langfuse pull from <YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com" }
TASK [langfuse : The data stores are the major versions the images were mirrored for] ***
ok: [localhost] => { "msg": "postgres (PostgreSQL) 18.6 / Valkey server v=9.1.2 sha=7f1dffed:1 malloc=jemalloc-5.3.0 bits=64 build=107b597c54f53ed" }
TASK [langfuse : The migrations landed, on the shared engine] ******************
ok: [localhost] => { "msg": "database langfuse: 13 tables, observations=SharedReplacingMergeTree, scores=SharedReplacingMergeTree, traces=SharedReplacingMergeTree" }
TASK [langfuse : Wait for the web node(s) to pass the NLB health check] ********
ok: [localhost] => (item=arn:aws:elasticloadbalancing:us-east-1:<YOUR_ACCOUNT_ID>:targetgroup/k8s-langfuse-langfuse-cf561287b8/555bbccbda3bd599)
TASK [langfuse : Langfuse must answer through its Service] *********************
ok: [localhost] => { "msg": "GET http://langfuse-web:3000/api/public/health -> 200" }
TASK [langfuse : Report] *******************************************************
ok: [localhost] => {
    "msg": [
        "url:        http://a84b396aee3e34772bd93d0e1e0b8a0b-fb2db62407b0e15d.elb.us-east-1.amazonaws.com",
        "exposure:   internal NLB a84b396aee3e34772bd93d0e1e0b8a0b-fb2db62407b0e15d.elb.us-east-1.amazonaws.com, allowed from 10.20.0.0/16; 1 healthy target(s); answers 200 from inside the VPC",
        "login:      admin@example.com -- password in .../state/langfuse-admin-password",
        "api keys:   .../state/langfuse-public-key (public), .../state/langfuse-secret-key (secret) -- project demo",
        "clickhouse: database langfuse at c-default-us-01-server-any.ns-default-us-01.svc:8123 as langfuse, 13 tables, cluster mode on",
        "smoke test: scripts/langfuse-smoke.sh   (posts a trace and reads it back from ClickHouse)",
        "teardown:   ansible-playbook deploy.yml --tags lf-app -e langfuse_state=absent   (keeps the ClickHouse data; --tags lf-db -e langfuse_db_state=absent purges it)"
    ]
}
PLAY RECAP *********************************************************************
localhost                  : ok=52   changed=1    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```

**Pods, images, health:**

```
$ kubectl get pods -n langfuse -o wide
langfuse-postgresql-0              1/1  Running  0   ip-10-20-6-253.ec2.internal     # operator node (x86_64)
langfuse-redis-77db74676d-2xcwf    1/1  Running  0   ip-10-20-67-217.ec2.internal    # operator node
langfuse-web-8475849787-wvssn      1/1  Running  0   ip-10-20-6-253.ec2.internal
langfuse-worker-6fc7ccd4d7-4sftt   1/1  Running  0   ip-10-20-67-217.ec2.internal
$ kubectl get pods -n langfuse -o jsonpath='...{.image}...' | sort -u
<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/chainguard/postgres:pg18-cg
<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/chainguard/valkey:valkey9-cg-dev
<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/langfuse/langfuse-worker:4.25.0
<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/langfuse/langfuse:4.25.0
```

Both Chainguard subcharts pull their init containers from the same mirrored
images (6 containers in total, all from our ECR). The probe pod answered
`health: 200` through `langfuse-web:3000` and `nlb: 200` through the NLB from
a node without a web pod; the NLB target group showed 1 healthy target for 1
web replica (instance targets and `externalTrafficPolicy: Local`, as in
Step 12).

**ClickHouse tables** (`system.tables WHERE database = 'langfuse'`, after the
46 migrations of app 4.25.0):

```
analytics_observations       View                       events_core_mv     MaterializedView
analytics_scores             View                       events_full        SharedReplacingMergeTree
analytics_traces             View                       observations       SharedReplacingMergeTree
blob_storage_file_log        SharedReplacingMergeTree   observations_batch_staging  SharedReplacingMergeTree
dataset_run_items_rmt        SharedReplacingMergeTree   schema_migrations  SharedMergeTree
events_core                  SharedReplacingMergeTree   scores             SharedReplacingMergeTree
                                                        traces             SharedReplacingMergeTree
```

Langfuse declares `traces`, `observations`, `scores` as `ReplacingMergeTree`;
`cloud_mode=1` realises them as `SharedReplacingMergeTree` — hence the role's
`Shared\w*MergeTree` check rather than the literal `SharedMergeTree`. The
migrations themselves: 46 applied, `traces` first at 0.34 s, the slowest
single statements around 10 s, the whole run about 2.5 minutes from
container start to Ready.

**Chainguard PostgreSQL, as deployed:**

```
$ kubectl get pod langfuse-postgresql-0 -n langfuse -o jsonpath='{.spec.securityContext} {.spec.containers[0].securityContext}'
{"fsGroup":70,"supplementalGroups":[999]}
{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":70,"runAsNonRoot":true,"runAsUser":70}
$ kubectl exec -n langfuse langfuse-postgresql-0 -- sh -c 'id; echo PGDATA=$PGDATA; ls -la /var/lib/postgresql/data'
uid=70(postgres) gid=70(postgres) groups=70(postgres),999
PGDATA=/var/lib/postgresql/data/pg
drwxrwsr-x  root     postgres  .            # the gp3 volume, fsGroup 70 (setgid)
drwxrws---  root     postgres  lost+found
drwx------  postgres postgres  pg           # initdb wrote here
$ kubectl logs -n langfuse langfuse-postgresql-0 | head
fixing permissions on existing directory /var/lib/postgresql/data/pg ... ok
...
Success. You can now start the database server ...
LOG:  starting PostgreSQL 18.6 on x86_64-pc-linux-gnu, compiled by x86_64-pc-linux-gnu-gcc (Wolfi 16.2.0-r1) 16.2.0, 64-bit
```

So: uid/gid 70 with `fsGroup: 70` on a fresh gp3 volume works (PGDATA is the
`pg` subdirectory, so `lost+found` is no obstacle), and the Chainguard
entrypoint runs under the subchart's `readOnlyRootFilesystem: true` with only
the subchart's emptyDirs (`/var/run`, `/tmp`, `scripts`, `configs`) writable
— it wrote nowhere else. The subchart's `initscripts` mount at
`/docker-entrypoint-initdb.d` is indeed ignored by this image (its entrypoint
reads `/var/lib/postgres/initdb/`), which is why the role creates the
`langfuse` PostgreSQL role itself: `psql -h localhost -U postgres` with
`PGPASSWORD` from the pod's `POSTGRES_PASSWORD` and the role password read by
`\getenv` from `USERDB_PASSWORD` connected fine, printed `role: created` on
attempt 2 and `role: exists` on every run after (`changed=0`). Valkey runs as
uid 65532 with `readOnlyRootFilesystem: true`, its init container from the
same `-dev` image (the one with `/bin/sh`).

**Secrets in the namespace, by name and key** (values never printed):

```
langfuse-app             Opaque   (no keys -- the chart's, empty because every value is provided)
langfuse-app-auth        Opaque   encryption-key nextauth-secret salt          # Ansible
langfuse-clickhouse      Opaque   password                                      # Ansible, from Step 14
langfuse-init            Opaque   LANGFUSE_INIT_ORG_ID ... LANGFUSE_INIT_USER_PASSWORD (9 keys)   # Ansible
langfuse-postgresql-auth Opaque   POSTGRES_DB POSTGRES_PASSWORD POSTGRES_USER USERDB_PASSWORD USERDB_USER   # chart
langfuse-redis-auth      Opaque   default                                       # chart
```

## 5. Smoke test

```bash
scripts/langfuse-smoke.sh
```

The script as committed by task 6 reached Langfuse (the internal NLB does not
answer from a laptop off the VPC, so it fell back to the `3000:3000`
port-forward) and was then refused:

```
==> Posting a trace
  [fail] ingestion rejected 2 event(s): [{"id":"...","status":400,"message":"Event type not accepted",
  "error":"Event type \"trace-create\" is not accepted by /api/public/ingestion when LANGFUSE_MIGRATION_V4_WRITE_MODE
  is events_only. This endpoint only accepts score and log events. Upgrade the client or integration to a
  v4-compatible SDK or OTLP ingestion path. As a temporary migration bridge, set LANGFUSE_MIGRATION_V4_WRITE_MODE=dual
  on both the web and worker services and redeploy. ..."}, {... "generation-create" ...}]
```

**Defect 4 (the demo script, not the roles).** Langfuse 4.x stores everything
as OpenTelemetry spans and, in its default `events_only` write mode, refuses
the v3 batch event types the design's script posted. Probing the running
server settled the rest of the v4 picture:

| | v3 (what the design assumed) | Langfuse 4.25.0, `events_only` (observed) |
|---|---|---|
| Write | `POST /api/public/ingestion` with `trace-create` / `generation-create` | rejected (400); `POST /api/public/otel/v1/traces` (OTLP/JSON or protobuf) → 200, queued via S3 |
| Read | `GET /api/public/traces/{id}`, `/api/public/observations` | 404 `"This endpoint is not available on deployments running in Langfuse v4 events_only mode"`; `GET /api/public/v2/observations?traceId={id}` → 200 |
| ClickHouse | `langfuse.traces`, `langfuse.observations` | `langfuse.events_core` (one row per span) and `events_full`; `traces`/`observations`/`scores` exist (created by the migrations) but stay **empty** |

The alternative — running the fresh install in `LANGFUSE_MIGRATION_V4_WRITE_MODE=dual`
so the v3 endpoints and tables work — is the temporary v3→v4 migration bridge
in Langfuse's own words, and was rejected for a greenfield v4 deployment.
The script now posts one OTLP/JSON request (a root span named after the run
plus a `generation` child with `gen_ai.*` attributes), polls
`GET /api/public/v2/observations?traceId=<id>` until both spans are listed,
and reads the same trace id back from `langfuse.events_core`. The credential
handling is unchanged (curl config on stdin from a 0600 file; the secret key
never enters argv or a shell variable). Commit `f893278`. **This deviates
from the queries the plan pinned (`FROM langfuse.traces` / `langfuse.observations`)**;
on a v4 server those tables cannot show the trace without the bridge mode.

The rewritten script, against the live stack:

```
==> Reaching Langfuse
  load balancer (internal NLB): http://a84b396aee3e34772bd93d0e1e0b8a0b-fb2db62407b0e15d.elb.us-east-1.amazonaws.com
  [warn] http://a84b396aee3e34772bd93d0e1e0b8a0b-fb2db62407b0e15d.elb.us-east-1.amazonaws.com does not answer /api/public/health from here (VPN? security group?)
  forwarding localhost:3000 -> svc/langfuse-web:3000 in langfuse
  [ ok ] health check passed through the port-forward

==> Posting a trace
  [ ok ] accepted trace 392e04de3367de01095af8f81f987ea1 (name smoke-20260911-220101) with one generation
  waiting for GET /api/public/v2/observations?traceId=392e04de3367de01095af8f81f987ea1 to list both spans
  [ ok ] API returns the trace: traceId=392e04de3367de01095af8f81f987ea1 observations=2 (SPAN, GENERATION)

==> Reading it back from ClickHouse (langfuse database)
  SELECT trace_id, span_id, name, type FROM langfuse.events_core WHERE trace_id = '392e04de3367de01095af8f81f987ea1'
  forwarding localhost:19000 -> c-default-us-01-server-5jukk4d-0:9000 in ns-default-us-01
   ┌─trace_id─────────────────────────┬─span_id──────────┬─name──────────────────┬─type───────┐
1. │ 392e04de3367de01095af8f81f987ea1 │ 806d2cd0bf904d95 │ answer                │ GENERATION │
2. │ 392e04de3367de01095af8f81f987ea1 │ bb2c7c890fdb859e │ smoke-20260911-220101 │ SPAN       │
   └──────────────────────────────────┴──────────────────┴───────────────────────┴────────────┘
  SELECT hostName(), count() FROM langfuse.events_core GROUP BY 1
   ┌─hostName()───────────────────────┬─count()─┐
1. │ c-default-us-01-server-5jukk4d-0 │       4 │       # this trace's 2 spans + 2 from a hand-posted probe
   └──────────────────────────────────┴─────────┘

==> Done
  [ ok ] trace 392e04de3367de01095af8f81f987ea1 went in through the API and came back out of ClickHouse Private
```

The ClickHouse half runs through `scripts/ch-client.sh` exactly as before
(pod port-forward here; `--lb` would send it through the Step 12 NLB), so the
follow-up on that path is confirmed. The trace was also visible in the S3
bucket as `events/otel/demo/<date>/<uuid>.json` (1,094 bytes), written by
the web pod through IRSA.

## 6. Idempotency

With everything deployed:

```bash
scripts/play.sh --tags langfuse      # Steps 13, 14, 15 in one run, 33s
```

```
PLAY RECAP *********************************************************************
localhost                  : ok=85   changed=0    unreachable=0    failed=0    skipped=13   rescued=0    ignored=0
```

Nothing changed: the bucket and stack converge, the ClickHouse user
authenticates with the stored hash so no `ALTER USER` runs, the `GRANT`s
compare equal before and after, the Secrets are written as `data:` and
converge, Helm sees identical values, and the PostgreSQL role fix prints
`role: exists`.

## 7. Teardown and rebuild

### Down, with the switch already off

`langfuse.enabled` was set back to `false` **with Langfuse still deployed**,
then the default teardown:

```bash
scripts/down.sh --yes
```

```
==> Tearing down (default): lf-app lb cluster nodes
  keeps: VPC, EKS control plane, IRSA, operator, StorageClass. ~$0.15/hr
==> down: lf-app
TASK [langfuse : Remove the load balancer Service] *****************************
changed: [localhost]
TASK [langfuse : Uninstall the release] ****************************************
changed: [localhost]
TASK [langfuse : Remove the namespace and everything left in it] ***************
changed: [localhost]
localhost                  : ok=5    changed=3    unreachable=0    failed=0    skipped=22   rescued=0    ignored=0
==> down: lb
localhost                  : ok=5    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
==> down: cluster
localhost                  : ok=8    changed=2    unreachable=0    failed=0    skipped=12   rescued=0    ignored=0
==> down: nodes
localhost                  : ok=8    changed=1    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0
==> Down in 12m
  [ ok ] load balancer, cluster and node groups removed. Rebuild: scripts/up.sh --from nodes (~15 min)
```

`lf-app` ran first even though the switch was off — `down.sh` kept it because
`helm status` found the release, and the role-level
`when: (langfuse.enabled | bool) or (langfuse_state | default('present')) == 'absent'`
in `deploy.yml` let the role run for the teardown. Its 22 skipped tasks are
the whole install path. Then the Step 12 load balancer, the ClickHouse
cluster (which takes the `langfuse` database with it) and the node groups.

Post-teardown, from `kubectl` and the AWS CLI (the two volume ids were
recorded from the PVs before the teardown):

```
namespace langfuse:                 Error from server (NotFound): namespaces "langfuse" not found
PVCs in langfuse:                   (none)
PVs bound to langfuse/*:            0
the Langfuse NLB by ARN:            An error occurred (LoadBalancerNotFound) ... One or more load balancers not found
EBS vol-04de59ec57d165524:          InvalidVolume.NotFound  (postgres-data-langfuse-postgresql-0)
EBS vol-08ceeeed8338d9a2d:          InvalidVolume.NotFound  (langfuse-redis)
EBS volumes tagged kubernetes.io/created-for/pvc/namespace=langfuse: 0
nodes:                              0
helm releases (all namespaces):     clickhouse-operator clickhouse-prerequisites
```

No Langfuse NLB, namespace, PVC or EBS volume remained. (The account is
shared with other SAs; the one NLB and the PVC-tagged volumes still listed
account-wide belong to other clusters and were left alone.)

### Step 13 teardown, while the app was gone (follow-up b)

Still with `enabled: false`:

```bash
scripts/play.sh --tags lf-storage -e langfuse_storage_state=absent
```

```
TASK [langfuse_storage : Remove the Langfuse IRSA role stack] ******************
changed: [localhost]
TASK [langfuse_storage : Report the teardown] **********************************
ok: [localhost] => {
        "absent: CloudFormation stack clickhouse-private-langfuse-irsa (and the role in it)",
        "kept:   bucket langfuse-<YOUR_ACCOUNT_ID>-us-east-1 -- it holds data; empty and delete it by hand if you mean it"
localhost                  : ok=3    changed=1    unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```

```
describe-stacks clickhouse-private-langfuse-irsa: rc 254 ("does not exist")
bucket langfuse-<YOUR_ACCOUNT_ID>-us-east-1:           present, 2 objects (the smoke tests' OTLP batches)
```

Only the stack went; the bucket and its data stayed. And the exit codes
`down.sh`'s prune keys off, on a stack with no Langfuse (follow-up e):
`helm status -n langfuse langfuse` → 1, `kubectl get service langfuse-lb -n langfuse` → 1,
`kubectl get namespace langfuse` → 1, `describe-stacks` → 254 — so every
`lf-*` entry would be dropped and a ClickHouse-only teardown runs exactly the
pre-feature steps.

### Up again, Langfuse included

`langfuse.enabled: true`, then:

```bash
scripts/up.sh --from nodes --yes
```

```
==> Bringing up: nodes storage prereqs operator cluster preflight verify lb lf-storage lf-db lf-app
  langfuse: enabled -- Steps 13-15 run after the load balancer (adds ~$0.02/hr for its NLB)
...
TASK [langfuse_storage : Report the IRSA wiring] *******************************
        "langfuse role: arn:aws:iam::<YOUR_ACCOUNT_ID>:role/clickhouse-private-langfuse-irsa-LangfuseS3Role-NCePMlBj3ZxM",   # a new stack, new suffix
...
TASK [langfuse : Report the cluster-mode decision] *****************************
        "CLUSTER granted to langfuse:        True",
        "on_cluster_queries_require_cluster_grant: not reported",
        "clickhouse.cluster.enabled:               True"
...
TASK [langfuse : Create the langfuse PostgreSQL role (what the skipped init script would have done)] ***
changed: [localhost]                                   # fresh volume: role: created
TASK [langfuse : Wait for the web, then the worker Deployment to be available] ***
ok: [localhost] => (item=web)
ok: [localhost] => (item=worker)
TASK [langfuse : The migrations landed, on the shared engine] ******************
    "msg": "database langfuse: 13 tables, observations=SharedReplacingMergeTree, scores=SharedReplacingMergeTree, traces=SharedReplacingMergeTree"
TASK [langfuse : Langfuse must answer through its Service] *********************
    "msg": "GET http://langfuse-web:3000/api/public/health -> 200"
PLAY RECAP *********************************************************************
localhost                  : ok=202  changed=17   unreachable=0    failed=0    skipped=23   rescued=0    ignored=0

==> Up in 15m
  [ ok ] connect:  scripts/ch-client.sh            (port-forward from this machine)
  [ ok ]           scripts/ch-client.sh --lb       (via the internal NLB, where its address is reachable)
  [ ok ] langfuse: http://ae533cf8448134c079b7a5e198fe2e44-6263614279b4332d.elb.us-east-1.amazonaws.com   (via the internal NLB; login: state/langfuse-admin-password)
  [ ok ]           scripts/langfuse-smoke.sh       (posts a trace and reads it back from ClickHouse)
```

One run, nodes through Langfuse, first time green — with the three role fixes
from §4 in place. The `state/` secrets were reused, so the same API keys and
admin password work on the rebuilt instance.

```bash
scripts/langfuse-smoke.sh
```

```
==> Posting a trace
  [ ok ] accepted trace ee06c582837ea16edd446571683297ab (name smoke-20260911-223408) with one generation
  [ ok ] API returns the trace: traceId=ee06c582837ea16edd446571683297ab observations=2 (SPAN, GENERATION)

==> Reading it back from ClickHouse (langfuse database)
   ┌─trace_id─────────────────────────┬─span_id──────────┬─name──────────────────┬─type───────┐
1. │ ee06c582837ea16edd446571683297ab │ c73a589e995226b9 │ answer                │ GENERATION │
2. │ ee06c582837ea16edd446571683297ab │ d412731ad7fa7d87 │ smoke-20260911-223408 │ SPAN       │
   └──────────────────────────────────┴──────────────────┴───────────────────────┴────────────┘
   ┌─hostName()───────────────────────┬─count()─┐
1. │ c-default-us-01-server-ilf7ovp-0 │       2 │       # a fresh database: the cluster teardown took the old one
   └──────────────────────────────────┴─────────┘

==> Done
  [ ok ] trace ee06c582837ea16edd446571683297ab went in through the API and came back out of ClickHouse Private
```

### Where the stack was left

This was an unattended run, so it ends with the meter off. `langfuse.enabled`
went back to `false` (the committed value) with the rebuilt Langfuse still
running, and the default teardown ran once more:

```bash
scripts/down.sh --yes
```

```
==> Tearing down (default): lf-app lb cluster nodes
==> down: lf-app      ok=5  changed=3  skipped=22
==> down: lb          ok=5  changed=1
==> down: cluster     ok=8  changed=2  skipped=12
==> down: nodes       ok=8  changed=1  skipped=2
==> Down in 11m
```

Same order, same gate, second time. Final state, checked afterwards:

```
namespace langfuse:                      NotFound
namespace ns-default-us-01:              NotFound
PVs bound to langfuse/*:                 0
EBS volumes tagged for namespace langfuse: 0
NLBs tagged kubernetes.io/cluster/clickhouse-private-eks: 0
nodes:                                   0        node groups: (none)
helm releases (all namespaces):          clickhouse-operator clickhouse-prerequisites
IRSA stack clickhouse-private-langfuse-irsa: CREATE_COMPLETE   (kept by the default plan, as Step 6's is)
bucket langfuse-<YOUR_ACCOUNT_ID>-us-east-1:  present, 3 objects   (never deleted by down.sh)
```

That is the `down.sh` default posture from Part 0 — VPC, EKS control plane,
IRSA, operator and StorageClass kept (~$0.15/hr) — with the Langfuse bucket
and IRSA stack alongside the ClickHouse ones. `scripts/up.sh --from nodes`
brings ClickHouse back in about 15 minutes; set `langfuse.enabled: true`
first and the same run brings Langfuse back with it, reusing the secrets
under `state/`.


## 8. Check mode

With the release deployed:

```bash
scripts/play.sh --check --tags lf-app        # 25s
```

```
TASK [langfuse : Install or upgrade Langfuse] **********************************
ok: [localhost]
...
TASK [langfuse : Report] *******************************************************
ok: [localhost] => { ... }
PLAY RECAP *********************************************************************
localhost                  : ok=52   changed=0    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```

The Helm module rendered the chart in check mode without a `validations.yaml`
failure (the existing-Secret names the values reference — `langfuse-app-auth`,
`langfuse-clickhouse`, `langfuse-init` — are consistent with what the role
creates), and every read, wait and probe task ran for real, as the
`check_mode: false` convention intends.

---

## Follow-ups from the offline evaluators

| | Question | Outcome |
|---|---|---|
| (a) | `system.users.auth_params` for the langfuse user; second `lf-db` run `changed=0`; `SHOW GRANTS` assert against the real rendering; `GRANT CLUSTER` refused?; wget flags | `['sha256_password'] / ['{}']`; `ok=25 changed=0`; assert passed against the folded/backticked rendering; **`GRANT CLUSTER` succeeded**; flags accepted (GNU wget) — §3 |
| (b) | `langfuse_storage` teardown deletes only the stack and keeps the bucket | see §7 |
| (c) | The `system.settings UNION ALL system.server_settings` query returns a row on 26.2.1 | **No row** on 26.2.1: the setting is in neither table. The role reports `not reported` and treats it as not enforced; the decision is `true` regardless because `CLUSTER` is granted — §4 |
| (d) | The ClickHouse half of `langfuse-smoke.sh` (`ch-client.sh` path) against the live cluster | works; the queries changed to `events_core` for v4 — §5 |
| (e) | The `or ... == 'absent'` teardown gate end to end; `helm status` / `describe-stacks` behave as the `down.sh` prune expects | see §7 |
| (f) | `psql -h localhost` with `PGPASSWORD` against the Chainguard image; the rescue path; GNU wget in the probe pod; `cloud_mode` yields `Shared*MergeTree` | psql path works (`role: created` then `role: exists`); the rescue path fired on attempt 2 and printed pods, Warning events and the log tails as designed; wget accepted `-qS --tries=1`; engines are `SharedReplacingMergeTree` / `SharedMergeTree` / `SharedAggregatingMergeTree` — §4 |

## Observed, not fixed

- **Step 2 `image_sync` prints the ECR registry token** in the per-item output
  of `Verify both logins succeeded` (`ansible/roles/image_sync/tasks/main.yml`,
  the assert after the two login tasks). The token task and the login task
  both carry `no_log: true`, but the assert loops over `_logins.results`, and
  Ansible prints each loop `item` — which nests the login result, which nests
  the token task's `stdout`. The token is a 12-hour ECR credential for the
  target registry. Pre-existing Step 1–12 code that `plan.constraints[5]`
  puts out of scope for this cycle; recorded in the plan's deferral ledger.
  The scratch log of this run was scrubbed. Fixed since by plan
  `fix-langfuse-deferrals` (task `def-d3`): the assert gained a
  `show_secrets`-gated `no_log`; then by plan `improve-langfuse-tls-hardening`
  (task 4): the assert loops over a token-free `{name, registry, rc, stderr}`
  projection, so no flag or verbosity can print the token.

## Commits from this run

| Commit | Change |
|---|---|
| `a921720` | `fix(langfuse): rename the app Secret to langfuse-app-auth, chart 2.1.0 owns <release>-app` |
| `0f21d2c` | `fix(langfuse): wait on the web and worker Deployments by name, the chart labels only their pods app=web` |
| `4c87515` | `fix(langfuse): give the web liveness probe room for first-boot ClickHouse migrations` |
| `f893278` | `fix(langfuse-smoke): speak Langfuse v4, OTLP in, v2 observations and events_core out` |
| `4231909` | `refactor(langfuse): derive the web Service name from the Helm fullname fact` (from the pre-commit code review) |

Plus this report, with `langfuse.enabled` back at `false`.

---

# Live run 2 — 2026-09-14: TLS at the Langfuse NLB

**Date: 2026-09-14.** Plan `improve-langfuse-tls-hardening`, task 6: bring the
stack up with `langfuse.enabled: true`, `langfuse.load_balancer.tls: true` and
`port: 443`, prove https end to end, tear down. Same account, region and
cluster as above; EKS is now 1.36 (`eks.10`, server `v1.36.2-eks-bca9cf6`),
Langfuse chart 2.1.0 / app 4.25.0, OpenSSL 3.6.4 on the operator's PATH. The
three values were `true` / `true` / `443` only for the live steps below and are
committed back at their defaults (`false` / `false` / `80`); no user was
present to confirm anything else. Outputs are quoted with secrets removed;
the account is shared with other SAs, so resources that are not ours are
counted but not named.

One defect showed up live and is fixed in this run (§2 below): the EKS cloud
controller cannot turn the listener it created into a TLS listener, so the
role now does it. Everything else in the TLS design worked the first time.

## 1. Up, with TLS on

```bash
scripts/up.sh --from nodes --yes        # 20 min to the failure below
```

```
==> Bringing up: nodes storage prereqs operator cluster preflight verify lb lf-storage lf-db lf-app
  load balancer type from group_vars: internal
  langfuse: enabled -- Steps 13-15 run after the load balancer (adds ~$0.02/hr for its NLB)
```

Nodes, storage, prerequisites, operator, cluster, preflight, verify, Step 12,
Steps 13 and 14 all came up as on 2026-09-11. Step 15 created the Service,
waited for its hostname, and the new TLS block ran:

```
TASK [langfuse : Read the openssl version] *************************************
ok: [localhost]
TASK [langfuse : Fail clearly if it is not OpenSSL 3+] *************************
ok: [localhost] => { "msg": "All assertions passed" }
TASK [langfuse : Read the SAN of the certificate already there, if any] ********
ok: [localhost]
TASK [langfuse : Look for the private key] *************************************
ok: [localhost]
TASK [langfuse : Generate the key and the self-signed certificate (missing, or naming another hostname)] ***
changed: [localhost]
TASK [langfuse : Keep the key owner-readable only] *****************************
ok: [localhost]
TASK [langfuse : Import the certificate into ACM (or find it there)] ***********
changed: [localhost]
TASK [langfuse : Note the certificate ARN] *************************************
ok: [localhost]
TASK [langfuse : Point the load balancer Service at the certificate] ***********
changed: [localhost]
TASK [langfuse : Settle the address people will use] ***************************
ok: [localhost]
TASK [langfuse : Report the address] *******************************************
ok: [localhost] => {
    "msg": "NEXTAUTH_URL: https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com"
}
```

The key was written 0600 by openssl itself (the chmod task reported `ok`),
the certificate went into ACM under `Name=clickhouse-private-langfuse-lb`,
the Service got its two `aws-load-balancer-ssl-*` annotations and
`NEXTAUTH_URL` came out as `https://<hostname>` with no port. The release
installed, migrated and passed every in-cluster check. Then:

```
TASK [langfuse : Wait for the listener to terminate TLS] ***********************
FAILED - RETRYING: ... (29 retries left).
...
FAILED - RETRYING: ... (0 retries left).
fatal: [localhost]: FAILED! => {"attempts": 30, "cmd": ["aws", "elbv2", "describe-listeners",
  "--load-balancer-arn=arn:aws:elasticloadbalancing:us-east-1:<YOUR_ACCOUNT_ID>:loadbalancer/net/ab39a131f49a44e9dbb8ac9e6887c936/5197570faae99cb6",
  "--query=Listeners[?Port==`443`].Protocol | [0]", "--output=text", "--profile=sa", "--region=us-east-1"],
  "rc": 0, "stdout": "TCP"}

PLAY RECAP *********************************************************************
localhost                  : ok=207  changed=19   unreachable=0    failed=1    skipped=24   rescued=0    ignored=0
```

The listener stayed `TCP` for the whole five minutes.

## 2. Defect: the cloud controller cannot change a listener's protocol

The Service's events said why:

```
$ kubectl get events -n langfuse --field-selector involvedObject.name=langfuse-lb
15:30:20Z  Normal   EnsuredLoadBalancer     Ensured load balancer
15:30:30Z  Warning  SyncLoadBalancerFailed  Error syncing load balancer: failed to ensure load balancer:
           error creating load balancer listener: "operation error Elastic Load Balancing v2: CreateListener,
           https response error StatusCode: 400, ... DuplicateListener: A listener already exists on this port
           for this load balancer 'arn:...:loadbalancer/net/ab39a131f49a44e9dbb8ac9e6887c936/5197570faae99cb6'"
15:30:36Z  Warning  SyncLoadBalancerFailed  (same)
15:30:47Z, 15:31:08Z, 15:31:49Z, 15:33:10Z, 15:35:51Z, 15:40:52Z, 15:45:53Z  (same, exponential backoff)
```

The controller EKS runs is `kubernetes/cloud-provider-aws`. In
`pkg/providers/v1/aws_loadbalancer.go` (`ensureLoadBalancerv2`, branch
`release-1.36`; `master` is the same) it indexes the listeners it finds by
**port and protocol** (`actual[port][protocol]`) and handles additions before
deletions. After the annotation patch it wants `(443, TLS)`; that key misses
the existing `(443, TCP)` listener, so the mapping is treated as an addition
and `CreateListener` is called on a port that already has a listener. The
deletion of the `TCP` listener is the next loop and is never reached. Every
retry fails the same way, forever. `ModifyListener` — which the controller
uses when the port-and-protocol key *does* match, for a certificate or policy
change — is what it would need here; it just never gets there.

**Fix (`ansible/roles/langfuse/tasks/main.yml`, committed as `bc0b725`).**
After the annotation patch the role reads the listener on the TLS port and,
unless it is already `TLS` with this certificate, calls
`aws elbv2 modify-listener --protocol TLS --certificates CertificateArn=<arn>
--ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06` itself. The Service patch
now also carries `aws-load-balancer-ssl-negotiation-policy` with that same
policy: the controller compares the listener's policy with the annotation
(empty when absent), so naming it is what makes the controller's next sync
find nothing to change. The `Find the NLB behind that hostname` lookup moved
up from the verification section so the TLS block can use the ARN. With
`tls: false` none of this runs, and the Service manifest is untouched.

```bash
scripts/play.sh --tags lf-app            # 3 min, with the fix
```

```
TASK [langfuse : Point the load balancer Service at the certificate] ***********
changed: [localhost]                                    # the policy annotation
TASK [langfuse : Read the listener on the TLS port] ****************************
ok: [localhost]
TASK [langfuse : The controller built a listener on that port] *****************
ok: [localhost] => { "msg": "All assertions passed" }
TASK [langfuse : Switch the listener to TLS with the certificate (the cloud controller cannot)] ***
changed: [localhost]
...
TASK [langfuse : Wait for the listener to terminate TLS] ***********************
ok: [localhost]
TASK [langfuse : Wait for the web node(s) to pass the NLB health check] ********
ok: [localhost] => (item=arn:...:targetgroup/k8s-langfuse-langfuse-9f3a2d5ba2/75076df78cc3436b)
TASK [langfuse : Langfuse must answer through its Service] *********************
ok: [localhost] => { "msg": "GET http://langfuse-web:3000/api/public/health -> 200" }
TASK [langfuse : Report] *******************************************************
    "url:        https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com",
    "exposure:   internal NLB ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com,
                 allowed from 10.20.0.0/16; 1 healthy target(s); answers 200 from inside the VPC;
                 TLS terminated at the NLB with a self-signed certificate -- clients trust
                 .../state/langfuse-tls-cert.pem (curl --cacert)",

PLAY RECAP *********************************************************************
localhost                  : ok=65   changed=2    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
```

The controller and the role do not fight. The patch fired one more controller
sync a second before the switch (one more `DuplicateListener` at 15:46:23Z);
its backoff retry then found `(443, TLS)` with the same certificate and
policy:

```
15:50:53Z  Normal  EnsuringLoadBalancer  Ensuring load balancer
15:50:54Z  Normal  EnsuredLoadBalancer   Ensured load balancer
```

and the listener was still `TLS` afterwards. The in-cluster soft probe
retried a few times while the switch propagated and then reported `200`
through the NLB (the `answers 200 from inside the VPC` above).

## 3. What `--tags lf-app` ends with (AC1)

```
$ aws elbv2 describe-listeners --load-balancer-arn arn:...:loadbalancer/net/ab39a131f49a44e9dbb8ac9e6887c936/5197570faae99cb6 \
    --query 'Listeners[].[Port,Protocol,SslPolicy,Certificates[0].CertificateArn]' --output text --profile sa --region us-east-1
443	TLS	ELBSecurityPolicy-TLS13-1-2-2021-06	arn:aws:acm:us-east-1:<YOUR_ACCOUNT_ID>:certificate/fb5f3e91-df19-4a04-9e87-f75a7878d7f4

$ kubectl get service langfuse-lb -n langfuse -o jsonpath='{.metadata.annotations}'     # the ssl keys
service.beta.kubernetes.io/aws-load-balancer-ssl-cert: arn:aws:acm:us-east-1:<YOUR_ACCOUNT_ID>:certificate/fb5f3e91-df19-4a04-9e87-f75a7878d7f4
service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
service.beta.kubernetes.io/aws-load-balancer-ssl-ports: 443

$ aws acm describe-certificate --certificate-arn arn:aws:acm:...:certificate/fb5f3e91-...   (Name=clickhouse-private-langfuse-lb)
Status ISSUED, Type IMPORTED, RSA-2048 / SHA256WITHRSA, Subject CN=langfuse,
SAN ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com, NotAfter 2028-12-17,
InUseBy [arn:...:loadbalancer/net/ab39a131f49a44e9dbb8ac9e6887c936/5197570faae99cb6]

$ openssl x509 -in state/langfuse-tls-cert.pem -noout -ext subjectAltName -subject -issuer -dates
X509v3 Subject Alternative Name:
    DNS:ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com
subject=CN=langfuse
issuer=CN=langfuse
notBefore=Sep 14 15:30:25 2026 GMT
notAfter=Dec 17 15:30:25 2028 GMT                    # 825 days

$ ls -l state/langfuse-tls-*
-rw-r--r--  1237 state/langfuse-tls-cert.pem
-rw-------  1704 state/langfuse-tls-key.pem

$ kubectl exec -n langfuse deploy/langfuse-web -- sh -c 'echo $NEXTAUTH_URL'
https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com
```

## 4. https end to end (AC2)

The NLB is `internal` (sources `10.20.0.0/16`), and this laptop is not in the
VPC: both curls below time out from here (`curl: (28)`), as the 2026-09-11 run
already found for the plain-HTTP NLB. So the client-side proof ran from
inside the VPC, in a ClickHouse Keeper pod: it has `curl 7.81.0`, and Keeper
nodes never carry a web pod, so there is no NLB hairpin. The (public)
certificate was copied in over `kubectl exec` stdin.

```
$ kubectl exec -i -n ns-default-us-01 c-default-us-01-keeper-0 -- sh -c 'cat > /tmp/langfuse-ca.pem' < state/langfuse-tls-cert.pem
$ kubectl exec -n ns-default-us-01 c-default-us-01-keeper-0 -- \
    curl --cacert /tmp/langfuse-ca.pem --write-out '\nHTTP %{http_code}  ssl_verify_result=%{ssl_verify_result}\n' \
    https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com/api/public/health
{"status":"OK","version":"4.25.0"}
HTTP 200  ssl_verify_result=0

$ kubectl exec -n ns-default-us-01 c-default-us-01-keeper-0 -- \
    curl https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com/api/public/health
curl: (60) SSL certificate problem: self-signed certificate
command terminated with exit code 60

$ ... curl --verbose --cacert /tmp/langfuse-ca.pem ...        # the handshake
SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256
subject: CN=langfuse
subjectAltName: host "ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com"
                matched cert's "ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com"
issuer: CN=langfuse
SSL certificate verify ok.
< HTTP/1.1 200 OK
```

With the CA: 200 over TLS 1.3, hostname matched against the SAN. Without it:
curl refuses the connection — the certificate is not publicly trusted and
nothing bypasses verification.

**The smoke script**, from the laptop:

```bash
scripts/langfuse-smoke.sh
```

```
==> Reaching Langfuse
  load balancer (internal NLB): https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com
  TLS: trusting the role's self-signed certificate at .../state/langfuse-tls-cert.pem
  [warn] https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com does not answer /api/public/health from here (VPN? security group?)
  forwarding localhost:3000 -> svc/langfuse-web:3000 in langfuse
  [ ok ] health check passed through the port-forward

==> Posting a trace
  [ ok ] accepted trace 027c0fb2c2c7f51bc59c5801fbf88239 (name smoke-20260914-155230) with one generation
  [ ok ] API returns the trace: traceId=027c0fb2c2c7f51bc59c5801fbf88239 observations=2 (GENERATION, SPAN)

==> Reading it back from ClickHouse (langfuse database)
   ┌─trace_id─────────────────────────┬─span_id──────────┬─name──────────────────┬─type───────┐
1. │ 027c0fb2c2c7f51bc59c5801fbf88239 │ 3d7d25255530aded │ smoke-20260914-155230 │ SPAN       │
2. │ 027c0fb2c2c7f51bc59c5801fbf88239 │ 4eb72e73775dadd9 │ answer                │ GENERATION │
   └──────────────────────────────────┴──────────────────┴───────────────────────┴────────────┘
==> Done
  [ ok ] trace 027c0fb2c2c7f51bc59c5801fbf88239 went in through the API and came back out of ClickHouse Private
```

The script did what task 2 built: it derived the https address from `tls:
true`, chose `--cacert state/langfuse-tls-cert.pem` for it, could not reach
the internal NLB from off the VPC, and fell back to the plain-http
port-forward (resetting the CA) — trace `027c0fb2c2c7f51bc59c5801fbf88239`.
To run its https path where the NLB answers, its exact requests were replayed
from the Keeper pod: the same OTLP/JSON body (built with the script's `jq`
program), the credential in a `curl --config -` file on `kubectl exec` stdin
(never in argv), `--cacert` the state certificate, then the same
`GET /api/public/v2/observations` poll, then the same `ch-client.sh -q`
query from the laptop:

```
trace_id=3b1410f2a21de3c7187aa1305ebd6676  name=smoke-https-20260914-155334

POST https://ab39a131f49a44e9dbb8ac9e6887c936-5197570faae99cb6.elb.us-east-1.amazonaws.com/api/public/otel/v1/traces
{"name":"otel-ingestion-job","data":{"id":"df6b4a85-611b-49a6-b392-7d6e0af300a5", ...
 "payload":{"data":{"fileKey":"events/otel/demo/2026/09/14/15/53/8a449cb6-....json","publicKey":"pk-lf-..."},
 "authCheck":{"validKey":true,"scope":{"projectId":"demo","accessLevel":"project","orgId":"demo"}}, ...
HTTP 200

GET https://.../api/public/v2/observations?traceId=3b1410f2a21de3c7187aa1305ebd6676&limit=10     # 2nd poll
traceId=3b1410f2a21de3c7187aa1305ebd6676 observations=2 (SPAN, GENERATION)

$ scripts/ch-client.sh -q "SELECT trace_id, span_id, name, type FROM langfuse.events_core FINAL WHERE trace_id = '3b1410f2a21de3c7187aa1305ebd6676' ORDER BY start_time FORMAT PrettyCompact"
   ┌─trace_id─────────────────────────┬─span_id──────────┬─name────────────────────────┬─type───────┐
1. │ 3b1410f2a21de3c7187aa1305ebd6676 │ 23f6c429e97f3406 │ answer                      │ GENERATION │
2. │ 3b1410f2a21de3c7187aa1305ebd6676 │ 61311ee055881877 │ smoke-https-20260914-155334 │ SPAN       │
   └──────────────────────────────────┴──────────────────┴─────────────────────────────┴────────────┘
```

Two traces, one over the tunnel and one over https through the TLS listener,
both readable from the API and from `langfuse.events_core`.

## 5. Idempotency (AC3)

```bash
scripts/play.sh --tags lf-app            # 29 s
```

```
TASK [langfuse : Generate the key and the self-signed certificate (missing, or naming another hostname)] ***
skipping: [localhost]                                   # SAN names the current hostname
TASK [langfuse : Import the certificate into ACM (or find it there)] ***********
ok: [localhost]                                         # same body, same ARN
TASK [langfuse : Point the load balancer Service at the certificate] ***********
ok: [localhost]
TASK [langfuse : Switch the listener to TLS with the certificate (the cloud controller cannot)] ***
skipping: [localhost]                                   # already TLS with this certificate
TASK [langfuse : Wait for the listener to terminate TLS] ***********************
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=64   changed=0    unreachable=0    failed=0    skipped=8    rescued=0    ignored=0
```

`changed=0`, no retries anywhere: the certificate is reused, ACM reports the
existing import, the three annotations are already there, the listener is
already TLS.

## 6. Teardown (AC4)

`langfuse.enabled` set back to `false` with Langfuse still deployed
(`tls` left `true`: the ACM deletion is gated on it, see below), then the
default teardown:

```bash
scripts/down.sh --yes                    # 15 min
```

```
==> Tearing down (default): lf-app lb cluster nodes
  keeps: VPC, EKS control plane, IRSA, operator, StorageClass. ~$0.15/hr
==> down: lf-app
TASK [langfuse : Remove the load balancer Service] *****************************
changed: [localhost]
FAILED - RETRYING: [localhost]: langfuse : Delete the ACM certificate (17 retries left).
...
FAILED - RETRYING: [localhost]: langfuse : Delete the ACM certificate (4 retries left).
TASK [langfuse : Delete the ACM certificate] ***********************************
changed: [localhost]
TASK [langfuse : Uninstall the release] ****************************************
changed: [localhost]
TASK [langfuse : Remove the namespace and everything left in it] ***************
changed: [localhost]
TASK [langfuse : Teardown summary] *********************************************
    "... the ACM certificate clickhouse-private-langfuse-lb is deleted, the TLS key and certificate under state/
     are kept and re-imported by the next --tags lf-app"
localhost                  : ok=6    changed=4    unreachable=0    failed=0    skipped=22   rescued=0    ignored=0
==> down: lb        ok=5  changed=1
==> down: cluster   ok=8  changed=2  skipped=12
==> down: nodes     ok=8  changed=1  skipped=2
==> Down in 15m
  [ ok ] load balancer, cluster and node groups removed. Rebuild: scripts/up.sh --from nodes (~15 min)
```

`lf-app` first, as before. The one new step, `Delete the ACM certificate`,
did exactly what its bounded retry is for: the Service was gone, the NLB was
still detaching, and ACM answered `ResourceInUseException` for fourteen
attempts (about two and a half minutes) before the deletion went through.
Anything other than that error would have stopped the run right there, with
the release and namespace still in place for `down.sh` to find again.

Post-teardown, from the AWS CLI and `kubectl` (the two volume ids were
recorded from the PVs before the teardown). ACM absence the way the plan
review asked for it — `list-certificates` does not return tags, so every ARN
is enumerated and `list-tags-for-certificate` called on each:

```
$ aws acm list-certificates --query 'CertificateSummaryList[].CertificateArn' --output text | tr '\t' '\n' |
    while read -r a; do printf '%s  Name=%s\n' "${a##*/}" \
      "$(aws acm list-tags-for-certificate --certificate-arn "$a" --query 'Tags[?Key==`Name`].Value | [0]' --output text)"; done
certificates: 11                                     # 11 before the run, 12 while Langfuse was up, 11 after
fe6ea969-...  Name=None
82d87c94-...  Name=None
... (9 more, all Name=None -- other SAs' certificates, untouched)
with Name=clickhouse-private-langfuse-lb: 0

$ aws acm describe-certificate --certificate-arn arn:aws:acm:us-east-1:<YOUR_ACCOUNT_ID>:certificate/fb5f3e91-df19-4a04-9e87-f75a7878d7f4
An error occurred (ResourceNotFoundException) when calling the DescribeCertificate operation: Could not find certificate ...

namespace langfuse:                 Error from server (NotFound): namespaces "langfuse" not found
PVCs in langfuse:                   No resources found
PVs bound to langfuse/*:            0
the Langfuse NLB by ARN:            LoadBalancerNotFound
EBS vol-0955f1317a1e13cf4:          InvalidVolume.NotFound   (langfuse-redis)
EBS vol-0ce97ddec7715143c:          InvalidVolume.NotFound   (postgres-data-langfuse-postgresql-0)
EBS volumes tagged kubernetes.io/created-for/pvc/namespace=langfuse: 0
NLBs tagged kubernetes.io/cluster/clickhouse-private-eks: 0   (1 NLB in the account, another team's)
namespace ns-default-us-01:         NotFound
nodes:                              0        node groups: (none)
helm releases (all namespaces):     clickhouse-operator clickhouse-prerequisites
IRSA stack clickhouse-private-langfuse-irsa: CREATE_COMPLETE   (kept by the default plan)
state/langfuse-tls-cert.pem, state/langfuse-tls-key.pem:  kept
```

No Langfuse NLB, namespace, PVC, EBS volume or ACM certificate remained, and
the stack is at zero nodes — the `down.sh` default posture from Part 0.

**Two things to know about `tls` and teardown.** The ACM deletion runs only
when `langfuse.load_balancer.tls` is `true` at teardown time, so flip
`enabled` off but leave `tls` alone until Langfuse is gone (task 1's
evaluator noted this; the run above did it that way). And the key and
certificate under `state/` are kept like the other generated secrets: the
next `--tags lf-app` re-imports the certificate if the new NLB gets the same
hostname, or regenerates it for the new one (the SAN check), so nothing has
to be cleaned up by hand.

## 7. Where the stack was left, and what is committed

Zero nodes, no node groups, the ClickHouse and Langfuse namespaces gone; VPC,
EKS control plane, both IRSA stacks, operator, StorageClass, the two S3
buckets and the ECR images kept (~$0.15/hr). `langfuse.enabled: false`,
`langfuse.load_balancer.tls: false` and `port: 80` are the committed values
— `ansible/group_vars/all.yml` is unchanged by this run.

## Follow-ups and observations from this run

- **The controller's listener bug is not ours to fix, but it is worth
  knowing.** With the role doing the switch, the `SyncLoadBalancerFailed`
  events from the window between the annotation patch and the switch stay in
  the namespace's event log until they age out (one hour). They are
  historical, not a live problem: the `EnsuredLoadBalancer` that follows is
  the controller agreeing with the listener the role built.
- **The internal NLB is not reachable from a laptop off the VPC**, so
  `scripts/langfuse-smoke.sh` will always take the port-forward there. That
  is the script working as designed (§4); to see the https path work, run it
  from inside the VPC, or set `LANGFUSE_URL` plus `LANGFUSE_CACERT` to
  whatever alias reaches the NLB from where you are.
- **`--check` with `tls: true` and no key or certificate in `state/` fails**
  at the chmod and the ACM import's file lookup, because check mode skips the
  openssl generation (task 1's evaluator). Not exercised here; a
  `--check` after a real run is fine.
- `NEXTAUTH_URL` is https; anyone opening the address in a browser gets the
  self-signed warning once and clicks through. That is the deal a self-signed
  certificate offers: encryption, not identity.

## Commits from this run

| Commit | Change |
|---|---|
| `bc0b725` | `fix(langfuse): switch the NLB listener to TLS in the role, the cloud controller cannot change its protocol` |

Plus this report, with `langfuse.enabled`, `langfuse.load_balancer.tls` and
`port` back at their defaults.
