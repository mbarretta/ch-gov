# Learning setup vs. production

This kit is built for learning and evaluation. It shows how ClickHouse Government fits together on AWS, and it is honest about where that differs from a production deployment. This page lists each difference in one place, so you know what you can rely on and what you should treat as a starting point.

## What you'll learn

- Which parts of the airgap are complete and which are not.
- What FIPS mode gives you, what it leaves out, and the commands to check it on your own cluster.
- What the shipped smoke tests and checks cover, and which paths nothing has exercised.
- Which sizing and resilience choices you would change before production, and why GovCloud is not supported yet.

## The airgap is partial

The design goal is a cluster that pulls container images only from your own ECR registry and never from the internet. The kit gets most of the way there:

- **Image pulls.** The ClickHouse, operator, Langfuse, and Grafana containers all come from your ECR registry. The images make one hop, from ClickHouse's registry (and, for the optional capabilities, from `cgr.dev`, `docker.langfuse.com`, and `dhi.io`) into yours, and that copy runs from your machine, not from the cluster. The EBS CSI driver is an EKS managed add-on, so its images come from an AWS-owned registry instead.
- **S3 traffic.** A VPC gateway endpoint keeps ClickHouse's table data traffic to S3 on the AWS network.
- **Grafana's plugin.** The ClickHouse datasource plugin is mirrored into your own S3 bucket, so the pod never reaches out to `grafana.com`.

Two things stay open:

- **A NAT gateway is present.** The private subnets route outbound traffic through it, so the cluster can reach the internet if something asks it to. The kit does not create VPC interface endpoints for ECR, STS, or CloudWatch, which is what would let you remove the NAT gateway entirely. Adding them is the next step toward a fully airgapped network.
- **The EKS API endpoint is public by default.** `kubectl` works from your laptop because of it. A hardened posture runs `scripts/play.sh --tags eks -e eks_public_endpoint=false` and reaches the API through a bastion, VPN, or Direct Connect.

## What FIPS mode does and does not give you

Setting `fips: true` switches the whole kit to its FIPS configuration. [FIPS.md](../FIPS.md) is the short answer and [Part 7](part-7-fips-hardening.md) explains the mechanism behind each item. This section states the boundaries that matter for a decision.

**What it changes.**

- **ClickHouse images and machines.** The three ClickHouse images (server, Keeper, operator) switch to their `-fips` variants, the nodes switch to x86_64, and image pulls use the FIPS ECR hostname.
- **AWS API calls.** The calls the automation makes on your machine go to FIPS endpoints, and ClickHouse's own S3 client targets the FIPS S3 endpoint.
- **Keys at rest.** New S3 objects and EBS volumes are encrypted under dedicated customer-managed KMS keys, and so are Kubernetes Secrets in etcd.
- **Encryption in transit.** ClickHouse's native protocol and Keeper traffic use TLS with a private CA and 3072-bit RSA keys. The connection from Langfuse to ClickHouse uses TLS, and a Langfuse or Grafana load balancer terminates TLS with a FIPS security policy.

**What it does not give you.**

- **A certification.** The kit is not FIPS-validated or certified as a whole. It selects and wires cryptographic modules that ClickHouse and AWS provide, and it does not validate them. Whether the result meets your compliance target is your decision.
- **Coverage of every component.** The Langfuse, PostgreSQL, Valkey, Grafana, and `awscli` images are not FIPS builds. Langfuse's own S3 client and other pod-side AWS SDK calls do not use FIPS endpoints.
- **Full certificate verification everywhere.** Langfuse's one-time schema migration connects over TLS without verifying the certificate, because the pinned Langfuse image hardcodes that. ClickHouse's native protocol verifies the certificate chain but not the hostname.
- **A validated certificate source.** The self-signed certificates come from whatever OpenSSL build runs on the machine driving the automation.
- **A confirmed Keeper answer.** Whether Keeper's plaintext listener is disabled once TLS is required is unconfirmed, and the kit assumes it may still be reachable.
- **A completed live test.** The full deployment has not been run with `fips: true` against a real cluster from start to finish. The configuration is derived from the code, the chart values, and the CloudFormation templates that ship in this repository, so the checks below are yours to run.

**Check it on your own cluster.** With `fips: true`, run these after `source scripts/env.sh`. Each shows what you should see.

1. Confirm the ClickHouse images come from the FIPS registry and carry `-fips` tags. You should see hostnames of the form `<account>.dkr-ecr-fips.<region>.on.aws`.

   ```bash
   kubectl -n ns-default-us-01 get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
   ```

2. Confirm every node is x86_64. You should see `amd64` in each row.

   ```bash
   kubectl get nodes -L kubernetes.io/arch
   ```

3. Confirm the AWS CLI is set to use FIPS endpoints. In SSO mode, `use_fips_endpoint = true` appears once per profile. In profile mode, the second command prints `true`.

   ```bash
   grep use_fips_endpoint .aws/config
   echo "$AWS_USE_FIPS_ENDPOINT"
   ```

4. Confirm ClickHouse answers over its TLS port with the private CA. The query succeeds because `scripts/ch-client.sh` connects on 9440 with `--secure` when `fips` is on.

   ```bash
   scripts/ch-client.sh -q "SELECT version()"
   ```

5. Confirm the bucket is encrypted with your KMS key. You should see `aws:kms`, a key ARN, and `BucketKeyEnabled` set to `true`.

   ```bash
   aws s3api get-bucket-encryption --bucket "clickhouse-private-<account>-<region>"
   ```

