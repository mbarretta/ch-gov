# ClickHouse Government on AWS EKS: a hands-on learning kit

This repository is a guided, automated way to learn ClickHouse Government by building it. You run a handful of commands, and Ansible builds a ClickHouse cluster with an airgapped design on Amazon EKS in your own AWS account. The docs explain every step it takes, so you can read, run, and take it apart at your own pace or in a facilitated workshop.

ClickHouse is a database built for analytics: it answers questions like "how many, by hour, by region" across billions of rows in well under a second. Two optional add-ons show what you can build on top of it. [Langfuse](https://langfuse.com) is an open-source platform for tracing and evaluating LLM applications, and it stores its data in ClickHouse. [Grafana](https://grafana.com) is a dashboarding tool, and here it queries the cluster through the ClickHouse datasource plugin.

## What ClickHouse Government is

ClickHouse Government is ClickHouse Private with a FIPS-validated cryptography build. ClickHouse Private is the core of ClickHouse Cloud packaged so that you run it yourself, in your own cloud account and on your own Kubernetes cluster, with no connection back to ClickHouse once it is installed. The Government build uses the FIPS-validated cryptography that ClickHouse provides, which means x86_64 machines and different image tags, and changes little else that you would notice day to day. ClickHouse Government is built for airgapped networks: the cluster that holds your data pulls container images only from a registry in your own account, and never from the internet. This kit adds a NAT gateway so that you can reach and test the cluster from your own machine. The gateway belongs to this learning environment and is not part of the production deployment.

## What you'll learn and see

- **An airgapped-design deploy on EKS.** How container images make one hop from ClickHouse's registry into yours, and how a VPC, an EKS cluster, node groups, storage, the ClickHouse operator, and a ClickHouse cluster with three servers and three Keeper nodes fit together.
- **FIPS 140-3 mode.** What the single `fips` switch changes, from images and instance types to AWS endpoints, encryption keys, and TLS between components, and what it does not cover. The validated cryptography is ClickHouse's; [limitations](docs/limitations.md) says what the kit covers and does not cover by design.
- **Langfuse on ClickHouse (optional).** How an application uses ClickHouse Private as its analytics store, including a smoke test that sends a trace in and reads it back out of ClickHouse.
- **Grafana with a ClickHouse datasource (optional).** How a dashboard tool is wired to the cluster with a read-only user and a plugin mirrored into your own S3 bucket.
- **How to operate it.** How to connect, verify, watch the cost meter, stop and resume the cluster, and tear everything down.

## What you need from ClickHouse

You need three things before you start, and all of them come from your ClickHouse account team:

- **The entitlement.** Access to ClickHouse Government (ClickHouse Private), which is what lets you read its container images.
- **Access to the image registry for your AWS account.** ClickHouse sets up the pull role `ClickHouseAirgapECRPullRole` in your AWS account, with the trust and the read access to the source registry that it needs. You do not create it. Share your AWS account ID with your ClickHouse contact, and the kit checks, before it copies anything, that your account can assume the role.
- **The source registry's account ID.** ClickHouse tells you the AWS account that hosts the images. In the docs and in `ansible/group_vars/all.yml` it appears as the placeholder `<SOURCE_ECR_ACCOUNT_ID>`, and you set the real value as `aws.source_ecr_account_id` in `state/deploy-vars.yml`. Part 1 walks through this file.

You also need an AWS account of your own with permission to create VPCs, EKS clusters, IAM roles, S3 buckets, KMS keys, and ECR repositories, and a way to sign in to it, either AWS IAM Identity Center (SSO) or a named profile you already have.

## Third-party accounts

- **Chainguard (free tier).** Only if you turn on Langfuse. Its bundled PostgreSQL and Valkey run on Chainguard images from `cgr.dev`, which the free tier serves without a login, so you need internet access for the image copy but no account.
- **Docker Hardened Images (DHI) entitlement.** Only if you turn on Grafana. Its images come from `dhi.io`, which requires a Docker Hub account entitled to the DHI catalog. You supply the username and an access token in `state/deploy-vars.yml` or in the `DHI_USERNAME` and `DHI_TOKEN` environment variables. A run without Grafana never asks for them.

## What it costs and how long it takes

> **Tear down when you finish.** A running cluster bills every hour whether or not you use it. Run `scripts/down.sh --all` when you are done. The default `scripts/down.sh` stops the expensive part but keeps the VPC, EKS control plane, and NAT gateway, which still cost about $0.15 an hour.

The figures below are planning estimates for `us-east-1` with the default `minimal` size. They cover the hourly price of compute, the EKS control plane, and one NAT gateway. Data transfer, EBS volumes, S3 storage, and CloudWatch logs are extra and small at learning scale. The `size: tutorial` setting uses the upstream tutorial's much larger nodes, and the compute alone then costs roughly $12 an hour, or $13.41 an hour with `fips: true`.

| State | Approximate cost | How you get there |
|---|---|---|
| Everything up, standard build | $2.32 an hour, about $56 a day | `scripts/up.sh` |
| Everything up, `fips: true` | $2.58 an hour, about $62 a day | `scripts/up.sh` with `fips: true` |
| Langfuse or Grafana switched on | about $0.02 an hour more for each | `enabled: true` in the `langfuse:` or `grafana:` block |
| Nodes down, VPC and EKS kept | about $0.15 an hour | `scripts/down.sh` |
| Everything removed except S3 data and ECR images | close to $0 | `scripts/down.sh --all` |

The playbook prints the same estimate before it creates the node groups, computed from the `pricing:` table in `ansible/group_vars/all.yml`. Change the instance types or the number of NAT gateways and the estimate changes with them.

For time, plan on roughly an hour for the first `scripts/up.sh`, most of it waiting for AWS to build the EKS control plane and the node groups. Rebuilding after a default `scripts/down.sh` with `scripts/up.sh --from nodes` takes roughly 15 minutes, and teardown takes roughly 10 to 15 minutes. Switching on Langfuse and Grafana adds roughly 10 minutes together. These are expectations for planning, not guarantees, and they vary with region, AWS load, and sizing.

## How to use these docs

The docs are numbered Parts. Part 0 is the concepts primer and Part 1 gets your machine ready. Parts 2 to 5 follow the deployment steps one at a time, and Parts 6 to 8 cover the optional capabilities and the FIPS switch. [Limitations](docs/limitations.md) says where this learning setup differs from a production one.

**Self-paced path.** Read Part 0 for the concepts, then Part 1 to set up your machine. Start `scripts/up.sh`, and while it runs, read Parts 2 to 5 to see what each step is doing and why. Add Part 6 and Part 8 if you switch on Langfuse or Grafana, read Part 7 if you use FIPS mode, and finish with the limitations page.

**Workshop path.** Start the first deploy before the session, because it takes about an hour, and walk the participants through the Parts against the live cluster. To repeat the exercise within a session, use `scripts/down.sh` and `scripts/up.sh --from nodes`, which takes roughly 15 minutes. A facilitator can pick a subset from the table below. The "Step N" numbers there are the kit's numbering of ClickHouse's tutorial steps, and the step table in [Part 0](docs/part-0-what-is-this.md) lists them all.

| Part | What it teaches | Deploy or operate |
|---|---|---|
| [Part 0](docs/part-0-what-is-this.md) | What ClickHouse, Keeper, the operator, and an airgap are; the two commands you run; what exists afterward | Both: concepts, then operating and teardown |
| [Part 1](docs/part-1-prerequisites.md) | Tools, AWS access, your account IDs, and the `up.sh` and `down.sh` scripts | Deploy: setup |
| [Part 2](docs/part-2-image-sync.md) | Steps 1 to 5: the pull role, copying images into your registry, the VPC, EKS, and node groups | Deploy |
| [Part 3](docs/part-3-storage-and-operator.md) | Steps 6 to 8: the S3 bucket, IAM roles for service accounts, Kubernetes prerequisites, and the operator | Deploy |
| [Part 4](docs/part-4-cluster-preflight-verify.md) | Steps 9 to 11: the ClickHouse cluster, preflight checks, and proving it works | Deploy, then operate: verify and connect |
| [Part 5](docs/part-5-load-balancer.md) | Step 12: reaching the cluster from outside with a load balancer | Deploy, then operate: connect |
| [Part 6](docs/part-6-langfuse.md) | Steps 13 to 15: Langfuse on ClickHouse, TLS, the smoke test, and teardown order | Deploy, then operate: smoke test and teardown |
| [Part 7](docs/part-7-fips-hardening.md) | What `fips: true` changes: endpoints, encryption keys, and TLS | Deploy: configuration and self-checks |
| [Part 8](docs/part-8-grafana.md) | Steps 16 to 18: Grafana with a ClickHouse datasource, and its smoke test | Deploy, then operate: smoke test and teardown |

## Quickstart

[Part 1](docs/part-1-prerequisites.md) has the ordered setup box with the details of each command. The order matters. A first `scripts/part1-setup.sh` run installs the tools and creates `state/deploy-vars.yml`, but its AWS profile checks report failures until you have edited that file and logged in. Once you have, run `scripts/part1-setup.sh --check` to confirm, then start the deploy.

```bash
scripts/part1-setup.sh    # install the tools; creates state/deploy-vars.yml (profile checks fail until the next two steps)
# edit state/deploy-vars.yml: your account ID, the source registry account ID,
# and your SSO portal URL (or set aws.auth_mode: profile to use a profile you already have)
source scripts/env.sh     # point this shell at the project's AWS configuration
aws sso login             # SSO mode only
scripts/part1-setup.sh --check   # verify the tools and both AWS profiles; changes nothing
scripts/up.sh             # prints the estimated cost, asks for a y, then builds Steps 1 to 12
```

When `scripts/up.sh` finishes, it prints how to connect. To check that the cluster answers, run a query through the port-forward helper. It needs a local ClickHouse client, one of the optional tools in [Part 1](docs/part-1-prerequisites.md), for example `brew install clickhouse`:

```bash
scripts/ch-client.sh -q "SELECT version()"
```

To include the optional capabilities, set `enabled: true` in the `langfuse:` block, the `grafana:` block, or both, in `state/deploy-vars.yml`. Then run `scripts/up.sh` again. Every step is idempotent, so running it over an existing stack changes only what differs.

To stop, use the teardown script:

```bash
scripts/down.sh --all
```

Run `scripts/up.sh --help` and `scripts/down.sh --help` to see every option.

## What this kit is, and what it is not

This kit is a reference for learning and workshops. It is not a supported production deployment. It uses small sizing, a single NAT gateway that the airgapped design does not include, and self-signed certificates, and [limitations](docs/limitations.md) states each difference along with what the kit does and does not cover by design. For a production deployment, or for support, contact your ClickHouse account team.

For the FIPS posture on its own, where the validated cryptography is ClickHouse's, read [FIPS.md](FIPS.md) for the short answer and [Part 7](docs/part-7-fips-hardening.md) for the mechanism behind each claim.

## What is in the repository

| Path | What it holds |
|---|---|
| [`docs/`](docs/part-0-what-is-this.md) | The Parts, in order, and [`docs/limitations.md`](docs/limitations.md) |
| [`FIPS.md`](FIPS.md) | The FIPS 140-3 posture in one page: what `fips: true` covers and what it does not |
| `ansible/` | The playbook and roles that build each step, and `ansible/group_vars/all.yml`, the one configuration file with a comment on every value |
| `scripts/` | The scripts you run: `up.sh`, `down.sh`, `play.sh`, `ch-client.sh`, the two smoke tests, and setup helpers |
| `state/` | Local files the scripts generate, such as passwords and the kubeconfig. Everything in it except the tracked example is gitignored |

## Check yourself

Use these as a quick review or as exercises in a workshop.

1. Run `kubectl get nodes -L clickhouseGroup` after `source scripts/env.sh`. You should see eight nodes: three keeper, three server, and two operator nodes. Only the keeper and server nodes carry the `clickhouseGroup` label, with an `-arm64` suffix in the standard build (`keeper-arm64`, `server-arm64`), so the two operator nodes show `<none>`. Which pods would you expect on each, and why?
2. Run `kubectl -n ns-default-us-01 get pods -o wide`. You should see three Keeper pods and three server pods, all Running, spread across different nodes. Why does the cluster need an odd number of Keeper nodes?
3. Find where the estimated hourly cost is printed and compare it with the table above. What would change it?
4. After `scripts/down.sh`, what is still running, what does it cost, and what does `scripts/up.sh --from nodes` recreate?
