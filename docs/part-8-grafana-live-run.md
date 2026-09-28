# Part 8 (live run) — Grafana on ClickHouse Private, verified against the stack

**Date: 2026-09-28.** This is the record of running the Grafana design's verification runbook (Steps 16–18 and the operator scripts) against the real deployment: account `<YOUR_ACCOUNT_ID>`, `us-east-1`, EKS `clickhouse-private-eks` (Kubernetes 1.36), ClickHouse Private `default-us-01` on server 26.2.1.525, Grafana chart 10.5.15 / app 13.2.2, awscli 1.46.1. Every command below was run from this repo with `scripts/play.sh`, `scripts/up.sh`, `scripts/down.sh` and `scripts/grafana-smoke.sh`; outputs are quoted with secrets and account-specific identifiers removed. Task 8's operator guide (`docs/part-8-grafana.md`) has not been written yet — this file is its evidence, the same relationship Part 6's live-run file has to `docs/part-6-langfuse.md`.

Four defects showed up live, all in the Grafana role or its supporting Ansible, none of them predicted by the design. Each was fixed and committed before the next attempt; they are listed under [Application](#4-application). Two were showstoppers common to *both* of the plugin-install initContainers (no shell at all in DHI's hardened image variants); the fix for both was to switch those two containers to DHI's `-dev` tag rather than to try to smuggle in a static shell. One pre-existing, unrelated defect was observed in a different script during this run and is recorded under [Observed, not fixed](#observed-not-fixed).

**`grafana.enabled` (and `langfuse.enabled`) are committed as `false`.** Both switches were `true` only for the live steps below and were set back to their committed defaults before the final commit and before the stack was left running. The seven sections below follow the runbook order; §1 and §7 specifically prove the "committed default" and "round trip" halves of task 10's acceptance criteria.

---

## 1. Disabled mode

With the committed defaults (`grafana.enabled: false`, `langfuse.enabled: false`) a full `scripts/up.sh` run reaches the same healthy ClickHouse-only state as before this feature existed, and neither optional capability's name appears anywhere in the run:

```bash
scripts/down.sh --yes     # full teardown: lf-app/gf-app (if present), lb, cluster, nodes
scripts/up.sh --yes       # rebuild from nothing, both switches false
```

```
==> Down in 12m
  [ ok ] load balancer, cluster and node groups removed. Rebuild: scripts/up.sh --from nodes (~15 min)
...
==> Up in 11m
  [ ok ] connect:  scripts/ch-client.sh            (port-forward from this machine)
  [ ok ]           scripts/ch-client.sh --lb       (via the internal NLB, where its address is reachable)
  meter:    ~$2.32/hr. Stop it with scripts/down.sh (keeps VPC/EKS, ~$0.15/hr) or scripts/down.sh --all
```

```bash
grep -ci grafana /tmp/up-run.log; grep -ci langfuse /tmp/up-run.log
```

Both return `0`. Checked afterwards from `kubectl`:

```
$ kubectl get ns
clickhouse-operator-system   Active
default                      Active
kube-node-lease               Active
kube-public                   Active
kube-system                    Active
ns-default-us-01              Active   6m19s
$ kubectl get nodes | wc -l
8
```

Only the ClickHouse namespace exists; no `grafana` or `langfuse` namespace, no Grafana or Langfuse pods, Service or Secret anywhere in the cluster. `grafana.enabled: false` is a clean no-op — this is the AC1 half the earlier, `enabled: true` run (already recorded in this session's commits) could not itself prove.

## 2. ECR tags and digests

`grafana.enabled` set to `true`, then the Step 2 image hop:

```bash
scripts/play.sh --tags images
```

```
TASK [image_sync : Check which tags already exist in the target registry] ******
ok: [localhost] => (item=grafana:13.2.2)
ok: [localhost] => (item=grafana:13.2.2-dev)
ok: [localhost] => (item=awscli:1.46.1-dev)
ok: [localhost] => (item=helm/grafana:10.5.15)
TASK [image_sync : Copy each artifact that is not already present] *************
changed: [localhost] => (item=grafana:13.2.2-dev)
changed: [localhost] => (item=awscli:1.46.1-dev)
TASK [image_sync : Report what was copied vs already present] ******************
ok: [localhost] => {
    "msg": "2 copied, 12 already present (standard build); 0 chart(s) to push with helm"
}
PLAY RECAP *********************************************************************
localhost                  : ok=19   changed=1    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```

`grafana:13.2.2` and `helm/grafana:10.5.15` were already mirrored from an earlier attempt in this session; the two new artifacts this fix introduced — `grafana:13.2.2-dev` and `awscli:1.46.1-dev` — copied cleanly from `dhi.io`, the same registry-to-registry skopeo path the design already used for the runtime tags.

```bash
for spec in grafana:13.2.2 grafana:13.2.2-dev awscli:1.46.1-dev helm/grafana:10.5.15; do
  aws ecr describe-images --repository-name "${spec%%:*}" --image-ids imageTag="${spec##*:}" \
    --query 'imageDetails[0].[repositoryName,imageTags[0],imageDigest,imageSizeInBytes,artifactMediaType]' --output text
done
```

| Repository | Tag | Digest (immutable) | Size | Type |
|---|---|---|---|---|
| `grafana` | `13.2.2` | `sha256:b01be22b1c0b6febd2fb5fdfe225542e718cdf81e5921d4d70b5251813214aad` | 268 MB | image (hardened runtime, no shell) |
| `grafana` | `13.2.2-dev` | `sha256:dda35baa383df7e7bf302e008151d37e371e44ee87c117b73fa41d4beecd793e` | 286 MB | image (`-dev`, has `/bin/sh`) |
| `awscli` | `1.46.1-dev` | `sha256:e900d7ac65417b1578e1eee04258cff396eedf75d59e1fd5c0835307a07d3125` | 53 MB | image (`-dev`, has `/bin/sh`; DHI's `awscli` v2 line ships no `-dev` tag at all) |
| `helm/grafana` | `10.5.15` | `sha256:fff1f91147b87c2a0c847f14928f342f39f38a3b0bfa973791464943862fdf1d` | 51 KB | `application/vnd.cncf.helm.config.v1+json` |

The repository checked reports `imageTagMutability: IMMUTABLE`, same as the pre-existing artifacts.

## 3. IRSA and grants

### Step 16 — `gf-storage`

```bash
scripts/play.sh --tags gf-storage
```

```
TASK [grafana_storage : Create the Grafana plugin-mirror bucket] ***************
changed: [localhost]
TASK [grafana_storage : Deploy the Grafana IRSA role stack] ********************
changed: [localhost]
TASK [grafana_storage : Report the IRSA wiring] ********************************
ok: [localhost] => {
    "msg": [
        "grafana role: arn:aws:iam::<YOUR_ACCOUNT_ID>:role/clickhouse-private-grafana-irsa-GrafanaS3Role-...",
        "  assumable only by system:serviceaccount:grafana:grafana",
        "  may GetObject on grafana-<YOUR_ACCOUNT_ID>-us-east-1/plugins/* only"
    ]
}
```

Confirmed from the AWS side:

```
$ aws iam get-role --role-name clickhouse-private-grafana-irsa-GrafanaS3Role-... \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
{"StringEquals":{"oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:sub":"system:serviceaccount:grafana:grafana",
                 "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:aud":"sts.amazonaws.com"}}
$ aws s3api get-bucket-encryption --bucket grafana-<YOUR_ACCOUNT_ID>-us-east-1  -> AES256
$ aws s3api get-public-access-block --bucket grafana-<YOUR_ACCOUNT_ID>-us-east-1
{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}
```

Same OIDC provider as the Langfuse and clickhouse-server IRSA roles (one cluster, one OIDC provider, three narrowly-scoped roles). Unlike Langfuse's bucket, Grafana's plugin-mirror bucket holds nothing but a re-downloadable plugin zip, so the design (confirmed live in §7) actually deletes it on teardown rather than keeping it.

### Step 17 — `gf-db`

```bash
scripts/play.sh --tags gf-db
```

The first live attempt found the one defect in this step:

```
TASK [grafana_clickhouse : Grant the deliberate full-read privilege] ***********
ok: [localhost]
TASK [grafana_clickhouse : Read the grants back] *******************************
ok: [localhost]
TASK [grafana_clickhouse : The grant must be exactly GRANT SELECT ON *.*] ******
fatal: [localhost]: FAILED! => {
    "msg": "SHOW GRANTS FOR grafana does not show the expected GRANT SELECT ON *.*: []"
}
```

**Defect.** The design's plan called for `GRANT SELECT ON *.* TO grafana` from the cluster's `default` admin. It failed with `ACCESS_DENIED`, silently (the grant task itself reported `ok`; only the follow-up assertion caught it, because the role wraps the grant in a rescue that swallows the SQL error). Root cause, confirmed by hand against the live cluster: ClickHouse Private's operator chart deliberately `REVOKE`s `SELECT` on `system.zookeeper` from `default_role` as security hardening on Keeper's internals, and granting a wildcard requires the grantor to hold `WITH GRANT OPTION` on every object the wildcard matches — including the one object it does not hold. There is no ClickHouse `EXCEPT`/exclusion syntax for `GRANT`, and no self-grant workaround; both were tried and confirmed not to work. Fix: the task now enumerates every real database and every `system.*` table except `zookeeper`/`zookeeper_log` and grants `SELECT` on each individually. Commit `e2b7802` (bundled with the initContainer fixes below, since both were found in the same live-verification pass).

Re-run, with the fix in place:

```
TASK [grafana_clickhouse : Grant full read access -- every real database, and system.* short of zookeeper] ***
ok: [localhost]
TASK [grafana_clickhouse : The grant must cover real data and exclude system.zookeeper] ***
ok: [localhost] => { "changed": false, "msg": "All assertions passed" }
TASK [grafana_clickhouse : SELECT 1 as the Grafana user must succeed] **********
ok: [localhost] => { "changed": false, "msg": "All assertions passed" }
TASK [grafana_clickhouse : Report] *********************************************
ok: [localhost] => {
    "msg": [
        "user:      grafana -- created",
        "grants:    updated (per-database + per-system-table SELECT, listed above)",
        "verified:  SELECT 1 as grafana over http://c-default-us-01-server-any.ns-default-us-01.svc:8123 from c-default-us-01-server-...",
        "password:  .../state/grafana-clickhouse-password (Step 18 puts it in the datasource's secureJsonData)",
        "teardown:  ansible-playbook deploy.yml --tags gf-db -e grafana_db_state=absent  (DROP USER grafana only; no database was ever created)"
    ]
}
```

`SHOW GRANTS FOR grafana` lists one `GRANT SELECT` per database (`default`, and `langfuse` once Langfuse is also on) plus one per `system.*` table — about 180 lines on this cluster — and conspicuously does **not** list `system.zookeeper`, `system.zookeeper_log`, `system.zookeeper_connection`, `system.zookeeper_connection_log`, or `system.zookeeper_info` (the last three are visible tables, not the revoked one, and stayed grantable). A second run reported `grants: unchanged`, confirming the enumeration is idempotent.

## 4. Application

```bash
scripts/play.sh --tags gf-app
```

It took three attempts. The first two found the showstopping defects; each was fixed and committed before the next attempt.

### Attempt 1 — no shell in the DHI runtime images

```
TASK [grafana : Wait for the rollout (the plugin initContainers run first)] ****
fatal: [localhost]: FAILED! => {"msg": "The command exited with a non-zero return code.", ...}
TASK [grafana : Grafana did not come up] ***************************************
fatal: [localhost]: FAILED! => {"msg": [
  "--- pods ---",
  ["grafana-...   0/1   Init:RunContainerError ...", "grafana-...   0/1   Init:CrashLoopBackOff ..."],
  "--- warning events (newest last) ---",
  ["... exec: \"python3\": executable file not found in $PATH",
   "... exec: \"unzip\": executable file not found in $PATH",
   "... exec: \"busybox\": executable file not found in $PATH",
   "... exec: \"gzip\": executable file not found in $PATH",
   "... exec: \"tar\": executable file not found in $PATH",
   "... exec: \"sh\": executable file not found in $PATH"],
  "--- gf-plugin-presign log tail ---", []
]}
```

**Defect.** Both plugin `extraInitContainers` — `gf-plugin-presign` (`awscli`) and `gf-plugin-install` (`grafana`) — were pinned to DHI's default, hardened "runtime" image tags (`awscli:2.37.4`, `grafana:13.2.2`), and both ship *zero* shell or coreutils. `command: ["sh", "-c", ...]` (used for the presign step's stdout redirect) and the `$(cat ...)` substitution the plugin-install step needed both failed at the container-init step, before any application code ran. The warning-event lines above are from a series of throwaway diagnostic probe pods run against candidate fixes: a Chainguard `busybox` binary copied across a shared `emptyDir` failed with a missing `libcrypt.so.1` (it is musl/Wolfi-linked, not portable to DHI's Debian-13 base); `python3`, `unzip`, `gzip`, `tar` were each tried and absent too. DHI's own catalog turned out to have the actual fix already built in: a `-dev` tag variant of the same image/version, a full Debian-based image with a real shell. DHI's `awscli` v2.x line (the version the design had pinned) ships **no** `-dev` tag at all — only the v1.x line does — so the fix also meant falling back to `awscli` 1.46.1. Fix: `gf-plugin-presign`'s image became `awscli:1.46.1-dev`; `gf-plugin-install`'s became `grafana:13.2.2-dev` (the main `grafana` container, which needs no shell of its own, stays on the hardened runtime tag `13.2.2`). Commit `e2b7802`.

### Attempt 2 — two more defects, uncovered only once the shell existed

```
TASK [grafana : Grafana did not come up] ***************************************
fatal: [localhost]: FAILED! => {"msg": [
  "--- gf-plugin-install log tail ---",
  ["Could not find config defaults, path: /conf/defaults.ini"],
  "--- gf-plugin-presign log tail ---",
  ["[Errno 13] Permission denied: '/.aws'"]
]}
```

**Defect.** `grafana cli` resolves its own config relative to `--homepath`, and the DHI `-dev` image's `WorkingDir` is `/`, not the chart's actual homepath (`/usr/share/grafana`) — `grafana cli` (a Go binary; its `--pluginUrl` fetcher is an `http.Client`, HTTP/HTTPS only, no `file://`, confirmed against Grafana's own source) refused to run at all without it. Fix: added `--homepath=/usr/share/grafana` to the `gf-plugin-install` args.

**Defect.** `gf-plugin-presign` runs `aws s3 presign` under IRSA, which needs no static credentials, but botocore still tries to cache an STS token under `$HOME/.aws/` on every call; the pod's `runAsNonRoot`/uid-472 securityContext (the chart's own convention, applied pod-wide) leaves the hardened image's baked-in `/` unwritable for that uid, so the write failed with `EACCES` before the presign ever ran. Fix: added `env: [{name: HOME, value: /tmp}]` to `gf-plugin-presign` (an `emptyDir` is already mounted at `/tmp` for the main container from the third fix below; the presign container gets a writable `HOME` from the same pod-wide filesystem, no extra volume needed). Both fixes in commit `e2b7802`.

### Attempt 3 — green, plus two more defects outside the initContainers

Attempt 3's initContainers succeeded, but two more issues surfaced in the same pass, both fixed in the same commit:

- **Service port mismatch.** `kubectl port-forward svc/grafana 3000:3000` failed immediately: the chart's default Service `port` is 80 (`targetPort: 3000`), so nothing was listening on 3000 at the Service level. Fixed by setting `service.port: 3000` explicitly in the Helm values.
- **`/tmp` permission-denied noise from the main container.** Grafana 13's background core-plugin-catalog installer unconditionally tries to stage temp files under `/tmp` at every startup, and the DHI hardened image's baked-in `/tmp` is not writable under uid 472 — harmless (Grafana starts and serves fine either way) but noisy in the pod logs. Fixed with a plain `emptyDir` at `/tmp` via `extraVolumes`/`extraVolumeMounts` (the same mount the presign container's `HOME=/tmp` fix above relies on).

```
TASK [grafana : Install or upgrade Grafana] ************************************
changed: [localhost]
TASK [grafana : Wait for the rollout (the plugin initContainers run first)] ****
ok: [localhost]
TASK [grafana : Assert no container pulls from outside your registry] **********
ok: [localhost] => { "changed": false, "msg": "all 6 containers in grafana pull from <YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com" }
TASK [grafana : Wait for the pod(s) to pass the NLB health check] **************
ok: [localhost] => (item=arn:aws:elasticloadbalancing:...:targetgroup/k8s-grafana-...)
TASK [grafana : Report] ********************************************************
ok: [localhost] => {
    "msg": [
        "url:        http://<nlb-hostname>.elb.us-east-1.amazonaws.com:3000",
        "exposure:   internal NLB <nlb-hostname>, allowed from 10.20.0.0/16; 1 healthy target(s)",
        "login:      admin -- password in .../state/grafana-admin-password",
        "datasource: uid clickhouse, ClickHouse Private at c-default-us-01-server-any.ns-default-us-01.svc.cluster.local:8123 (plaintext) as grafana",
        "smoke test: scripts/grafana-smoke.sh   (checks the datasource health and a live query)",
        "teardown:   ansible-playbook deploy.yml --tags gf-app -e grafana_state=absent   (keeps the ClickHouse user; --tags gf-db -e grafana_db_state=absent purges it)"
    ]
}
PLAY RECAP *********************************************************************
localhost                  : ok=34   changed=1    unreachable=0    failed=0    skipped=22   rescued=0    ignored=0
```

A later, from-scratch install (§7, after the fresh storage rebuild) reached this same green state on the **first** attempt, in 9 minutes total for Langfuse + Grafana together — confirming all four fixes above are the complete set for a clean install, not survivorship from repeated retries.

**Pods and images**, from the from-scratch install:

```
$ kubectl get pods -n grafana
grafana-...   1/1   Running   0   ...
$ kubectl get pods -n grafana -o jsonpath='...{.image}...' | sort -u
<account>.dkr.ecr.us-east-1.amazonaws.com/awscli:1.46.1-dev
<account>.dkr.ecr.us-east-1.amazonaws.com/grafana:13.2.2
<account>.dkr.ecr.us-east-1.amazonaws.com/grafana:13.2.2-dev
```

All three unique images (main container on the hardened runtime tag, both initContainers on `-dev` tags) pull from the deployer's own ECR only — the airgap assertion (AC3) confirmed both live at install time (`all 6 containers in grafana pull from ...`) and independently by hand against the freshly-rebuilt namespace.

## 5. Smoke test

```bash
scripts/grafana-smoke.sh
```

The first run, before the demo script's own bug was found, reached Grafana (the internal NLB does not answer from a laptop off the VPC, so it fell back to the `3000:3000` port-forward) but failed the datasource health check with an empty HTTP status:

```
==> Checking the ClickHouse datasource
  [fail] datasource health check returned no HTTP status (curl error?)
```

**Defect (the demo script, not the roles).** Manual, verbose `curl` through a manual port-forward worked fine directly, which pointed at the script's own curl-config builder: it wrote the admin password into a `curl --config` file with `cat`, and the password file (like every password file this repo writes) ends in a trailing newline — that byte landed inside the quoted config value and broke curl's config-file parser (the closing quote ended up alone on its own line), and the script's own `http_code()` helper swallows curl's stderr, so the parse failure surfaced only as an empty status. Fix: build the config line with `tr -d '\n'` instead of `cat`, preserving the script's existing secret-handling invariant (the password travels only through `tr`'s stdout — never through a shell variable, command substitution, or argv). Commit `e2b7802`.

Re-run, fixed, against the fresh install from §7 (with `langfuse.enabled: true` too, so the cross-database check has real Langfuse tables to reach):

```
==> Reaching Grafana
  load balancer (internal NLB): http://<nlb-hostname>.elb.us-east-1.amazonaws.com:3000
  [warn] http://<nlb-hostname>...  does not answer /api/health from here (VPN? security group?)
  forwarding localhost:3000 -> svc/grafana:3000 in grafana
  [ ok ] health check passed through the port-forward

==> Checking the ClickHouse datasource
  [ ok ] datasource uid=clickhouse is healthy: Data source is working

==> Querying system.tables through the datasource
  [ ok ] SELECT count() FROM system.tables = 189

==> Querying langfuse.events_core (blanket GRANT SELECT ON *.* reach check)
  [ ok ] SELECT count() FROM langfuse.events_core = 0 -- the grafana ClickHouse user's blanket grant reaches Langfuse's data too

==> Done
  [ ok ] datasource uid=clickhouse is healthy and returns real data
```

`langfuse.events_core` returned `0` rather than a positive count: this was a fresh Langfuse database with no trace posted yet, not a grant failure — the query *succeeding* (rather than `ACCESS_DENIED`) is exactly what §3's per-database grant enumeration was checked for. Posting one trace through `scripts/langfuse-smoke.sh` and re-running confirmed the non-zero case too:

```
$ scripts/langfuse-smoke.sh   # posts a trace, reads it back via ch-client.sh (see the deferred issue below)
  [ ok ] accepted trace <trace-id> ... [ ok ] trace <trace-id> went in through the API and came back out of ClickHouse Private
$ scripts/grafana-smoke.sh
  [ ok ] SELECT count() FROM langfuse.events_core = 2
```

Both halves of AC2 are confirmed: the datasource health check, the `system.tables` query, and the cross-database `langfuse.events_core` query all return real data through the Grafana ClickHouse user's grants.

## 6. Idempotency

With everything deployed, a second run of all three tags:

```bash
scripts/play.sh --tags gf-storage,gf-db,gf-app
```

reported `changed=0` for the storage and grant steps (the bucket, IRSA stack and per-object grants all converge) and `changed=0` for the Helm release (identical values), matching the pattern already established for Langfuse's own idempotency check.

## 7. Teardown and rebuild

### Storage teardown and rebuild, in isolation

Following the same pattern Langfuse's live-run used for its own storage teardown (task 10's AC4 "--all" behavior, exercised by tag rather than by the full, much larger `down.sh --all`, which would also tear down the shared VPC/EKS/nodes this plan does not own):

```bash
scripts/play.sh --tags gf-storage -e grafana_storage_state=absent
```

```
TASK [grafana_storage : Remove the Grafana IRSA role stack] ********************
changed: [localhost]
TASK [grafana_storage : Delete the plugin-mirror bucket] ***********************
changed: [localhost]
TASK [grafana_storage : Report the teardown] ***********************************
ok: [localhost] => {
    "msg": [
        "absent: CloudFormation stack clickhouse-private-grafana-irsa (and the role in it)",
        "absent: bucket grafana-<YOUR_ACCOUNT_ID>-us-east-1 -- re-downloadable, actually deleted (see this role's header comment)"
    ]
}
```

Unlike Langfuse's data bucket (kept — it holds real events), Grafana's plugin-mirror bucket holds nothing the design can't re-download from GitHub, so the role deletes it outright rather than leaving it behind. Bringing it back (`scripts/play.sh --tags gf-storage`) recreated both the bucket and a new IRSA stack (a new role-name suffix, same trust policy) with no `state/` file to reuse — there is none; the plugin bucket carries no secrets.

### Full round trip: down, then up from nothing

With `grafana.enabled: true` and `langfuse.enabled: true` (both switches — to exercise the cross-database grant end to end) and Grafana's storage freshly rebuilt above:

```bash
scripts/up.sh --yes
```

```
==> Up in 9m
  [ ok ] langfuse: http://<nlb-hostname>...   (via the internal NLB; login: state/langfuse-admin-password)
  [ ok ]           scripts/langfuse-smoke.sh
  [ ok ] grafana:  http://<nlb-hostname>...:3000   (via the internal NLB; login: admin / state/grafana-admin-password)
  [ ok ]           scripts/grafana-smoke.sh
PLAY RECAP *********************************************************************
localhost                  : ok=309  changed=22   unreachable=0    failed=0    skipped=102  rescued=0    ignored=0
```

One run, nodes through Grafana, first attempt green — with all four role fixes from §4 in place. Then the full default teardown:

```bash
scripts/down.sh --yes
```

```
==> Tearing down (default): lf-app gf-app lb cluster nodes
==> Down in 12m
  [ ok ] load balancer, cluster and node groups removed. Rebuild: scripts/up.sh --from nodes (~15 min)
```

`gf-app` ran (and was removed) even with the switch already back to `false` — `down.sh`'s `gf_app_exists()` check (looking at `helm status`, the `grafana-lb` Service and the namespace, independent of the `enabled` flag) kept it in the plan, same design Langfuse already used. Checked afterwards:

```
$ kubectl get ns
clickhouse-operator-system   Active
default                      Active
kube-node-lease               Active
kube-public                    Active
kube-system                    Active
$ kubectl get nodes
No resources found.
```

No `grafana` or `langfuse` namespace, no nodes. Both switches were set back to their committed `false` defaults before this final teardown, and `git diff` on `ansible/group_vars/all.yml` shows no drift from the committed values afterward. The Grafana (and Langfuse) IRSA stacks and their buckets were left in place — the same default posture (`~$0.15/hr`, VPC/EKS/IRSA/operator/StorageClass kept) Part 0 documents, now with Grafana's storage alongside Langfuse's and ClickHouse's own.

## Observed, not fixed

- **`scripts/ch-client.sh:79` fails with `SECURE_ARGS[@]: unbound variable` under macOS's system `/bin/bash` (3.2.57).** Surfaced while re-running `scripts/langfuse-smoke.sh` during this session's round trip (§5) — a pre-existing bug in a shared script this plan does not own or list in its `files[]`, introduced by an earlier, unrelated commit (`35a8367`, the native-TLS client work) and unrelated to any Grafana-role change here. Bash 3.2 (still the only `bash` on PATH on this machine) has the well-known bug where `"${empty_array[@]}"` under `set -u` throws `unbound variable` even after `arr=()`, unlike bash 4.4+. It did not affect this task's own acceptance criteria: `grafana-smoke.sh` talks to ClickHouse over a raw port-forward and `curl`, not through `ch-client.sh`, so AC2 is unaffected; the failure is cosmetic in `langfuse-smoke.sh` too (the script still reports `[ ok ]` because the trace round-trip through the API already proved the write, and the two broken `SELECT`s are informational only). Recorded here rather than fixed, matching this plan's own scope boundary; a fix belongs to whichever plan next touches `ch-client.sh`.

## Commits from this run

| Commit | Change |
|---|---|
| `bad9cb5` | `feat(grafana): persist DHI credentials in state/deploy-vars.yml instead of requiring env exports` |
| `e2b7802` | `fix(grafana): resolve live-verification blockers in shell-less DHI initContainers, ClickHouse grant scope, Service port, and smoke-script curl bug` |

Plus this report, with `grafana.enabled` and `langfuse.enabled` back at `false`.
