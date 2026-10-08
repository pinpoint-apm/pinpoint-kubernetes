# Production deployment

Run the stateless Web and Collector tier in Kubernetes and provision the
stateful services with operators or dedicated infrastructure. This chart's
external profile supports that arrangement. The bundled default stack is useful
for evaluation; its single filesystem-backed HBase pod is not a distributed
HBase/HDFS installation.

“External” means outside this application release, not necessarily outside
Kubernetes. The [operator-managed HBase/HDFS companion chart](../backends/hbase-stackable/README.md)
provides a Kubernetes deployment path with separate Master/RegionServer roles,
HDFS HA and three-member ZooKeeper. It is being qualified independently of the
application tier; see its prerequisites and acceptance requirements.
Pinpoint application, storage and dedicated operator pods can share one
`pinpoint` namespace while retaining separate Helm releases. External endpoints
can be Service DNS names in any namespace or private addresses outside the
cluster. Reuse the platform ingress controller. Operator CRDs/RBAC and CSI
integration still include cluster-scoped resources; reuse existing compatible
operators rather than deploying competing controllers.
Local Pinpoint ingestion and five individual HDFS/HBase process recovery cases
have passed on that path; this is evidence of integration and process recovery,
not qualification of your NFS storage or production workload.

## Reference architecture

| Tier | Deployment | Owner responsibilities |
| --- | --- | --- |
| Web | Two or more Kubernetes replicas; HTTPS ingress and shared login Secret | Access controls, resource sizing, request monitoring |
| Collector | Two or more Kubernetes replicas; gRPC Service | Agent routing, ingress capacity, ingestion monitoring |
| HBase | External distributed HBase with HDFS and its ZooKeeper ensemble | Master/RegionServer redundancy, WAL durability, region health, TTLs, snapshots and tested restore |
| ZooKeeper | External ensemble for Pinpoint coordination, optionally separate from HBase | Quorum, private networking, stable addresses |
| MySQL | External MySQL | Pinpoint schema, credentials, verified TLS, connection limits and backups |
| Redis | External Redis endpoint | Capacity, persistence/failover appropriate to its usage; stock clients in this chart lack TLS/Sentinel configuration |
| Kafka | External Kafka | Required topics, replication, retention, advertised listeners and consumer lag |
| Pinot | External Pinot | Required schemas/tables, replication, Kafka ingestion, segment storage and query health |

PostgreSQL cannot replace MySQL with stock Pinpoint 3.1.1 images: its schemas
and application queries require a [driver/schema/query adaptation](POSTGRESQL.md).
Kafka producers and ZooKeeper consumers
also lack the authenticated/encrypted connection configuration in this chart.
Use private trusted networks; NetworkPolicy restricts access but does not
encrypt traffic. If those protocols are mandatory, complete the client integration
before deploying. Backend versions need compatibility and security qualification;
the chart's pinned evaluation images are not a lifecycle policy for your services.

NFS alone does not provide HBase/HDFS HA. Keep HBase WALs and region storage on
an infrastructure validated for distributed HBase durability. An existing NFS
StorageClass should not be assumed suitable for HBase or Kafka simply because
their PVCs bind. Test storage failure/recovery, latency and throughput for each
backend. No NFS qualification or production load benchmark is claimed here.

## Configure the external profile

1. Provision the backends and apply the bundled 3.1.1 definitions in
   `files/sql/3.1.1` and `files/pinot/3.1.1`. Create HBase tables using the
   upstream 3.1.1 HBase script, respecting the configured namespace. Create
   the eight Kafka topics listed in `templates/init-job-kafka.yaml`, including
   `heatmap-stat-app-00`. Set replication/retention for your recovery objectives.
   Existing table/topic configurations are preserved by chart bootstrap;
   their migration is an explicit operator action.
2. Copy `values-production.yaml` to your own values file. Replace every example
   hostname/CIDR, select the ingress controller and set actual backend ports.
   HBase discovery and Pinpoint coordination can use separate ZooKeeper ensembles.
   Keep access to all discovered RegionServers, Kafka advertised brokers and
   Pinot brokers, not just initial bootstrap/controller endpoints.
3. Create the referenced MySQL, Redis, login and HTTPS Secrets in the release
   namespace using your secret manager. Login needs a random JWT secret and
   `admin` credentials as described in [configuration](CONFIGURATION.md#basic-login).
   All Web replicas must share the same JWT key. External MySQL uses the
   application user; the chart does not request external root credentials or
   modify its schema automatically.
4. Configure MySQL certificate trust in the application JVM when using
   `sslMode=VERIFY_IDENTITY`. Mount a Secret containing the truststore with
   `web.extraVolumes`/`extraVolumeMounts` and the equivalent Collector settings;
   set the JVM truststore options through `*.jvmOptions`. Distribute credentials
   through your secret manager rather than committing them to values files.
5. Review NetworkPolicy ingress selectors for your ingress controller/agent
   namespaces and external agent CIDRs. Allow DNS and the complete backend
   network through `externalEgress`. Use an enforcing CNI and test both allowed
   and denied traffic. Quickstart and Telegraf are disabled in this profile;
   enable system-metric collection only for a defined collection scope.

```bash
helm dependency build .
helm upgrade --install pinpoint . --namespace pinpoint --create-namespace \
  -f my-production-values.yaml --wait --timeout 20m
```

This renders only Web/Collector, their Services, optional ingress, PDBs and
network rules. It does not provision the external backends or guarantee their
availability. External topic/table initialization is opt-in:
`global.kafka.manageExternalTopics=true` with `createTopics=true`, or
`global.pinot.manageExternalTables=true` with `createTables=true` and
`controllerUrl`. Those initializers do not configure backend HA or migrate
existing definitions.

## Capacity and availability

The example requires two schedulable workers and spreads each application
across hostnames. PDBs keep one replica available during voluntary disruption;
they cannot prevent failure from simultaneous node loss. Rolling updates use
`maxUnavailable: 0`, `maxSurge: 1`; provide spare CPU/memory and node capacity
for the replacement pods. Agent gRPC connections also need reconnect/failover
verification against your actual Service/load-balancer setup.

Both Web and Collector create primary and metadata MySQL pools. With two Web
and two Collector replicas and the default pool maximum of 10, reserve up to
`4 × 2 × 10 = 80` connections plus surge pods, other clients, bootstrap and
administration. Their baseline minimum is `4 × 2 × 2 = 16`. Tune
`global.datasource.pool` against the database limit and measured demand. Stock
Pinpoint defaults can hold 30 idle connections per pool; explicit chart limits
avoid scaling into that idle connection cost.

Set HBase TTLs, Kafka retention and Pinot retention together with your required
history window and disk budget. Alert on HBase WAL recovery/region unavailability,
pod restarts/OOM, database connection usage, Kafka consumer lag and Pinot
ingestion/query errors. Probe success alone does not establish end-to-end health.

## Acceptance before production

Verify actual agent traces, Inspector, URI and expected system metrics through
HTTPS with authentication. Exercise worker maintenance, application updates,
backend failover and restoring backups. Test alarm delivery separately. Record
the deployed values, image digests, Secrets ownership, backup schedule, recovery
time/data-loss objectives and an upgrade/rollback procedure.

[Local tests](LOCAL-TESTING.md) demonstrate the chart's application configuration,
authentication, network isolation and graceful worker maintenance. They use
one physical host and include distributed HBase/HDFS process recovery. They
do not establish independent hardware failure resilience, NFS durability,
production ingress behavior or your ingestion capacity.
