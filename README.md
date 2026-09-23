# ClickHouse Private on AWS EKS

An Ansible-driven, airgapped deployment of ClickHouse Private (optionally
with Langfuse on top) into your own AWS account and EKS cluster, following
[ClickHouse's own tutorial](https://clickhouse.com/docs/cloud/clickhouse-private/tutorials/deploy-aws)
step for step. Start with [`docs/part-0-what-is-this.md`](docs/part-0-what-is-this.md)
if you have never touched this project before — it explains what gets built,
why, and the two commands you actually run.

## Top-level files

| Path | What |
|---|---|
| [`FIPS.md`](FIPS.md) | Short posture synopsis: what `fips: true` protects, what it doesn't, and the bottom line for a compliance decision |
| [`docs/`](docs/part-0-what-is-this.md) | The step-by-step parts, in order — Part 0 first |
| `ansible/` | The playbook and roles that do the actual deployment |
| `scripts/` | The wrapper shell scripts (`up.sh`, `down.sh`, `play.sh`, and friends) that drive the playbook |
| `.gitignore` | Excludes generated, credential-bearing files (`.aws/config`, `state/`) from version control |

## Getting started

```bash
scripts/part1-setup.sh   # one-time local tool setup -- see docs/part-1-prerequisites.md
scripts/up.sh            # bring the whole deployment up -- see docs/part-0-what-is-this.md
```

For the FIPS-hardened posture (`fips: true` in `ansible/group_vars/all.yml`),
read [`FIPS.md`](FIPS.md) first, then [`docs/part-7-fips-hardening.md`](docs/part-7-fips-hardening.md)
for the mechanism behind each claim.
