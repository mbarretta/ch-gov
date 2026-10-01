# Part 8 — Steps 16–18: Grafana, wired to ClickHouse as its datasource

> **What you'll learn**
>
> - How Grafana reads from your ClickHouse cluster: which pod talks to which service, as which user, and why that user is read-only.
> - Why Grafana's install needs two things Langfuse's did not: a paid image catalog login and a plugin that reaches the cluster through your own S3 bucket.
> - How to switch Grafana on, check that it works, and tear it down without leaving anything behind.
> - What the Grafana smoke test covers and what it leaves to you.
>
> **Run it:** set `grafana.enabled: true`, then run `scripts/up.sh` and `scripts/grafana-smoke.sh`. Grafana adds one small load balancer, at about $0.02 per hour.

Parts 1–5 end with a ClickHouse cluster behind a load balancer. [Part 6](part-6-langfuse.md) adds Langfuse next to it, off by default. These three steps add a second, independent optional capability, also off by default: a Grafana server with one pre-provisioned datasource pointed at the ClickHouse cluster you already built. It is there for learning and workshops, when you want to explore the data with dashboards instead of only `SELECT` statements. With the switch off, nothing else changes.

```bash
# in state/deploy-vars.yml (or ansible/group_vars/all.yml):  grafana.enabled: true
scripts/up.sh                     # Steps 1-18 in order; every step is idempotent, so re-running over a live stack is safe
scripts/grafana-smoke.sh          # check the datasource, run a real query through it
```

