# Part 9 — Steps 6b and 11b: single sign-on with Amazon Cognito

> **What you'll learn**
>
> - How one Amazon Cognito user pool signs people in to Langfuse (OpenID Connect) and to ClickHouse (a JWT), and where an external identity provider can plug in.
> - How to switch it on, which `sso:` variables and tags drive it, and how a Cognito group becomes a ClickHouse role.
> - How to log in as yourself with `scripts/ch-client.sh --sso`, and what `scripts/sso-smoke.sh` checks.
> - The behaviours of ClickHouse's JWT user directory that decide how safe it is to run, with the mitigation the kit applies for each.
> - Why the service connections (Langfuse, Grafana, admin, Prometheus) stay on passwords, what changes in GovCloud, and why IAM outbound identity federation is documented here and not built.
>
> **Run it:** set `sso.enabled: true` plus the pieces you want, then run `scripts/up.sh` and `scripts/sso-smoke.sh`. Cognito bills by monthly active user; see [Amazon Cognito pricing](https://aws.amazon.com/cognito/pricing/).

Parts 1–5 end with a ClickHouse cluster behind a load balancer. [Part 6](part-6-langfuse.md) and [Part 8](part-8-grafana.md) add Langfuse and Grafana next to it. This part adds a third optional capability, also off by default: people sign in as themselves instead of sharing the generated admin passwords. With `sso.enabled: false` (the shipped default) no existing step renders anything different and no AWS resource is created.

```bash
# in state/deploy-vars.yml (or ansible/group_vars/all.yml):  sso.enabled: true  (plus the keys in section 3)
scripts/up.sh                       # Steps 1-18 in order; sso-idp runs after storage, ch-jwt after verify
scripts/sso-smoke.sh                # check discovery, Langfuse's provider list, and a token login
scripts/ch-client.sh --sso          # open a ClickHouse session as yourself
```

---

## 1. The architecture

Three things work together, and each one has its own step.

```
                         Amazon Cognito user pool  (Step 6b)
        ┌──────────────────────────────────────────────────────────┐
        │  users + groups (clickhouse-readonly, clickhouse-admin)  │
        │  optional SAML identity provider (agency IdP, Identity   │
        │  Center) that authenticates users before Cognito signs   │
        │  the tokens                                              │
        │                                                          │
        │  app client "langfuse"   (confidential, has a secret)    │
        │  app client "clickhouse" (public, PKCE, no secret)       │
        └───────┬───────────────────────────────┬──────────────────┘
                │ OIDC code flow                │ ID token (RS256 JWT)
                │ (hosted UI + token endpoint)  │ claims: aud, cognito:groups
                ▼                               ▼
   browser ──► Langfuse pods              scripts/ch-client.sh --sso
   (AUTH_COGNITO_*)                              │  clickhouse-client --jwt <token>
                                                 ▼
                          ClickHouse server: <user_directories><jwt>   (Step 9)
                            fetches Cognito's JWKS, checks signature + aud,
                            maps cognito:groups to roles (Step 11b creates them)
```

- **The Cognito user pool (Step 6b).** One CloudFormation stack holds the pool, its hosted-UI domain, the groups you list, an optional SAML identity provider and two app clients. Sign-up is off: an administrator creates the users, or the SAML provider brings them. See [Amazon Cognito's SAML documentation](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-saml-idp.html) for how a pool federates to an external identity provider, such as [IAM Identity Center as a SAML application](https://docs.aws.amazon.com/singlesignon/latest/userguide/customermanagedapps-saml2-setup.html) or an agency identity provider. The kit takes only a SAML metadata URL.
- **Langfuse sign-in (Step 15, `lf-app`).** Langfuse has a built-in Cognito provider, configured through `AUTH_COGNITO_*` environment variables. The kit writes them to a Kubernetes Secret called `langfuse-sso` and hands it to the web and worker pods. See [Langfuse's authentication and SSO documentation](https://langfuse.com/self-hosting/security/authentication-and-sso).
- **ClickHouse sign-in (Steps 9 and 11b).** Step 9 adds a JWT user directory to the server configuration, and Step 11b creates the ClickHouse roles that Cognito group names map to. A person gets a short-lived Cognito ID token from the `clickhouse` app client and presents it to the server. The server checks the token itself; it never calls Cognito at login time, because it keeps a copy of the pool's public signing keys (its JWKS document).

The ClickHouse path relies on the JWT user directory that ClickHouse ships in the server build the Government images come from. ClickHouse's [JWT authentication page](https://clickhouse.com/docs/operations/external-authenticators/jwt) describes the feature and which builds carry it. The kit does not restrict the directory to `fips: true`.

## 2. What the steps are

| Step | Tag | What happens | Runs when |
|---|---|---|---|
| 6b | `sso-idp` | Creates the Cognito stack, reads the pool's live OpenID discovery document, and writes `state/sso-cognito-outputs.json` (and the Langfuse client secret to `state/sso-cognito-client-secret`) | `sso.enabled` |
| 9 | `cluster` | Adds the JWT user directory to the ClickHouse Helm values, after checking that a pod on the server nodes can fetch the JWKS URL | `sso.enabled` and `sso.clickhouse_jwt.enabled` |
| 11b | `ch-jwt` | Creates one ClickHouse role per group and the permission-limit role that caps every token login | `sso.enabled` and `sso.clickhouse_jwt.enabled` |
| 15 | `lf-app` | Writes the `langfuse-sso` Secret and rolls the Langfuse pods when it changes | `sso.enabled` and `sso.langfuse.enabled` and `langfuse.enabled` |

The tag `sso` selects both 6b and 11b. The order matters and `scripts/up.sh` keeps it: `sso-idp` comes after `storage` and before `cluster`, because Step 9 reads the issuer, the JWKS URL and the ClickHouse client ID from the outputs file, and `ch-jwt` comes after `verify`, so a broken cluster is caught first. `--from` preserves the order.

## 3. The switches: the `sso:` variables

Put overrides in `state/deploy-vars.yml`. `ansible/group_vars/all.yml` holds the defaults, and `state/deploy-vars.yml.example` carries the same block commented out. `ansible/ansible.cfg` sets `hash_behaviour = merge`, so nested mappings under `sso:` merge key by key across sources while lists (`groups`, `enforce_domains`, `networks`) are replaced whole. A run that does not use that `ansible.cfg` replaces the entire `sso` mapping instead, so copy the complete block when in doubt.

| Variable | Default | What it does |
|---|---|---|
| `sso.enabled` | `false` | The master switch. `false` means Steps 6b and 11b do nothing |
| `sso.provider` | `"cognito"` | The only provider the kit implements |
| `sso.cognito.domain_prefix` | `""` | Hosted-UI domain prefix: `https://<prefix>.auth.<region>.amazoncognito.com`. Required when enabled. Lowercase letters, digits and hyphens, unique within the region, and it must not contain `aws`, `amazon` or `cognito` |
| `sso.cognito.saml_metadata_url` | `""` | A SAML metadata URL from your identity provider. Empty means users are held in the Cognito pool itself |
| `sso.cognito.groups` | `clickhouse-readonly`, `clickhouse-admin` | Cognito groups created in the pool. Names must be distinct and contain no spaces |
| `sso.langfuse.enabled` | `false` | Creates the Langfuse app client and wires Langfuse's Cognito sign-in. Needs `langfuse.enabled: true` |
| `sso.langfuse.disable_password_login` | `false` | `true` hides the email and password form so Cognito is the only way in. While it is `false`, password self-registration is open too (see section 5) |
| `sso.langfuse.enforce_domains` | `[]` | Email domains Langfuse limits sign-in to. Empty means no restriction |
| `sso.langfuse.default_org_role` | `"VIEWER"` | Organization role a user gets at first sign-in. One of `OWNER`, `ADMIN`, `MEMBER`, `VIEWER`, `NONE` |
| `sso.langfuse.default_project_role` | `"VIEWER"` | Project role at first sign-in, same choices |
| `sso.clickhouse_jwt.enabled` | `false` | Adds the JWT user directory (Step 9) and creates the roles (Step 11b) |
| `sso.clickhouse_jwt.permission_limit_role` | `""` | Name of the role that caps every token login. Empty means `jwt_ceiling` |
| `sso.clickhouse_jwt.group_prefix` | `"clickhouse-"` | Only groups whose name starts with this prefix map to ClickHouse roles |
| `sso.clickhouse_jwt.role_grants` | `{}` | Group name to a list of `GRANT` statements for that group's role |
| `sso.clickhouse_jwt.networks` | `[]` | Source networks ClickHouse accepts token logins from. Empty means the VPC CIDR (`infrastructure.vpc_cidr`) and `127.0.0.1/32`. A list you set is used exactly as given |

A complete override that turns on both consumers looks like this:

```yaml
sso:
  enabled: true
  provider: "cognito"
  cognito:
    domain_prefix: "<YOUR_COGNITO_DOMAIN_PREFIX>"
    saml_metadata_url: ""
    groups:
      - "clickhouse-readonly"
      - "clickhouse-admin"
  langfuse:
    enabled: true
    disable_password_login: false
    enforce_domains: []
    default_org_role: "VIEWER"
    default_project_role: "VIEWER"
  clickhouse_jwt:
    enabled: true
    permission_limit_role: ""
    group_prefix: "clickhouse-"
    role_grants:
      clickhouse-readonly:
        - "GRANT SELECT ON *.*"
      clickhouse-admin:
        - "GRANT SELECT, INSERT ON *.*"
    networks: []
```

Each `role_grants` statement is written without a `TO` clause; the group's role is added as the grantee. Every key must start with `group_prefix`, every statement must be a single `GRANT`, and the role names may use letters, digits, underscore, dot and hyphen only. The defaults leave `role_grants` empty on purpose: because dictionaries merge across sources, an operator could not remove a default entry. A group with no `role_grants` entry gets a role that grants nothing.

Langfuse sign-in also needs `langfuse.url` set to the `https://` address people use. Cognito accepts only `https` callbacks (plain `http` is allowed for `localhost` alone), and the kit's self-signed load balancer hostname is not one it should redirect a browser to, so Step 6b stops with a message if the URL is missing. See the [Cognito app client documentation](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-settings-client-apps.html) for the callback rules.

## 4. Step 6b: the pool, the groups and the two clients

`scripts/play.sh --tags sso-idp` creates the stack `<environment_name>-sso` from `ansible/roles/sso_cognito/files/cognito.yaml`. What is in it:

- **The pool.** Email is the sign-in name and cannot be changed later without replacing the pool and its users. Self sign-up is off. The password policy asks for at least 14 characters with lowercase, uppercase, a number and a symbol.
- **The groups.** One per entry in `sso.cognito.groups`. A user's memberships travel in the token's `cognito:groups` claim. A SAML provider does not assign Cognito groups, so add a federated user to a group in the pool for their token to carry the claim.
- **The Langfuse app client.** A confidential client with a secret, authorization-code flow, scopes `openid email profile`. It exists only when `sso.langfuse.enabled` and `langfuse.enabled` are both true.
- **The ClickHouse app client.** A public client with no secret, because it runs on a person's machine; the authorization-code exchange is protected by PKCE instead. Its ID token is valid for 60 minutes and its refresh token for one day. Its only registered callback is the loopback address `http://localhost:8765/callback`, and Cognito matches a redirect URI exactly, so the helper script listens on that fixed port.

Then the role reads the pool's live discovery document at `<issuer>/.well-known/openid-configuration` and records what it says. The issuer and the JWKS location are taken from that document, never assembled from the region, so they are right whatever host pattern the partition uses. Cognito's [endpoint reference](https://docs.aws.amazon.com/cognito/latest/developerguide/federation-endpoints.html) lists the discovery, authorization, token and JWKS endpoints.

`state/sso-cognito-outputs.json` holds no secret. Its keys are `issuer`, `jwks_uri`, `pool_id`, `hosted_ui_domain`, `hosted_ui_url`, `authorization_endpoint`, `token_endpoint`, `region`, `langfuse_client_id`, `langfuse_callback_url`, `clickhouse_client_id` and `clickhouse_callback_url`. The two Langfuse keys are `null` when there is no Langfuse client. `state/sso-cognito-client-secret` holds the Langfuse client secret at mode `0600`, is read only by tasks that set `no_log`, and is never written to a committed file, a log line or a command line. Both files are gitignored. The later steps and the scripts read them from disk rather than from earlier tasks' facts, so a single `--tags` run works on its own.

Cognito creates no users for you. Add them in the console or with `aws cognito-idp admin-create-user`, then put them in a group with `aws cognito-idp admin-add-user-to-group`. Both commands take `--user-pool-id`, and the pool ID is `pool_id` in the outputs file.

## 5. Langfuse sign-in

Step 15 assembles the `langfuse-sso` Secret from the outputs file and the client secret: `AUTH_COGNITO_CLIENT_ID`, `AUTH_COGNITO_CLIENT_SECRET`, `AUTH_COGNITO_ISSUER` and `AUTH_COGNITO_ALLOW_ACCOUNT_LINKING`, plus the `LANGFUSE_DEFAULT_ORG_ID`, `LANGFUSE_DEFAULT_ORG_ROLE`, `LANGFUSE_DEFAULT_PROJECT_ID` and `LANGFUSE_DEFAULT_PROJECT_ROLE` values that place a new user in the seeded organization and project. Langfuse documents the [`AUTH_*` variables](https://langfuse.com/self-hosting/security/authentication-and-sso) and the [`LANGFUSE_DEFAULT_*` variables](https://langfuse.com/self-hosting/configuration) on its own pages. Two more are added only when you set them: `AUTH_DISABLE_USERNAME_PASSWORD` (from `disable_password_login`) and `AUTH_DOMAINS_WITH_SSO_ENFORCEMENT` (from `enforce_domains`).

- **Sign-up is open while Cognito sign-in is on.** Langfuse creates a first-time Cognito user through its sign-up path, and with `AUTH_DISABLE_SIGNUP=true` that user fails with `OAuthCreateAccount`. So when `sso.enabled` and `sso.langfuse.enabled` are both `true`, Step 15 renders sign-up open whatever `langfuse.signup_disabled` says; with SSO off it still renders that value. The consequence is that, while password login is enabled, anyone who can reach Langfuse can also register with an email and password, and the new account receives the default organization and project role. Three settings limit it: `sso.langfuse.disable_password_login: true` makes Cognito the only way in, `sso.langfuse.enforce_domains` limits sign-in to your email domains, and `langfuse.load_balancer.allowed_cidrs` limits who can reach the page at all.
- **Account linking is on.** A person who already has an email and password user, the seeded admin included, can sign in through Cognito with the same address and keep their data.
- **New users land as VIEWER** in the seeded organization and project unless you change the two default roles.
- **Changing the Secret rolls the pods.** The release carries a fingerprint of the Secret in the pods' own environment, so the same `helm upgrade` that changes the Secret restarts web and worker.
- **Leave `disable_password_login` at `false`** until you have signed in through Cognito once. Turning it on first can lock you out of the seeded admin.

## 6. ClickHouse sign-in

### What the server does with a token

Step 9 writes a values file (`state/clickhouse-jwt-values.yaml`, mode `0600`, no secret) and passes it to the Helm release. It lands under the chart's `server.config.user_directories.jwt` value:

```yaml
server:
  config:
    user_directories:
      jwt:
        aud: <clickhouse_client_id>
        iss: <issuer>
        jwks:
          url: <jwks_uri>
          update_interval_ms: 300000
        permission_limit:
          role: jwt_ceiling
        remap_claims:
          roles: "cognito:groups"
        networks:
          ip: [<your networks, or the VPC CIDR>]
```

The chart merges this with its own access-storage settings, so `default`, `admin`, `prometheus` and the service users keep working beside it. A token login appears as a user named `JWT::<iss>::<aud>::<sub>::<hash>`, and the kit's checks look for the `JWT::` prefix.

### The behaviours to know, and what the kit does about each

These are properties of the server's JWT user directory, taken from ClickHouse's JWT documentation and from the server's own behaviour and source (`JWTAccessStorage.cpp` in the ClickHouse Private server). The kit's own notes on them are in the comment block above the JWT step in `ansible/roles/clickhouse_cluster/tasks/main.yml`.

| Behaviour | Consequence | What the kit does |
|---|---|---|
| `aud` is mandatory, in the configuration and on the token. The server refuses to start without it in the configuration, and rejects a token without an `aud` claim or with a different one | A token is accepted only for the audience you configured. Cognito ID tokens carry `aud` equal to the app client ID, per [Cognito's ID token documentation](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-id-token.html) | `aud` is the ClickHouse app client ID, and `ch-client.sh --sso` presents the ID token, not the access token |
| `iss` is not validated in JWKS mode | The issuer is not an access control. Trust rests on the JWKS signing keys plus `aud`: any token signed by a key in that JWKS and carrying the right `aud` is accepted | `iss` only shapes the user name. The audience is limited to a dedicated app client, and `networks` limits where logins may come from (the VPC CIDR and `127.0.0.1/32` unless you set it) |
| Keys are RS256 and the signature is checked against the JWKS | Tokens signed with another key, expired tokens and unknown key IDs are refused | No shared secret exists, so no JWT signing secret is stored anywhere |
| Roles are read only from the remapped claim, `cognito:groups`, which must be a top-level array | A string instead of an array is refused. Any other claim name is ignored. A group with no matching ClickHouse role is dropped without an error and leaves the login with no rights | Step 11b creates a role per group, named exactly like the group |
| `currentRoles()` is always empty for a JWT user, because the granted rights are flattened onto the user | A check on `currentRoles()` tells you nothing | Read effective access with `SHOW GRANTS`. The smoke test does |
| Effective access is the intersection of the mapped group roles and the permission-limit role | The permission-limit role is a ceiling. A user in two groups gets the union of those two roles, then the intersection with the ceiling | The ceiling role is granted every group role, so its rights are the union of theirs, and a token login cannot exceed what you wrote under `role_grants` |
| The permission-limit role must exist before the first login | A login before it exists has nothing to intersect with | Step 11b creates it, and `up.sh` runs `ch-jwt` right after `verify` |
| The configured JWKS URL must be reachable from the server pods before the JWT directory is enabled. While the JWKS has never loaded, a token that carries a key ID (`kid`) in its header can crash the server process | Enabling the directory against an unreachable URL turns any client that can reach the native port into a way to crash a server | Step 9 starts a throwaway pod on the server node group and fetches the JWKS URL with `clickhouse-local` first. If the fetch fails, Helm is not touched and the step stops with the route to fix. Treat a crash-looping server after enabling SSO as this behaviour |

Two more consequences follow from the table. Because the server never calls Cognito at login, revoking a user in Cognito does not end a token the user already holds: it stays valid until it expires, which for the ClickHouse client is at most 60 minutes. And the server fetches the JWKS on a timer (`update_interval_ms`, 300000 ms here), so a key rotation in the pool reaches the server on the next refresh.

If you turn SSO off while the cluster keeps running, run `scripts/play.sh --tags cluster` with `sso.clickhouse_jwt.enabled: false` to remove the directory before you delete the pool. A server restarted with the directory configured and a JWKS URL that no longer resolves is in the state the last table row warns about.

### Step 11b: from Cognito groups to ClickHouse roles

`scripts/play.sh --tags ch-jwt` runs as the admin user inside a server pod, with the password on stdin and never on the command line. It creates:

- One role per group that starts with `group_prefix`, plus any group named under `role_grants`, named exactly like the group, with the statements under `role_grants` granted to it.
- The permission-limit role (`jwt_ceiling` unless you name another), granted every group role.

It is idempotent: it reads the role and grant tables before and after, and reports a change only when they differ. Roles live in ClickHouse's replicated access storage, so one pod is enough.

### Checking a user's access

```bash
scripts/ch-client.sh --sso -q "SELECT currentUser()"      # JWT::<issuer>::<client id>::<sub>::<hash>
scripts/ch-client.sh --sso -q "SHOW GRANTS"               # the effective rights; currentRoles() is empty by design
```

A user in no group, or in a group with no role, logs in but has no rights beyond what every user can read. `networks` is matched against the client address the server sees. If a token login is refused with an authentication error on one path (for example the port-forward) and accepted on another (`--lb`), compare that path's source address with the `sso.clickhouse_jwt.networks` list.

The default list is the VPC CIDR plus `127.0.0.1/32`. The port-forward path (`ch-client.sh --sso` without `--lb`) reaches the server as `::ffff:127.0.0.1`, which `127.0.0.1/32` covers and the VPC CIDR does not. `127.0.0.1` is reachable only from inside the pod's network namespace and through `kubectl port-forward`, so the entry adds no access for anyone without cluster access. The `--lb` path is admitted by the VPC CIDR because the load balancer preserves the client address. A list you set is used exactly as given and replaces that default, so include `127.0.0.1/32` in it if you want the port-forward path.

## 7. Operating it

### Browser login to Langfuse

Open `langfuse.url`. With `sso.langfuse.enabled` the sign-in page offers Cognito. Choose it, sign in on the hosted UI, and Langfuse creates or links the user and lands them in the seeded organization and project as `default_org_role` and `default_project_role`. The seeded admin can link to its Cognito identity the first time it signs in through Cognito with the same email address.

### `scripts/ch-client.sh --sso`

```bash
scripts/ch-client.sh --sso                      # interactive session as yourself, through the port-forward
scripts/ch-client.sh --sso -q "SHOW GRANTS"     # one query
scripts/ch-client.sh --sso --lb                 # through the Step 12 load balancer
```

Run `scripts/ch-client.sh --help` for the accepted flag order.

The script gets an ID token for the ClickHouse app client through the hosted UI's authorization-code flow with PKCE. It opens your browser at the authorization endpoint from the outputs file, waits for the redirect on `http://localhost:8765/callback` with a short-lived listener on your machine (it uses Python's standard library), exchanges the code at the token endpoint, and runs `clickhouse-client --jwt` against the same targets the script already supports. The token is never written to disk. It does travel on the client's command line, which is the one place a credential is allowed there: it is short-lived and scoped to one audience, unlike a password. The port 8765 must be free on your machine. Needing a browser on the same machine is the reason the flow is a person's tool, not something to run from a build agent.

### `scripts/sso-smoke.sh`

```bash
scripts/sso-smoke.sh                            # checks the parts that are switched on
CH_JWT=<id token> scripts/sso-smoke.sh          # also log in to ClickHouse with a token you already have
scripts/sso-smoke.sh --sso                      # run the browser flow and use the token it returns
```

In order, it:

1. **Fetches the issuer's discovery document** and confirms it is reachable and that its `issuer` matches the one in `state/sso-cognito-outputs.json`.
2. **Reads Langfuse's `/api/auth/providers`** and confirms `cognito` is listed, when `sso.langfuse.enabled` is on.
3. **Logs in to ClickHouse with the token**, when `sso.clickhouse_jwt.enabled` is on and a token is supplied through `CH_JWT` or `--sso`. It checks that `SELECT currentUser()` starts with `JWT::` and that `SHOW GRANTS` for that user is not empty. It reads `SHOW GRANTS` and not `currentRoles()` for the reason in section 6.

Parts that are switched off are skipped with a message that says so. The script reads the same merged configuration the playbook does, so a `state/deploy-vars.yml` override of `sso:` counts. **What it does not cover:** the Langfuse browser login itself, group membership of a particular person, and anything behind a SAML provider.

## 8. Why the service paths stay on passwords

The ClickHouse users that machines use keep password authentication: the Langfuse user (Step 14), the Grafana user (Step 17), `admin`, and `prometheus`. No service connection depends on a token, for three reasons.

- **Langfuse's ClickHouse client has no way to present a JWT.** Langfuse connects with a username and password from its environment (see the ClickHouse variables in [Langfuse's configuration reference](https://langfuse.com/self-hosting/configuration)), and the kit cannot change that. This is a statement about the pinned Langfuse application, not a ClickHouse limitation.
- **A token is a person's short-lived credential.** The ClickHouse app client is configured for a 60-minute ID token and a one-day refresh token because a human runs it in a browser. A long-running service would need a refresh loop that holds a refresh token, which moves a long-lived secret from the password file to a less obvious place.
- **The service users are already narrow.** The Langfuse user holds grants on one database and the Grafana user is read-only, so a password for each is a small, checkable surface, and a token login would add a dependency on Cognito and its JWKS to every query those services make.

The passwords stay as they are: generated into gitignored `state/` files at mode `0600`, or in Kubernetes Secrets. The Cognito client secret follows the same rule and lives only in `state/` and in the `langfuse-sso` Secret.

## 9. FIPS mode and the endpoints the kit does not route

With `fips: true` the JWT directory runs in the `-fips` server image, and the `-fips` tag must be mirrored into your ECR before the deploy, as in [Part 2](part-2-image-sync.md). The Cognito hops sit outside the kit's FIPS routing:

- **The controller's own calls** (CloudFormation, the Cognito API for the client secret) go through `use_fips_endpoint` like every other controller call, so they use FIPS endpoints.
- **The browser and the Langfuse pods** reach Cognito's hosted UI and token endpoints over whichever endpoints Cognito publishes for your region. The kit does not route these.
- **ClickHouse's fetch of the JWKS document** uses the JWKS URL in the discovery document, and the server's own TLS stack makes the request. The kit does not route this either.

These are the same gaps [FIPS.md](../FIPS.md) and [Part 7](part-7-fips-hardening.md) list. Whether the traffic is FIPS-validated depends on the endpoints Cognito offers in your region and on the TLS libraries on each side, which are not something this kit validates.

## 10. GovCloud notes

GovCloud is out of scope for the kit ([Scope and boundaries](limitations.md)). If you adapt it, the Cognito side differs in ways AWS documents. [Amazon Cognito in AWS GovCloud (US)](https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/govcloud-cog.html) and the [Cognito endpoint reference](https://docs.aws.amazon.com/general/latest/gr/cognito_identity.html) are the sources for the points below; read them for your region before you rely on this summary.

- **FIPS-only endpoints.** Cognito in GovCloud is reached through FIPS endpoints only. The hosted-UI host, the token endpoint and the issuer therefore carry FIPS hostnames, and the `iss` of your tokens follows from that.
- **No custom domains.** The hosted UI uses the Cognito-provided domain (`<prefix>.auth...amazoncognito.com`, with a FIPS variant in GovCloud). The kit never sets a custom domain either way.
- **Verify `iss` from the discovery document.** Do not assemble it from the region. Step 6b reads `issuer`, `jwks_uri`, `authorization_endpoint` and `token_endpoint` from the live document and uses those for the Langfuse issuer setting and for the ClickHouse directory's `iss` and `jwks.url`. The stack itself builds no ARN literal; the pool's ARN comes from `Fn::GetAtt`, which carries the right partition.
- **Check the route from the server pods to the JWKS host.** The reachability check in Step 9 answers this for your network. In this kit's learning environment the NAT gateway provides the route; an airgapped design must provide its own.

To see what your pool reports:

```bash
issuer=$(jq -r .issuer state/sso-cognito-outputs.json)
curl -s "$issuer/.well-known/openid-configuration" | jq '{issuer, jwks_uri, authorization_endpoint, token_endpoint}'
```

## 11. IAM outbound identity federation: documented, not implemented

AWS IAM can issue a short-lived JWT for an IAM principal through `sts:GetWebIdentityToken`, which a service outside AWS can verify against an AWS-published key set. See the [GetWebIdentityToken API reference](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetWebIdentityToken.html). It is tempting for ClickHouse, because the JWT user directory would accept such a token.

The kit does not build it, for one reason: the token identifies a role, not a person. Its `sub` is the role's ARN, and it carries no claim listing groups or roles of a human user. The directory maps roles from a top-level array claim (`remap_claims`), so there would be nothing to key a ClickHouse role on except the one role ARN. Everyone who assumed that IAM role would share one ClickHouse identity and one set of rights, which is the shared login this part exists to remove. Read the claim list in the API reference above before using this summary to decide otherwise. Cognito keeps groups in the token and gives each person their own identity, so it stays the design.

The option fits automation that already runs as an IAM role and needs a ClickHouse identity of its own. The kit's directory takes one JWKS URL and one audience, so using both sources at once would need a second directory and is left to you.

## 12. Tear it down

`scripts/down.sh` removes the Cognito stack when one exists, after the cluster is removed, so nothing that trusts the pool outlives it. To remove one layer:

```bash
scripts/play.sh --tags sso-idp -e sso_idp_state=absent    # deletes the stack: the pool, its users and groups, both app clients
scripts/play.sh --tags ch-jwt -e ch_jwt_state=absent      # drops the group roles and the permission-limit role
```

- **The pool and its users are deleted with the stack.** The two files in `state/` stay and describe a pool that no longer exists; the next run overwrites them.
- **`ch-jwt` teardown leaves the directory in the server configuration.** Re-apply the cluster with `sso.clickhouse_jwt.enabled: false` (`--tags cluster`) to remove it. Do that before deleting the pool if the cluster keeps running, for the reason in section 6.
- **Langfuse users created through Cognito stay in Langfuse's own database.** They can no longer sign in through Cognito. Delete them in Langfuse if you want them gone.

## 13. What exists once it is up

```
AWS:        CloudFormation stack <environment_name>-sso  (user pool, hosted-UI domain, groups, [SAML provider], 1-2 app clients)
Kubernetes: Secret langfuse-sso in the langfuse namespace             (with Langfuse sign-in)
ClickHouse: user directory "jwt" in the server config; roles named like the groups, plus jwt_ceiling
state/:     sso-cognito-outputs.json (no secret), sso-cognito-client-secret (0600),
            clickhouse-jwt-values.yaml (0600, no secret)
```

## 14. Troubleshooting

- **`domain_prefix must be set`.** Set `sso.cognito.domain_prefix` in `state/deploy-vars.yml`. It is unique within the region and must not contain `aws`, `amazon` or `cognito`.
- **Step 6b asks for `langfuse.url`.** Cognito accepts only `https` callbacks. Set `langfuse.url` to the address people use and run `scripts/play.sh --tags sso-idp,lf-app`.
- **Step 9 says a pod cannot fetch the JWKS URL.** Fix the route from the server nodes to the Cognito host (NAT or an endpoint) and re-run. Helm has not been touched.
- **A server pod crash-loops after enabling SSO.** Read section 6, last row of the table. Disable `sso.clickhouse_jwt` and run `--tags cluster`, then fix the JWKS route.
- **`ch-client.sh --sso` hangs at the browser step.** Check that nothing else holds port 8765 and that the browser can reach the hosted UI.
- **A token is refused.** The usual causes are an expired token (60 minutes), a token for the other app client (wrong `aud`), a user whose `networks` address is not listed, or a `cognito:groups` claim that is not an array.
- **A login works and `SHOW GRANTS` shows nothing.** The user is in no group, or the group has no role or no `role_grants` entry. Add the statements and run `scripts/play.sh --tags ch-jwt`.

## 15. Things to confirm in your environment

These points depend on your pool, your region or AWS's documentation, so they are worth a look before you rely on them.

- **The exact claims in your tokens.** Decode an ID token from your pool (for example the middle section of the token, base64url-decoded) and confirm `aud` is the ClickHouse client ID and `cognito:groups` is an array.
- **Hosted-UI and issuer hostnames in GovCloud.** Use the discovery document command in section 10.
- **The claims in an IAM outbound identity token.** Use the API reference in section 11.
- **Whether a configuration change restarts the server pods or is reloaded.** That is the operator's behaviour. Watch `kubectl -n ns-default-us-01 get pods` after a `--tags cluster` run.

## 16. Check yourself

1. Why does `ch-client.sh --sso` present the ID token and not the access token? [section 6]
2. Why is `iss` not an access control in JWKS mode, and what limits who can log in? [section 6]
3. Why do you read `SHOW GRANTS` and not `currentRoles()` for a token user? [sections 6 and 7]
4. What does Step 9 check before it enables the JWT directory, and what goes wrong if the check is skipped? [section 6]
5. Why do the Langfuse and Grafana ClickHouse users stay on passwords? [section 8]
6. Where do the issuer and JWKS URL come from, and why not from the region? [sections 4 and 10]
7. Why does IAM outbound identity federation not replace Cognito here? [section 11]

**Where to go next:** [Part 7](part-7-fips-hardening.md) for the FIPS boundaries this capability sits inside, and the [limitations page](limitations.md) for the kit's scope.
