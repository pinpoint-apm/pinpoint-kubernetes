# Upgrading the Pinpoint chart

## Chart 3.1.4 to 3.1.5

Pinpoint stays on 3.1.1 and the locked dependency charts are unchanged. Most
upgrades need no values changes, but review these behavior changes first.

**Web admin API password.** Pinpoint Web's `/api/admin/**` endpoints (remove
applications/agents) were protected only by the fixed password `admin`. The
chart now creates `<release>-web-admin-api` with a random password and keeps it
on later upgrades. To keep using a known password or render with
`helm template`/Argo CD (no Helm lookup), reference your own Secret:

```yaml
web:
  adminApi:
    passwordSecret:
      name: pinpoint-login
      key: admin-api-password
```

`values-production.yaml` now uses that key; add `admin-api-password` to the
login Secret before upgrading with it. Scripts that call the admin API with
`password=admin` must use the new value. An empty password is never rendered
because Pinpoint would then skip the check.

**Bundled MySQL passwords.** The defaults `pinpoint`/`mysql` were removed. Helm
CLI upgrades keep the existing `<release>-mysql` Secret through lookup, so
existing databases continue to work. With `helm template` or Argo CD, set
`mysql.auth.existingSecret`, or the previous explicit values, before upgrading;
otherwise new random passwords would not match the initialized data directory.

**Telegraf is opt-in.** It was a single-replica Deployment that reported one
arbitrary node under its pod name. It is now a DaemonSet that reports every
node under its Kubernetes node name, and it is disabled by default. Set
`telegraf.enabled=true` (and optionally `telegraf.hostGroupName`) to keep host
metrics. Host series appear under node names instead of the old pod name.
Telegraf needs the Pod Security `privileged` level for its read-only `/proc`
and `/sys` hostPath mounts; `/etc` is no longer mounted.

**Standalone agent removed.** `agent.enabled=true` now fails rendering. That
Deployment could not instrument other pods, crash-looped on its own volume and
configured wrong stat/span ports. Follow [AGENTS.md](AGENTS.md) instead.

**Kafka topics.** The topic list moved to `global.kafka.topics`. The
initializer still creates missing topics, and now raises the partition count of
existing topics that have fewer partitions than configured; it never deletes
topics or lowers partitions. Bundled Kafka auto-creates topics with one
partition when the Collector produces before the post-install hook runs, so
the first 3.1.5 upgrade can log `Raising url-stat partitions from 1 to 64`.
Topics with a lower replication factor are reported, not reassigned. Increasing
partitions changes key-to-partition mapping for new records only. For external
Kafka the change applies only with `global.kafka.manageExternalTopics=true`.

**HBase.** New tables use the stock image's TTL variables for the 3.1.1 v2
indexes: `TRACEINDEX_TTL` (now 7 days, matching `TRACEV2_TTL`),
`APPLICATION_TTL`, `AGENTID_TTL` and the optional v3 `MAP*` tables. Existing
tables keep their TTLs. The unused `AGENTSTATV2_TTL`/`APPSTATAGGRE_TTL` keys were
dropped from the defaults. To apply new retention to an existing `TraceIndex`,
alter it in the HBase shell during a maintenance window. The HBase pod now drops
Linux capabilities and disables privilege escalation; it still runs as root,
so existing volumes need no ownership change. HBase restarts during this
upgrade because its pod template changes.

**Other defaults.**
- `web.config.sendUsage` and `batch.config.sendUsage` default to `false`;
  Pinpoint Web no longer sends UI usage to Google Analytics unless enabled.
- `networkPolicy.assetDownloadEgress` is empty. Bootstrap assets are bundled,
  so initialization Jobs and Telegraf get no Internet egress by default.
- Web's MySQL wait no longer receives the MySQL root password.
- Dependency checks and bootstrap Jobs run with a restricted security context
  (`global.initSecurityContext`), using `global.waitImage` instead of a fixed
  `busybox:1.36`.
