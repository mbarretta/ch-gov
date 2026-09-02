# Part 1 — Prerequisites and Environment Setup

> **Goal of Part 1:** get your laptop able to talk to two AWS accounts and
> prove you can reach the ClickHouse image registry. Nothing is deployed yet
> and nothing costs money yet.
>
> **Run it:** `./scripts/part1-setup.sh` (or `--check` to verify without changing anything)

---

## 1. What you are actually building, and why it looks odd

Before the tool list makes sense, you need the shape of the thing.

A normal Kubernetes deployment pulls container images from the public internet —
Docker Hub, quay.io, whatever. **ClickHouse Private deliberately cannot do that.**
It runs in an *airgapped* model: the VPC hosting your database has no route to the
internet at all. That is the point. It is the property that makes the product
viable for regulated and classified environments.

That single constraint explains almost every strange thing in Part 1:

```
  ClickHouse's AWS account                 YOUR AWS account
  ┌───────────────────────────┐            ┌──────────────────────────────┐
  │ source ECR                │            │  your ECR                    │
  │ <SOURCE_ECR_ACCOUNT_ID>              │  skopeo    │  <your-account-id>           │
  │  clickhouse-server        │ ─────────► │   clickhouse-server          │
  │  clickhouse-keeper        │   copy     │   clickhouse-keeper          │
  │  clickhouse-operator      │            │   clickhouse-operator        │
  └───────────────────────────┘            │            │                 │
        (read-only, cross-account)         │            ▼  pull           │
                                           │  ┌──────────────────────┐    │
                                           │  │ EKS cluster          │    │
                                           │  │ (no internet route)  │    │
                                           │  └──────────────────────┘    │
                                           └──────────────────────────────┘
```

Images make exactly one hop from ClickHouse's registry into yours, and the
cluster only ever pulls from yours. Your cluster never talks to ClickHouse Inc.

**Why this matters for you:** you need credentials for *two* accounts, and a tool
that can copy images between registries. Hence two AWS profiles, and `skopeo`.

---

## 2. The seven tools, and what each one is for

Install them all; the deployment fails on a missing one.

| Tool | Min version | Its job in this deployment |
|---|---|---|
| **aws** | v2.x | Creates AWS resources. Also mints the short-lived token used to log into ECR. |
| **kubectl** | v1.28+ | Talks to the Kubernetes API once EKS exists. Your main inspection tool. |
| **helm** | v3+ (**we use v4**) | Installs the ClickHouse operator and cluster as packaged "charts". |
| **skopeo** | v1.x | Copies images registry→registry *without* a local `docker pull`. The airgap workhorse. |
| **jq** | any | Parses the JSON that `aws` and `kubectl` emit. The scripts lean on it heavily. |
| **python3** | 3.9+ | Ansible's runtime. |
| **ansible** | 2.15+ | Runs the 14-phase deployment playbook that does the real work. |

Two details worth internalizing:

**Why skopeo and not docker?** `docker pull` + `docker push` would drag every
image layer down to your laptop and back up again — gigabytes, twice, slowly.
`skopeo copy` instructs the two registries to transfer layers directly. It also
needs no running Docker daemon.

**A note on the helm version.** The guide specifies v3.x, and Ansible's
`kubernetes.core` helm modules were written against v3. **We are running v4 by
choice.** Worth knowing so you can recognize the symptom: if a helm task in the
playbook fails in a way that looks like a chart-apply or manifest problem rather
than a real config error, version skew is the first suspect. `helm@3` stays
installed alongside (keg-only), so switching back is one command:

```bash
brew unlink helm && brew link --overwrite --force helm@3
```

### Two supporting pieces

- **`helm-diff` plugin** — shows what a `helm upgrade` *would* change before it
  changes anything. The playbooks use it to stay **idempotent**: re-running a
  deploy becomes a no-op instead of a surprise. Worth understanding, because
  "just run it again" is your main recovery tool later.
- **Four Ansible collections** (`amazon.aws`, `community.aws`, `kubernetes.core`,
  `community.general`) — these teach Ansible to speak CloudFormation, EC2, and
  Kubernetes. Without them the playbook dies on its first task with
  "module not found".

---

## 3. AWS access: two profiles, one login

An AWS **profile** is a named set of credentials. You select one per command
with `--profile`, or globally with `export AWS_PROFILE=...`.

### Config lives in the repo, not in your home directory

By default the CLI reads `~/.aws/config`. We instead keep it at **`.aws/config`
inside this project** and point the CLI at it with `AWS_CONFIG_FILE`, so the
entire setup moves as one directory.

```bash
source scripts/env.sh    # sets AWS_CONFIG_FILE + AWS_PROFILE, prints your identity
```

The scripts under `scripts/` detect and use the in-repo config on their own, so
they work without activating anything. Sourcing `env.sh` is only for your own
interactive `aws` / `kubectl` commands.

**Two consequences worth knowing:**

1. **A bare `aws` command outside this project finds no profiles.** That's
   deliberate — there is one source of truth, not two that can drift. If you
   want these profiles available everywhere, copy `.aws/config` to `~/.aws/config`,
   and accept that you now maintain both.
2. **The SSO token cache does not move.** The CLI hardcodes `~/.aws/sso/cache`
   and offers no environment variable to relocate it. This is a non-issue: it
   holds only a short-lived token that `aws sso login` regenerates. Just don't
   expect a copy of this directory to arrive somewhere already logged in.

