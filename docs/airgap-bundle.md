# Building the ClickHouse airgap bundle

This page lists the smallest set of ClickHouse artifacts you need to carry into an airgapped network. It shows how to package them so their digests survive the trip, and which chart values keep the cluster from reaching back out. Everything after the import is your own automation.

## What you'll learn

- Which images, charts and CRD files make up the bundle, and where each one comes from.
- How to export them on a connected machine and import them inside the enclave with every digest intact.
- Which chart values point outside an enclave by default, and what to set instead.
- How to confirm that nothing in the running cluster pulls from outside your registry.

## The handoff in three moves

| Where | Step | What happens |
|---|---|---|
| Connected side | Export | Copy images and charts from ClickHouse's private registry into a directory, and record each digest. |
| Transfer | Carry across | Move one tar file and a checksum list through whatever cross-domain process your site uses. |
| Enclave side | Import | Push into your in-enclave OCI registry, confirm the digests match, then install with your own tooling. |

## What's in the bundle

A ClickHouse deployment needs four container images, two Helm charts and three Kubernetes CRD files. The preflight chart and its runner are optional. Every image is a multi-architecture index (linux/amd64 and linux/arm64), and the ClickHouse indexes also carry their attestations.

| Artifact | Version | Source | Size* | |
|---|---|---|---|---|
| **Container images** | | | | |
| `clickhouse-server` | `26.2.1.525` | ClickHouse registry | ~2.4 GB | required |
| `clickhouse-keeper` | `26.2.1.258` | ClickHouse registry | ~2.3 GB | required |
| `clickhouse-operator` | `main-1.20441.1` | ClickHouse registry | ~130 MB | required |
| `kubebuilder/kube-rbac-proxy` | `v0.13.0` | `registry.k8s.io` | ~95 MB | required |
| **Helm charts (OCI artifacts)** | | | | |
| `helm/clickhouse-operator-helm` | `1.20441.1` | ClickHouse registry | < 1 MB | required |
| `helm/onprem-clickhouse-cluster` | `1.8.7` | ClickHouse registry | < 1 MB | required |
| `helm/preflight-check` | `1.38.4` | ClickHouse registry | < 1 MB | optional |
| **Kubernetes prerequisites** | | | | |
| VolumeSnapshot CRDs (3 files) | `v8.6.0` | `kubernetes-csi/external-snapshotter` | < 1 MB | required |
| Troubleshoot `preflight` binary | current | Troubleshoot project releases | varies | optional |

*Compressed, both architectures. The full standard bundle is about 5 GB. The FIPS build is about the same size.

`kube-rbac-proxy` is the one image ClickHouse doesn't publish. It's a small sidecar in front of the operator's metrics endpoint. The operator chart references it, so it has to be in your registry too, or the operator pod won't start. The operator also won't start unless the VolumeSnapshot CRDs are installed in the cluster.

## Before you start

- **Read access to ClickHouse's registry.** Give your ClickHouse contact the AWS account ID you'll pull from. ClickHouse grants that account read access to its private registry and gives you the registry's account ID and region. The registry is Amazon ECR, so you authenticate with the AWS CLI.
- **A connected staging machine** with about 12 GB free: room for the exported directory plus the tar file.
- **An OCI registry inside the enclave** that accepts both container images and Helm charts. Amazon ECR, Harbor, Artifactory, Quay and the CNCF Distribution registry all qualify.
- **An OCI copy tool** on both sides. The examples use `skopeo` for images and `helm` for charts. Any tool that copies multi-architecture indexes without rewriting them works the same way, such as `crane`, `regctl` or `oras`.

## Choose the build

ClickHouse publishes two builds of each of its three images. The FIPS build uses the same version with `-fips` appended, for example `clickhouse-server:26.2.1.525-fips`. The FIPS-validated cryptography belongs to ClickHouse's crypto modules, and ClickHouse validates it on x86_64, so run FIPS builds on x86_64 nodes. The FIPS indexes still include arm64 entries.

The Helm charts are shared between both builds. You choose FIPS through the image tag, so never add `-fips` to a chart version. `kube-rbac-proxy` has no FIPS variant.

Each image index holds both architectures. You can halve the bundle by copying only your nodes' architecture, but the result is no longer the published index, so its digest won't match ClickHouse's. If you want digest verification end to end, keep the full index.

## Export on the connected side

