# Pinpoint Helm Chart

[![Helm CI](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml/badge.svg)](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml)
![Pinpoint](https://img.shields.io/badge/Pinpoint-3.1.1-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

Deploy **Pinpoint 3.1.1** with Helm 3. Two installation paths share the same
chart: a production application profile with independently managed backends,
and a bundled Metric stack for evaluation. Classic is an optional legacy profile.

## Production installation

[values-production.yaml](values-production.yaml) deploys **two Web and two
Collector pods** with PDBs, node spreading, bounded JVM heaps, non-root containers,
HTTPS login and NetworkPolicies. It does not install databases or operators.
Backend endpoints can be Kubernetes Service names or private external addresses.
Use your existing ingress controller and configure its class, hostname and TLS Secret.

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm pull pinpoint/pinpoint --version 3.1.1 --untar --untardir /tmp/pinpoint-chart
cp /tmp/pinpoint-chart/pinpoint/values-production.yaml my-production-values.yaml
# Edit endpoints, Secret references, ingress and network rules before installing.
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.1 --namespace pinpoint --create-namespace \
  -f my-production-values.yaml --wait --timeout 20m
```

Provision backend schemas and Secrets first; follow
[production deployment](docs/PRODUCTION.md) for supported services, sizing,
backup/restore and deployment acceptance. The profile is a starting configuration;
its example addresses and Secret names must be replaced.

For HBase on Kubernetes, the optional
[HBase/HDFS companion chart](backends/hbase-stackable/README.md) provides HA storage
under separately installed Stackable operators. Give that release a validated
StorageClass. Operators and CSI drivers are platform dependencies installed once;
the root chart does not create them. Existing HBase endpoints require none of them.
Application, backend and operator releases can share a `pinpoint` namespace.
See the [local demonstration](examples/local-production/README.md) for a complete
installation and the backend's exact pod footprint.

## Evaluation installation

The default uses **Metric mode**: Web, Collector, HBase, ZooKeeper, MySQL, Redis,
Kafka, Pinot, Telegraf and Quickstart demo traces. Batch and Flink are disabled.
It requires persistent storage and Linux amd64 capacity for the stock HBase/demo
images. Defaults reserve about **20.6 GiB RAM and 7.75 CPU cores**, excluding
bootstrap/system pods; a 32 GiB local host is recommended.

```bash
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.1 --namespace pinpoint --create-namespace \
  --wait --timeout 20m
kubectl get pods,jobs,pvc -n pinpoint
kubectl port-forward -n pinpoint service/pinpoint-web 8080:8080
```

Open http://localhost:8080. Bundled HBase is **one filesystem-backed pod** with
daemon supervision, health probes, schema repair and graceful shutdown. Use the
production profile and independent backends for HA deployments. NFS durability
and recovery from independent host failure were not qualified by the local tests.

Before publication, run `helm dependency build .` and install this checkout using
`.` instead of `pinpoint/pinpoint`, omitting `--version`. For production, copy
`values-production.yaml` directly from the checkout.

## Defaults and resource sizing

Application/backend containers and chart-owned initialization containers have
explicit CPU/memory requests and limits. JVM
heaps are bounded separately to leave space for native memory, direct buffers
and caches. The following memory settings apply **per pod**:

| Component | Memory request / limit | Maximum JVM heap |
| --- | --- | --- |
| Web | 1.5 / 3 GiB | 1.5 GiB |
| Collector | 2 / 4 GiB | 2 GiB |
| HBase | 2 / 4 GiB | 1 GiB each for Master and RegionServer |
| Kafka, each controller/broker | 1.5 / 2 GiB | 1 GiB |
| ZooKeeper, each of 3 pods | 0.5 / 1.5 GiB | 0.5 GiB |
| Pinot server | 2 / 4 GiB | 1 GiB; extra memory for off-heap/segments |
| Pinot controller/broker/minion | 1.25 / 2 GiB | 1 GiB |
| MySQL / Redis | 1 / 2 GiB; 0.25 / 0.5 GiB | — |
| Quickstart / Telegraf | 0.5 / 1.5 GiB; 64 / 256 MiB | Quickstart: 0.5 GiB |

These are tested starting values, not capacity guarantees. Inspect
`kubectl top pods -n pinpoint` and tune each component's `resources` in
[values.yaml](values.yaml). Increase JVM heap and memory limits together
(`web.jvmOptions`, `collector.jvmOptions`, `hbase.heapSize`,
`kafka.controller.heapOpts`, `kafka.broker.heapOpts`, `zookeeper.heapSize`).
`global.initResources` controls dependency checks and MySQL/Kafka bootstrap;
`global.pinot.initResources` controls Pinot bootstrap. Kafka uses KRaft; its three controller pods also serve as brokers by default.

## Supported external services

| External service | Support |
| --- | --- |
| MySQL | `mysql.enabled=false` + `global.datasource.*`; operator-managed schema |
| Redis | `redis.enabled=false` + `global.redis.*`; password/Secret supported |
| Kafka | `kafka.enabled=false` + `global.kafka.bootstrapServers`; plaintext only |
| PostgreSQL | Requires [custom application/SQL adaptation](docs/POSTGRESQL.md); stock images unsupported |
| HBase | `hbase.enabled=false` + `global.hbase.*`; operator-managed tables |
| ZooKeeper | `zookeeper.enabled=false` + `global.zookeeper.address` |
| Pinot | `pinot.enabled=false` + `global.pinot.jdbcUrl`; operator-managed schemas/tables |

Kafka SASL/TLS and ZooKeeper client authentication are rejected because stock
clients are not wired for them. Topic/table bootstrap repairs missing resources
and preserves existing configuration; replication overrides apply to new
resources. See [configuration and issue #41](docs/CONFIGURATION.md).

**Classic mode is an optional legacy profile**, retained for existing
Batch/Flink deployments via `global.metric.enabled=false`. It is not the
default or a second recommended installation. Its manifests are validated;
the local runtime test covers Metric mode. See
[profile configuration](docs/CONFIGURATION.md#configuration).

## Validation and upgrades

[Local k3s testing](docs/LOCAL-TESTING.md) covers default installation, external
backends, two application replicas, HTTPS/JWT, NetworkPolicy, worker drains,
schema repair and HBase process recovery.
The optional distributed backend also passed a clean install and individual
NameNode, JournalNode, DataNode, Master and RegionServer recovery tests.
With Helm, Python 3 and Ruby installed, run `bash scripts/helm-validate.sh` for lint, render, packaging and bootstrap
regression checks. Review [upgrade notes](docs/UPGRADING.md) before reusing PVCs
and [release checks](docs/RELEASE-3.1.1.md) before publishing.

```bash
helm uninstall pinpoint --namespace pinpoint
```

Persistent volumes may remain after uninstall; manage their retention explicitly.
