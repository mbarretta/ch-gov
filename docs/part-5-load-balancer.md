# Part 5 — Step 12: a load balancer, and the chart value that does nothing

> **What you'll learn**
>
> - Why the cluster chart's `loadBalancer` values do nothing in this deployment, and how the kit creates a Network Load Balancer (NLB) itself.
> - How `internal` and `public` differ, why the source ranges are never left empty, and why the kit probes from a different node than the servers.
> - How to check the load balancer, connect through it, and remove it in the right order.
>
> **Run it:** `scripts/up.sh` runs this step last, after the cluster is verified. To change the load balancer type later, edit `state/deploy-vars.yml` and run `scripts/up.sh --from lb`. Connect with `scripts/ch-client.sh --lb` from anywhere the load balancer's address is reachable.

Parts 1 to 4 end with a working cluster that only `kubectl` can reach. This step gives it an address. The step is not in the tutorial, and it comes with one finding that matters more than the step itself.

You choose the load balancer type with one setting, `clickhouse.load_balancer.type`. Put it in `state/deploy-vars.yml` (see section 3b of [Part 1](part-1-prerequisites.md)) to override the default in `ansible/group_vars/all.yml`:

```yaml
clickhouse:
  load_balancer:
    type: "internal"      # none | internal | public
    allowed_cidrs: []     # required for public; optional for internal
```

> **Advanced: run individual steps.** To run only this step, pass its tag to `scripts/play.sh`:
>
> ```bash
> scripts/play.sh --tags lb
> ```

---

## The chart's `loadBalancer` values do nothing here

The cluster chart exposes values that look like exactly what you need:

```yaml
loadBalancer:
  type: none        # none | internal | public
  hostname: ""      # "Required if type is not none"
```

If you set them, the operator records both on the ClickHouseCluster:

```
$ kubectl get clickhousecluster c-default-us-01 -n ns-default-us-01 -o jsonpath='{.spec.loadBalancerType} {.spec.loadBalancerHostname}'
internal clickhouse.example.internal
```

And then nothing happens. No Service of type `LoadBalancer` appears (the three Services stay `ClusterIP`), the operator log says nothing about it, and the hostname reaches neither the server config nor the pod. In ClickHouse Cloud these fields drive components such as Istio gateways, DNS and certificate SANs. A private deployment does not run those components, so in this deployment the fields are metadata.

The consequence is that **Step 12 has to create the load balancer itself**. The `clickhouse_loadbalancer` role leaves the chart values at `none`, so nobody later reads `type: internal` on the CR and believes it did something.

## Two ways to get an NLB, and why the "legacy" one

| | Cloud controller (built in) | AWS Load Balancer Controller |
|---|---|---|
| What you install | nothing | a Helm chart from a public repo, an image from `public.ecr.aws`, an IRSA role with a ~250-line IAM policy, a webhook |
| Airgap cost | none | mirror the image (Step 2), vendor the chart |
| Target type | instance (NodePort) | instance or **IP** (pod direct) |
| Trigger | `service.beta.kubernetes.io/aws-load-balancer-type: nlb` | `...aws-load-balancer-type: external` |
| Also does | nothing extra | ALB Ingress, TargetGroupBindings, security-group-per-LB |

EKS runs the AWS cloud controller manager in the control plane. It still provisions NLBs for `Service type: LoadBalancer` when you ask with the `nlb` annotation, using **instance** targets: every node is registered on a NodePort, and the NLB health-checks them. AWS calls this the legacy path and recommends the Load Balancer Controller. For an internet-facing production edge that advice is right, because IP targets skip a hop and the controller manages security groups per load balancer.

For this kit the built-in path wins on the same grounds as the EBS CSI add-on in Step 7 and the vendored CRDs: **nothing new to mirror, nothing new to keep patched.** While the controller works, the Service shows events like these:

```
Normal  EnsuringLoadBalancer  Ensuring load balancer
Normal  EnsuredLoadBalancer   Ensured load balancer
```

The Load Balancer Controller remains the upgrade path if you need IP targets or an ALB. The Service this role creates would move over with one annotation.

## What the role creates

The role creates one Service, named `<cluster>-lb`. Its selector is **read from the operator's own `c-<cluster>-server-any` Service** and not guessed. The label it uses (`external-connectivity: c-default-us-01-any`) belongs to the operator and could change.

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

With `fips: true` the ports are the TLS ports instead, `8443` for HTTPS and `9440` for the native protocol, because ClickHouse turns the plaintext listeners off when TLS is required.

**`internal` vs `public`** is one annotation plus a choice of subnets. Step 3 tags the private subnets `kubernetes.io/role/internal-elb` and the public ones `kubernetes.io/role/elb`, and the controller chooses by the `-internal` annotation. An internal NLB lands in the three private subnets with one private IP per availability zone.

