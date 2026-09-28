# Part 8 — Steps 16–18: Grafana, wired to ClickHouse Private as its datasource

Parts 1–5 end with a ClickHouse cluster behind a load balancer; Part 6 adds
Langfuse next to it, off by default. These three steps add a second,
independent optional capability, also off by default: a Grafana server with
one pre-provisioned datasource pointed at the ClickHouse cluster you already
built, for demos and workshops where you want to poke at the data with
dashboards rather than only `SELECT` statements. Nothing else changes when
the switch is off.

```bash
# in ansible/group_vars/all.yml:  grafana.enabled: true
scripts/up.sh                     # Steps 1-18 in order; --from lb if the cluster is already up
scripts/grafana-smoke.sh          # check the datasource, run a real query through it
```

> **Status: run end to end on 2026-09-28** against the real stack, twice
> (once from nodes through a from-scratch install with Langfuse also on, to
> exercise the cross-database grant). Four defects showed up only live, all
> in the Grafana role or its supporting Ansible; each is described below at
> the point where you would meet it. The commands, the outputs and the
> digests quoted here come from
> [`docs/part-8-grafana-live-run.md`](part-8-grafana-live-run.md), which is
> the evidence for every claim of the form "this works".

---

## 1. What Grafana is, in one paragraph

Grafana is an open-source dashboarding and exploration UI: you point it at a
data source, write or build a query, and it renders the result as a graph,
table or panel — the tool people reach for when they want to look at data
visually rather than type SQL every time. This capability installs it with
**one datasource already wired up**: a read-only ClickHouse user (Step 17)
reached through the `grafana-clickhouse-datasource` plugin (Step 18),
pointed at the exact cluster Parts 1–5 built. There is no starter dashboard
and nothing is provisioned beyond the datasource itself — what you build in
the UI is yours, and none of it survives a pod restart (§3 says why). It is
the same "here is a working connection, go explore" role Part 6 gives
Langfuse's own data, generalized to whatever else lives in the cluster —
including Langfuse's tables, once both capabilities are on.

## 2. Why this one needed two things Langfuse's install didn't

Langfuse's images come from `docker.langfuse.com` and Chainguard's anonymous
`cgr.dev`; its one extra artifact is a chart. Grafana's install needed two
things with no precedent in Part 6:

