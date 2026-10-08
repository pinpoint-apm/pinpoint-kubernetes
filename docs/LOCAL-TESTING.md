# Local runtime testing

Use an isolated k3d cluster and its explicit kubeconfig on every command.
A k3s executable alone does not imply a running server. These checks use Linux
amd64, one physical computer with 30 GiB memory and local-path storage. Defaults
reserve about 20.6 GiB memory and 7.75 CPU cores before bootstrap/system pods;
32 GiB host memory is recommended. Run one installation scenario at a time.

## Create an isolated cluster

Requires Helm 3, kubectl, Docker, k3d, Python 3 and Ruby for chart validation.
Verify the official k3d release checksum. This creates three virtual nodes for
the optional HA example without changing the default Kubernetes context:

```bash
k3d cluster create pinpoint-311-test \
  --image rancher/k3s:v1.35.5-k3s1 \
  --servers 1 --agents 2 --api-port 127.0.0.1:16443 \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --k3s-arg '--disable=traefik@server:0' \
  --k3s-arg '--disable=servicelb@server:0' --wait
k3d kubeconfig get pinpoint-311-test > /tmp/pinpoint-311-kubeconfig.yaml
chmod 600 /tmp/pinpoint-311-kubeconfig.yaml
kubectl --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml get nodes
```

Behind a TLS inspection proxy, install your trusted CA in the node/container
runtime. Do not disable certificate verification. A default evaluation install
can use a single virtual node; the distributed example needs three.

## Test the default evaluation stack

```bash
bash scripts/helm-validate.sh
helm package . --destination /tmp/pinpoint-release
helm install pinpoint /tmp/pinpoint-release/pinpoint-3.1.1.tgz \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint --create-namespace --wait --timeout 20m
python3 scripts/local-smoke.py \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint --release pinpoint
kubectl --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint port-forward service/pinpoint-web 18081:8080
```

Keep the last command running and open http://localhost:18081. The smoke script
uses temporary loopback port-forwards, generates demo requests and verifies
application registration, Inspector/Pinot ingestion and HBase traces. Quickstart
must be enabled. It accepts loopback API endpoints only and does not kill pods
or change table definitions. This default uses filesystem-backed, single-pod HBase.

## Test the production application profile with separate backends

On an empty local cluster, follow the complete
[production-profile example](../examples/local-production/README.md). It installs
application, storage, Metric fixtures and dedicated operators as independent
releases in one `pinpoint` namespace. Traefik represents a shared platform
controller in `kube-system`. The example documents each release and its pod cost.
Its HTTPS URL is **https://localhost:18443/login**, with a running port-forward;
no hosts entry is required on the same computer.

The application initially installs only two Web and two Collector pods.
The optional demo overlay adds Quickstart/Telegraf. Run the example's smoke and
real-ingress checks after adding that overlay. Credentials stay in a private
directory outside the checkout, never in tracked values files.

The evaluation and distributed-backend scenarios are alternatives. Do not install
both into the same namespace with the same release name or reuse incompatible PVCs.
The complete example's small storage heaps and singleton MySQL/Redis/Pinot are
local fixtures, not a production backend capacity configuration.

## Optional recovery checks

These tools deliberately create fixture data and, for HA recovery, kill verified
backend JVMs. Run them only on the isolated loopback cluster. Successful fixtures
are removed; failed Jobs/data remain for diagnosis. They are not maintenance tools.

For the distributed backend installed by the example:

```bash
python3 scripts/local-ha-recovery.py \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint --backend-name pinpoint-storage
```

Use `--roles master` (or another role) for a single case. After diagnosis and
when no recovery test is running, `--cleanup-fixtures` removes retained
`PinpointHA_<10 hex digits>` tables and `/pinpoint-ha-test-<10 hex digits>` files.
It does not remove Pinpoint trace tables or WALs.

For the default evaluation stack's bundled MySQL:

```bash
python3 scripts/local-mysql-recovery.py \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint --release pinpoint
```

This checks partial schema repair, idempotent reruns and dump/restore with
uniquely named fixture databases. It requires the bundled MySQL release Secret.

## Recorded validation scope

Release-candidate checks on 2026-10-07/08 used k3d 5.9.0, k3s v1.35.5+k3s1,
Helm 3.21.3 and Linux amd64. The following results apply to the tested local
configuration, not to untested production values:

| Check | Result and scope |
| --- | --- |
| Default packaged install and upgrade | 18 workload pods Ready; bootstrap hooks completed; upgrade retained PVCs |
| End-to-end ingestion | Real traces, Inspector heap, URI statistics, Heatmap and system metrics verified |
| Application production profile | Two Web and two Collector replicas; shared JWT accepted by both Web replicas |
| Actual HTTPS ingress | Certificate/hostname validation, login page HTTP 200, anonymous/invalid rejection and Secure/HttpOnly/Lax cookie |
| NetworkPolicy with enforcing k3s CNI | Authorized backend TCP allowed; unrelated same-namespace pod denied while DNS remained available |
| Graceful worker maintenance | Two separate drains; 240/240 Web requests succeeded; workers restored |
| MySQL | Partial-schema repair, two reruns and dump/restore preserved marker/sequence values |
| Filesystem HBase recovery | RegionServer JVM loss and WAL replay preserved an unflushed fixture marker |
| HBase snapshot/clone | Restored a deleted fixture marker; local storage only |
| ZooKeeper member replacement | All three member pod IPs changed; stable client Services kept HBase connected |
| Distributed HBase/HDFS | Five independent JVM-loss cases preserved SYNC_WAL/HDFS markers and fresh writes; standby NameNode/Master takeover verified |
| Fresh single-namespace distributed install | New PVCs; 22 HBase tables verified in 2m52s, no failed schema retry pods; all running pods Ready |
| Manifest/package validation | Metric/Classic/external renders, strict API validation, initialization regressions and both chart archives checked |

Kafka's initial small limit caused an OOM; final defaults align a 1 GiB heap
with a 2 GiB pod limit and showed no OOM in the subsequent local tests. Some
Pinot pods retried once during cold ZooKeeper startup and then became Ready.
Schema bootstrap now waits inside its pod for bounded transient Master startup
errors; regression checks also cover timeout, authentication and disabled tables.

Classic Batch/Flink runtime, authenticated Kafka/ZooKeeper, alarm delivery,
prior-version data migration, independent host/disk loss, quorum loss, network
partitions/fencing, NFS durability, off-cluster restore and sustained production
load remain unqualified. Three virtual nodes on one computer cannot establish
independent failure-domain resilience. See [production acceptance](PRODUCTION.md).