Grafana needs Docker Hardened Images credentials before it can install. [Part 1, Persisting your account IDs](part-1-prerequisites.md#persisting-your-account-ids-and-sso-portal-statedeploy-varsyml) shows where to put them, and [Two things Grafana needs](#two-things-grafana-needs-that-langfuse-did-not) below explains why.

---

## How Grafana reads from ClickHouse

Grafana is an open-source dashboarding and exploration UI. You point it at a data source, write or build a query, and it renders the result as a graph, a table, or a panel. It is the tool people reach for when they want to look at data visually instead of typing SQL each time.

This capability installs Grafana with **one datasource already wired up**. Before you run any steps, it helps to see the path a query takes:

```
browser ──► load balancer (NLB, port 3000) ──► Grafana pod
                                                  │  grafana-clickhouse-datasource plugin
                                                  ▼
            ClickHouse Service  c-<cluster>-server-any.<namespace>.svc  (HTTP 8123, or TLS 8443 with fips: true)
                                                  │  authenticates as the read-only user `grafana`
                                                  ▼
                                   any ClickHouse server replica
```

Three pieces make this work, and each one has its own step:

- **A ClickHouse user** named `grafana` with read access across the cluster (Step 17). Grafana reads through a read-only user because a dashboard tool has no reason to create, alter, or drop anything, and a leaked datasource password should not become an admin login.
- **The datasource plugin**, `grafana-clickhouse-datasource`, which teaches Grafana to speak ClickHouse's HTTP interface. You mirror it into your own S3 bucket (Step 16) and the pod loads it at start (Step 18).
- **Grafana itself**, installed from a Helm chart with the datasource defined as configuration (Step 18), so it exists from the first start and needs no clicking.

There is no starter dashboard, and nothing is provisioned beyond the datasource. What you build in the UI is yours, and it does not survive a pod restart, because Grafana runs with no persistent storage ([Step 18](#step-18-grafana-itself-gf-app) says why). If Langfuse is also on, the same datasource can read Langfuse's tables, because the `grafana` user's read access covers every database, `langfuse` included.

## Two things Grafana needs that Langfuse did not

Langfuse's images come from `docker.langfuse.com` and Chainguard's anonymous `cgr.dev`, and its one extra artifact is a chart. Grafana's install adds two requirements.

**DHI is a paid, authenticated catalog.** Docker Hardened Images (DHI) publishes hardened, minimal builds of common images, including Grafana's own upstream image and `awscli`. Pulling from `dhi.io` needs a Docker Hub account entitled to the catalog, unlike Chainguard's anonymous pulls. Step 2's `image_sync` logs in to `dhi.io` with `skopeo login`, passing the credential on stdin and never in a command line, the same way it handles ECR. It logs in only when an artifact in the list actually sources from `dhi.io`, so a run with Grafana off never asks for the credential. Where the credential comes from (`dhi.username` and `dhi.token` in `state/deploy-vars.yml`, or `DHI_USERNAME` and `DHI_TOKEN` in the environment) is covered once, for every optional credential the kit needs, in [Part 1, Persisting your account IDs](part-1-prerequisites.md#persisting-your-account-ids-and-sso-portal-statedeploy-varsyml).

**The ClickHouse datasource is a plugin, and the cluster is not meant to fetch it.** `grafana-clickhouse-datasource` is not baked into any image. A pod that fetched it from `grafana.com` at startup would need the cluster to reach the internet, which the airgapped design of ClickHouse Government avoids. So Step 16 mirrors one pinned, SHA256-verified copy of the plugin zip into your own S3 bucket from your machine, the same "mirror once, pull only from your own account" shape Step 2 uses for images. Step 18's pod then reaches the bucket through an IRSA-authenticated initContainer, and never reaches `grafana.com`. IRSA (IAM roles for service accounts) is the mechanism that lets a pod assume an AWS role without static keys.

## The switch, and what it changes

Everything hangs off one key, `grafana:`, the last top-level block in `ansible/group_vars/all.yml`, after `langfuse:`. Keep it last, as `langfuse:` is kept after `clickhouse:`, because the scripts read these blocks by position. The comment above the block in that file explains the constraint.

```yaml
grafana:
  enabled: false            # the switch. false = Steps 16-18 do nothing
  namespace: "grafana"
  release: "grafana"        # the chart's fullnameOverride, so also the ServiceAccount name IRSA trusts
  clickhouse_user: "grafana" # SELECT on every database and most system tables -- ease of use, not least privilege; see [Step 17](#step-17-a-read-only-clickhouse-user-gf-db)
  bucket_name: "grafana-{{ aws.target_account_id }}-{{ aws.target_region }}"
  url: ""                   # override; empty derives it from the NLB (or localhost:3000 for type none)
  load_balancer:
    type: "internal"        # none | internal | public, exactly as clickhouse.load_balancer / langfuse.load_balancer
    allowed_cidrs: []
    port: 3000               # Grafana's own default UI port
    cross_zone: true
    tls: false               # true = the NLB terminates TLS with a self-signed certificate ([TLS at the load balancer](#tls-at-the-load-balancer))
    tls_cert_days: 825
  pod: {replicas: 1, cpu: "500m", memory: "512Mi"}
  telemetry_enabled: false  # no phone-home
```

**With `enabled: false`**, the committed default, nothing observable changes. No Grafana artifact is mirrored, `up.sh` adds no steps, and `scripts/play.sh --tags grafana` skips every Grafana role. Your cluster runs only the ClickHouse namespace and, if enabled, Langfuse's.

**With `enabled: true`**, three things happen:

1. Step 2 mirrors three DHI images and one chart ([Step 2 again](#step-2-again-three-dhi-images-and-a-chart)).
2. `up.sh` appends `gf-storage gf-db gf-app` *after* Langfuse's `lf-storage lf-db lf-app`. If both are on, Langfuse's database already exists by the time Step 17 grants read access, so the grant covers `langfuse.*` in the same run.
3. `down.sh` removes Grafana after Langfuse, and both before the load balancer, the cluster, and the node groups ([Operate it: tear it down](#operate-it-tear-it-down)).

Each step has its own tag, so you can run one alone. This is an advanced use; `scripts/up.sh` runs them in order for you.

> **Advanced: run individual steps.** `scripts/play.sh` wraps the playbook with the right environment. Pass it a tag to run one step:
>
> ```bash
> scripts/play.sh --tags grafana        # Steps 16, 17, 18
> scripts/play.sh --tags gf-storage     # Step 16: bucket, IRSA role, plugin mirror
> scripts/play.sh --tags gf-db          # Step 17: the read-only ClickHouse user
> scripts/play.sh --tags gf-app         # Step 18: the Helm release, NLB, datasource
> ```

## Step 2 again: three DHI images and a chart

After you flip the switch, run the image hop again. `scripts/up.sh` does this as its first step; to run only this step:

```bash
scripts/play.sh --tags images
```

Three artifacts are new, all from `dhi.io`. The chart comes from Grafana's own plain-HTTP Helm repository (`helm/grafana` in your ECR, pushed as an OCI artifact exactly like Langfuse's chart).

| Repository | Tag | What and why |
|---|---|---|
| `grafana` | `13.2.2` | The main container. DHI's hardened "runtime" tag has no shell and no coreutils. |
| `grafana` | `13.2.2-dev` | The same version, DHI's `-dev` variant. Only the plugin-install initContainer ([Step 18](#step-18-grafana-itself-gf-app)) uses it, because that container needs a real shell. |
| `awscli` | `1.46.1-dev` | The presign initContainer ([Step 18](#step-18-grafana-itself-gf-app)). DHI's `awscli` v2 line ships no `-dev` tag with a shell, so this pins v1, whose `s3 presign` takes the same flags. |
| `helm/grafana` | `10.5.15` | The chart, from `grafana.github.io/helm-charts`. Upstream froze this chart on 2026-01-30 in favor of `grafana-community/helm-charts`, but the pinned version still installs. |

Neither `grafana_app` nor `awscli_app` carries a `fips_suffix`. DHI requires an entitled login to resolve its own tags, so these versions are the closest public equivalents of the upstream `grafana/grafana` and `amazon/aws-cli` tags, not FIPS builds. Whether that matters for your compliance target is a question this kit does not answer for you. [Learning setup vs. production](limitations.md) lists the images that are not FIPS builds, and [Part 7](part-7-fips-hardening.md) covers the rest of FIPS mode.

## Step 16: a bucket and an IRSA role (`gf-storage`)

```bash
scripts/play.sh --tags gf-storage
```

This step has the same shape as Langfuse's Step 13 (a bucket plus a CloudFormation IRSA stack), with one deliberate difference:

- **The bucket**, `grafana-<account>-<region>` (`grafana.bucket_name`), is created with AES256 default encryption and all four public-access blocks on, the same pattern every bucket in this kit uses. It holds exactly one object: the mirrored `grafana-clickhouse-datasource` plugin zip. The role fetches the zip once at a pinned version (`versions.grafana_clickhouse_plugin_version`) and checks it against a pinned SHA256 (`versions.grafana_clickhouse_plugin_sha256`). Before every upload it checks whether the object is already there, so a re-run does not fetch or upload again.
- **Unlike Langfuse's bucket, this one is deleted on teardown** (`grafana_storage_state=absent`). Langfuse's bucket holds real event data that a delete would lose. This bucket holds one artifact you can download from `grafana.com` again at any time, so deleting it loses nothing, and leaving it behind would only orphan a bucket after a disable and re-enable cycle.
- **The stack**, `clickhouse-private-grafana-irsa`, holds one IAM role. It is federated on the cluster's OIDC provider (the same one Langfuse's and ClickHouse's IRSA roles use) and restricted to `system:serviceaccount:grafana:grafana`. Its policy is the narrowest of any role in the kit: `s3:GetObject` on `plugins/*` only. It has no `ListBucket`, `Put`, or `Delete`, because the pod only ever reads one key it already knows.

At the end of the step you see a report like this:

```
TASK [grafana_storage : Report the IRSA wiring] ********************************
ok: [localhost] => {
    "msg": [
        "grafana role: arn:aws:iam::<account>:role/clickhouse-private-grafana-irsa-GrafanaS3Role-…",
        "  assumable only by system:serviceaccount:grafana:grafana",
        "  may GetObject on grafana-<account>-<region>/plugins/* only -- no ListBucket/Put/Delete"
    ]
}
```

No S3 access keys exist anywhere. The pod's ServiceAccount annotation supplies `AWS_ROLE_ARN` and a projected web-identity token, as it does for every other IRSA role in the kit.

## Step 17: a read-only ClickHouse user (`gf-db`)

```bash
scripts/play.sh --tags gf-db
```

Grafana could be handed the `default` admin account. It is not. Step 17 creates a user, `grafana`, and grants it read access across the whole cluster. That breadth is a deliberate ease-of-use choice for learning and workshops, and it is a tradeoff, not a least-privilege default. No database is created for it: this capability exists for ad-hoc exploration across whatever is in the cluster, not for a scoped application schema.

**The password travels the way Langfuse's does.** The role generates it into `state/grafana-clickhouse-password` (mode 0600) and hashes it with SHA-256 in Ansible, so the SQL carries only the hash and the plaintext never reaches `system.query_log`. Every statement runs through `kubectl exec -i` with the admin password on stdin, the same pattern as Step 14. Inside the pod, the shell exports the password as `CLICKHOUSE_PASSWORD`, which `clickhouse-client` reads itself, so it is not on the client's command line either. The one exception is the `wget` check of the Grafana user's own login: BusyBox `wget` can only take the `X-ClickHouse-Key` header as an argument, so the password is visible in that container's process list while that check runs.

**The grant is not literally `GRANT SELECT ON *.*`.** A wildcard grant fails on this cluster. The ClickHouse operator chart revokes `SELECT` on `system.zookeeper` from `default_role` itself, as deliberate hardening of Keeper's internals, and a wildcard grant needs `WITH GRANT OPTION` on every object it matches, including the one the grantor does not hold. `GRANT` has no exclusion syntax to skip a single table. So the role builds the same effective scope from the parts. It grants `SELECT` on each real database, and on each `system.*` table except `zookeeper` and `zookeeper_log`, one statement at a time:

```
GRANT SELECT ON `default`.* TO grafana
GRANT SELECT ON `langfuse`.* TO grafana        -- once Langfuse is also on
GRANT SELECT ON system.`tables` TO grafana
... (one statement per remaining database and system table; system.zookeeper and system.zookeeper_log are absent)
```

The role discovers the database and table names from ClickHouse itself, so the boundary tracks the operator's own. It skips any name that contains a backtick, because a crafted name could otherwise inject SQL into a statement that runs with the admin's credentials.

Step 17 is idempotent. A second run reports `grants: unchanged`. A database you create later is picked up the next time you run `scripts/play.sh --tags gf-db`, with no separate grant. Langfuse's database is picked up the same way the moment Langfuse is on.

```
TASK [grafana_clickhouse : Report] *********************************************
ok: [localhost] => {
    "msg": [
        "user:      grafana -- created",
        "grants:    updated -- SELECT on every database and system.* short of zookeeper (covers langfuse.* automatically when Langfuse is on)",
        "verified:  SELECT 1 as grafana over http://c-default-us-01-server-any.ns-default-us-01.svc:8123 from c-default-us-01-server-...",
        "password:  .../state/grafana-clickhouse-password (Step 18 puts it in the datasource's secureJsonData)",
        "teardown:  ansible-playbook deploy.yml --tags gf-db -e grafana_db_state=absent  (DROP USER grafana only; no database was ever created)"
    ]
}
```

The last line of the report shows the underlying playbook call. [Operate it: tear it down](#operate-it-tear-it-down) gives the `scripts/play.sh` form to use.

## Step 18: Grafana itself (`gf-app`)

```bash
scripts/play.sh --tags gf-app
```

Order matters the same way it does for Langfuse. `GF_SERVER_ROOT_URL` is baked into the pod, so the role creates the load balancer Service and reads its hostname before it installs the Helm release. The role then installs Grafana with `persistence.enabled: false` (no PVC, so a pod restart starts from the provisioned state) and one pre-provisioned datasource. Two mechanisms have no counterpart in Langfuse's install.

### The plugin initContainers, and the shell they need

The plugin cannot be baked into the image, and an airgapped cluster is not meant to fetch it from `grafana.com` ([Two things Grafana needs](#two-things-grafana-needs-that-langfuse-did-not)). Two chained initContainers load it on every pod start:

1. **`gf-plugin-presign`** (the `awscli` image) computes a short-lived presigned URL for the one S3 key Step 16 mirrored. The URL expires after five minutes. It is a purely local SigV4 signature under IRSA, with no `ListBucket` call, and the container writes it to a small shared `emptyDir`.
2. **`gf-plugin-install`** (the `grafana` image) runs `grafana cli --pluginUrl "$(cat ...)" plugins install grafana-clickhouse-datasource <version>`. It fetches that URL and unzips it with Grafana's own Go zip handling. `--pluginUrl` uses a plain Go `http.Client`, so it needs a real HTTP(S) URL. That is why the presign-and-relay step exists, instead of a shared volume holding the raw zip.

Both containers need a shell to run their `command: ["sh", "-c", ...]`. DHI's default hardened "runtime" tags ship no shell, no `busybox`, no `python3`, and no `unzip`, so both initContainers use DHI's `-dev` tags instead, `awscli:1.46.1-dev` and `grafana:13.2.2-dev`. The main Grafana container needs no shell and stays on the hardened runtime tag. Three smaller details follow from running in a locked-down image:

- `grafana cli` gets an explicit `--homepath=/usr/share/grafana`, because the image's working directory is not Grafana's homepath.
- The presign container sets `HOME=/tmp`, because the AWS CLI tries to cache an STS token under `$HOME/.aws/` even under IRSA, and the default `HOME` for uid 472 resolves somewhere unwritable.
- The main container gets a scratch `emptyDir` at `/tmp`, because Grafana 13 stages background plugin installs there on every start and the image's own `/tmp` is not writable by uid 472.

### The datasource

The datasource is provisioned as configuration, not through a dashboard or datasource sidecar, with the fixed uid `clickhouse`. The smoke test depends on that literal value:

```yaml
datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    uid: clickhouse
    jsonData: {host: c-<cluster>-server-any.<ns>.svc.cluster.local, port: 8123, secure: false, username: grafana}
    secureJsonData: {password: "<from state/grafana-clickhouse-password>"}
```

The whole entry carries a `secret:` sub-key, so the Grafana chart renders it into its own Kubernetes Secret instead of the plain ConfigMap that other provisioning keys land in. The ClickHouse password never reaches a ConfigMap.

**With `fips: true`**, the connection moves to the cluster's TLS listener on port `8443`, and the role hands the datasource the ClickHouse CA certificate directly. The plugin's own configuration schema (`tlsAuthWithCACert` and `tlsCACert`) supports that, so the role uses it. Langfuse takes a different route and mounts a CA Secret into its pod.

The admin login is a Secret of Ansible's own (`grafana-admin`), generated into `state/grafana-admin-password` and reused across runs. It has to be the value Ansible controls, not whatever Grafana would generate for itself, so it gets a Secret separate from the chart's generated ones.

### What a passing step reports

```
url:        http://<hostname>.elb.us-east-1.amazonaws.com:3000
exposure:   internal NLB <hostname>, allowed from 10.20.0.0/16; 1 healthy target(s)
login:      admin -- password in .../state/grafana-admin-password
datasource: uid clickhouse, ClickHouse Private at c-default-us-01-server-any.ns-default-us-01.svc.cluster.local:8123 (plaintext) as grafana
smoke test: scripts/grafana-smoke.sh   (checks the datasource health and a live query)
teardown:   ansible-playbook deploy.yml --tags gf-app -e grafana_state=absent   (keeps the ClickHouse user; --tags gf-db -e grafana_db_state=absent purges it)
```

The `teardown` line shows the underlying playbook call. [Operate it: tear it down](#operate-it-tear-it-down) gives the `scripts/play.sh` form to use.

Before the step reports, the role also asserts that every container in the pod, both initContainers included, pulled its image from your own ECR registry.

## Reaching it from a browser

The default exposure is an **internal** NLB. You have the same three options that [Part 6](part-6-langfuse.md) gives Langfuse:

1. A VPN or peering into the VPC. The URL in the report works as printed.
2. `type: none`, then `kubectl port-forward -n grafana svc/grafana 3000:3000` and open `http://localhost:3000`. The local port must be exactly 3000, because `GF_SERVER_ROOT_URL` is set to that address in this mode.
3. `type: public` with `allowed_cidrs` set to your own egress CIDR. The default is plain HTTP, so turn on `grafana.load_balancer.tls` ([TLS at the load balancer](#tls-at-the-load-balancer)) before you expose it this way. `0.0.0.0/0` needs `-e allow_open_internet=true`, as elsewhere in the kit.

Log in as `admin` with the password in `state/grafana-admin-password`. The kit is built around the `internal` type; see [Operate it: check that it works](#operate-it-check-that-it-works).

## TLS at the load balancer

The mechanism is the same as Langfuse's, which [Part 6](part-6-langfuse.md) explains in full. Plain HTTP is the default because the NLB is a TCP pass-through with no domain behind it. To terminate TLS at the NLB, set:

```yaml
grafana:
  load_balancer:
    tls: true               # the NLB terminates TLS
    port: 3000               # unchanged -- Grafana's UI port, not 443/80
    tls_cert_days: 825
```

`fips: true` turns this on for you, as it does for Langfuse. The effective TLS state is `tls` OR `fips` whenever `load_balancer.type` is not `none`, and under `fips: true` the NLB's negotiation policy becomes `ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04`. The role generates a self-signed certificate. It gives you encryption but not identity, because nobody vouches for it. Part 6's TLS section explains what that does and does not buy you, and none of it is Grafana-specific.

`scripts/grafana-smoke.sh` follows the same rule as Langfuse's smoke test. It trusts the role's self-signed certificate (`gf_cacert()` in `scripts/lib/common.sh`) only for the address it derived from the NLB hostname, and never uses `-k` or `--insecure`.

Grafana with `grafana.load_balancer.tls: true` uses the same code as the Langfuse TLS path, with an `internal` load balancer. See [Scope and boundaries](limitations.md).

## Operate it: check that it works

```bash
scripts/grafana-smoke.sh
```

The script needs `curl`, `jq`, and `kubectl`. It is safe to run at any time. In order, it:

1. **Finds a URL that answers**, with the same precedence as `scripts/langfuse-smoke.sh`: the `GRAFANA_URL` environment variable, then `grafana.url`, then the `grafana-lb` NLB hostname. If none answers, it falls back to a `kubectl port-forward` on `3000:3000`.
2. **Calls `GET /api/datasources/uid/clickhouse/health`** with Basic Auth (`admin` and `state/grafana-admin-password`) and asserts `status: "OK"`.
3. **Calls `POST /api/ds/query`** against that datasource with `SELECT count() AS n FROM system.tables`. This is the same path Grafana's own panels use, and it proves that the Step 17 grant reaches ClickHouse, not only that the health ping succeeded.
4. **When Langfuse is also `enabled`**, runs a third query against `langfuse.events_core`. It proves the same grant reaches Langfuse's database, with no grant of its own.

The admin credential never enters a shell variable or a command line. The script writes it into a mode-0600 curl config under a private temporary directory and hands it to curl as `--config -` on stdin, so `bash -x` shows only file paths.

```
==> Checking the ClickHouse datasource
  [ ok ] datasource uid=clickhouse is healthy: Data source is working
==> Querying system.tables through the datasource
  [ ok ] SELECT count() FROM system.tables = <n>
==> Querying langfuse.events_core (blanket GRANT SELECT ON *.* reach check)
  [ ok ] SELECT count() FROM langfuse.events_core = <n>
```

The last query appears only when Langfuse is on, and its count is `0` until Langfuse has received a trace.

**What the smoke test covers, and what it does not.** It checks that the datasource is healthy and that live queries return data. It does not check dashboards, alerting, or user management. The `type: public` load balancer and `grafana.load_balancer.tls: true` are outside what the smoke test checks. [Scope and boundaries](limitations.md) collects these boundaries for the whole kit.

## Idempotency and check mode

To re-run all three steps over a deployed stack:

```bash
scripts/play.sh --tags gf-storage,gf-db,gf-app
```

A second run reports `changed=0` for the bucket, the IRSA stack, and the per-database grants, because they converge on the state that already exists. The Helm release also reports `changed=0`, because its values are identical.

## Cost

Grafana adds no instances. Like Langfuse, it lands on the operator node group that Step 5 already pays for, and it has no PVC, so there is no volume charge. Its own cost is one more NLB, about $0.02 per hour, matching Langfuse's, plus the plugin bucket, which holds one small zip and costs effectively nothing. The floor with the nodes down stays at about $0.15 per hour. A default `down.sh` keeps the Grafana IRSA stack and the bucket the way it keeps Langfuse's and ClickHouse's, and neither costs anything while idle.

## Operate it: tear it down

Grafana holds no data of its own that depends on the ClickHouse cluster being reachable, because it has no PVC and no database. Its ordering constraint is looser than Langfuse's. Both still have to finish before the load balancer, the cluster, and the node groups go. `down.sh` keeps `lf-app` first in its default plan, which matches the order the steps install in, and removes Grafana second:

```bash
scripts/down.sh          # lf-app, gf-app, lb, cluster, nodes
scripts/down.sh --all    # + lf-db, gf-db, lf-storage, gf-storage, and everything below them
```

- **Only what exists is torn down.** `gf-app` stays in the plan only if `helm status`, the `grafana-lb` Service, or the `grafana` namespace shows something to remove. The check ignores the `enabled` flag, so a Grafana you deployed and then disabled is still removed.
- **The switch can already be off.** `deploy.yml` gates each role on `enabled` OR the teardown-state variable, so setting `enabled` back to `false` never orphans a deployed release.
- **`gf-db` is the data-purge switch and is not in the default plan**, for the same reason Langfuse's `lf-db` is not. A default teardown removes the whole ClickHouse cluster anyway, so "keep the cluster, drop only the Grafana user" should be an explicit command.

To remove one layer and keep the rest:

```bash
scripts/play.sh --tags gf-app -e grafana_state=absent            # NLB Service, (with tls) the ACM certificate, release, namespace. Keeps the ClickHouse user
scripts/play.sh --tags gf-db -e grafana_db_state=absent          # DROP USER IF EXISTS grafana. No database to drop -- one was never created
scripts/play.sh --tags gf-storage -e grafana_storage_state=absent  # the IRSA stack AND the plugin-mirror bucket -- both deleted ([Step 16](#step-16-a-bucket-and-an-irsa-role-gf-storage))
```

**Unlike every other bucket in this kit, `gf-storage`'s teardown deletes the bucket.** The plugin zip can be downloaded from `grafana.com` again at any time, so there is nothing to lose. Bringing the step back creates both the bucket and a fresh IRSA stack (a new role-name suffix, the same trust policy). No `state/` file is needed, because the plugin bucket carries no secrets.

The `state/` files ([What exists once it is up](#what-exists-once-it-is-up)) survive a default teardown. A `scripts/down.sh` followed by `scripts/up.sh --from nodes` reuses them, so the rebuilt Grafana accepts the same admin login and the same ClickHouse credential. The [limitations page](limitations.md) notes this behavior for Langfuse as well.

## What exists once it is up

```
namespace grafana
  deployment    grafana                       1 pod, plugin loaded by two initContainers on every start
  service       grafana                       ClusterIP :3000 -- the port-forward target
  service       grafana-lb                    type LoadBalancer -> the NLB (absent when type is none; ssl annotations when tls is true)
  serviceaccount grafana                      carries the IRSA role annotation
  secrets       grafana-admin                 (Ansible) -- admin-user / admin-password
                grafana-config-secret         (chart) -- holds the datasource's password (and, under fips, its CA)

ClickHouse   user grafana, SELECT on every database + system.* short of zookeeper (covers langfuse.* automatically when Langfuse is on)
AWS          bucket grafana-<account>-<region>; stack clickhouse-private-grafana-irsa; one NLB; with tls, one ACM certificate tagged Name=clickhouse-private-grafana-lb
```

In `state/`, next to the ClickHouse and Langfuse files:

| File | What |
|---|---|
| `grafana-clickhouse-password` | The `grafana` ClickHouse user's password (Step 17) |
| `grafana-admin-password` | The `admin` login (Step 18) |
| `grafana-tls-key.pem`, `grafana-tls-cert.pem` | With `tls`: the NLB's private key (0600) and its self-signed certificate, which is also the CA file clients trust. Regenerated only when the NLB hostname changes |

If you lose `state/`, you lose these files. Protect and back it up as you would any secret store.

## Troubleshooting

**Step 2 stops with `An artifact sources from dhi.io but the DHI username/token are empty or still a <...> placeholder`.**
Cause: Grafana is on, and neither `dhi.username` and `dhi.token` in `state/deploy-vars.yml` nor `DHI_USERNAME` and `DHI_TOKEN` in the environment is set. Fix: set them as [Part 1, Persisting your account IDs](part-1-prerequisites.md#persisting-your-account-ids-and-sso-portal-statedeploy-varsyml) shows, using an account entitled to the DHI catalog, then re-run `scripts/up.sh`.

**The Grafana pod stays in `Init` and an initContainer fails before it does any work.**
Cause: an initContainer image has no shell. The hardened runtime tags of both DHI images ship none, and the initContainers start with `sh -c`. Fix: keep `versions.grafana_app_dev` and `versions.awscli_app` on `-dev` tags, and keep `versions.grafana_app` on the runtime tag for the main container. To read an initContainer's log, run `kubectl logs -n grafana deploy/grafana -c gf-plugin-presign` or `-c gf-plugin-install`. The role prints the same tails when the rollout fails.

**`gf-plugin-presign` fails with `Permission denied: '/.aws'`, or `gf-plugin-install` cannot find Grafana's home directory.**
Cause: the container's default `HOME` is unwritable for uid 472, and `grafana cli` does not know where Grafana lives in the DHI image. Fix: the role sets `HOME=/tmp` on the presign container and `--homepath=/usr/share/grafana` on the install command. If you change either container, keep both.

**`scripts/grafana-smoke.sh` stops with `something already listens on localhost:3000; stop it or set GRAFANA_URL`.**
Cause: the load balancer is `internal` and does not answer from your machine, so the script falls back to a port-forward on the fixed local port 3000, and another process holds that port. Fix: stop that process, or set `GRAFANA_URL` to an address you can reach (a VPN alias or an SSH tunnel).

**The smoke test warns `does not answer /api/health from here (VPN? security group?)`.**
Cause: an `internal` load balancer answers only from inside the VPC or over a VPN. Fix: none is needed for the script, which carries on through a port-forward. To use the UI from your machine, use the port-forward or VPN options in [Reaching it from a browser](#reaching-it-from-a-browser).

**A database you created does not appear in Grafana, or a query returns an access error.**
Cause: the `grafana` user's read access is granted per database, and a database created after Step 17 ran has no grant yet. Fix: run `scripts/play.sh --tags gf-db`. The step is idempotent and picks up every current database.

**A manual `GRANT SELECT ON *.* TO grafana` fails.**
Cause: the operator's `default_role` has `SELECT` on `system.zookeeper` revoked, and a wildcard grant needs grant option on every object it matches ([Step 17](#step-17-a-read-only-clickhouse-user-gf-db)). Fix: do not grant by wildcard. Run `scripts/play.sh --tags gf-db` and let the role build the grants from the parts.

## Check yourself

Run these in order after `source scripts/env.sh`. Each shows a command and what you should see, and the checks double as exercises for a workshop. Checks 2 to 7 assume `grafana.enabled: true` and a finished `scripts/up.sh`.

1. **With the switch off, nothing Grafana exists.** Set `grafana.enabled: false` on a fresh stack, then run:

   ```bash
   kubectl get ns
   ```

   You should not see a `grafana` namespace. `scripts/play.sh --tags grafana` skips every Grafana role.

2. **Step 2 mirrored the DHI images and the chart.**

   ```bash
   aws ecr describe-images --repository-name grafana --region <target_region> --query 'imageDetails[].imageTags[]' --output text
   ```

   You should see `13.2.2` and `13.2.2-dev`. Repeat with `--repository-name awscli` for `1.46.1-dev`, and with `helm/grafana` for `10.5.15`.

3. **The plugin mirror bucket exists with one object.**

   ```bash
   aws s3 ls "s3://grafana-<account>-<region>/plugins/"
   ```

   You should see one file, `grafana-clickhouse-datasource-4.21.3.zip`.

4. **The `grafana` user is read-only and excludes `system.zookeeper`.**

   ```bash
   scripts/ch-client.sh -q "SHOW GRANTS FOR grafana" | grep -Ec 'system\.`?zookeeper`? TO'
   ```

   You should see `0`. Without the `grep`, the output lists one `GRANT SELECT` line per database and system table, and nothing but `SELECT`. Tables whose names only contain `zookeeper`, such as `zookeeper_connection`, can appear in that list.

5. **The pod is up and the plugin loaded.**

   ```bash
   kubectl get pods -n grafana
   kubectl logs -n grafana deploy/grafana -c gf-plugin-install
   ```

   You should see one `grafana` pod `Running` and `1/1` ready. The install log shows `grafana-clickhouse-datasource` being installed without errors.

6. **The smoke test passes.**

   ```bash
   scripts/grafana-smoke.sh
   ```

   You should see `[ ok ]` for the datasource health and the `system.tables` count, and, with Langfuse on, for the `langfuse.events_core` count. The exit status is `0`.

7. **A second run changes nothing.**

   ```bash
   scripts/play.sh --tags gf-storage,gf-db,gf-app
   ```

   You should see `changed=0` in the play recap.

8. **Teardown removes Grafana even with the switch off.** Set `grafana.enabled: false` while Grafana is still deployed, then run:

   ```bash
   scripts/down.sh
   ```

   The `Tearing down (default):` line lists `gf-app` among the steps, right after `lf-app` if Langfuse is deployed. Answer `n` at the prompt to stop there, or `y` to tear the stack down.

Discussion questions for a workshop:

- Why does the Grafana plugin travel through your S3 bucket and a presigned URL instead of a volume or a download from `grafana.com`?
- Which choice in Step 17 trades least privilege for convenience, and what would you change for production?
- Why is the Grafana bucket deleted on teardown when Langfuse's is kept?
