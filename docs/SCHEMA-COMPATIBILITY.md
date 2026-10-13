# Pinpoint 3.1.1 schema compatibility

Chart 3.1.3 targets the stock Pinpoint 3.1.1 images. Definitions are pinned to
[`v3.1.1`](https://github.com/pinpoint-apm/pinpoint/tree/v3.1.1), with source paths
and bundled checksums in `files/schema-manifest-3.1.1.json`. The archive includes
all schema assets and their attribution in `files/NOTICE`.

| Store/module | Chart-managed initialization | Coverage |
| --- | --- | --- |
| MySQL Web, alarms, users | `mysql.enabled=true` | 8 core tables and their named indexes |
| MySQL Spring Batch | `mysql.enabled=true` | 9 batch tables; existing sequence values preserved |
| MySQL service registry / feature flags | `mysql.enabled=true` | `service`, `feature_flag` |
| MySQL custom metrics / OTLP | MySQL + metric profile enabled | `application_metric_definition` |
| HBase traces, metadata, maps and application/agent identity | Bundled HBase supervisor | 22 versioned tables, missing tables only; existing TTLs preserved |
| Distributed HBase | Independent `pinpoint-hbase-stackable` chart | Same 22 table names/column families; separate install and ownership |
| Pinot Inspector, URI, system metrics, Heatmap, exception trace and OTLP metrics | Metric profile + `global.pinot.createTables` | 11 schemas, 18 typed tables; all supplied REALTIME/OFFLINE definitions |
| Kafka metric ingestion | Metric profile + `global.kafka.createTopics` | 11 topics, including all Pinot realtime sources |
| Redis and ZooKeeper | Dependency charts or external services | No SQL/table initialization |

For external MySQL, initialize the bundled SQL through the database owner;
`mysql.enabled=false` does not run a database-admin hook. External Kafka and
Pinot require explicit `manageExternalTopics` / `manageExternalTables` opt-in
for chart-managed initialization. Custom partitioned deployments with more
than the upstream default `00` shard must create matching tables/topics;
this chart does not infer shards from arbitrary application environment overrides.

SQL source adaptations are limited to idempotent batch sequence inserts and
the already-required webhook 127-character columns. The migration transforms
CREATE statements to IF NOT EXISTS and repairs missing named indexes. It checks
required tables/columns but does not reconcile arbitrary column-type, primary-key
or permission differences; these need a reviewed database migration.

Pinot init selects the configured Kafka endpoint and replication. It uses the
Kafka 3 consumer plugin for Pinot 1.3 and corrects the upstream Heatmap topic
name to `heatmap-stat-app-00`. Existing schemas/configs are preserved. Successful
resource creation is followed by existence verification; ingestion and queries
are checked separately. A schema manifest is not a data migration or backup.

HBase schema definitions retain the existing image/companion TTL defaults.
The main chart applies `hbase.config.ttl` overrides to newly created tables.
Changing values does not rewrite existing TTLs or move data between backends.

This coverage is for the stock classic/metric deployment and versioned store
assets. Optional Flink processing, custom authentication/JDBC implementations,
custom shard counts and log/OTLP exporters still need their module-specific
configuration and integration tests. Do not equate creation of a table with
end-to-end qualification of every optional upstream feature.

## Retention and NFS capacity

Most realtime metric tables retain 7 days. Upstream metadata retains 70 days;
exception trace realtime/offline retains 28/112 days. Offline Inspector/Heatmap
retains 14 days and URI/system/OTLP numeric metrics retain 56 days. Existing
values/configs are never shortened by this patch. Budget for all enabled
histories, segment conversion and replication, not only the 7-day window.

The default 20Gi claim is an evaluation starting point. Production needs
measured ingestion growth and adequate headroom on the underlying filesystem.
With `nfs-subdir-external-provisioner`, PVC size is not an enforced quota and
PVC expansion is unsupported, even if StorageClass.allowVolumeExpansion is true.
Monitor actual NFS free space and Pinot data growth; changing a requested size
neither creates free space nor guarantees a number of retained days.

Source: [NFS provisioner limitations](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner#nfs-provisioner-limitationspitfalls).

## Collector entrypoints

Metric mode exposes OTLP metrics via HTTP/protobuf at Collector Service
`15200/opentelemetry` (container 9995), and OTLP trace gRPC at Service
`collector.service.ports.otlpTrace` (default 9998, container 9998). These are
Pinpoint-specific defaults, not standard OTLP ports 4317/4318. Internal Spring
management ports are not exported as ingestion Services. Explicit agent ingress
NetworkPolicy rules include the trace receiver when metric mode is enabled.

## Known Pinpoint 3.1.1 application limitation

A gauge point whose `startTimeUnixNano` is absent/zero can produce HTTP 500
in the stock Collector: `PinotOtlpMetricCollectorService.save` unboxes a null
start time. This was reproduced during the dev ingestion check. Supplying a
nonzero start time allowed both long and double points to reach Pinot. This is
an application defect, not a missing table; chart schema initialization cannot
fix it. Qualify the actual exporter payloads before relying on OTLP metrics.
See the [3.1.1 Collector implementation](https://github.com/pinpoint-apm/pinpoint/blob/v3.1.1/otlpmetric/otlpmetric-collector/src/main/java/com/navercorp/pinpoint/otlp/collector/service/PinotOtlpMetricCollectorService.java).
