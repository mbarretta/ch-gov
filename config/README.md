# config/

The settings a deploy reads. Everything here except the `.example` files and this README is gitignored, so your account IDs and credentials stay out of git. What a run writes goes in `state/` instead.

| File | What it is | How you get it |
|---|---|---|
| `deploy-vars.yml` | Your account IDs, SSO portal URL, load balancer choices and any other override of `ansible/group_vars/all.yml`. Only the keys you set change. | The first script you run creates it. Or copy `deploy-vars.yml.example`. |
| `deploy-flags.json` | The component switches (`fips`, `size`, `langfuse`, `grafana`, `sso`, and `clickhouse.second_service` for the second service). Layered on top of `deploy-vars.yml`, so a key set in both takes this file's value. | `scripts/go.sh` writes it from its flags. Or copy `deploy-flags.json.example` and edit it. |

Every script reads both files, so `scripts/go.sh`, `scripts/up.sh` and `scripts/play.sh` always agree on what is switched on. [Part 1](../docs/part-1-prerequisites.md) walks through the keys.