**`externalTrafficPolicy: Local`** means a connection that reaches a node is served by the server pod on *that* node. There is no second hop through kube-proxy, and the client IP is preserved. Nodes without a server pod fail the health check, which uses a dedicated `healthCheckNodePort`, so the target group shows **3 healthy of 8 registered**. That is the correct steady state, not a partial failure, and the role waits for exactly `server.replicas` healthy targets.

## Source ranges: the default you must not take

The controller turns `loadBalancerSourceRanges` into ingress rules on the cluster's node security group, one per NodePort. If you leave the field empty, the controller writes rules like these (abridged):

```
<NodePort A>  <NodePort A>  0.0.0.0/0      kubernetes.io/rule/nlb/client=<hash>
<NodePort B>  <NodePort B>  0.0.0.0/0      kubernetes.io/rule/nlb/client=<hash>
<NodePort C>  <NodePort C>  10.20.0.0/18   kubernetes.io/rule/nlb/health=<hash>   (x3, one per private subnet)
```

For an internal NLB the `0.0.0.0/0` rule is moot in practice, because the address is private. It is still a NodePort open to the world on every node's security group. For a public NLB it is the open internet, on a database port, without TLS. So the role never leaves the field empty:

- **`internal`** defaults to the VPC CIDR (`infrastructure.vpc_cidr`), or to `allowed_cidrs` if you set it, for example a peered network or a VPN range.
- **`public`** *requires* `allowed_cidrs`, and refuses `0.0.0.0/0` unless you also pass `-e allow_open_internet=true`. There is no sensible default for who on the internet may reach a database.

## The hairpin, and where the probe runs from

To prove the path works, the role runs `clickhouse-client` from a throwaway pod against the NLB hostname. It runs that pod on the **operator** nodes, and this is not incidental. With instance targets and client-IP preservation, a node cannot reach itself through an NLB: the return packet has the node's own address as both source and destination, and the network drops it. This is the classic NLB *hairpin* problem. Probe from a server node and roughly one connection in three would hang. The operator nodes run no server pods, so every hop is a real one. The mirrored `clickhouse-server` image is multi-arch, so it runs on the x86 operator nodes too.

The probe opens six connections and prints how many each replica answered, then checks HTTP `/ping`. A healthy result looks like this:

```
native 9000:       <count> c-default-us-01-server-<suffix A>-0
native 9000:       <count> c-default-us-01-server-<suffix B>-0
http 8123:   Ok.
```

Seeing two or more different replicas answer shows the load balancer is spreading connections. The role waits for the target group to report healthy targets before it probes, and it retries the probe until a run has no timeouts. See Troubleshooting for why.

## What `internal` means for you at a laptop

An internal NLB has a private address. If you resolve it from outside the VPC, you get three `10.20.x.x` addresses that you cannot route to. Your options, in order of seriousness:

1. **`scripts/ch-client.sh` (no `--lb`)** still works. It port-forwards through the Kubernetes API server. The load balancer is for *applications in the VPC*.
2. **A VPN or peering into the VPC.** After that, `scripts/ch-client.sh --lb` and any other client work with the hostname directly.
3. **`type: public` with `allowed_cidrs: ["<your egress IP>/32"]`.** This suits a lab, but without `fips: true` it is plain TCP: the native protocol on 9000 and HTTP on 8123 both carry credentials in the clear. With `fips: true` the ports are the TLS ones, and the certificate is self-signed. Either way, treat `public` as a convenience. [Learning setup vs. production](limitations.md) notes that the `public` type has not been exercised.

## Cost

An NLB is billed hourly (about $0.0225/hr, or $17 a month) plus a small per-LCU charge that a lab will not notice. Cross-zone load balancing adds inter-AZ transfer at $0.01/GB. Setting `type: none` and re-running the step removes the load balancer.

## Teardown order

Deleting the Service is what deletes the NLB, its target groups and the security-group rules, because the controller acts on the delete event. So remove the load balancer **before** the cluster, the node groups or the control plane. If you delete the EKS cluster with the Service still in it, the NLB is orphaned: still billing, still holding an ENI in each private subnet, and blocking the VPC stack's deletion.

You should not have to remember that. `scripts/down.sh` removes the load balancer first, then the cluster (while the nodes are still up, so the operator and the CSI driver can clean up after it), then the node groups. `--all` goes on through the operator, prerequisites, storage, EKS and the VPC. Section 5b of [Part 1](part-1-prerequisites.md) has the full reasoning.

> **Advanced: run individual steps.** If you tear down by hand, keep the same order:
>
> ```bash
> scripts/play.sh --tags lb -e lb_state=absent     # or set type: none and re-run
> scripts/play.sh --tags cluster -e cluster_state=absent
> scripts/play.sh --tags nodes -e nodegroups_state=absent
> ```

## What a passing run reports

When the step finishes, the role prints a summary in this shape:

