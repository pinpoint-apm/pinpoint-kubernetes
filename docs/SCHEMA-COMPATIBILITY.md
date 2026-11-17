# Schema compatibility

Chart 4.0.1 targets Pinpoint 4.0.1. Versioned assets are pinned to
[`v4.0.1`](https://github.com/pinpoint-apm/pinpoint/tree/v4.0.1), with source paths
and checksums in `files/schema-manifest-4.0.1.json`. Pinpoint 3.1.1 assets remain
available for explicit compatibility installs and upgrade tests.

| Store | 4.0.1 coverage | Initialization |
| --- | --- | --- |
| MySQL | 29 tables: 20 existing Web/Batch/service/metric tables and 9 Service Alarm tables | Bundled MySQL or explicit external schema opt-in |
| HBase | 22 upstream tables; unused legacy tables are retained | Bundled supervisor or independent Stackable schema Job |
| Pinot | 11 schemas and 18 REALTIME/OFFLINE tables from 29 JSON assets | Metric mode and `global.pinot.createTables` |
| Kafka | 11 configured topics covering the selected metric/trace modules | Bundled Kafka or explicit external topic opt-in |
| Redis/ZooKeeper | No relational schema | Dependency chart or externally managed service |

MySQL requires 8.4+ for 4.0.1. Initialization preserves existing records and
Spring Batch sequences, creates missing tables/indexes and verifies required
columns. Existing incompatible types, keys and grants need a reviewed migration.
Generated invisible primary keys are enabled for newly created 4.0.1 tables so
Spring Batch sequence tables can be created on MySQL Group Replication.

Pinot adds `exceptionTrace.serviceName` with the upstream `DEFAULT` fallback.
Existing schemas change only with `global.pinot.migrateExistingSchemas=true`.
Preflight rejects conflicting types/cardinality and additions without explicit
defaults; custom fields are preserved. Controller-normalized attributes are
accepted during readback verification. Existing segments are not rewritten or
reloaded. Table settings change only through explicitly enabled retention.

HBase definitions retain upstream column families/splits. Initializers create
missing tables and preserve existing settings unless retention updates were
explicitly requested. Both application and storage releases select their schema
with `global.pinpointVersion`; configure them consistently.

Kafka endpoints, Pinot replication and the Kafka 3 consumer plugin are adapted
to the deployment. Heatmap uses `heatmap-stat-app-00`, matching the Collector.
More shards or optional modules require corresponding schemas/topics; arbitrary
environment overrides do not generate these automatically.

The qualified 4.x profile uses BASIC, METRIC and OTLPTRACE Collector modules.
The separate legacy LOG process is not configured. Service Alarm schema and
an opt-in workload are provided; its custom image and notification paths need
separate runtime qualification. Creation of schema assets does not establish
end-to-end compatibility of every optional upstream feature.

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
