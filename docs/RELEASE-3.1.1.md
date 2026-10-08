# Pinpoint chart 3.1.1 release notes

This release targets the official Pinpoint **3.1.1** application images. It is
a release with a tested production application profile and an optional
operator-managed HBase/HDFS backend. Deployment-specific qualification remains
the responsibility of the platform owner.

## Changes

- Default application images and versioned assets target 3.1.1. Pinot defaults
  to the compatible 1.3.0 release; classic Flink remains at 3.0.3.
- Explicit Web/Collector image tags are honored verbatim. Custom release names
  resolve the shared ZooKeeper, HBase, Flink and Web services correctly.
- Stock HBase, Agent/Quickstart and classic Flink pods select Linux amd64 nodes.
  Those stock images cannot be used on an arm64-only cluster. Web/Collector,
  Batch, Pinot and the Python initializer have arm64 manifests.
- Web basic login can read credentials and the required JWT key from an
  existing Secret. Cookie defaults require HTTPS.
- Web/Collector/Batch primary and metadata Hikari datasource settings honor custom JDBC
  drivers. Bundled MySQL consumers honor `mysql.auth.existingSecret`; external
  MySQL, Redis and plaintext Kafka configuration paths are validated.
- PostgreSQL is not supported by stock Pinpoint images. Setting a JDBC URL or
  driver does not port the application's MySQL SQL/mappers.
- Kafka initialization creates every required topic idempotently and stops on
  failure. New topic replication is configurable.
- Pinot initialization uses bundled upstream JSON and the controller REST API,
  checks exact schema/table names, creates missing resources and preserves
  existing configs. New table replication is configurable; initialization
  can be disabled for operator-managed resources.
- Unsupported Kafka client SASL/TLS and ZooKeeper authentication combinations
  fail Helm validation. Misleading production comments were removed.
- Failed init hooks are retained for diagnosis until the next hook run or
  operator cleanup; successful hooks are removed by Helm. Hook deadlines and
  the Helm command's overall wait timeout are documented separately.
- Bundled HBase now supervises both daemons, bounds their heaps, repairs missing
  schema tables, exposes startup/readiness/liveness probes and flushes on shutdown.
- Kafka heap and pod limits are aligned; Pinot uses the dependency's actual
  `replicaCount` keys and does not request external LoadBalancers by default.
- Metric is the sole default; Classic is an optional legacy profile. All
  workloads have explicit requests/limits, with bounded application JVM heaps
  and room for native memory. Defaults reserve about 20.6 GiB and 7.75 CPU.
- Per-member ZooKeeper ClusterIP Services prevent the stock HBase client's
  cached pod addresses from breaking connectivity after ZooKeeper replacement.
- Collector primary/metadata MySQL settings and metric HTTP routing are fixed.
  Heatmap topic and both Pinot table types are initialized.
- MySQL SQL and Telegraf config are bundled to avoid runtime GitHub downloads.
- Packaging excludes local credential/agent directories and Python caches.
- External HBase, ZooKeeper and Pinot endpoints use the actual application
  properties; external bootstrap is skipped unless explicitly enabled.
- `values-production.yaml` provides two Web/Collector replicas, release-scoped
  hostname spreading, PDBs and rolling-update controls with external backends.
- Web/Collector run as the image's existing UID 1000 with a read-only root,
  dropped capabilities, seccomp, bounded temp/log volumes and no service-account
  token. Scheduling, truststore mounts and image pull Secrets are configurable.
- Primary and metadata MySQL pools have explicit tunable maximum/idle/timeout
  limits to avoid exhausting database connections when replicas scale.
- Bundled MySQL initialization repairs exact missing tables/indexes while
  preserving existing data and sequence rows; unrelated tables do not hide a
  partial installation.
- An independent `pinpoint-hbase-stackable` chart provisions HBase/HDFS HA
  under Stackable 26.7.0 operators, with explicit disk storage, role anti-affinity,
  disruption budgets and an idempotent 22-table bootstrap. Operators are
  installed separately; the root chart's evaluation default is unchanged.
- Operator ZooKeeper discovery ConfigMaps can supply quorum/port/chroot to all
  HBase application clients. Pinpoint coordination remains a separate setting.
- Chart-owned numeric settings are schema-validated; PDB zero/percentage
  budgets are supported. Dependency checks and initialization hooks have
  explicit resource limits, registry Secret support and bounded Kafka CLI heap.
- CI validates and packages both charts; the release workflow publishes both
  archives. Companion chart versions advance independently.

## Issue #41

[Issue #41](https://github.com/pinpoint-apm/pinpoint-kubernetes/issues/41) is
related to the chart. Its Inspector table error accompanies Kafka client
failures after enabling server security without matching client configuration.
The previous topic/table count checks also hid partial initialization.

This candidate fixes initialization and detects unsupported server-only auth
configurations. It does **not** add SASL/TLS support to Pinpoint's upstream
producer factory or supply ZooKeeper JAAS settings to every consumer. Keep the
issue open until the supported deployment is verified with actual Inspector
ingestion; environments requiring those security protocols need additional
client integration. Do not label the original secure configuration as fixed.

## Validation

Run `bash scripts/helm-validate.sh` from the repository root. It builds the
locked dependencies and validates metric/classic profiles, external services,
Secrets, login guards, image overrides, custom release names, replication,
unsupported authentication settings and the packaged chart. It also runs
`scripts/test-initialization.py`, covering partial installs, reruns, controller
permission/server errors, conflicts, JSON API requests/responses and failed
topic creation and Heatmap topic matching (13 regression tests).

Local checks cover a fresh default install/upgrade, actual trace and Metric
ingestion, two Web/Collector replicas, HTTPS/JWT, allowed/denied network access,
graceful worker drains, MySQL schema repair/restore and HBase process recovery.
The optional distributed backend also passed a fresh single-namespace install
and five individual JVM recovery cases. Exact scope and reproducible commands
are in [LOCAL-TESTING.md](LOCAL-TESTING.md).

These checks do not qualify production storage/load, prior-version data migration,
independent host/disk failure or network partitions. The staging checks below
still apply to the deployment configuration being published.

## Deployment acceptance and upgrade qualification

1. Install using a new namespace and production-equivalent storage/network
   configuration. Confirm all initialization hooks and application pods become
   healthy. Check all eight Kafka topics, eight Pinot schemas and nine typed tables.
2. Send traces and application statistics from a 3.1.1 agent. Verify Web traces,
   URI statistics and Inspector queries, especially `inspectorStatApp` and
   `systemMetricDataType`. Table existence alone does not prove ingestion.
3. Verify login/JWT, HTTPS cookies, configured alarms and external service
   credentials. Test the NetworkPolicy rules with the cluster's enforcing CNI.
4. Interrupt workloads and confirm recovery with retained volumes. Test an
   upgrade from the previous chart with backed-up persistent data. Handle the
   Pinot 1.0-to-1.3 migration and existing table configs explicitly.
5. Record the applicable results and limitations in the PR. Merging to
   `master` publishes the chart automatically. Existing-installation migration
   and production storage/load acceptance must be completed before deploying
   that configuration to production; they are not implied by fresh-install tests.

See [UPGRADING.md](UPGRADING.md) and [RELEASING.md](RELEASING.md) for procedures.