- HBase, Quickstart, Telegraf, Batch and Flink receive `global.imagePullSecrets`.
  `global.image.registry` falls back to `global.imageRegistry`, which Bitnami
  dependencies also read; relocated Bitnami images additionally need
  `global.security.allowInsecureImages=true`. Pinot needs
  `pinot.imagePullSecrets` and `pinot.image.repository`.
- Classic Flink moves from 3.0.3 to 3.0.5, the newest published Flink image.
- Batch alarm mail uses Spring Mail properties read by 3.1.1:
  `batch.mail.from`, `smtpAuth`, `starttls` and `starttlsRequired`. The ignored
  `ALARM_MAIL_*` variables and Batch `ADMIN_PASSWORD` were removed, as were
  the Gmail placeholder defaults for `batch.mail.host`/`username`.
- `values.schema.json` rejects unknown top-level keys, such as `colector:`.
- Web/Collector accept `serviceAccountName`, `priorityClassName`, `podLabels`
  and `lifecycle`; `web.httpRoute` adds an optional Gateway API route.

## Storage chart 0.1.2 to 0.1.3

The schema Job name now includes a hash of its image, settings and schema
files, so changing `hbase.version`, `bootstrap.*` or pull settings creates a new
Job instead of failing on Kubernetes' immutable Job template. Upgrading reruns
the idempotent verification once. New `TraceIndex` and v3 map tables use the
7-day TTL of `TraceV2`; existing tables are unchanged.

## Storage chart 0.1.0 / 0.1.1 to 0.1.2

The independently versioned `pinpoint-hbase-stackable` chart now limits WAL
recovery to one splitter and two bounded writer threads per RegionServer.
HBase role-level `configOverrides` are supported. Applying these defaults
rolls RegionServers; retain existing resource, PVC and image settings.
The application chart remains 3.1.4 and Pinpoint remains 3.1.1.

Backend CRs request Argo CD server-side apply, preserving explicit null
ZooKeeper TLS settings. When adopting existing resources, run one sync if
changing the apply method alone does not trigger it. Argo CD does not update
the legacy Helm release history; inspect Application revisions and live health.

If client TLS had been enabled unintentionally, first verify the ZooKeeper
Service exposes 2181. Reconcile the existing HBase/HDFS Znode claims to refresh
their discovery ConfigMaps without changing claim paths. Verify the generated
HBase configuration, then restart affected roles in sequence. Confirm zero
regions in transition, readable `Application`/`AgentId` data, recent ingestion
and HDFS block health; ready pods alone are insufficient.

## Chart 3.1.3 to 3.1.4

Pinpoint stays on 3.1.1; dependencies, schema definitions and persistence sizes
are unchanged. The new `collector.externalService` is disabled by default.
Existing `collector.service` behavior is preserved. New Services expose only
agent gRPC ports, without opening the internal Service's other receivers.

To adopt an existing external agent Service, retain its name, traffic policy,
Service ports and NodePorts. For example:

```yaml
collector:
  externalService:
    enabled: true
    name: pinpoint-collector-nodeport
    type: NodePort
    externalTrafficPolicy: Cluster
    nodePorts:
      grpcAgent: 30991
      grpcStat: 30992
      grpcSpan: 30993
```

Preserve any required Service annotations under `externalService.annotations`.
The Service's ports follow `collector.service.ports`. Compare the rendered
spec/selector to the existing Service before applying. Do not delete the old
Service or create a second Service requesting the same allocated NodePorts.
The example is not a portable reservation of those ports in every cluster.

For **Argo CD**, change the chart version, enable the external Service with the
existing name, and remove the duplicate raw Service manifest in the **same Git
change**, after the new chart is published. The resource stays under the same
Application and keeps its identity. Review the diff before sync; do not prune,
Force or Replace the Service as part of adoption.

