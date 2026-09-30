# Part 1 — Prerequisites and AWS access

> **What you'll learn**
>
> - Why an airgapped ClickHouse Government deployment needs one AWS account of yours plus a read grant on ClickHouse's registry, reached through a role chain, and how the `aws.auth_mode` setting gives you two ways to provide them.
> - Which tools the kit needs, what each one does, and how to install them on macOS and Linux.
> - Which AWS permissions the deploying identity needs, and how to check your setup before you spend anything.
>
> **Run it:** `scripts/part1-setup.sh` installs and checks everything. Add `--check` to verify without changing anything. Nothing is deployed and nothing costs money in this Part.
>
> **Step numbers:** "Step 1" to "Step 18" refer to the table in [Part 0, section 5](part-0-what-is-this.md#5-how-a-deployment-goes-in-general).

### Do this in order

1. **Install the tools.** Run `scripts/part1-setup.sh` (section 2). On macOS it installs what is missing. On Linux, install the tools first.
2. **Edit `state/deploy-vars.yml`.** The first script you run creates it. Replace the `<...>` placeholders with your account ID, the source registry account ID and, in SSO mode, your portal URL (section 3b).
3. **Log in.** `source scripts/env.sh`, then `aws sso login --profile "$AWS_PROFILE"` (section 3). In `profile` mode, refresh your credentials the way your organization does.
4. **Check everything.** Run `scripts/part1-setup.sh --check` (section 6).

The first time you run the setup script, before steps 2 and 3, it reports failures for the two AWS profiles. That is expected: the profiles cannot authenticate until the file is edited and you are logged in. Run the check again after step 3.

---

## 1. What you are building, and why it looks odd

Before the tool list makes sense, you need the shape of the thing.

A normal Kubernetes deployment pulls container images from the public internet: Docker Hub, quay.io, and so on. ClickHouse Government deliberately does not. It is built for *airgapped* networks: the cluster that hosts your database is designed to pull only from a registry you control, and never needs the public internet.

That single constraint explains almost everything in this Part:

```
  ClickHouse's AWS account                 YOUR AWS account
  ┌───────────────────────────┐            ┌──────────────────────────────┐
  │ source ECR                │  skopeo    │  your ECR                    │
  │  clickhouse-server        │ ─────────► │   clickhouse-server          │
  │  clickhouse-keeper        │   copy     │   clickhouse-keeper          │
  │  clickhouse-operator      │            │   clickhouse-operator        │
  └───────────────────────────┘            │            │                 │
        (read-only, cross-account)         │            ▼  pull           │
                                           │  ┌──────────────────────┐    │
                                           │  │ EKS cluster          │    │
                                           │  │ pulls only from your │    │
                                           │  │ ECR                  │    │
                                           │  └──────────────────────┘    │
                                           └──────────────────────────────┘
```

Images make exactly one hop from ClickHouse's registry into yours, and the cluster only ever pulls from yours. The cluster never talks to ClickHouse Inc.

The learning environment this kit builds includes a NAT gateway so that you can reach and test the cluster from your own machine. The NAT gateway belongs to the learning environment only. It is not part of the production deployment.

**Why this matters to you:** you need one AWS account of your own, a read grant on ClickHouse's registry that you reach through a role chain, and a tool that can copy images between registries. That is why the kit uses two AWS profiles and `skopeo`.

---

## 2. The seven tools, and what each one is for

Install all seven. The deployment stops at the first missing one.

| Tool | Minimum version | Its job in this deployment |
|---|---|---|
| **aws** | v2 | Creates AWS resources and mints the short-lived token used to log in to ECR. |
| **kubectl** | v1.28 | Talks to the Kubernetes API once EKS exists. Your main inspection tool. |
| **helm** | v3 or v4 | Installs the ClickHouse operator and cluster as packaged *charts*. |
| **skopeo** | v1 | Copies images from registry to registry without a local `docker pull`. The workhorse of the airgapped design. |
| **jq** | any | Parses the JSON that `aws` and `kubectl` print. The scripts rely on it heavily. |
| **python3** | 3.12 | Ansible's runtime. |
| **ansible** | ansible-core 2.21 | Runs the deployment playbook that does the real work (Steps 1–12, plus the optional Steps 13–18). |

**Why skopeo and not docker?** `docker pull` followed by `docker push` drags every image layer down to your machine and back up again, which is gigabytes moved twice. `skopeo copy` asks the two registries to transfer layers directly, and it needs no running Docker daemon.

### Install on macOS

The setup script installs missing tools with [Homebrew](https://brew.sh):

```bash
scripts/part1-setup.sh
```

To install by hand instead, this is what the script runs, plus Helm and the `krew` plugin manager:

```bash
brew install awscli kubectl skopeo jq ansible helm krew
brew install python@3.14     # only if your python3 is older than 3.12
```

### Install on Linux

`scripts/part1-setup.sh` installs missing tools with Homebrew only. If one of the base tools (`aws`, `kubectl`, `skopeo`, `jq`, `ansible` or `python3`) is missing and Homebrew is not on your `PATH`, the script stops and asks for Homebrew. Helm and krew also install through Homebrew, so without it a missing helm ends with `helm install failed` and a missing krew ends with `could not install kubectl preflight`. Krew has its own Linux instructions under "Supporting pieces" below. On Linux you have two choices:

- Install [Homebrew for Linux](https://brew.sh) and run `scripts/part1-setup.sh` as on macOS.
- Install the tools with your distribution's package manager or each tool's official installer, then run `scripts/part1-setup.sh`. When every tool is already present, the script skips the Homebrew step and installs only the pieces listed under "Supporting pieces" below.

| Tool | Linux install |
|---|---|
| aws | The [official AWS CLI v2 installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| kubectl | The [Kubernetes install page](https://kubernetes.io/docs/tasks/tools/) |
| helm | The [Helm install page](https://helm.sh/docs/intro/install/) |
| skopeo | `sudo apt-get install -y skopeo` on Debian and Ubuntu, `sudo dnf install -y skopeo` on Fedora and RHEL. Other distributions: the [skopeo install guide](https://github.com/containers/skopeo/blob/main/install.md) |
| jq | `sudo apt-get install -y jq` or `sudo dnf install -y jq` |
| python3 | `sudo apt-get install -y python3 python3-venv` or `sudo dnf install -y python3`. The version must be 3.12 or later, and `python3` on your `PATH` must be that version. The `python3-venv` package matters on Debian and Ubuntu, because the script builds a virtual environment. |
| ansible | The [Ansible install guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html). For example: `pipx install --include-deps ansible` |

### Supporting pieces

`scripts/part1-setup.sh` installs and checks five more things. You need them all, but you do not install them by hand, except krew on a Linux machine without Homebrew.

- **`helm-diff` plugin.** Shows what a `helm upgrade` *would* change before it changes anything. The playbooks use it to stay *idempotent*, which means running a deployment again changes nothing that already matches. That property makes "run it again" your main recovery tool.
- **Four Ansible collections** (`amazon.aws`, `community.aws`, `kubernetes.core`, `community.general`). They teach Ansible to speak CloudFormation, ECR, S3 and Kubernetes. Without them the playbook stops on its first task with "module not found".
- **`kubectl preflight` plugin.** This is the Troubleshoot-project runner behind Step 10's preflight checks. It runs on your machine against the cluster API, so nothing needs mirroring into ECR.
- **`krew`, the kubectl plugin manager.** Krew is not optional: it is the installer the script uses to add `kubectl preflight`, which is required. The script checks for the plugin, not for krew. When the plugin is present, krew is never touched. When the plugin is absent, the script installs krew with Homebrew if it is missing, then runs `kubectl krew install preflight`. With `--check`, the script installs nothing and reports `kubectl preflight plugin missing`. On Linux without Homebrew, install krew yourself with the [krew install guide](https://krew.sigs.k8s.io/docs/user-guide/setup/install/), then run the script, and it installs the plugin. Add `$HOME/.krew/bin` to your `PATH` for your own shell. The scripts add it for themselves.
- **A project-local Python virtual environment** at `.venv/`, holding `boto3` and `kubernetes`. Ansible's AWS and Kubernetes modules import these libraries inside whichever Python runs them. A project-local environment leaves your system Python untouched, and `ansible/group_vars/all.yml` points `ansible_python_interpreter` at it.

### Optional tools

Two more tools make the kit easier to use, but nothing in the deployment requires them, and `scripts/part1-setup.sh` does not check for them.

| Tool | What it is for | macOS | Linux |
|---|---|---|---|
| A local ClickHouse client (`clickhouse-client`, or the `clickhouse` binary) | `scripts/ch-client.sh` opens a query session against the cluster from your laptop. It accepts either name. | `brew install clickhouse` | The [ClickHouse install page](https://clickhouse.com/docs/install), which covers the `clickhouse` binary and the `clickhouse-client` packages for Debian, Ubuntu and RPM-based distributions |
| The Session Manager plugin for the AWS CLI | `aws ssm start-session` reaches a node without SSH, for example to read a node's setup log (Part 2). | `brew install --cask session-manager-plugin` | The AWS guide, [Install the Session Manager plugin for the AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |

---

## 3. AWS access: one setting, two paths

An AWS *profile* is a named set of credentials. You pick one per command with `--profile`, or for a whole shell with `export AWS_PROFILE=...`.

The kit uses two profiles: one for your account, and one that chains into a read-only role for ClickHouse's registry:

| Config key | Default name | Purpose |
|---|---|---|
| `aws.target_profile` | `ch-gov-target` | Your account. Builds the VPC, EKS, S3 and your ECR, and holds your data. |
| `aws.source_ecr_profile` | `ch-gov-ecr-pull` | Assumes `ClickHouseAirgapECRPullRole`, the role ClickHouse sets up in your account, to read ClickHouse's source ECR. Used only while copying images (Step 2). |

The setting `aws.auth_mode` decides who creates those profiles:

| `aws.auth_mode` | Choose it when | What the kit does |
|---|---|---|
| `sso` (default) | You sign in with AWS IAM Identity Center (SSO). | Renders a project-local `.aws/config` with both profiles and points the AWS CLI at it. |
| `profile` | You already have a working named profile. | Renders nothing. It uses your own AWS config, and both profiles must exist there. |

You set these keys in `state/deploy-vars.yml`. Section 3b explains that file, and the defaults live in `ansible/group_vars/all.yml`.

### Path A: SSO with IAM Identity Center (`auth_mode: sso`)

Set these keys in `state/deploy-vars.yml`:

| Key | What to put there |
|---|---|
| `target_account_id` | The 12-digit ID of your account. |
| `source_ecr_account_id` | The account ID of ClickHouse's source registry, which ClickHouse gives you. |
| `sso_start_url` | Your IAM Identity Center portal URL, like `https://<your-portal-id>.awsapps.com/start`. |
| `sso_role_name` | The permission set to use in your account. The default is `AdministratorAccess`. |
| `target_region` | The AWS Region. The default is `us-east-1`. |

The kit renders `.aws/config` from `ansible/files/aws-config.ini.j2`. The file is generated, gitignored, and rewritten on every run, so never edit it by hand. It holds no secrets: only your portal URL, your account ID and a role ARN.

Log in once. The repo-local config is the one to use, so point the CLI at it:

```bash
source scripts/env.sh                        # sets AWS_CONFIG_FILE, AWS_PROFILE and KUBECONFIG
aws sso login --profile "$AWS_PROFILE"
```

The scripts under `scripts/` find the repo-local config on their own, so they work without `env.sh`. You source `env.sh` only for your own interactive `aws` and `kubectl` commands. It also prints your current identity, or the exact login command when you are logged out.

Two consequences of keeping the config in the repo:

1. A bare `aws` command outside this project finds no profiles. That is deliberate: there is one source of truth. Use `source scripts/env.sh` in each new shell.
2. The SSO token cache does not move. The AWS CLI always keeps it in `~/.aws/sso/cache`. It holds only a short-lived token that `aws sso login` regenerates.

The credentials chain like this:

```
  you ──browser login──► IAM Identity Center (SSO)
                              │
                              ▼
                     cached token (hours)
                              │
                              ▼
                 profile target_profile  ──sts:AssumeRole──►  profile source_ecr_profile
                   (ch-gov-target)                              (ch-gov-ecr-pull)
                   (your account)                              (ClickHouseAirgapECRPullRole)
                          │                                     │
                          ▼                                     ▼
                 build all infrastructure               read source ECR only
```

The idea is *role chaining*. `ch-gov-ecr-pull` has no credentials of its own. Its config says "use the target profile's credentials to assume this role", so one browser login covers both profiles. The AWS CLI renews the role's one-hour credentials silently. You never manage a long-lived access key, which is why SSO is the default: nothing secret sits on your disk.

SSO tokens expire after a few hours. When commands start failing with `Error loading SSO Token`, or a script prints `not authenticated`, run the login command again.

### Path B: an existing profile (`auth_mode: profile`)

Use this path when your organization already gives you AWS credentials through named profiles, for example through `aws configure`, a credential helper, or a company login tool. Set these keys in `state/deploy-vars.yml`:

```yaml
aws:
  auth_mode: "profile"
  target_account_id: "<YOUR_ACCOUNT_ID>"
  source_ecr_account_id: "<SOURCE_ECR_ACCOUNT_ID>"
  target_profile: "my-profile"          # a profile you already have
  source_ecr_profile: "ch-gov-ecr-pull" # must exist in your AWS config (see below)
```

In this mode the kit renders no `.aws/config` and leaves `AWS_CONFIG_FILE` alone, so the AWS CLI reads your own file (`~/.aws/config` by default). The `sso_*` keys are ignored.

The kit cannot create the ECR pull profile for you here, so add it to your AWS config. It chains off your target profile:

```ini
[profile ch-gov-ecr-pull]
source_profile = my-profile
role_arn = arn:aws:iam::<YOUR_ACCOUNT_ID>:role/ClickHouseAirgapECRPullRole
role_session_name = ch-gov-ecr-pull
region = us-east-1
```

The role lives in *your* account, so the account ID in `role_arn` is your `target_account_id`. ClickHouse sets the role up; you do not create it. Keep your credentials fresh the way your organization does it. There is no SSO session for the kit to log in to, so a failing profile produces a message that names the profile and asks you to refresh it.

With `fips: true` and this mode, the scripts export `AWS_USE_FIPS_ENDPOINT=true` so the AWS CLI uses FIPS endpoints. In SSO mode the rendered config carries that setting instead.

### Check that both profiles work

```bash
source scripts/env.sh
aws sts get-caller-identity --profile "$AWS_PROFILE"       # your account and your role
aws sts get-caller-identity --profile ch-gov-ecr-pull      # the ClickHouseAirgapECRPullRole session
```

Replace `ch-gov-ecr-pull` with your `source_ecr_profile` if you changed the name. ClickHouse sets up `ClickHouseAirgapECRPullRole` in your AWS account, with the trust relationship and read grant it needs. You share your AWS account ID with your ClickHouse contact so they can do that, and you do not create the role. The kit never creates it either. If the second command fails, the role is not in place for your account yet, so ask your ClickHouse contact. Step 1 of the playbook only checks that you can assume the role.

### What the pull role needs

This section is background, because ClickHouse sets the role up. The kit reads exactly three repositories in the source registry, by name: `clickhouse-server`, `clickhouse-keeper` and `clickhouse-operator`. To do that, the role needs read access to ECR: `ecr:GetAuthorizationToken`, plus the image-read actions `BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability` and `DescribeImages`. The kit never lists repositories, so a permission error when you try to list them with this profile does not mean your setup is broken.

### Permissions for the deploying identity

The identity behind `target_profile` creates real infrastructure, so it needs permissions across several AWS services. In SSO mode the default `sso_role_name` is `AdministratorAccess`, which covers everything below. If your organization requires something narrower, this table is where to start. Each row names the role or template that makes the calls.

| Area | What the kit does | Where |
|---|---|---|
| STS | Reads its own identity, and assumes the ECR pull role (`sts:GetCallerIdentity`, `sts:AssumeRole` on `ClickHouseAirgapECRPullRole`). | Roles `ecr_pull_role`, `ecr_setup`; every script |
| CloudFormation | Creates, updates and deletes the stacks `clickhouse-private-vpc`, `-eks`, `-nodegroups`, `-irsa` and `-ebs-csi`, plus `-langfuse-irsa` and `-grafana-irsa` when those options are on. Stacks that create IAM roles need the `CAPABILITY_IAM` acknowledgement. | Roles `vpc`, `eks_cluster`, `eks_nodegroups`, `storage_iam`, `k8s_prereqs`, `langfuse_storage`, `grafana_storage` |
| EC2 and VPC | Creates the VPC, subnets, internet gateway, NAT gateways, Elastic IPs, route tables, the S3 gateway endpoint and the node launch templates. Also checks which availability zones offer your node instance types (`ec2:DescribeInstanceTypeOfferings`). | Role `vpc` (its tasks and `vpc.yaml`), `ansible/roles/eks_nodegroups/files/eks-nodegroups.yaml` |
| EKS | Creates the cluster, three node groups and the EBS CSI add-on, and writes a kubeconfig (`eks:DescribeCluster`). | `eks-cluster.yaml`, `eks-nodegroups.yaml`, `ebs-csi-addon.yaml`; role `eks_cluster` |
| IAM | Creates and deletes roles and their policies, passes them to EKS, and registers the cluster's OIDC identity provider and later checks that it exists (`iam:CreateOpenIDConnectProvider`, `iam:ListOpenIDConnectProviders`, `iam:GetOpenIDConnectProvider`). | Templates `eks-cluster.yaml`, `eks-nodegroups.yaml`, `irsa-roles.yaml.j2`, `langfuse-irsa.yaml.j2`, `grafana-irsa.yaml.j2`; roles `eks_cluster`, `storage_iam`, `langfuse_storage`, `grafana_storage` |
| ECR (your account) | Creates repositories with immutable tags and scan-on-push, then pushes the copied images and charts. | Roles `ecr_setup`, `image_sync` |
| S3 | Creates buckets, sets their encryption, and reads, writes and deletes objects. | Roles `storage_iam`, `langfuse_storage`, `grafana_storage`; `scripts/s3-purge-cluster-data.sh` |
| CloudWatch Logs | Creates the EKS control-plane log group and sets its retention. | Role `eks_cluster` |
| KMS | Creates keys and aliases. Only when `fips: true`. | `eks-cluster.yaml`, `irsa-roles.yaml.j2`, `langfuse-irsa.yaml.j2` |
| ACM | Imports and deletes a certificate. Only when `langfuse.load_balancer.tls` or `grafana.load_balancer.tls` is on, or `fips: true`. | Roles `langfuse`, `grafana` |
| Elastic Load Balancing | Read-only lookups of the Network Load Balancer that Kubernetes creates for each service: it finds the load balancer, its target groups and its listener, and waits for the targets to pass health checks (`elasticloadbalancing:DescribeLoadBalancers`, `DescribeTargetGroups`, `DescribeTargetHealth`, `DescribeListeners`). When TLS is on for Langfuse or Grafana, it also switches the listener to TLS (`elasticloadbalancing:ModifyListener`). | Roles `clickhouse_loadbalancer`, `langfuse`, `grafana` |

The kit does not create the load balancers itself. When Kubernetes sees a `Service` of type `LoadBalancer`, the EKS control plane creates the Network Load Balancer for you, and the kit only reads it (and, with TLS on, modifies its listener) as the Elastic Load Balancing row describes.

Treat this list as a starting point, not a least-privilege policy. It is derived from what the roles create and call. If a deployment fails with `AccessDenied`, the error names the missing action, so add it and run the step again.

One more rule follows from how EKS works. The identity that creates the cluster becomes its cluster administrator (`BootstrapClusterCreatorAdminPermissions` in `eks-cluster.yaml`), so use the same identity for the `kubectl` commands that follow.

---

## 3b. Persisting your account IDs and SSO portal: `state/deploy-vars.yml`

The `aws:` block in `ansible/group_vars/all.yml` ships with placeholders such as `"<YOUR_ACCOUNT_ID>"` and `"<SOURCE_ECR_ACCOUNT_ID>"`. Real account numbers do not belong in a tracked file, and every script and role reads those values, so you fill them in somewhere else: `state/deploy-vars.yml`.

**Do not hand-edit `.aws/config` or its template, `ansible/files/aws-config.ini.j2`.** `ansible/deploy.yml` re-renders `.aws/config` on every run (`tags: [always]`), so a hand edit is overwritten. `state/deploy-vars.yml` is the one place your values survive.

The first time you run any script under `scripts/` (each one sources `scripts/lib/common.sh`), the kit generates `state/deploy-vars.yml` for you. It is gitignored, so it can never be committed by accident. It holds the same `aws:` shape as `all.yml`. A tracked copy at `state/deploy-vars.yml.example` shows the file without running anything:

```yaml
aws:
  auth_mode: "sso"                       # or "profile" (Path B)
  target_account_id: "<YOUR_ACCOUNT_ID>"
  target_region: "us-east-1"
  target_profile: "ch-gov-target"
  source_ecr_account_id: "<SOURCE_ECR_ACCOUNT_ID>"
  source_ecr_region: "us-east-1"
  source_ecr_profile: "ch-gov-ecr-pull"
  ecr_pull_role_name: "ClickHouseAirgapECRPullRole"
  ecr_pull_session_name: "ch-gov-ecr-pull"
  # auth_mode: sso only -- ignored in profile mode
  sso_start_url: "https://<YOUR_SSO_PORTAL_ID>.awsapps.com/start"
  sso_session_name: "ch-gov"
  sso_region: "{{ aws.target_region }}"
  sso_role_name: "AdministratorAccess"

# Optional -- only needed when grafana.enabled is true (see below).
dhi:
  username: ""   # your Docker Hub username
  token: ""      # your Docker Hub DHI access token
```

Open the file once, as step 2 of "Do this in order" at the top of this Part says, and replace every `<...>` placeholder that applies to your `auth_mode`: the two account IDs always, and `sso_start_url` in SSO mode. Only the keys you set change. Every other key keeps its `all.yml` default, because dictionaries merge key by key. `scripts/play.sh` passes the file to Ansible automatically as `-e @state/deploy-vars.yml`.

If a placeholder is still there, the playbook stops before it touches AWS. It names the offending key and never prints your values.

The generated file and `state/deploy-vars.yml.example` also end with commented-out `fips:`, `langfuse:` and `grafana:` switches that stay off until you uncomment them, as [Part 6](part-6-langfuse.md), [Part 7](part-7-fips-hardening.md) and [Part 8](part-8-grafana.md) explain. The same file can set `size: tutorial` to swap the default `minimal` node and pod sizes for the upstream tutorial's larger ones, and [Part 4](part-4-cluster-preflight-verify.md) explains the difference.

### DHI credentials (Grafana only)

Docker Hardened Images (DHI) is a paid, entitled catalog of images on `dhi.io`. You need DHI credentials in exactly one situation: **when `grafana.enabled` is `true`.** In that case Step 2 mirrors the Grafana and `awscli` images from `dhi.io`, and `image_sync` logs in to that registry first. With Grafana off, the playbook never asks for the credentials. The ClickHouse, Langfuse and Chainguard images are pulled without them.

Provide them in `state/deploy-vars.yml`, using the `dhi:` block shown earlier:

```yaml
dhi:
  username: "<your Docker Hub username>"
  token: "<your Docker Hub DHI access token>"
```

The account must be entitled to the DHI catalog. Alternatively, set the `DHI_USERNAME` and `DHI_TOKEN` environment variables. The kit uses them only when the two `dhi` keys are empty. The file survives new shells and reboots, so it is the more convenient choice. The file is gitignored, and the login is written to `state/skopeo-auth.json`, which is also gitignored.

If Grafana is on and both are missing, `image_sync` stops with `An artifact sources from dhi.io but the DHI username/token are empty or still a <...> placeholder`. Part 8 covers the Grafana steps.

---

## 4. How this repo relates to ClickHouse's tutorial

ClickHouse publishes a tutorial for this deployment at [docs/cloud/clickhouse-private/tutorials/deploy-aws](https://clickhouse.com/docs/cloud/clickhouse-private/tutorials/deploy-aws). It gives the steps as explicit commands. The Ansible in `ansible/` implements those steps, in the same order, so you can read the tutorial for the reasoning and this repo for the automation. Part 2 walks through the first steps.

## 5. Running the playbook: `scripts/play.sh`

The deployment is an Ansible playbook, but you rarely start it directly. `scripts/up.sh` (section 5b) calls `scripts/play.sh`, and `play.sh` sets up the environment the playbook needs. You get the same result with less to remember, because three things are easy to get wrong:

**1. The environment has to point into the repo.** `AWS_CONFIG_FILE` (in SSO mode) and `KUBECONFIG` must be the project-local ones. If they are not, you get `The config profile (ch-gov-target) could not be found`, or, much worse, a run against whatever cluster your personal `~/.kube/config` names.

**2. The playbook must run from `ansible/`.** `ansible.cfg` is resolved relative to the current directory, and it supplies the inventory and `roles_path`. From the repo root, Ansible silently uses different settings.

**3. Ansible refuses to start on non-blocking pipes.**

```
ERROR: Ansible requires blocking IO on stdin/stdout/stderr.
Non-blocking file handles detected: <stdout>, <stderr>
```

This has nothing to do with your command. Some parent processes, such as CI runners and certain editor terminals, hand their child non-blocking file descriptors, and Ansible checks for that and stops. `play.sh` clears the flag on the three descriptors before it starts the playbook, so the terminal stays attached and you keep coloured output.

`play.sh` also checks your credentials before it does anything. When they have expired, you see the exact fix:

```
[fail] not authenticated -- run: AWS_CONFIG_FILE=/path/to/repo/.aws/config aws sso login --profile ch-gov-target
```

Without that check, an expired token shows up partway into a run as an unrelated-looking module failure, sometimes after something has already been created.

> **Advanced: run individual steps.** While you learn one step at a time, or when you re-run a step after fixing a problem, pass a tag to `play.sh`:
>
> ```bash
> scripts/play.sh --tags nodes           # one step
> scripts/play.sh --check --tags storage # dry run
> scripts/play.sh --help                 # usage and the full list
> ```
>
> The tags are `images vpc eks nodes storage prereqs operator cluster preflight verify lb`, plus `lf-storage lf-db lf-app` and `gf-storage gf-db gf-app` for the optional Steps 13–18. Parts 2 onward name the tag for each step.

## 5b. The two scripts you will actually use: `up.sh` and `down.sh`

Day to day you want two verbs, and you want them to know the order so you do not have to:

```bash
scripts/up.sh                  # Steps 1-12, in order, idempotent; asks first
scripts/up.sh --from nodes     # start at a step (for example after down.sh)
scripts/up.sh --skip-images    # skip the Step 2 image hop once it has run

scripts/down.sh                # stop the meter: load balancer, cluster, node groups
scripts/down.sh --nodes-only   # just the nodes: fastest; pods go Pending, the NLB stays
scripts/down.sh --all          # everything except the S3 bucket and ECR images
```

`up.sh` adds the optional Langfuse steps (`lf-storage lf-db lf-app`, Steps 13–15) and Grafana steps (Steps 16–18) when `langfuse.enabled` or `grafana.enabled` is `true` (both are `false` by default), and `down.sh` removes whatever exists, whether or not the setting is still `true`. Part 6 covers Langfuse and Part 8 covers Grafana.

`down.sh` exists because teardown is **not** `up.sh` backwards. Several dependencies point the other way, and getting one wrong leaves something orphaned and billing:

1. The load balancer `Service` goes **before** the cluster or EKS. Deleting the `Service` is what deletes the NLB. Delete EKS first and the NLB survives it, then blocks deletion of the VPC stack.
2. The ClickHouse cluster goes **while the nodes are still up.** Removing its namespace needs the operator (to unwind the resource's finalizers) and the EBS CSI controller (to release Keeper's volumes). With no nodes, neither runs, the namespace hangs in `Terminating`, and the EBS volumes are orphaned. `down.sh` refuses to start if it finds the namespace with no nodes, and tells you what to do instead.
3. The prerequisites and storage teardowns read the EKS cluster and the IRSA stack, so they run before EKS goes, and prerequisites before storage.
4. Langfuse (optional Steps 13–15) goes **before the ClickHouse cluster.** Its tables live in that cluster, and its PostgreSQL and Valkey disks are EBS volumes, so removing it needs the operator and the EBS CSI driver running. The same zero-nodes refusal applies to the `langfuse` namespace.
5. Grafana (optional Steps 16–18) also goes before the ClickHouse cluster, for the same load-balancer reason. It has no persistent volume, so it does not need the nodes to be up.

Each teardown is a separate playbook run, because every role ends the play after its own teardown task. That is why the script loops instead of passing one long `--tags` list. Neither script deletes your ClickHouse or Langfuse data buckets. The one bucket teardown does remove is Grafana's plugin mirror, which holds a single re-downloadable file.

## 6. Check your setup

Run these checks in order. Each one gives a command and the result you should see, and the checks double as exercises for a workshop. If one fails, section 7 lists the common causes.

1. **All tools and both profiles pass the setup check.**

   ```bash
   scripts/part1-setup.sh --check
   ```

   You should see a version table with no `NOT FOUND` entries, an `[ ok ]` line for each profile, and a final `Part 1 complete` heading followed by `tools installed, both profiles authenticate, source ECR reachable`, then the closing line:

   ```
   next: source scripts/env.sh, then scripts/up.sh
   ```

   The exit status is `0`. On a first run, before you have edited `state/deploy-vars.yml` and logged in, expect failures for the two profiles instead. Fix them in the order shown under "Do this in order", and run the check again.

2. **Your shell points at the repo's configuration.**

   ```bash
   source scripts/env.sh
   ```

   You should see `AWS_CONFIG_FILE`, `AWS_PROFILE` (your `target_profile`) and `KUBECONFIG` (`state/kubeconfig`), then a line starting `identity:` with your role's ARN. `not logged in` means you need to log in or refresh credentials.

3. **The target profile is in the right account.**

   ```bash
   aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text
   ```

   You should see the 12-digit `target_account_id` you set.

4. **The pull profile assumes the pull role.**

   ```bash
   aws sts get-caller-identity --profile ch-gov-ecr-pull --query Arn --output text
   ```

   You should see an ARN that ends `assumed-role/ClickHouseAirgapECRPullRole/ch-gov-ecr-pull`, in your account.

5. **You can read ClickHouse's registry.** The last section of the setup check does this. Look for `ECR authorization token obtained`, then the three repositories with up to three recent image tags each. Those tags are the ones a deployment can copy today.

6. **The Python environment is ready for Ansible.**

   ```bash
   .venv/bin/python3 -c 'import boto3, kubernetes; print("ok")'
   ```

   You should see `ok`.

7. **The wrapper runs.**

   ```bash
   scripts/play.sh --help
   ```

   You should see the usage text. Nothing is deployed.

## 7. Troubleshooting

Each entry gives the symptom, the cause and the fix.

**`Error loading SSO Token`, or a script prints `not authenticated -- run: ... aws sso login ...`**

- *Cause:* the SSO token expired. Tokens last hours, not days.
- *Fix:* run the login command the message prints, or `source scripts/env.sh` and `aws sso login --profile "$AWS_PROFILE"`.

**`The config profile (ch-gov-target) could not be found`, or `profile '...' not defined`**

- *Cause (SSO mode):* the AWS CLI is not reading the repo's `.aws/config`, because your shell never sourced `scripts/env.sh`.
- *Cause (profile mode):* the profile is missing from the config file the CLI reads.
- *Fix:* in SSO mode, run `source scripts/env.sh` or go through the scripts. In profile mode, add the profile to your AWS config, and check that the names match `target_profile` and `source_ecr_profile`.
- *On a first run:* if you have not yet edited `state/deploy-vars.yml` or logged in, see the entry "The first `scripts/part1-setup.sh` run reports ..." below.

**`These settings still hold a <...> placeholder`**

- *Cause:* `state/deploy-vars.yml` still contains a value such as `<YOUR_ACCOUNT_ID>`. The message lists the keys.
- *Fix:* edit `state/deploy-vars.yml` (section 3b) and run again.

**The first `scripts/part1-setup.sh` run reports `profile '...' not defined` or `will not authenticate`**

- *Cause:* you have not yet edited `state/deploy-vars.yml` or logged in. The profiles cannot authenticate before that.
- *Fix:* follow "Do this in order" at the top of this Part: edit the file (section 3b), log in (section 3), then run `scripts/part1-setup.sh --check` again.

**`Profile '...' resolves to account X, but group_vars says Y`**

- *Cause:* `target_account_id` does not match the account your `target_profile` actually signs in to.
- *Fix:* correct `target_account_id` in `state/deploy-vars.yml`, or point `target_profile` at the right account.

**`Profile '...' could not authenticate`, or `authenticates, but not as the ECR pull role`**

- *Cause:* the pull role is not set up for your account, its trust relationship does not allow your identity, or the names in your configuration do not match.
- *Fix:* check `ecr_pull_role_name` and `source_ecr_profile`, and make sure the target profile is logged in. If both look right, ask your ClickHouse contact to confirm the role exists in your account.

**`scripts/part1-setup.sh` stops with `Homebrew required`**

- *Cause:* a tool is missing and Homebrew is not installed. This is common on Linux.
- *Fix:* install the missing tools as section 2 describes, or install Homebrew for Linux, then run the script again.

**`python3 is X.Y; need 3.12+`**

- *Cause:* `ansible-core` 2.21 requires Python 3.12 or later, so the playbook fails on an older interpreter.
- *Fix:* install Python 3.12 or later and make it the `python3` on your `PATH`. The script rebuilds an older `.venv/` on its own.

**`module not found`, or a message that `boto3` or `kubernetes` is missing**

- *Cause:* the Ansible collections or the `.venv/` environment are missing or out of date.
- *Fix:* run `scripts/part1-setup.sh`. It installs both.

**`ERROR: Ansible requires blocking IO on stdin/stdout/stderr`**

- *Cause:* the process that started your shell gave it non-blocking file descriptors.
- *Fix:* start the playbook through `scripts/play.sh` (which `up.sh` uses), which clears the flag.

**The image copy in Step 2 fails because a tag does not exist**

- *Cause:* ClickHouse purges old tags from the source registry over time, and the versions pinned under `versions:` in `ansible/group_vars/all.yml` can fall out of date.
- *Fix:* run `scripts/part1-setup.sh` and read the tags it lists in the final section. Set the matching entry under `versions:` in `state/deploy-vars.yml` to a tag that exists, then run again. Enter the base tag only: with `fips: true` the kit appends the `-fips` suffix itself.

**`kubectl` prints a version-skew warning**

- *Cause:* Kubernetes supports a `kubectl` within one minor version of the cluster. Your `kubectl` is further away from `infrastructure.eks_version`.
- *Fix:* install a `kubectl` within one minor version of `infrastructure.eks_version`, or choose an `eks_version` that fits the `kubectl` you have.

**A Helm task fails in a way that looks unrelated to your change**

- *Cause:* the Ansible Helm modules were written against Helm 3, and Helm 4 behaves differently in places. Part 4 describes one such case with the operator.
- *Fix:* check the Helm version first (`helm version --short`). Try Helm 3 if a Helm task misbehaves.

**`An artifact sources from dhi.io but the DHI username/token are empty`**

- *Cause:* `grafana.enabled` is `true` and no DHI credentials are set.
- *Fix:* set `dhi.username` and `dhi.token` in `state/deploy-vars.yml` (section 3b).

**`kubectl preflight` is not found in your own shell**

- *Cause:* `krew` puts plugins in `~/.krew/bin`, which is not on your `PATH`. The scripts add it for themselves only.
- *Fix:* add `$HOME/.krew/bin` to your `PATH`.

**`kubectl` says `You must be logged in to the server (Unauthorized)`**

- *Cause:* you are using a different identity from the one that created the cluster, and only the creator is an administrator by default.
- *Fix:* use the profile you deployed with (`source scripts/env.sh`, then run `kubectl` again).

**Where to go next:** Part 2 copies the images into your registry and starts building the infrastructure.