6. Confirm the EKS cluster encrypts Secrets with a customer-managed key. You should see `secrets` and a key ARN.

   ```bash
   aws eks describe-cluster --name clickhouse-private-eks --query cluster.encryptionConfig
   ```

7. If Langfuse is on, confirm its certificate key size. You should see `3072 bit`.

   ```bash
   openssl x509 -in state/langfuse-tls-cert.pem -noout -text | grep Public-Key
   ```

## What the smoke tests and checks cover

The kit ships checks at three levels. Each one tells you something specific, and none is a substitute for testing your own workload.

**ClickHouse (Steps 10 and 11).** The preflight check reports whether the cluster's environment meets ClickHouse's requirements. The verify step writes three rows on one replica and reads them from another, which proves storage in S3, metadata in Keeper, and replication all work together. It does not test performance, failure recovery, or your data.

**Langfuse (`scripts/langfuse-smoke.sh`).** It posts one OpenTelemetry trace with a generation, checks that the Langfuse API lists both spans, and reads the same trace back from `langfuse.events_core` in ClickHouse. It does not cover the Langfuse UI, SDK ingestion from your application, prompts or evaluations, or load.

**Grafana (`scripts/grafana-smoke.sh`).** It checks the health of the ClickHouse datasource, runs a live query through it, and, when Langfuse is also on, runs a query against Langfuse's tables through the same datasource. It does not cover dashboards, alerting, or user management. Dashboards you build in the UI do not survive a pod restart, because Grafana runs with no persistent storage.

Some paths are not exercised:

- **The `public` load balancer type.** It is not exercised for ClickHouse, Langfuse, or Grafana. The tested path is `internal`. `public` changes an annotation and the subnets the load balancer uses, and it requires `allowed_cidrs`.
- **Grafana with `grafana.load_balancer.tls: true`.** It is not exercised. It shares its code with the Langfuse TLS path, which is exercised on an `internal` load balancer.
- **The Langfuse smoke test over https from outside the VPC.** It is not possible against an `internal` load balancer, because that address does not answer from outside the VPC. The script falls back to a `kubectl port-forward` tunnel. Its https path is exercised only where the load balancer answers, which means from inside the VPC or over a VPN.

One behavior worth knowing: a `scripts/down.sh` followed by `scripts/up.sh --from nodes` reuses the generated secrets in `state/`. Langfuse and Grafana come back with the same logins and credentials, as long as you keep `state/`.

## Sizing and resilience

Everything is sized so the pods fit and the cost stays low, not for load or for surviving failures.

- **Small nodes.** The node types are the smallest that fit the chart's pod requests, well below what ClickHouse's own tutorial specifies for production. Expect modest query throughput.
- **One NAT gateway.** `infrastructure.nat_mode: single` puts one NAT gateway in one availability zone. If that zone fails, outbound traffic from the private subnets fails with it. `per_az` gives one per zone at about three times the cost.
- **No autoscaler.** The node groups have minimum and maximum sizes, but nothing installed grows or shrinks them in response to load. You change the size yourself.
- **No backups.** The kit configures no backups of ClickHouse data, Keeper's volumes, or the Langfuse PostgreSQL and Valkey volumes. Table data lives in S3, and `scripts/down.sh` never deletes it. A default teardown deletes Keeper's volumes with the cluster, and a rebuild starts with an empty cluster pointed at the same bucket. Old tables are not adopted again.
- **Single instances.** Langfuse runs one web pod, one worker, one PostgreSQL, and one Valkey. Grafana runs one pod.

## Access and security defaults

These defaults are convenient for learning and worth changing for production.

- **Plain text unless TLS is on.** Without `fips: true`, the ClickHouse load balancer carries plain TCP, and the Langfuse and Grafana load balancers serve plain HTTP unless you set `load_balancer.tls: true`.
- **Self-signed certificates.** Where TLS is on, the certificates are self-signed. They give you encryption, not identity, and you trust them by file or by clicking through a browser warning.
- **Generated passwords in `state/`.** The admin passwords are files on the machine that ran the kit. Anyone with the files has the credentials, so protect and back up `state/` as you would any secret store.
- **Broad Grafana read access.** Grafana's ClickHouse user can read almost everything, including system tables and Langfuse's data. This is a deliberate convenience for exploring, not least privilege.
- **A demo organization in Langfuse.** Langfuse starts with a seeded organization, project, and admin login, with sign-up disabled.

## GovCloud is not supported yet

Deploying into AWS GovCloud is not supported. The kit derives the right ARN partition from a `us-gov-` region, but nothing else has been adapted or tested there:

- **The image source is in the commercial partition.** ClickHouse's source registry is an ECR registry in the commercial `aws` partition, and the kit reads it from a commercial region.
- **FIPS hostnames are untested in GovCloud.** The `dkr-ecr-fips` and `s3-fips` hostname shapes are unverified there.
- **Instance availability is untested.** The standard build uses `m7g` instances, and whether they are offered in the GovCloud region you would use is unchecked.

If you need GovCloud, raise it with your ClickHouse account team.

## Check yourself

1. Name two ways the network in this kit differs from a fully airgapped one. What would you add to close each?
2. Under `fips: true`, which traffic is TLS-encrypted with a verified certificate, and which is not? Run the ClickHouse check from the FIPS section and explain why it uses port 9440.
3. The Langfuse smoke test falls back to a tunnel when the load balancer does not answer. Why does an `internal` load balancer not answer from your laptop, and what would make its https path testable?
4. Pick one item from the sizing list and describe what you would change first for a production cluster, and what it would cost.
