# Production application profile on a local cluster

This example shows what the **application chart** deploys when all bundled
backends are disabled. Pinpoint workloads and operators share the **pinpoint**
namespace, with separate releases so application upgrades do not replace storage.
The local ingress controller represents existing platform infrastructure:

| Release | Namespace | Resources |
| --- | --- | --- |
| `pinpoint-storage` | `pinpoint` | Operator-managed ZooKeeper, HDFS HA and HBase |
| `services` | `pinpoint` | Local MySQL, Redis, Kafka, Pinot and their ZooKeeper; schemas/topics |
| `pinpoint` | `pinpoint` | Two Web and two Collector replicas, Services, login, ingress, PDBs and NetworkPolicies |
| Six Stackable operator releases | `pinpoint` | Reconcile HBase/HDFS/ZooKeeper and provide their CSI infrastructure |
| `pinpoint-ingress` | `kube-system` | Traefik controller serving the application's HTTPS Ingress |

The `services` release reuses the root chart with Web/Collector/HBase disabled
**as a local fixture**. In production, use your managed or operator-managed
backend services instead. This example's single MySQL/Redis/Pinot instances,
local-path storage, small HBase heaps, and self-signed TLS certificate are not
a production capacity/durability configuration. MySQL TLS is disabled only in
this isolated local fixture. Production uses verified TLS and a trusted CA.

### Expected pod count

This complete local example has **47 pods**, including one completed schema Job:

| Group | Pods | Needed by the production application release? |
| --- | ---: | --- |
| Web + Collector | 4 | Yes, two replicas of each |
| Quickstart + Telegraf | 2 | Optional demonstration overlay |
| HBase + HDFS + ZooKeeper storage | 15 | Only when provisioning this companion backend |
| Stackable controllers + CSI | 12 | Only for the companion backend on these three nodes |
| MySQL + Redis + Kafka + Pinot + coordination ZooKeeper | 13 | Local fixtures; replace with separately managed endpoints |
| Completed HBase schema Job | 1 | Companion bootstrap; no running process after completion |

The root chart does not install Stackable operators. Its production profile
installs four application pods and connects to existing services; its default
evaluation profile bundles backends. The optional companion's production defaults
use three RegionServers rather than this example's two, for 16 storage pods.
The six controllers manage HBase, HDFS, ZooKeeper, shared resource definitions, Secrets and
listeners. Secret/listener CSI DaemonSets add two pods per eligible node, so their
count scales with the cluster, not with the number of Pinpoint application releases.

## Install from the checkout

Requires an isolated three-node local cluster, Helm 3, Python 3, OpenSSL,
kubectl. The six Stackable 26.7.0 operators are installed once below. Their
CRDs/RBAC and CSI integration also contain cluster-scoped resources. Reuse
existing compatible operators instead of deploying duplicate controllers.
Use the explicit kubeconfig on every command; do not reuse production namespaces.

```bash
helm dependency build .
python3 examples/local-production/setup-local.py \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml

for operator in commons secret listener zookeeper hdfs hbase; do
  helm upgrade --install "$operator-operator" \
    "oci://oci.stackable.tech/sdp-charts/$operator-operator" \
    --version 26.7.0 --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
    --namespace pinpoint -f examples/local-production/operators.yaml \
    --wait --timeout 10m
done

helm upgrade --install pinpoint-storage backends/hbase-stackable \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint \
  -f backends/hbase-stackable/values-local.yaml \
  -f examples/local-production/storage.yaml \
  --wait --wait-for-jobs --timeout 20m

helm upgrade --install services . \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint \
  -f examples/local-production/services.yaml --wait --timeout 20m

kubectl --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  apply -f examples/local-production/services-access.yaml

helm upgrade --install pinpoint-ingress traefik \
  --repo https://traefik.github.io/charts --version 41.6.1 \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace kube-system \
  -f examples/local-production/ingress.yaml --wait --timeout 5m

helm upgrade --install pinpoint . \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint \
  -f values-production.yaml \
  -f examples/local-production/application.yaml \
  --wait --timeout 20m
```

The setup helper accepts loopback API endpoints only. It creates random local
Secrets and a TLS certificate for `localhost` and `pinpoint.localhost`. Credentials are retained
privately in `/tmp/pinpoint-production-demo`, outside the repository; rerunning
it does not rotate passwords of an existing database. Keep that directory for
reruns. If `/tmp` is cleared after reboot, recreate the entire local fixture or
recover its existing credentials before running setup again.

The application release does **not** run HBase, MySQL, Redis, Kafka, Pinot or
ZooKeeper installation/schema hooks. Those services and schemas are ready
before it starts. The HBase discovery ConfigMap is in the application's
namespace; the Metric services are reached through explicit Service DNS names.
NetworkPolicies select backend pods by release labels even in the same namespace.
The backend MySQL Secret includes its root password; the application Secret does not.

## Generate demonstration data

Add `-f examples/local-production/demo.yaml` as the **last** values argument
to the application Helm command to enable one Quickstart pod and one Telegraf
pod. This optional overlay generates agent/system metrics; omit it in production.
With the overlay installed, verify actual ingestion and both Web login replicas:

```bash
python3 scripts/local-smoke.py \
  --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  --namespace pinpoint --release pinpoint \
  --backend-namespace pinpoint --backend-release services \
  --stackable-hbase-cluster pinpoint-storage-hbase \
  --hbase-namespace pinpoint \
  --application-name PINPOINT_PRODUCTION_DEMO \
  --login-credentials /tmp/pinpoint-production-demo/login.json --timeout 360
```

Inspect the releases separately:

```bash
helm list --all-namespaces --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml
kubectl --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  -n pinpoint get deployments,statefulsets,jobs,pdb,ingress
k9s --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml --all-namespaces
```

## Open the UI through the real ingress

```bash
kubectl --kubeconfig /tmp/pinpoint-311-kubeconfig.yaml \
  -n kube-system port-forward \
  service/pinpoint-ingress-traefik 18443:443 --address localhost
```

Keep the port-forward terminal open and visit **https://localhost:18443/login**
from a browser on the same computer. No hosts entry is required. The alternative
`https://pinpoint.localhost:18443` needs local DNS resolution or a hosts entry
`127.0.0.1 pinpoint.localhost` if your system does not resolve it automatically.
Use `https://` explicitly. `--address localhost` binds both IPv4 and IPv6 loopback
so the browser can use either localhost address.
The certificate is self-signed: explicitly trust the demo certificate on your
test client, without disabling verification for production. For a verified CLI
request, in a second terminal:

```bash
curl --noproxy '*' \
  --cacert /tmp/pinpoint-production-demo/tls.crt \
  https://localhost:18443/login

python3 examples/local-production/verify-ingress.py
```

If the cluster/port-forward runs on a different computer reached over SSH,
forward its loopback port to the browser computer with
`ssh -N -L 18443:127.0.0.1:18443 user@cluster-host`, then use the same localhost URL.
The Kubernetes port-forward must also remain running on that cluster computer.

Read the local account from `/tmp/pinpoint-production-demo/login.json` on your
machine. No fixed production passwords are embedded in the example.

Traefik is installed independently using its
[official Helm chart](https://github.com/traefik/traefik-helm-chart). Existing
production ingress controllers can be reused by changing the ingress class,
TLS Secret and NetworkPolicy selectors; installing Traefik is not a Pinpoint
requirement.