`.aws/config` is tracked in git. It contains no credentials — only an SSO start
URL, an account ID, and a role ARN. `.gitignore` blocks `.aws/credentials` and
the cache directories so that static keys can never be committed by accident.
If you'd rather not have account identifiers in the repo, make `.aws/config` a
template and gitignore the real one.

We use the two names the deployment config expects:

| Profile | Resolves to | Purpose |
|---|---|---|
| `sa` | your account, via SSO | Builds VPC, EKS, S3, your ECR. Holds your data. |
| `private-us` | an assumed IAM role | Read-only access to ClickHouse's source ECR. |

### How the credentials actually flow

```
  you ──browser login──► IAM Identity Center (SSO)
                              │
                              ▼
                     cached token (~8h)
                              │
                              ▼
                    profile "sa"  ──sts:AssumeRole──►  profile "private-us"
                   (your account)                     (ClickHouseAirgapECRPullRole)
                          │                                     │
                          ▼                                     ▼
                 build all infrastructure               read source ECR only
```

The key idea is **role chaining**. `private-us` has no credentials of its own —
its config says "use `sa`'s credentials to assume this role." So one browser
login covers both profiles, and the CLI silently re-assumes the role whenever
those 1-hour role credentials expire. You never manage a long-lived access key,
which is the whole reason SSO is preferred: nothing secret sits on your disk.

### The one command you'll rerun

SSO tokens expire (roughly daily). When commands start failing with
`Error loading SSO Token`, that's all it is:

```bash
source scripts/env.sh            # if not already active in this shell
aws sso login --profile sa
```

### Verifying it worked

```bash
aws sts get-caller-identity --profile sa          # your account + SSO role
aws sts get-caller-identity --profile private-us  # ClickHouseAirgapECRPullRole
```

If the second fails, you lack the cross-account role — that's a permissions
request to your ClickHouse contact, not something you can configure around.

### What the pull role can and cannot do

Worth knowing so its error messages don't confuse you. The role grants exactly:
`GetAuthorizationToken`, `BatchGetImage`, `GetDownloadUrlForLayer`,
`BatchCheckLayerAvailability`, `DescribeImages`, `ListImages` — scoped to
account **<SOURCE_ECR_ACCOUNT_ID>**.

It deliberately does **not** grant `DescribeRepositories`. So you cannot list
*which* repositories exist; you can only inspect ones you already know by name.
There are three: `clickhouse-server`, `clickhouse-keeper`, `clickhouse-operator`.
A denial on any other repo name is expected, not a broken setup.

---

## 4. Notes from doing this for real

The guide is old, so treat its specific versions as illustrative, not literal.
Two things are worth carrying forward:

### 4.1 The pull role's account number is wrong in the guide

The guide prints `role_arn = arn:aws:iam::925472944448:...`, which did not work.
The role that exists for this SSO login is in **<YOUR_ACCOUNT_ID>** — matching the
guide's own "Expected output" block a few lines later. Three accounts are in
play, which is the confusing part:

- **<YOUR_ACCOUNT_ID>** — your account; also hosts the pull role
- **<SOURCE_ECR_ACCOUNT_ID>** — where the images actually live (source ECR)
- **925472944448** — in the guide's `role_arn`; unverified

### 4.2 Resolve image versions at deploy time

The guide's pinned tags are stale (two of its three no longer exist in the
registry) — expected for a doc this age. The habit that matters: **list what's
actually in the registry before deploying** rather than trusting a pinned
config, because a missing tag fails at the image-sync phase well into a run.
`part1-setup.sh` prints the current tags for that reason.

### 4.3 Everything runs current, which shifts the version question to EKS

All tooling is at current releases (kubectl 1.37, helm 4.2.4, ansible-core 2.21,
jq 1.8.2, skopeo 1.24, aws-cli 2.36). Nothing is pinned backwards.

The consequence: kubectl 1.37 against the guide's `eks_version: "1.31"` is six
minor versions of skew, where Kubernetes supports ±1. Everyday commands
generally still work, but the fix is to pick a **current** `eks_version` in
`deploy-config.yaml` rather than to downgrade kubectl — one more reason not to
take the old guide's config values literally.

### 4.4 FIPS and hardened variants

Every image also ships as `-fips`, `-nocve`, and sometimes `-fips-ubi9`.
`-fips` means FIPS 140 validated crypto — typically **mandatory** for US federal
work. The original guide never mentions these, and for a government target this
is probably a day-one `deploy-config.yaml` decision rather than a later
migration.

## 5. The deployment repository question, resolved

The training guide's Section 3 opens with `cd cloud/aws/ansible` but never says
where that directory comes from — no clone URL, no repo name. Searching the
ClickHouse GitHub org for its distinctive filenames turned up nothing reachable.

**We stopped looking and wrote our own.** The public tutorial at
[docs/cloud/clickhouse-private/tutorials/deploy-aws](https://clickhouse.com/docs/cloud/clickhouse-private/tutorials/deploy-aws)
documents all 11 steps as explicit commands, and it is *current* — its versions
match what actually exists in the source ECR today, unlike the training doc. Our
Ansible lives in `ansible/` and follows that tutorial. See
`docs/part-2-image-sync.md`.

## 6. Checkpoint

Verified working:

- [x] All 7 tools installed (helm v4)
- [x] helm-diff plugin + 4 Ansible collections
- [x] `sa` profile authenticates via SSO
- [x] `private-us` assumes the pull role
- [x] Source ECR reachable; real image versions enumerated
- [x] Python venv with boto3 for Ansible's AWS modules
- [x] Deployment automation — we write our own (`ansible/`)

Re-verify any time with:

```bash
./scripts/part1-setup.sh --check
```