```
type:      internal NLB, private address, cross-zone on, TLS off
endpoint:  <NLB_HOSTNAME_HASH>.elb.<target_region>.amazonaws.com
ports:     8123, 9000
allowed:   10.20.0.0/16
healthy:   3/3 targets per port (one per server node; other nodes fail the health check by design)

native 9000:       <count> c-default-us-01-server-<suffix>-0
http 8123:   Ok.
```

---

## Troubleshooting

**The probe reports `Code: 209. DB::NetException: Timeout: connect timed out` in the first minute or two after the NLB goes `active`**

- *Cause:* a freshly active NLB drops a share of connections while its zonal nodes learn the target state. This can happen even when all targets already show `healthy`, and it affects one zonal IP at a time.
- *Fix:* wait. The role retries the probe until a run has no timeouts. A few minutes later, connections through every zonal IP should succeed.

**An application behind the NLB reports sporadic connect timeouts long after setup**

- *Cause:* AWS documents an intermittent failure with client IP preservation on. A client that reuses the same ephemeral source port toward different zonal IPs can have both connections routed to the same target, and the target sees them as a duplicate.
- *Fix:* follow AWS's listed mitigations: set `clickhouse.load_balancer.cross_zone: false`, or disable client IP preservation on the target group (and use Proxy Protocol v2 to keep the client IP). Start there before you suspect ClickHouse.

**The role stops with `clickhouse.load_balancer.type is 'public' but allowed_cidrs is empty`**

- *Cause:* `public` has no safe default for who may connect, so the role refuses to guess.
- *Fix:* set `allowed_cidrs` to the CIDRs that should reach ClickHouse (for example `["203.0.113.7/32"]`), then run the step again.

**`scripts/ch-client.sh --lb` hangs or times out from your machine**

- *Cause:* the load balancer is `internal`, so its private address is not routable from outside the VPC.
- *Fix:* use `scripts/ch-client.sh` without `--lb` (a port-forward), or connect over a VPN or peering into the VPC.

---

## Self-checks

Run these in order. Each gives a command and what you should see, and they double as workshop exercises. Start with `source scripts/env.sh`, and set the namespace once (use your `clickhouse.namespace` if you changed it):

```bash
source scripts/env.sh
NS=ns-default-us-01
```

1. **The Service exists and only the load balancer Service is exposed.**

   ```bash
   kubectl get service -n "$NS"
   ```

   You should see a `default-us-01-lb` Service of type `LoadBalancer` with an `EXTERNAL-IP` that is an `elb` hostname. The operator's own Services stay `ClusterIP`.

2. **The traffic policy and source ranges are set.**

   ```bash
   kubectl get service default-us-01-lb -n "$NS" \
     -o jsonpath='{.spec.externalTrafficPolicy} {.spec.loadBalancerSourceRanges}{"\n"}'
   ```

   You should see `Local` and a list that is not empty. For an `internal` load balancer with no `allowed_cidrs`, the list is your VPC CIDR, `["10.20.0.0/16"]`.

   **Exercise:** what would the controller write into the node security group if this list were empty, and why does that matter more for `public`?

3. **Exactly the server nodes are healthy.** Replace `<target_region>` with your Region.

   ```bash
   HOST=$(kubectl get service default-us-01-lb -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   ARN=$(aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region <target_region> \
     --query "LoadBalancers[?DNSName=='$HOST'].LoadBalancerArn | [0]" --output text)
   for tg in $(aws elbv2 describe-target-groups --load-balancer-arn "$ARN" --profile "$AWS_PROFILE" --region <target_region> \
     --query 'TargetGroups[].TargetGroupArn' --output text); do
     aws elbv2 describe-target-health --target-group-arn "$tg" --profile "$AWS_PROFILE" --region <target_region> \
       --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
   done
   ```

   You should see `3` once per port, which matches `server.replicas`, even though eight nodes are registered. The other five fail the health check by design.

   **Exercise:** why is 3 healthy out of 8 registered the correct steady state?

4. **The probe reaches more than one replica.**

   ```bash
   scripts/play.sh --tags lb
   ```

   The role prints the `native` lines and `http ...: Ok.` with no `Timeout`. You should see the connection counts split across replicas.

5. **The private address is not reachable from outside the VPC (internal type).**

   ```bash
   scripts/ch-client.sh -q "SELECT hostName()"      # port-forward: works
   scripts/ch-client.sh --lb -q "SELECT hostName()" # only works from the VPC, a VPN or peering
   ```

   The first command always works. The second answers only where the private address is routable.

6. **Removal is clean and reversible.** Remove the load balancer, confirm the Service is gone, and put it back:

   ```bash
   scripts/play.sh --tags lb -e lb_state=absent
   kubectl get service -n "$NS"
   scripts/play.sh --tags lb
   ```

   After the first command the `-lb` Service is gone, and the NLB disappears from AWS within a minute or so. After the last command it is back.

   **Exercise:** why must the load balancer go before the EKS cluster in a teardown?

**Not covered here:** TLS on ports 9440 and 8443 outside `fips: true`. Add it before any real public exposure.
