# Upgrading the Pinpoint chart

## Chart 3.1.0 to 3.1.1

The default Web, Collector, Agent, Batch and HBase images now use Pinpoint
3.1.1. The [upstream release notes](https://github.com/pinpoint-apm/pinpoint/releases/tag/v3.1.1)
state that there are no schema changes from 3.1.0. Back up persistent data and
test the upgrade in staging before changing a production release.

### Bundled HBase and Kafka

The HBase pod now uses a chart-mounted supervisor and health scripts instead
of the image's original entrypoint. Configuration changes restart the pod.
Both daemon JVMs default to 1024 MiB heap each; the pod memory limit is 4 GiB.
Review overrides to provide enough memory for both heaps, native memory and
bootstrap. Readiness waits for all Pinpoint tables; missing tables are repaired
without replacing existing tables. Existing TTLs are not rewritten. The pod
has a 300-second graceful shutdown budget. The wrapper requires the stock
image's Bash, `timeout`, daemon scripts and `configure-hbase.sh`; custom images
must provide compatible paths and tools.

Kafka controller/broker memory limits now default to 2 GiB with a 1 GiB JVM
maximum heap, replacing the dependency's too-small 768 MiB limit. Review any
resource overrides before a rolling upgrade. These changes do not add HA to
single-pod HBase or migrate storage.

The optional Stackable backend is a **new distributed deployment**, not an
in-place conversion of the bundled filesystem PVC. It uses HBase 2.6.6/HDFS
3.4.3 with separately provisioned disks and ZooKeeper claims. Do not attach an
old HBase 1.x or bundled local-filesystem volume to it and assume compatibility.
For existing history, plan a supported HBase upgrade/export/import path with
staging restore checks. Switching the application endpoint alone does not copy
old traces. A fresh installation starts with new history.

All default workloads now have explicit requests/limits. Web and Collector
heaps are set with `*.jvmOptions`; Kafka heaps use the role-specific
`kafka.controller.heapOpts` and `kafka.broker.heapOpts`. ZooKeeper defaults to
a 512 MiB heap within a 1536 MiB limit. Check scheduling capacity before the
upgrade: defaults reserve about 20.6 GiB RAM and 7.75 CPU, plus surge/init/system
pods. Existing user overrides are retained unless explicitly reset.

HBase now uses stable per-member ZooKeeper ClusterIP Services to work around
the stock image's ZooKeeper 3.4.10 client caching old pod IPs. This changes
the HBase configuration and restarts its pod once. Keep those Services across
future ZooKeeper rolling upgrades; recreating them may require restarting HBase.

### Pinot

Pinpoint 3.1.x is incompatible with Pinot 1.0.0. This chart changes the default
Pinot image to 1.3.0. Schema initialization now uses a separate Python image
(`global.pinot.initImage.*`), bundled versioned JSON and the Pinot REST API.
For a persistent Pinot 1.0 installation, plan and test the Pinot data upgrade
separately using the [Apache Pinot documentation](https://docs.pinot.apache.org/).
Changing the image tag alone is not a verified data migration procedure.

The init hook creates only missing schemas and tables. Existing resources,
including their Kafka endpoints, consumer plugins and replication, are preserved.
Heatmap bootstrap now includes REALTIME and OFFLINE tables and maps its Kafka
topic to `heatmap-stat-app-00`, matching Collector 3.1.1. An existing Heatmap
table with the upstream placeholder topic is preserved and must be corrected
through an operator-reviewed change.

Review existing realtime table configs for the Pinot 1.3 Kafka 3.0 consumer
factory (`org.apache.pinot.plugin.stream.kafka30.KafkaConsumerFactory`) when
migrating. Update existing resources through an operator-reviewed procedure;
hook success does not prove that existing stream consumers ingest data.

### Authentication settings and partial initialization (#41)

Server-only Kafka SASL/TLS or ZooKeeper auth configurations now fail Helm
validation with an explanation. Earlier production comments were misleading:
stock Pinpoint 3.1.1 does not expose Kafka producer security properties and
this chart does not pass ZooKeeper credentials to all clients. Do not disable
authentication on an existing service to work around this validation. Such
deployments need client integration before upgrading; see the README.

The Kafka hook now creates every required topic idempotently and stops on
creation errors. The Pinot hook checks exact schema/table names rather than
total counts, so unrelated resources cannot hide missing Inspector tables.
`global.pinot.createTables=false` opts out for operator-managed initialization.
Topic/table replication settings apply only to newly created resources.

### Basic login and webhooks

Basic login is configurable through `web.login.*`. Enabling it requires an
existing Secret containing the JWT key and configured credential keys. Cookie
defaults are HttpOnly, Secure and SameSite=Lax; use HTTPS. Pinpoint rejects the
public example JWT key `__PINPOINT_JWT_SECRET__`. Rotate to a random secret.

Pinpoint 3.1.1 rejects webhooks resolving to private, loopback and link-local
addresses. Review existing internal alarm webhook destinations before upgrading;
this chart does not bypass upstream SSRF validation.

### Image overrides and external databases

HBase, Agent/Quickstart and classic Flink pods now select Linux amd64 nodes by
default. The stock HBase/Agent/Flink image manifests do not include arm64.
On mixed clusters, verify amd64 capacity and that existing volumes can attach
there before upgrading. Pure arm64 deployments require compatible custom images
and component `nodeSelector` overrides.

Explicit Web and Collector image tags are now used verbatim. If an existing
metric values file sets `web.image.tag: "3.1.0"` or
`collector.image.tag: "3.1.0"`, update it to `"3.1.1-metric"` or leave the tag
empty to inherit the chart default.

External MySQL remains supported through `global.datasource.*`; passwords may
reference an existing Secret. Custom driver settings are now also passed to
the primary and metadata Hikari datasources. This does not add PostgreSQL
application support: the stock schemas and MyBatis mappers remain MySQL-specific.

### External profile, application security and connection pools

`values-production.yaml` now supplies an application-only profile with external
HBase/ZooKeeper/MySQL/Redis/Kafka/Pinot, two Web/Collector replicas, PDBs and
strict hostname spreading. Replace example endpoints and Secrets before use.
New `global.hbase.*` settings configure the actual HBase client host, port,
znode and namespace. `global.zookeeper.address` controls Pinpoint coordination;
`global.pinot.jdbcUrl` controls external Pinot. Disabling dependencies does not
initialize their external schemas. See [production deployment](PRODUCTION.md).

Web/Collector now run as UID/GID 1000 with a read-only root filesystem,
RuntimeDefault seccomp and dropped capabilities. Temporary files and logs use
bounded writable volumes. Custom images must include that UID in `/etc/passwd`
or provide an existing user through security overrides. Review custom file
paths, mounts and filesystem permissions before upgrading.

Primary and metadata MySQL pools default to a maximum of 10 and a minimum of
2 idle connections each, with a 5000 ms connection timeout. Tune
`global.datasource.pool` for actual load and budget connections across replicas
and rolling-update surge. This replaces stock application pool defaults;
check database latency and saturation after the rollout.

The bundled MySQL hook repairs missing tables and named indexes using exact
versioned definitions, rather than skipping initialization based on total table
count. Existing records and batch sequence rows are preserved. This is not a
general schema migration tool; back up the database and review compatibility
of existing columns/table definitions before upgrading.

## Chart 2.2.x to 3.1.0

Chart 3.1.0 updates the default Pinpoint application version from 3.0.3 to
3.1.0. Back up the MySQL database and HBase persistent volume before upgrading.

### Bundled databases

When the bundled MySQL chart is enabled, the chart's `post-upgrade` hook widens
the Pinpoint 3.1 webhook columns to `VARCHAR(127)` when required.

The Pinpoint 3.1 HBase image uses the new `AgentId` table as its schema marker.
When upgrading a persistent 3.0.3 HBase volume, the image creates the new 3.1
tables because that marker is absent. After the upgrade, verify that these
tables exist:

```text
MapAppSelf
MapAgentSelf
MapAppOut
MapAppIn
MapAppHost
TraceIndex
Application
AgentId
```

### External databases

The chart does not modify external MySQL or HBase instances. Before starting
Pinpoint 3.1.0 against an external MySQL database, apply this idempotent schema
change:

```sql
ALTER TABLE webhook
  MODIFY COLUMN application_id VARCHAR(127) NULL,
  MODIFY COLUMN service_name VARCHAR(127) NULL;
```

For external HBase, create the new 3.1 tables using the official
[`hbase-create.hbase`](https://github.com/pinpoint-apm/pinpoint/blob/v3.1.0/hbase/scripts/hbase-create.hbase)
definitions and verify the eight tables listed above before starting the 3.1
Web and Collector workloads.

### Classic mode

Pinpoint does not publish a `pinpoint-flink:3.1.0` image. The chart pins Flink
to the compatible 3.0.3 image in classic mode. Override `flink.image.tag` only
after confirming that the requested image exists and is compatible.