For **Helm CLI**, a manually created Service must first have the ownership
metadata for the intended release: `app.kubernetes.io/managed-by: Helm` plus
`meta.helm.sh/release-name` and `meta.helm.sh/release-namespace`. Check that no
other release/controller owns it before changing these fields. Upgrade with
reviewed values; do not force-recreate it to bypass an ownership error.

Creating an external Service does not change NetworkPolicy or firewall rules.
With `externalTrafficPolicy: Local`, send traffic only to nodes with a ready
Collector endpoint. Validate agent ingestion via the actual proxy/LB after
adoption. SQL/Kafka/Pinot initialization hooks still follow their existing
install/upgrade/sync lifecycle; enabling this Service does not disable them.

## Chart 3.1.2 to 3.1.3

Application images remain 3.1.1. Back up MySQL and review the existing values
before upgrading. Bundled MySQL's post-upgrade hook adds the missing service,
feature-flag and metric-definition tables, validates required columns and
preserves existing rows/batch sequences. No destructive SQL reset is used.
External MySQL schemas remain database-owner managed; apply the versioned
SQL listed in [SCHEMA-COMPATIBILITY.md](SCHEMA-COMPATIBILITY.md).

Kafka and Pinot hooks add only missing OTLP topics/tables and exception trace
REALTIME. Existing retention and topic settings remain unchanged. External
backends require their existing explicit management opt-ins. Verify Inspector,
trace queries and custom metric save/read after the hooks succeed.

Pinot Controller and Server roll when probes are enabled. Single-replica Pinot
can have a brief interruption while those pods recover. Retain explicit probe
customizations, or deliberately set `pinot.server.probes.*Enabled` and
`pinot.controller.probes.*Enabled` to true if an older all-values file disabled
them. Startup allows about 30 minutes of recovery; tune it to measured load.

**Keep the currently deployed persistence.size in upgrade values.** The new
20Gi Server default applies to fresh claims. StatefulSet claim templates are
immutable and changing this value does not resize existing PVCs; a blind
`--reset-values` can fail the upgrade. For CSI expansion, use a separately
reviewed storage procedure. For NFS subdirectory provisioning, expansion is
unsupported even with allowVolumeExpansion=true; monitor actual filesystem space.

Use `helm upgrade pinpoint <reviewed-3.1.3-package> --namespace pinpoint -f
<existing-values.yaml> --wait --timeout 20m`, with the explicitly selected
cluster/context. Avoid printing rendered Secrets. Validate the package in
staging first; [RELEASE-3.1.3.md](RELEASE-3.1.3.md) lists the changes.

## Chart 3.1.1 to 3.1.2

Pinpoint application images stay at 3.1.1. The bundled Pinot Server now requests
4 GiB and limits memory at 6 GiB (previously 2 GiB request / 4 GiB limit). Plan the
additional capacity and a Server rollout when these defaults take effect;
existing explicit values remain authoritative. The JVM heap and CPU are unchanged.

The Pinot init hook creates missing `inspectorStatAgent00_OFFLINE`,
`uriStat_OFFLINE` and `systemMetricDouble_OFFLINE` tables with configured
replication. Upstream retention is 14 days for agent Inspector and 56 days for
URI/system offline measurements; budget disk space for the additional history.
It preserves existing realtime tables and other table configs/data. Check that the Minion's
`RealtimeToOfflineSegmentsTask` stops reporting a missing table and successfully
produces offline segments; table existence alone does not establish history.
If `global.pinot.createTables=false`, ask the backend owner to create these tables
from the bundled definition with the deployment's replication settings.

Use chart version `3.1.2` with your reviewed values file. Chart 3.1.1 packages
are not overwritten. Detailed traces still follow HBase TTL; adding an offline
metric table does not extend trace retention.

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
upgrade: chart 3.1.1 defaults reserve about 20.6 GiB RAM and 7.75 CPU, plus surge/init/system
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