The script copies each image into a `dir:` layout, which stores the manifests byte for byte. This matters for `kube-rbac-proxy`: it's published as a Docker manifest list, and writing it into an OCI archive forces a conversion that changes its digest. The `dir:` layout keeps every artifact at its source digest, and the script records each digest in `images.txt` so the enclave side can check it.

```bash
#!/usr/bin/env bash
# export.sh
set -euo pipefail

SRC_REGION="<region>"                                   # from ClickHouse
SRC="<clickhouse-account-id>.dkr.ecr.${SRC_REGION}.amazonaws.com"
SUFFIX=""                                               # "" for standard, "-fips" for FIPS
OUT="clickhouse-airgap"

mkdir -p "$OUT/images" "$OUT/charts" "$OUT/crds"
: > "$OUT/images.txt"

# Authenticate with the identity ClickHouse granted read access.
aws ecr get-login-password --region "$SRC_REGION" | skopeo login --username AWS --password-stdin "$SRC"
aws ecr get-login-password --region "$SRC_REGION" | helm registry login --username AWS --password-stdin "$SRC"

# Images: registry, repository, tag. --all keeps every architecture,
# --preserve-digests refuses any change that would alter a digest.
while read -r reg repo tag; do
  dir="images/$(printf '%s' "$repo" | tr / _)_${tag}"
  digest="sha256:$(skopeo inspect --raw "docker://$reg/$repo:$tag" | sha256sum | cut -d' ' -f1)"
  skopeo copy --all --preserve-digests "docker://$reg/$repo:$tag" "dir:$OUT/$dir"
  printf '%s %s %s %s\n' "$dir" "$repo" "$tag" "$digest" >> "$OUT/images.txt"
done <<EOF
$SRC clickhouse-server 26.2.1.525$SUFFIX
$SRC clickhouse-keeper 26.2.1.258$SUFFIX
$SRC clickhouse-operator main-1.20441.1$SUFFIX
registry.k8s.io kubebuilder/kube-rbac-proxy v0.13.0
EOF

# Charts, as packaged .tgz files. Drop preflight-check if you skip preflight.
for chart in clickhouse-operator-helm:1.20441.1 onprem-clickhouse-cluster:1.8.7 preflight-check:1.38.4; do
  helm pull "oci://$SRC/helm/${chart%%:*}" --version "${chart##*:}" --destination "$OUT/charts"
done

# VolumeSnapshot CRDs, pinned to a tag rather than a branch.
BASE="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0/client/config/crd"
for f in snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
         snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
         snapshot.storage.k8s.io_volumesnapshots.yaml; do
  curl -fsSL -o "$OUT/crds/$f" "$BASE/$f"
done

# One checksum list for every file, then one tar for the transfer.
(cd "$OUT" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + > SHA256SUMS)
tar -cf "$OUT.tar" "$OUT"
sha256sum "$OUT.tar" > "$OUT.tar.sha256"
```

On macOS, install GNU coreutils for `sha256sum`, or substitute `shasum -a 256`. If you use preflight, add the Troubleshoot `preflight` binary for your enclave workstation's platform to the bundle as well.

The finished `images.txt` is the bundle's manifest. For the standard build it looks like this:

```text
images/clickhouse-server_26.2.1.525 clickhouse-server 26.2.1.525 sha256:67ec77990d68aa133e4ca488540dcc530a69e099301c2722c7d5f5037ebb578d
images/clickhouse-keeper_26.2.1.258 clickhouse-keeper 26.2.1.258 sha256:c08bf2b62b36c03446e080253c17f1975c45fd90be9bb64e79ded3e6ec87a99e
images/clickhouse-operator_main-1.20441.1 clickhouse-operator main-1.20441.1 sha256:7aed51751a623b7b3b7b40b6adc8ebbdadfe1a454e176edf40994827c1ad362e
images/kubebuilder_kube-rbac-proxy_v0.13.0 kubebuilder/kube-rbac-proxy v0.13.0 sha256:d99a8d144816b951a67648c12c0b988936ccd25cf3754f3cd85ab8c01592248f
```

The bundle layout:

```text
clickhouse-airgap/
├── images.txt          dir, repository, tag, digest
├── SHA256SUMS
├── images/
│   ├── clickhouse-server_26.2.1.525/
│   ├── clickhouse-keeper_26.2.1.258/
│   ├── clickhouse-operator_main-1.20441.1/
│   └── kubebuilder_kube-rbac-proxy_v0.13.0/
├── charts/
│   ├── clickhouse-operator-helm-1.20441.1.tgz
│   ├── onprem-clickhouse-cluster-1.8.7.tgz
│   └── preflight-check-1.38.4.tgz
└── crds/
    ├── snapshot.storage.k8s.io_volumesnapshotclasses.yaml
    ├── snapshot.storage.k8s.io_volumesnapshotcontents.yaml
    └── snapshot.storage.k8s.io_volumesnapshots.yaml
```

## Import on the enclave side

Verify the tar first, then the files inside it, then push. The script checks each image's digest after the push, so a registry that silently rewrote a manifest stops the import instead of going unnoticed.

```bash
#!/usr/bin/env bash
# import.sh
set -euo pipefail

DST="<your-registry>"                      # for example 111122223333.dkr.ecr.us-gov-west-1.amazonaws.com

sha256sum -c clickhouse-airgap.tar.sha256
tar -xf clickhouse-airgap.tar
cd clickhouse-airgap
sha256sum -c --quiet SHA256SUMS

# Log in to your registry with skopeo and helm. For ECR:
#   aws ecr get-login-password | skopeo login --username AWS --password-stdin "$DST"
#   aws ecr get-login-password | helm registry login --username AWS --password-stdin "$DST"

# ECR only: repositories must exist before a push. Other registries create them on push.
# for repo in clickhouse-server clickhouse-keeper clickhouse-operator kubebuilder/kube-rbac-proxy \
#             helm/clickhouse-operator-helm helm/onprem-clickhouse-cluster helm/preflight-check; do
#   aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 ||
#     aws ecr create-repository --repository-name "$repo" --image-tag-mutability IMMUTABLE >/dev/null
# done

while read -r dir repo tag digest; do
  skopeo copy --all --preserve-digests "dir:$dir" "docker://$DST/$repo:$tag"
  got="sha256:$(skopeo inspect --raw "docker://$DST/$repo:$tag" | sha256sum | cut -d' ' -f1)"
  if [ "$got" != "$digest" ]; then echo "digest mismatch: $repo:$tag" >&2; exit 1; fi
  echo "ok  $repo:$tag  $digest"
done < images.txt

# Charts land at oci://$DST/helm/<chart-name>.
for chart in charts/*.tgz; do helm push "$chart" "oci://$DST/helm"; done
```

The repository paths are up to you. The ones above mirror ClickHouse's own layout. Whatever paths you choose, the chart values in the next section have to name them.

If your registry supports immutable tags, turn them on, as ECR does with `IMMUTABLE`. Then `clickhouse-server:26.2.1.525` always refers to the bytes you verified, and nobody can repoint the tag later.

## Point the charts at your registry

Both charts default to registries outside your enclave, so a few values are required. The values below cover only what the airgap changes. Your zones, sizing and storage settings stay the same as in a connected install.

### Operator chart

```yaml
# operator-values.yaml
image:
  repository: <your-registry>/clickhouse-operator
  tag: main-1.20441.1                 # main-1.20441.1-fips for the FIPS build

operator:
  # Base path for the debug and init containers the operator generates.
  # Separate from image.repository and easy to miss.
  imageRegistryBasePath: <your-registry>

kubeRBACProxy:
  image:
    repository: <your-registry>/kubebuilder/kube-rbac-proxy   # tag stays at the chart's v0.13.0

webhooks:
  enabled: false                      # see "Defaults that reach outside"
```

### Cluster chart

```yaml
# cluster-values.yaml
server:
  image:
    repository: <your-registry>/clickhouse-server
    # tag: 26.2.1.525-fips            # FIPS only; leave unset to use the chart's pinned version
  storage:
    s3:
      endpoint: https://s3.<region>.amazonaws.com   # or your in-enclave S3 endpoint
      region: <region>

keeper:
  image:
    repository: <your-registry>/clickhouse-keeper
    # tag: 26.2.1.258-fips
```

Then install from your own registry, using whatever automation you prefer:

```bash
kubectl apply -f crds/

helm install clickhouse-operator oci://<your-registry>/helm/clickhouse-operator-helm \
  --version 1.20441.1 --namespace clickhouse-operator-system --create-namespace \
  -f operator-values.yaml

helm install <cluster-release> oci://<your-registry>/helm/onprem-clickhouse-cluster \
  --version 1.8.7 --namespace <cluster-namespace> --create-namespace \
  -f cluster-values.yaml
```

