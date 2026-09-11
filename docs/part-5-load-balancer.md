# Part 5 — Step 12: a load balancer, and the chart value that does nothing

Parts 1–4 end with a working cluster that only `kubectl` can reach. This step
gives it an address. It is not in the tutorial, and building it turned up one
finding that matters more than the step itself.

```bash
# in ansible/group_vars/all.yml:  clickhouse.load_balancer.type: none | internal | public
scripts/play.sh --tags lb
scripts/ch-client.sh --lb -q "SELECT hostName()"
```

---

## The chart's `loadBalancer` values are inert here

The cluster chart exposes exactly what you would expect:

```yaml
loadBalancer:
  type: none        # none | internal | public
  hostname: ""      # "Required if type is not none"
```

Set them and re-deploy, and the operator dutifully records both on the
ClickHouseCluster:

```
$ kubectl get clickhousecluster c-default-us-01 -n ns-default-us-01 -o jsonpath='{.spec.loadBalancerType} {.spec.loadBalancerHostname}'
internal clickhouse.private.internal
```

And then nothing happens. No Service of type LoadBalancer appears — the three
Services stay `ClusterIP` — the operator log says nothing about it, and the
hostname reaches neither the server config nor the pod. In ClickHouse Cloud
these fields drive components (Istio gateways, DNS, certificate SANs) that a
private deployment does not run. In this deployment they are metadata.

The consequence is that **Step 12 has to create the load balancer itself**,
and the role leaves the chart values at `none` so that nobody later reads
`type: internal` on the CR and believes it did something.

## Two ways to get an NLB, and why the "legacy" one

| | Cloud controller (built in) | AWS Load Balancer Controller |
|---|---|---|
| What you install | nothing | a Helm chart from a public repo, an image from `public.ecr.aws`, an IRSA role with a ~250-line IAM policy, a webhook |
| Airgap cost | none | mirror the image (Step 2), vendor the chart |
| Target type | instance (NodePort) | instance or **IP** (pod direct) |
| Trigger | `service.beta.kubernetes.io/aws-load-balancer-type: nlb` | `...aws-load-balancer-type: external` |
| Also does | — | ALB Ingress, TargetGroupBindings, security-group-per-LB |

EKS runs the AWS cloud controller manager in the control plane. It still
provisions NLBs for `Service type: LoadBalancer` when asked with the `nlb`
annotation, with **instance** targets: every node is registered on a NodePort
and the NLB health-checks them. AWS calls this the legacy path and recommends
the Load Balancer Controller, and for an internet-facing production edge it is
right — IP targets skip a hop, and the controller manages security groups
per load balancer.

For this project the built-in path wins on the same grounds as the EBS CSI
add-on in Step 7 and the vendored CRDs: **nothing new to mirror, nothing new
to keep patched.** It provisioned an internal NLB in three seconds:

```
Normal  EnsuringLoadBalancer  Ensuring load balancer
Normal  EnsuredLoadBalancer   Ensured load balancer          (3s later)
```

The Load Balancer Controller remains the upgrade path if you need IP targets
or an ALB; the Service this role creates would move over with one annotation.

## What the role creates

One Service, named `<cluster>-lb`, whose selector is **read from the
operator's own `c-<cluster>-server-any` Service** rather than guessed — the
label it uses (`external-connectivity: c-default-us-01-any`) belongs to the
operator and could change.

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"      # omitted for public
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  loadBalancerSourceRanges: [10.20.0.0/16]                              # never empty, see below
  ports: [{name: http, port: 8123}, {name: native, port: 9000}]
