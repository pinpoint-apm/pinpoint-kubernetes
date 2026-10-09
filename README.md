# Pinpoint Helm Chart

[![Helm CI](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml/badge.svg)](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml)
![Pinpoint](https://img.shields.io/badge/Pinpoint-3.1.1-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

Deploy Pinpoint APM 3.1.1 on Kubernetes with Helm 3. **Metric mode is the
default**, providing application tracing and Kafka/Pinot-based metrics.
Chart **3.1.2** targets Pinpoint **3.1.1**; chart fixes have their own release version.

| Installation | What the chart installs |
| --- | --- |
| Default evaluation stack | Web, Collector, HBase, ZooKeeper, MySQL, Redis, Kafka, Pinot, Telegraf and a Quickstart demo application |
| [Production profile](values-production.yaml) | Two Web and two Collector replicas connected to independently managed backends; no databases or operators |

Classic mode is available for existing Batch/Flink deployments; see
[profile configuration](docs/CONFIGURATION.md#configuration).

## Components at a glance

| Component | Purpose |
| --- | --- |
| Web | UI and APIs for application maps, traces and metrics. |
| Collector | Receives agent data and writes traces and metrics to their backends. |
| HBase | Stores traces, application-map statistics and agent metadata. |
| ZooKeeper | Coordinates HBase, Pinot and Pinpoint services. |
| MySQL | Stores Web configuration, users/groups and alarm settings. |
| Redis | Shares transient application state between Pinpoint services. |
| Kafka | Buffers metric events between Collector and Pinot. |
| Pinot | Stores and queries metrics: Server ingests/serves data, Broker routes queries, Controller manages tables/segments, and Minion runs background segment tasks. |
| Telegraf / Quickstart | Optional system-metric collection / demo application. |

The optional HBase/HDFS HA backend adds two HBase Masters, three RegionServers,
two HDFS NameNodes, three JournalNodes, three DataNodes and three ZooKeeper members.
Masters manage regions; RegionServers serve HBase data. NameNodes manage filesystem
metadata, JournalNodes replicate its edit log, and DataNodes store data blocks.

Stackable operators manage these backend clusters. Their **Secret CSI** drivers
mount pod-specific credentials/certificates; **Listener CSI** drivers provide
service connection details. They run once per eligible node, so pod count grows
with worker count. They support the Stackable backend and do not store trace data
or replace the StorageClass's disk provisioner. See the
[backend component guide](backends/hbase-stackable/README.md#components-and-pod-count).

Install operators once per cluster and manage backends as independent releases.
With existing backends, the production application profile installs only
**two Web and two Collector pods**, plus the configured initialization Jobs.

## Requirements

You need Kubernetes, Helm 3 and kubectl. Bundled backends require persistent
storage: use a default StorageClass or configure backend storage in your values
file. Stock HBase and demo images require Linux amd64 nodes.

The default stack requests approximately **22.6 GiB RAM and 7.75 CPU cores**,
excluding initialization and cluster services. Allow additional capacity for
startup and workload growth. See [resource sizing](docs/CONFIGURATION.md#resource-sizing)
and [values.yaml](values.yaml) for resource and JVM settings.

## Install the evaluation stack

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.2 --namespace pinpoint --create-namespace \
  --wait --timeout 20m
kubectl get pods,jobs,pvc -n pinpoint
kubectl port-forward -n pinpoint service/pinpoint-web 8080:8080
```

Keep the port-forward running and open http://localhost:8080. Quickstart
provides demo data. Batch and Flink are disabled in this profile.

Bundled HBase runs Master and RegionServer in a **single filesystem-backed
pod**. For backend HA, use independently managed storage services with the
production profile.

## Install with production backends

Provision HBase, ZooKeeper, MySQL, Redis, Kafka and Pinot first. They can run in
Kubernetes or on separate infrastructure; endpoints can be Service DNS names or
private addresses. After adding the Helm repository, copy the production example:

```bash
helm pull pinpoint/pinpoint --version 3.1.2 --untar --untardir /tmp/pinpoint-chart
cp /tmp/pinpoint-chart/pinpoint/values-production.yaml my-production-values.yaml
```

Edit backend endpoints, Secret references, ingress class/hostname/TLS and network
rules. Initialize backend schemas and create Secrets following the
[production guide](docs/PRODUCTION.md), then install:

```bash
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.2 --namespace pinpoint --create-namespace \
  -f my-production-values.yaml --wait --timeout 20m
```

The profile enables PDBs, node spreading, HTTPS login and NetworkPolicies. It
requires two schedulable workers and an existing ingress controller. Backend
availability, storage durability and capacity must be verified for your environment.

For HBase/HDFS in Kubernetes, the optional [companion chart](backends/hbase-stackable/README.md)
uses separately installed Stackable operators. It is an independent Helm release;
the application chart does not install operators or CSI drivers.

## Connect agents

Agents use Collector gRPC ports **9991/TCP** for agent/metadata, **9992/TCP** for
statistics and **9993/TCP** for spans. With release name `pinpoint`, the default
Collector Service is `pinpoint-collector` with type `ClusterIP`.

Agents outside Kubernetes need a reachable Collector endpoint, such as a TCP
load balancer or a TCP proxy forwarding to NodePorts. Configure Collector access
separately from the Web UI ingress.

For example, add this to your installation values to expose the Collector on
worker node IPs:

```yaml
collector:
  service:
    type: NodePort
```

After installing/upgrading with that values file, find the allocated ports:

```bash
kubectl get service pinpoint-collector -n pinpoint \
  -o jsonpath='{range .spec.ports[*]}{.name}{"="}{.nodePort}{"\n"}{end}'
```

For a Java agent, add these JVM options alongside your `-javaagent` option.
Replace the hostname and the three example ports with a reachable worker address
and the returned `grpc-agent`, `grpc-stat` and `grpc-span` NodePorts:

```text
-Dpinpoint.applicationName=my-application
-Dpinpoint.agentId=my-application-instance-01
-Dprofiler.transport.grpc.collector.ip=worker.example.internal
-Dprofiler.transport.grpc.agent.port=30991
-Dprofiler.transport.grpc.stat.port=30992
-Dprofiler.transport.grpc.span.port=30993
```

Use a unique `agentId` for each application instance; it is not the Collector
address. Allow agent traffic through firewalls and, when enabled, NetworkPolicies.
Verify the application appears in the Web UI with recent traces and statistics.

For production, prefer a stable TCP load balancer/proxy endpoint. A proxy can
listen on **9991/9992/9993** and forward to the allocated worker NodePorts, keeping
the agent's standard ports. A Web ingress path such as `/collector` does not
provide this three-port gRPC endpoint.

## External services

Disable the bundled backend and provide its connection settings:

| Backend | Values |
| --- | --- |
| HBase | `hbase.enabled=false`, `global.hbase.*` |
| ZooKeeper | `zookeeper.enabled=false`, `global.zookeeper.address` |
| MySQL | `mysql.enabled=false`, `global.datasource.*` |
| Redis | `redis.enabled=false`, `global.redis.*` |
| Kafka | `kafka.enabled=false`, `global.kafka.bootstrapServers` |
| Pinot | `pinot.enabled=false`, `global.pinot.*` |

Kafka supports plaintext connections. Redis supports host/port connections with
password/Secret configuration. Kafka SASL/TLS, Redis Sentinel/TLS and ZooKeeper
client authentication are unsupported. PostgreSQL requires
[application and SQL changes](docs/POSTGRESQL.md); a JDBC URL change alone is insufficient.

See [configuration](docs/CONFIGURATION.md) for examples, login, initialization and
resource tuning. Keep credentials in Kubernetes Secrets and environment-specific
values outside this repository.

## Documentation and development

- [Production deployment](docs/PRODUCTION.md): architecture, capacity and acceptance checks.
- [Configuration](docs/CONFIGURATION.md): profiles, connection settings, Secrets and recovery.
- [Local testing](docs/LOCAL-TESTING.md): installation and runtime validation.
- [Upgrades](docs/UPGRADING.md): persistent data and version changes.
- [Release notes](docs/RELEASE-3.1.2.md) and [release process](docs/RELEASING.md).

To install a checkout, run `helm dependency build .`, use `.` as the chart path
and omit `--version`. Run `bash scripts/helm-validate.sh` for chart validation;
it requires Helm 3, Python 3 and Ruby.

To uninstall, run `helm uninstall pinpoint -n pinpoint`. Review PVC retention
separately; removal does not necessarily delete persistent data or independent backends.
