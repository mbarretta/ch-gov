# VolumeSnapshot CRDs — vendored, not fetched

These three files come from
[kubernetes-csi/external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter)
at tag **v8.6.0**, path `client/config/crd/`.

They are committed here rather than applied from a URL at deploy time, for two
reasons:

1. **The tutorial's URLs point at `master`.** An unpinned branch means the CRDs
   you get depend on the day you deploy, which is the opposite of what a
   reproducible install needs.
2. **An airgapped cluster has no route to `raw.githubusercontent.com`.** Any
   step that reaches the public internet at deploy time is a step that will
   fail in the environment this whole guide is aimed at.

To update: bump the tag, re-download all three, and commit the diff.

```bash
BASE=https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/<tag>/client/config/crd
for f in snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
         snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
         snapshot.storage.k8s.io_volumesnapshots.yaml; do
  curl -fsSL "$BASE/$f" -o "$f"
done
```

**Note:** these are the CRDs only, which is all the ClickHouse operator
requires in order to start. Snapshots do not actually *function* without the
`snapshot-controller` Deployment, which is a separate install. The tutorial
installs only the CRDs, and so do we.