```

**`internal` vs `public`** is one annotation and which subnets the controller
picks. Step 3 tagged the private subnets `kubernetes.io/role/internal-elb` and
the public ones `kubernetes.io/role/elb`; the controller chooses by the
`-internal` annotation. The internal NLB landed in the three private subnets
with one private IP per AZ.

**`externalTrafficPolicy: Local`** means a connection that reaches a node is
served by the server pod on *that* node — no second hop through kube-proxy,
and the client IP is preserved. Nodes without a server pod fail the health
check, which is a dedicated `healthCheckNodePort`, so the target group shows
**3 healthy of 8 registered**. That is the correct steady state, not a partial
failure, and the role waits for exactly `server.replicas` healthy targets.

## Source ranges: the default you must not take

The controller turns `loadBalancerSourceRanges` into ingress rules on the
cluster's node security group, one per NodePort. The experiment left it empty
and got this:

```
30766  30766  0.0.0.0/0      kubernetes.io/rule/nlb/client=a1c13419...
32585  32585  0.0.0.0/0      kubernetes.io/rule/nlb/client=a1c13419...
30869  30869  10.20.0.0/18   kubernetes.io/rule/nlb/health=a1c13419...   (x3, one per private subnet)
```

For an internal NLB the `0.0.0.0/0` is moot in practice — the address is
private — but it is still a NodePort open to the world on every node's
security group. For a public NLB it is the open internet, on a database
port, without TLS. So the role never leaves it empty:

- `internal` — defaults to the VPC CIDR (`infrastructure.vpc_cidr`), or
  `allowed_cidrs` if set (a peered network, a VPN range).
- `public` — **requires** `allowed_cidrs`, and refuses `0.0.0.0/0` unless you
  also pass `-e allow_open_internet=true`. There is no sensible default for
  who on the internet may reach a database.

## The hairpin, and where the probe runs from

To prove the path, the role runs `clickhouse-client` from a throwaway pod
against the NLB hostname. It runs that pod on the **operator** nodes, and this
is not incidental: with instance targets and client-IP preservation, a node
cannot reach itself through an NLB — the return packet has the node's own
address as both source and destination and is dropped. Probe from a server
node and roughly one connection in three would hang. The operator nodes run no
server pods, so every hop is a real one. The mirrored `clickhouse-server`
image is multi-arch, so it runs on the x86 operator nodes too.

Six connections in the experiment, before all targets had finished their
initial health check:

```
1  c-default-us-01-server-5kha3ik-0
4  c-default-us-01-server-en5qo86-0
1  Code: 209. DB::NetException: Timeout: connect timed out: 10.20.153.189:9000
http 8123: Ok.
```

Two different replicas answering, and one timeout from the zonal address whose
targets were still `initial` — hence the role's wait on target health before it
probes. HTTP `/ping` answered `Ok.`

## What `internal` means for you at a laptop

An internal NLB has a private address. Resolving it from outside the VPC gives
you three `10.20.x.x` addresses you cannot route to. Your options, in order of
seriousness:

1. `scripts/ch-client.sh` (no `--lb`) — still works, still port-forwards
   through the API server. The load balancer is for *applications in the VPC*.
2. A VPN or peering into the VPC, after which `scripts/ch-client.sh --lb` and
   any client work with the hostname directly.
3. `type: public` with `allowed_cidrs: ["<your egress IP>/32"]` — fine for a
   lab, but understand that it is plain TCP: the native protocol on 9000 and
   HTTP on 8123 both carry credentials in the clear. TLS (`server.openSSL` in
   the chart, a certificate Secret, port 9440/8443) is the prerequisite for a
   real public endpoint and is not part of this project yet.

## Cost

An NLB is billed hourly (~$0.0225/hr, ~$17/mo) plus a small per-LCU charge
that a lab will not notice. Cross-zone load balancing adds inter-AZ transfer
at $0.01/GB. Setting `type: none` and re-running removes it.

## Teardown order

Deleting the Service is what deletes the NLB, its target groups and the
security-group rules — the controller does it on the delete event. So remove
the load balancer **before** the cluster, the node groups or the control plane.
Delete the EKS cluster with the Service still in it and the NLB is orphaned:
still billing, still holding an ENI in each private subnet, and blocking the
VPC stack's deletion.

You should not have to remember that. `scripts/down.sh` does the load
balancer first, then the cluster (while nodes are still up, so the operator
and the CSI driver can clean up after it), then the node groups; `--all` goes
on through operator, prerequisites, storage, EKS and VPC. Part 1 §6b has the
full reasoning. If you are doing it by hand:

```bash
scripts/play.sh --tags lb -e lb_state=absent     # or type: none + re-run
scripts/play.sh --tags cluster -e cluster_state=absent
scripts/play.sh --tags nodes -e nodegroups_state=absent
```

## What a passing run reports

```
type:      internal NLB, private address, cross-zone on
endpoint:  <NLB_HOSTNAME_HASH>.elb.us-east-1.amazonaws.com
ports:     8123, 9000
allowed:   10.20.0.0/16
healthy:   3/3 targets per port (one per server node; other nodes fail the health check by design)

native 9000:       1 c-default-us-01-server-5kha3ik-0
native 9000:       3 c-default-us-01-server-caiz7tq-0
native 9000:       2 Code: 209. DB::NetException: Timeout: connect timed out: 10.20.68.231:9000 ...
http 8123:   Ok.
```

Those two timeouts are the one wrinkle worth recording. They happened in the
first minute after the NLB went `active`, against a single zonal IP, with all
three targets already `healthy`. Repeating the probe a few minutes later from
operator nodes in two different zones, four connections to each of the three
zonal IPs:

```
from us-east-1a:  10.20.25.233 ok=4   10.20.68.231 ok=4   10.20.152.26 ok=4
from us-east-1b:  10.20.25.233 ok=4   10.20.68.231 ok=4   10.20.152.26 ok=4
```

24 of 24, every zonal IP reaching every server. A freshly active NLB drops a
share of connections while its zonal nodes converge on target state; the role
therefore retries the probe until a run has no timeouts rather than failing on
the first. AWS's troubleshooting page also describes a steady-state
*intermittent* failure with client IP preservation on: a client reusing the
same ephemeral source port to different zonal IPs, both routed to the same
target, looks like a duplicate connection. The listed mitigations are
`cross_zone: false`, or disabling client IP preservation on the target group
(then Proxy Protocol v2 for the client IP). Neither was needed here, but if an
application behind this NLB reports sporadic connect timeouts, start there.

# Checkpoint

- [x] The chart's `loadBalancer.type` / `.hostname` proven inert in this deployment: set, recorded on the CR, no Service created
- [x] `clickhouse.load_balancer.type` in `group_vars`: `none` | `internal` | `public`; `none` removes an existing Service
- [x] Internal NLB provisioned by the built-in cloud controller — no new controller, no new images
- [x] Selector read from the operator's Service, not hardcoded
- [x] Source ranges never empty: VPC CIDR by default for `internal`; `public` demands `allowed_cidrs` and refuses `0.0.0.0/0` without an explicit override
- [x] `externalTrafficPolicy: Local`, 3 healthy of 8 targets, waited on before probing
- [x] Probe from operator nodes through the NLB: every zonal IP reaches every replica; HTTP `/ping` Ok
- [x] `scripts/ch-client.sh --lb` for when the address is reachable from your machine
- [ ] `public` type not exercised (no safe CIDR to allow from here); the code path differs by one annotation and the subnet tag it selects
- [ ] TLS on 9440/8443 before any real public exposure