## Defaults that reach outside

These are the chart defaults that point outside an enclave. Most are image references. The last one is an object storage endpoint, which counts too.

| Chart | Value | Default | What to do |
|---|---|---|---|
| Operator | `image.repository` | ClickHouse's own registry (`609927696493…us-west-2`) | Point it at your registry. |
| Operator | `operator.imageRegistryBasePath` | The same ClickHouse registry | Point it at your registry. Pods the operator generates later use it. |
| Operator | `kubeRBACProxy.image.repository` | `registry.k8s.io` | Point it at your mirror. Setting `kubeRBACProxy.enabled: false` also works, but it removes the access check in front of the metrics endpoint. |
| Operator | `webhooks.enabled` | `true`, which runs a `kube-webhook-certgen` job from `k8s.gcr.io` | Set it to `false`. To keep webhooks, also mirror `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.0` and set `webhooks.patch.image.repository`. The chart pins that image by digest, so it must keep its source digest. |
| Operator | `operator.metricsScraper.enabled` | `false` (`clickhouse-scraper` image) | Leave it off. It's a managed-service feature, and turning it on adds an image to the bundle. |
| Cluster | `server.image.repository`, `keeper.image.repository` | Empty, and required | Point them at your registry. The tags default to the versions the chart pins. |
| Cluster | `server.storage.s3.endpoint` and `region` | The us-west-2 regional S3 endpoint | Set them to your region's endpoint (the FIPS endpoint for FIPS builds) or to your in-enclave object storage. |

The operator builds some container specs itself, using `imageRegistryBasePath` as their registry. A standard cluster runs only the server and keeper containers. If you turn on a feature that adds operator-generated containers, ask ClickHouse which image it uses and add that image to the bundle.

## Verify nothing points outside

Render each chart with your values before you install. Every image line should start with your registry, so this command should print nothing:

```bash
helm template op oci://<your-registry>/helm/clickhouse-operator-helm --version 1.20441.1 \
  -f operator-values.yaml | grep -E '^\s*(- )?image:' | grep -v '<your-registry>/'
```

After the install, check the running pods, init containers included. For a cluster in its own namespace:

```bash
for ns in clickhouse-operator-system <cluster-namespace>; do
  kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
done | sort -u
```

Expect exactly four lines, each starting with your registry: `clickhouse-operator`, `kube-rbac-proxy`, `clickhouse-server` and `clickhouse-keeper`. If a pod sits in `ImagePullBackOff`, `kubectl describe pod` names the image it tried to pull.

## Reading the versions for a new release

The versions on this page come from the charts themselves, so a new release only needs a new chart version. The charts tell you which image tags to export:

- **Operator image tag:** the operator chart's `appVersion`, from `helm show chart oci://…/helm/clickhouse-operator-helm --version <v>`.
- **kube-rbac-proxy tag:** `kubeRBACProxy.image.tag` in `helm show values` for the same chart. Keep the chart's pin, because later versions changed the flags the chart passes.
- **Server and keeper tags:** the cluster chart pins them during rendering, so `helm show values` shows them as empty. Render the chart with your values and read the tags from the `ClickHouseCluster` it produces.

```bash
helm template x oci://<clickhouse-registry>/helm/onprem-clickhouse-cluster --version <v> \
  -f cluster-values.yaml | grep -A2 -E 'repository: .*clickhouse-(server|keeper)'
```

## What the bundle doesn't include

The bundle covers ClickHouse and the few third-party pieces its charts require. Your platform supplies the rest:

- **Kubernetes** and its system images (CNI, DNS, kube-proxy), whether a managed service provides them or you mirror them for your distribution.
- **A CSI driver and a StorageClass** for the server and keeper volumes. On AWS, the cluster chart expects a class named `gp3-encrypted` unless you set `server.storage.storageClassName` and `keeper.storage.storageClassName`.
- **A snapshot controller** if you want VolumeSnapshots to work. The CRDs in the bundle are enough for the operator to start, but not for snapshots to function.
- **Object storage**: an S3 bucket, or an S3-compatible store, reachable from the cluster.
- **Your client tools**: `kubectl`, `helm`, your copy tool, and whatever runs your automation.

Versions on this page: operator chart 1.20441.1, cluster chart 1.8.7, preflight chart 1.38.4, server 26.2.1.525, keeper 26.2.1.258.