**DHI is a paid, authenticated catalog.** Docker Hardened Images (DHI)
publishes hardened, minimal builds of common images — including Grafana's
own upstream image and `awscli` — but pulling from `dhi.io` needs a Docker
Hub account entitled to the catalog, unlike Chainguard's anonymous pulls.
`image_sync` (Step 2) logs into `dhi.io` with `skopeo login`, the same
stdin-only, no-argv discipline it already uses for ECR, and only when
something in the artifact list actually sources from `dhi.io` — a
Grafana-less run never asks for the credential. Where that credential
comes from (`state/deploy-vars.yml`, or `DHI_USERNAME`/`DHI_TOKEN` in the
environment) is covered once, for every optional credential this repo
needs, in
[`docs/part-1-prerequisites.md` §3b](part-1-prerequisites.md#3b-persisting-your-account-ids-and-sso-portal-statedeploy-varsyml).

**The ClickHouse datasource is a plugin, and this cluster is airgapped.**
`grafana-clickhouse-datasource` is not baked into any image, and a pod that
tried to fetch it from `grafana.com` at startup would need a route out of
the cluster — the one thing this whole project is built to avoid. So Step 16
mirrors one pinned, SHA256-verified copy of the plugin zip into your own S3
bucket during the laptop-side sync, the same "mirror once, pull only from
your own account" shape Step 2 already uses for images; Step 18's pod then
reaches it through an IRSA-authenticated initContainer, never grafana.com.

## 3. The switch, and what it changes

Everything hangs off one key, last in `ansible/group_vars/all.yml`, after
`langfuse:` for the same first-match-`awk`-scrape reason Part 6 §3
explains:

```yaml
grafana:
  enabled: false            # the switch. false = Steps 16-18 do nothing
  namespace: "grafana"
  release: "grafana"        # the chart's fullnameOverride, so also the ServiceAccount name IRSA trusts
  clickhouse_user: "grafana" # GRANT SELECT ON *.* (in effect) -- ease of use, not least privilege; see §6
  bucket_name: "grafana-{{ aws.target_account_id }}-{{ aws.target_region }}"
  url: ""                   # override; empty derives it from the NLB (or localhost:3000 for type none)
  load_balancer:
    type: "internal"        # none | internal | public, exactly as clickhouse.load_balancer / langfuse.load_balancer
    allowed_cidrs: []
    port: 3000               # Grafana's own default UI port
    cross_zone: true
    tls: false               # true = the NLB terminates TLS with a self-signed certificate (§9)
    tls_cert_days: 825
  pod: {replicas: 1, cpu: "500m", memory: "512Mi"}
  telemetry_enabled: false  # no phone-home
```

**With `enabled: false`** — the committed default — nothing observable
changes: `up.sh --help` is unaffected, no Grafana artifact is mirrored, and
`scripts/play.sh --tags grafana` skips straight through. The live run
confirmed this with a full teardown-and-rebuild: `grep -ci grafana` on the
resulting log returned `0`, and `kubectl get ns` afterward showed only the
ClickHouse namespace.

**With `enabled: true`**, three things happen: Step 2 mirrors three DHI
images and one chart (§4); `up.sh` appends `gf-storage gf-db gf-app` *after*
Langfuse's own `lf-storage lf-db lf-app` (so if both are on, the
blanket ClickHouse grant Step 17 creates already covers `langfuse.*` by the
time it's checked); `down.sh` removes Grafana after Langfuse, both before
the load balancer, the cluster and the node groups (§13). Each step has its
own tag:

```bash
scripts/play.sh --tags grafana        # Steps 16, 17, 18
scripts/play.sh --tags gf-storage     # Step 16: bucket, IRSA role, plugin mirror
scripts/play.sh --tags gf-db          # Step 17: the read-only ClickHouse user
scripts/play.sh --tags gf-app         # Step 18: the Helm release, NLB, datasource
```

## 4. Step 2 again: three DHI images and a chart

Flip the switch and re-run the image hop:

```bash
scripts/play.sh --tags images
```

Three artifacts are new, all from `dhi.io`, plus the chart from Grafana's
own plain-HTTP Helm repository (`helm/grafana`, pushed to ECR as an OCI
artifact exactly like Langfuse's chart):

| Repository | Tag | What / why |
|---|---|---|
| `grafana` | `13.2.2` | The main container. DHI's hardened "runtime" tag — no shell, no coreutils. |
| `grafana` | `13.2.2-dev` | Same version, DHI's `-dev` variant. Used **only** by the plugin-install initContainer (§6), which needs a real shell. |
| `awscli` | `1.46.1-dev` | The presign initContainer (§6). DHI's `awscli` **v2** line ships no `-dev`/shell-having tag at all — confirmed against the live catalog — so this pins v1 instead, whose `s3 presign` takes the same flags. |
| `helm/grafana` | `10.5.15` | The chart, from `grafana.github.io/helm-charts`. Upstream froze this chart on 2026-01-30 in favor of `grafana-community/helm-charts`, but the pinned version still installs cleanly. |

Digests from the live run are in
[`docs/part-8-grafana-live-run.md` §2](part-8-grafana-live-run.md#2-ecr-tags-and-digests).
**Neither `grafana_app` nor `awscli_app` carries a `fips_suffix`** — a
deliberate, documented gap. DHI requires an entitled login to even resolve
its own tags, so the versions pinned here are a best-available proxy against
public `grafana/grafana`/`amazon/aws-cli` tags rather than a confirmed FIPS
build; whether that matters for your compliance target is, as with Part 7's
own caveats, a question this repo does not answer for you. Confirm against
the real DHI catalog at your first `--tags images` run.

## 5. Step 16 — a bucket and an IRSA role (`gf-storage`)

```bash
scripts/play.sh --tags gf-storage        # ~30 s
```

A mirror of Step 13's shape (bucket + CloudFormation IRSA stack), with one
deliberate divergence:

- **The bucket** `grafana-<account>-<region>` (`grafana.bucket_name`) is
  created with AES256 default encryption and all four public-access blocks
  on — the same pattern every bucket in this project uses. It holds exactly
  one object: the mirrored `grafana-clickhouse-datasource` plugin zip,
  fetched once with a pinned version and a SHA256 check
  (`versions.grafana_clickhouse_plugin_version`/`_sha256`) and uploaded with
  an idempotent head-object check before every re-run.
- **Unlike Langfuse's bucket, this one IS deleted on teardown**
  (`grafana_storage_state=absent`). Langfuse's bucket holds real event data
  that would be lost; this bucket holds one artifact you can re-download
  from `grafana.com` at any time, so there is no data-loss risk in deleting
  it and no upside in leaving an orphaned bucket behind a disable/re-enable
  cycle.
- **The stack** `clickhouse-private-grafana-irsa` holds one IAM role,
  federated on the cluster's OIDC provider (the same one Langfuse's and
  ClickHouse's own IRSA roles use), restricted to
  `system:serviceaccount:grafana:grafana`. Its policy is the narrowest of
  any role in this project: `s3:GetObject` on `plugins/*` only — no
  `ListBucket`, `Put` or `Delete` at runtime, since the pod only ever needs
  to read one already-known key.

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

No S3 access keys anywhere: the pod's ServiceAccount annotation supplies
`AWS_ROLE_ARN` and a projected web-identity token, exactly as every other
IRSA role in this project.

## 6. Step 17 — a read-only ClickHouse user (`gf-db`)

```bash
scripts/play.sh --tags gf-db             # ~10 s
```

Grafana could be handed the `default` admin account. It is not. Step 17
creates a user `grafana` and grants it read access across the whole
cluster — a deliberate ease-of-use choice for demos and workshops, stated
plainly here as a tradeoff, not a least-privilege default. No database is
created for it: the entire point of this capability is ad-hoc exploration
across whatever exists, not a scoped app schema.

**The password travels exactly like Langfuse's**: generated into
`state/grafana-clickhouse-password` (mode 0600), hashed with SHA-256 in
Ansible, and every statement run through `kubectl exec -i` with the admin
password on stdin — the same pattern Step 14 uses, with the same
already-flagged, not-fixed-here gap (the ClickHouse client inside the pod
still takes the password on its own `--password` argv; see the deferred
item in Step 14's own header comment).

**The grant is not literally `GRANT SELECT ON *.*`.** The design's plan
called for exactly that, and it fails live: ClickHouse Private's operator
chart `REVOKE`s `SELECT` on `system.zookeeper` from `default_role` itself,
as deliberate hardening of Keeper's internals, and a wildcard grant needs
`WITH GRANT OPTION` on every object it matches — including the one the
grantor does not hold. There is no `EXCEPT`/exclusion syntax on `GRANT` in
ClickHouse, and no self-grant workaround; both were tried live and neither
works. The fix, confirmed live: enumerate every real database plus every
`system.*` table except `zookeeper`/`zookeeper_log`, and grant `SELECT` on
each individually — the same effective scope, built by construction instead
of by wildcard:

```
GRANT SELECT ON `default`.* TO grafana
GRANT SELECT ON `langfuse`.* TO grafana        -- once Langfuse is also on
GRANT SELECT ON system.`tables` TO grafana
... (about 180 lines total; system.zookeeper and system.zookeeper_log are absent)
```

This is idempotent (a second run reports `grants: unchanged`) and picks up
any database created later on the next `--tags gf-db` run, with no separate
grant needed — including `langfuse.*` automatically, the moment Langfuse is
also enabled.

```
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

## 7. Step 18 — Grafana itself (`gf-app`)

```bash
scripts/play.sh --tags gf-app            # ~1 min once the images and plugin are mirrored
```

Order matters the same way it does for Langfuse: `GF_SERVER_ROOT_URL` is
baked into the pod, so the load balancer Service is created and its
hostname read before the Helm release. The role then installs Grafana with
`persistence.enabled: false` (the plan's "no PVC" decision) and one
pre-provisioned datasource. Two mechanisms have no precedent in Part 6.

### The plugin initContainers, and the shell they needed

The plugin can't be baked into the image and can't be fetched from
`grafana.com` in an airgapped cluster (§2), so it is loaded by two chained
initContainers on every pod start:

1. **`gf-plugin-presign`** (the `awscli` image) computes a short-lived
   (5-minute), already-scoped presigned URL for the one S3 key Step 16
   mirrored — a purely local SigV4 signature under IRSA, no `ListBucket`
   call — and writes it to a small shared `emptyDir`.
2. **`gf-plugin-install`** (the `grafana` image) runs
   `grafana cli --pluginUrl "$(cat ...)" plugins install grafana-clickhouse-datasource <version>`,
   fetching that presigned URL and unzipping it with Grafana's own internal
   Go zip handling. `grafana cli --pluginUrl` is a plain Go `http.Client` —
   confirmed against Grafana's own source — so it must be a real HTTP(S)
   URL; that's why the presign-and-relay dance exists instead of a shared
   volume with the raw zip.

**The defect the live run found, twice.** Both DHI images' default,
hardened "runtime" tags ship *zero* shell or coreutils — not `sh`, not
`busybox`, not `python3`, not `unzip`. Both initContainers failed at their
own `command: ["sh", "-c", ...]` before any application logic ran. The fix
is DHI's own `-dev` tag variant — a full Debian-based image with a real
shell — for both: `awscli:1.46.1-dev` and `grafana:13.2.2-dev` (the *main*
Grafana container, which needs no shell of its own, stays on the hardened
runtime tag). DHI's `awscli` **v2** line ships no `-dev` tag at all, which
is why the presign container is pinned to v1 instead. Two smaller defects
surfaced only once the shell existed: `grafana cli` needed an explicit
`--homepath=/usr/share/grafana` (the image's own working directory isn't
Grafana's homepath), and the presign container needed `HOME=/tmp` (botocore
tries to cache an STS token under `$HOME/.aws/` even under IRSA, and uid
472's default `HOME` resolves somewhere unwritable). Full detail, including
the diagnostic probes that ruled out smuggling in a static shell, is in
[`docs/part-8-grafana-live-run.md` §4](part-8-grafana-live-run.md#4-application).

### The datasource, and the FIPS CA-trust wrinkle

The datasource is provisioned as config-as-code — not a dashboard/datasource
sidecar, per the plan's own constraint — with the fixed uid `clickhouse`
(both the smoke test and the live-verification task depend on that literal
value):

```yaml
datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    uid: clickhouse
    jsonData: {host: c-<cluster>-server-any.<ns>.svc.cluster.local, port: 8123, secure: false, username: grafana}
    secureJsonData: {password: "<from state/grafana-clickhouse-password>"}
```

The whole entry carries a `secret:` sub-key, so the pulled chart renders it
into its own Kubernetes Secret rather than the plain ConfigMap every other
provisioning key lands in — the ClickHouse password never reaches a
ConfigMap. **With `fips: true`**, the datasource's own config schema
(`grafana-clickhouse-datasource`'s `tlsAuthWithCACert`/`tlsCACert` keys)
switches the connection to the cluster's TLS listener on port `8443` and
hands it the ClickHouse cluster's CA certificate directly, rather than
Langfuse's fallback of mounting a CA Secret into the pod's filesystem — the
plugin's schema supports the direct-config path, so this role takes it.

The admin account is a Secret of Ansible's own (`grafana-admin`, generated
into `state/grafana-admin-password` and reused across runs) — it must be the
value Ansible controls, not whatever Grafana would generate for itself, so
it gets a Secret separate from the chart's own generated ones.

### What a passing run reports

```
url:        http://<hostname>.elb.us-east-1.amazonaws.com:3000
exposure:   internal NLB <hostname>, allowed from 10.20.0.0/16; 1 healthy target(s)
login:      admin -- password in .../state/grafana-admin-password
datasource: uid clickhouse, ClickHouse Private at c-default-us-01-server-any.ns-default-us-01.svc.cluster.local:8123 (plaintext) as grafana
smoke test: scripts/grafana-smoke.sh   (checks the datasource health and a live query)
teardown:   ansible-playbook deploy.yml --tags gf-app -e grafana_state=absent   (keeps the ClickHouse user; --tags gf-db -e grafana_db_state=absent purges it)
```

A from-scratch install (nodes through Grafana, Langfuse also on) reached
this state on the first attempt in the live run, in 9 minutes total —
confirming the four role fixes above are the complete set for a clean
install, not survivorship from repeated retries. The airgap assertion
covers every container including both initContainers: all three unique
images (main container plus two `-dev` initContainers) pulled from the
deployer's own ECR only, both at install time and confirmed independently
afterward.

## 8. Reaching it from a browser

The default exposure is an **internal** NLB, the same three options as
Part 6 §8 apply:

1. A VPN or peering into the VPC — the URL above works as printed.
2. `type: none`, then `kubectl port-forward -n grafana svc/grafana 3000:3000`
   and open `http://localhost:3000`. The port must be exactly 3000: that is
   what `GF_SERVER_ROOT_URL` is set to for this mode.
3. `type: public` with `allowed_cidrs` set to your own egress CIDR. Plain
   HTTP by default; turn on `grafana.load_balancer.tls` (§9) before
   exposing it this way. `0.0.0.0/0` needs `-e allow_open_internet=true`,
   as elsewhere in this project.

Log in as `admin` with the password in `state/grafana-admin-password`.

## 9. TLS at the load balancer

Identical mechanism to Part 6 §9, renamed: plain HTTP is the default because
the NLB is a TCP pass-through with no domain behind it.

```yaml
grafana:
  load_balancer:
    tls: true               # the NLB terminates TLS
    port: 3000               # unchanged -- Grafana's UI port, not 443/80
    tls_cert_days: 825
```

`fips: true` turns this on for you the same way it does for Langfuse: the
effective TLS state is `tls` OR `fips`, whenever `load_balancer.type` isn't
`none`, and under `fips: true` the NLB's negotiation policy becomes
`ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04`. The certificate is self-signed —
the role generates it, nobody vouches for it — and gives you encryption, not
identity, exactly as Part 6 §9's longer discussion of that tradeoff spells
out; read that section for what it does and does not buy you, since none of
it is Grafana-specific. `scripts/grafana-smoke.sh` knows the same rule
Langfuse's smoke test does: it trusts the role's self-signed certificate
(`gf_cacert()` in `common.sh`) only for the address it derived from the NLB
hostname itself, never with `-k`/`--insecure`.

This mechanism was not exercised live in this cycle's run (plain HTTP
throughout); it shares its code path with Part 6's own TLS run, which was.

## 10. The smoke test

```bash
scripts/grafana-smoke.sh
```

Needs `curl`, `jq` and `kubectl`. What it does, in order:

1. **Finds a URL that answers**, the same precedence as
   `langfuse-smoke.sh`: an env override, then `grafana.url`, then the
   `grafana-lb` NLB hostname, falling back to a fixed `3000:3000`
   port-forward.
2. **`GET /api/datasources/uid/clickhouse/health`** (Basic Auth,
   `admin`/`state/grafana-admin-password`) and asserts `status: "OK"`.
3. **`POST /api/ds/query`** against that datasource —
   `SELECT count() AS n FROM system.tables` — the same path Grafana's own
   panels use, proving the Step 17 grant actually reaches ClickHouse and
   not just that the health ping succeeded.
4. **When Langfuse is also `enabled`**, a third query against
   `langfuse.events_core` proves the same blanket grant reaches Langfuse's
   database too, with no separate grant of its own.

The admin credential never enters a shell variable or argv: it is assembled
straight into a mode-0600 curl config under a private temp directory and
handed to curl as `--config -` on stdin — `bash -x` shows only file paths.

```
==> Checking the ClickHouse datasource
  [ ok ] datasource uid=clickhouse is healthy: Data source is working
==> Querying system.tables through the datasource
  [ ok ] SELECT count() FROM system.tables = 189
==> Querying langfuse.events_core (blanket GRANT SELECT ON *.* reach check)
  [ ok ] SELECT count() FROM langfuse.events_core = 2
```

**Defect from the live run, in the demo script itself, not the roles.** The
script's curl-config builder originally used `cat` to write the password
into the config file; the password file, like every password file this
repo writes, ends in a trailing newline, and that byte landed inside the
quoted config value and broke curl's config parser — surfacing only as an
empty HTTP status, because the script's own error handling swallows curl's
stderr. The fix, `tr -d '\n'` instead of `cat`, still keeps the secret off
argv and out of any shell variable. Full detail, including the `0`-vs-`2`
non-zero cross-database proof, is in
[`docs/part-8-grafana-live-run.md` §5](part-8-grafana-live-run.md#5-smoke-test).

## 11. Idempotency and check mode

```bash
scripts/play.sh --tags gf-storage,gf-db,gf-app
```

With everything deployed, a second run reports `changed=0` for the bucket,
the IRSA stack and the per-object grants (all converge) and for the Helm
release (identical values) — the same pattern Langfuse's own idempotency
check established.

## 12. Cost

Grafana adds no instances: like Langfuse, it lands on the operator node
group Step 5 already pays for, and there is no PVC to add a volume charge.
Its own line item is the second-optional NLB (~$0.02/hr, matching
Langfuse's own), plus the plugin bucket, which holds one small zip and
costs effectively nothing. Unchanged at the ~$0.15/hr floor with the nodes
down — a default `down.sh` keeps the Grafana IRSA stack and bucket the way
it keeps Langfuse's and ClickHouse's own, both of which cost nothing idle.

## 13. Teardown order: Langfuse, then Grafana, both before ClickHouse

Grafana holds no data of its own that depends on the ClickHouse cluster
being reachable to remove safely — no PVC, no database — so its ordering
constraint is looser than Langfuse's, and `down.sh` removes it **after**
Langfuse rather than before: whichever order the two run in, both still
have to finish before the load balancer, the cluster and the node groups
go, so `down.sh` keeps `lf-app` first in its default plan (matching the
order Steps 13-15 and 16-18 install in) and Grafana second:

```bash
scripts/down.sh          # lf-app, gf-app, lb, cluster, nodes
scripts/down.sh --all    # + lf-db, gf-db, lf-storage, gf-storage, and everything below them
```

- **Only what exists is torn down.** `gf-app` stays in the plan only if
  `helm status`, the `grafana-lb` Service or the `grafana` namespace says
  there is something to remove — independent of the `enabled` flag, so a
  previously-deployed-then-disabled Grafana is still torn down correctly.
  The live run confirmed this: `gf-app` ran and was removed with the switch
  already back to `false`.
- **It works with the switch already off**, the same way Langfuse's
  teardown does — `deploy.yml` gates each role on `enabled` OR the
  teardown-state variable, so flipping `enabled` back to `false` never
  orphans a deployed release.
- **`gf-db` is the data-purge switch and is not in the default plan**, for
  the same reason Langfuse's `lf-db` isn't: a default teardown removes the
  whole ClickHouse cluster anyway, so "keep the cluster, drop only the
  Grafana user" should be an explicit command:

```bash
scripts/play.sh --tags gf-app -e grafana_state=absent            # NLB Service, (with tls) the ACM certificate, release, namespace. Keeps the ClickHouse user
scripts/play.sh --tags gf-db -e grafana_db_state=absent          # DROP USER IF EXISTS grafana. No database to drop -- one was never created
scripts/play.sh --tags gf-storage -e grafana_storage_state=absent  # the IRSA stack AND the plugin-mirror bucket -- both actually deleted (§5)
```

**Unlike every other bucket in this project, `gf-storage`'s teardown
actually deletes the bucket**, confirmed live: the plugin zip is
re-downloadable from `grafana.com` at any time, so there is nothing to
lose, and leaving an orphaned bucket behind a disable/re-enable cycle has no
upside. Bringing it back re-creates both the bucket and a fresh IRSA stack
(a new role-name suffix, same trust policy) with no `state/` file to
reuse — the plugin bucket carries no secrets to persist.

## 14. What exists once it is up

```
namespace grafana
  deployment    grafana                       1 pod, plugin loaded by two initContainers on every start
  service       grafana                       ClusterIP :3000 -- the port-forward target
  service       grafana-lb                    type LoadBalancer -> the NLB (absent when type is none; ssl annotations when tls is true)
  serviceaccount grafana                      carries the IRSA role annotation
  secrets       grafana-admin                 (Ansible) -- admin-user / admin-password
                grafana-config-secret         (chart) -- holds the datasource's password (and, under fips, its CA)

ClickHouse Private   user grafana, SELECT on every database + system.* short of zookeeper (covers langfuse.* automatically when Langfuse is on)
AWS                  bucket grafana-<account>-<region>; stack clickhouse-private-grafana-irsa; one NLB; with tls, one ACM certificate tagged Name=clickhouse-private-grafana-lb
```

And in `state/`, alongside the ClickHouse and Langfuse files:

| File | What |
|---|---|
| `grafana-clickhouse-password` | The `grafana` ClickHouse user's password (Step 17) |
| `grafana-admin-password` | The `admin` login (Step 18) |
| `grafana-tls-key.pem`, `grafana-tls-cert.pem` | With `tls`: the NLB's private key (0600) and its self-signed certificate, also the CA file clients trust. Regenerated only when the NLB hostname changes |

The same rule as Part 0: lose `state/` and you lose these. A `down.sh` /
`up.sh --from nodes` cycle reuses them, so the rebuilt Grafana accepts the
same admin login and the same ClickHouse credential — the live run's full
round trip confirmed this, and confirmed `git diff` on `all.yml` shows no
drift from the committed `enabled: false` afterward.

## 15. Where the evidence is

Every output quoted in this Part is taken from
[`docs/part-8-grafana-live-run.md`](part-8-grafana-live-run.md), the record
of the 2026-09-28 run: the disabled-mode round trip, the ECR digests, the
Step 16/17/18 outputs including the grant-scope defect and its fix, the
three `gf-app` install attempts and the four defects they found (two
shell-less initContainers, a missing `--homepath`, a botocore `HOME`
failure, a Service port mismatch, and `/tmp` permission noise), the smoke
test before and after its own curl-config bug, idempotency, the isolated
storage teardown/rebuild, and the full down/up round trip with both
optional capabilities on. Where this Part and the original design
disagree — the exact grant statement, which images need `-dev` tags — the
live run is what happened.

# Checkpoint

- [x] `grafana.enabled: false` (the default) changes nothing: no artifact mirrored, `--tags grafana` a no-op, full down/up round trip shows `grep -ci grafana` = 0
- [x] Step 2 mirrors three DHI images (`grafana`, `grafana-dev`, `awscli-dev`) and pushes the chart; digests recorded in the live-run doc
- [x] Step 16: plugin-mirror bucket encrypted and blocked; IRSA role scoped to `s3:GetObject` on `plugins/*` only; bucket (deliberately, unlike Langfuse's) deleted on teardown
- [x] Step 17: read-only user with per-database + per-system-table grants (not a literal wildcard -- `system.zookeeper` stays revoked); SQL carries a hash, password on stdin; second run `changed=0`
- [x] Step 18: two chained initContainers load the plugin via a presigned S3 URL; both DHI images needed their `-dev` tag for a shell; airgap assertion covers both initContainers and the main container; datasource provisioned as config-as-code with uid `clickhouse`, secret-backed
- [x] `scripts/grafana-smoke.sh`: datasource health, a real `system.tables` count, and (once Langfuse posted a trace) a non-zero `langfuse.events_core` count through the same blanket grant
- [x] `--tags gf-storage,gf-db,gf-app` re-run `changed=0` across all three
- [x] `down.sh` removes Grafana even with the switch already off; nothing orphaned; `up.sh --from nodes` brings it back with the same admin login and ClickHouse credential
- [x] Isolated `gf-storage` teardown and rebuild: bucket and IRSA stack both actually deleted, then recreated with no `state/` file to reuse
- [ ] `grafana.load_balancer.tls: true` not exercised live in this cycle (plain HTTP throughout); shares its code path with Part 6's own TLS run, which was
- [ ] `type: public` not exercised (no safe CIDR to allow from here); the path differs from Part 6's own `public` case by nothing new
