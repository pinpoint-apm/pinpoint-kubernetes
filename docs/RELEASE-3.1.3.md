# Pinpoint chart 3.1.3 release notes

Chart **3.1.3** keeps Pinpoint application **3.1.1**, Pinot 1.3.0 and the locked
backend dependencies. It fills gaps in initialization for the shipped modules.

- Bundle the service registry, feature flag and OTLP custom metric MySQL schemas.
  The install/upgrade hook repairs missing tables without replacing existing
  rows or resetting batch sequences. Metric mode additionally requires
  `application_metric_definition`; classic mode does not initialize that table.
  Verification checks exact table and column names and fails on missing columns
  in an existing table rather than silently reporting success.
- Bundle all versioned Pinot definitions: 11 schemas and 18 typed tables,
  including exception trace REALTIME and OTLP metadata/long/double tables and
  their offline destinations. Initialize the matching three OTLP Kafka topics.
  Existing table configs, retention and topic settings remain intact.
- Expose the stock metric image’s OTLP trace gRPC receiver on Service port
  9998, with matching NetworkPolicy. OTLP metric HTTP already uses the
  existing 15200 -> 9995 mapping.
- Ship the 22 HBase table definitions in the main chart instead of relying on
  the image's schema file. Apply the existing TTL values only when creating
  missing tables. The independent HBase backend chart is unchanged.
- Enable configurable startup/readiness/liveness probes for Pinot Server and
  Controller through the existing dependency's `*.probes` values. Startup
  allows approximately 30 minutes for recovery before restarting a container.
- Increase the **new-install** Pinot Server claim default from **10Gi to 20Gi**.
  This is a starting budget, not a guaranteed retention capacity. No table
  retention changes or automatic existing-PVC expansion are included.
- Add schema provenance/checksums, coverage regression checks, and disposable
  MySQL database tests for profile gating, schema repair, missing-column failure,
  idempotency and preservation of existing rows/sequences.

See [schema compatibility](SCHEMA-COMPATIBILITY.md) for module coverage and
[upgrade instructions](UPGRADING.md#chart-312-to-313) before deploying.

## Validation and remaining application limits

See [staging validation](VALIDATION-3.1.3.md) for the install/upgrade, schema repair,
PVC/config preservation and runtime checks. The stock 3.1.1 Collector still
fails some gauge exports with absent/zero start time; this requires an
application fix or exporter compatibility work, not a Helm schema change.
This release does not claim to fix every upstream application defect.
