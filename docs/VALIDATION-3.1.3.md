# Chart 3.1.3 validation

Checked on 2026-10-13 against an existing staging Kubernetes deployment.
The target cluster and namespace were selected explicitly for every command.
Production deployments were not changed.

## Before deployment

- Branched from upstream chart 3.1.2; application remains 3.1.1.
- `bash scripts/helm-validate.sh`: passed both profiles, dependency rendering,
  schema coverage, initialization regression checks and packaged chart checks.
- HBase Ruby checks include partial table repair and TTL override preservation.
- Disposable MySQL database test in dev: classic-to-metric initialization,
  missing table/index repair, idempotency, row/sequence preservation,
  missing-column failure and dump/restore passed. Fixture databases and
  successful test Job/ConfigMap were removed.
- Captured existing values/workload/PVC state and a transactional MySQL backup
  locally with restricted file permissions. Credentials were not logged or
  committed. Server-side Helm dry-run passed.
- Manifest comparison confirmed no removed resources, credential resources or
  claim-template changes. Changed pod templates were Collector, Pinot Controller
  and Pinot Server only.

## Deployed package

The reviewed `pinpoint-3.1.3.tgz` upgraded the staging release from chart
3.1.2 to **chart 3.1.3**, appVersion **3.1.1**, using existing
values and `--atomic --wait --timeout 30m`. Helm reported `deployed`; all init
hooks succeeded. Controller/Server health endpoints and live probes passed
following segment recovery. Collector has two ready replicas.

All existing PVC UIDs, backing volumes and size requests were preserved;
the staging Pinot Server remains 10Gi. New default installations request 20Gi.
All pre-existing Pinot table configs were preserved. Live inventory now has
**20 SQL tables** and **11 Pinot schemas / 18 typed tables**.

## Runtime checks

- Authenticated discovery returned applications with recent agent activity.
- Server map for an existing application: three nodes returned through HBase.
- Custom metric definition save/read passed; its unique SQL fixture row was
  removed afterward.
- Two small, labeled synthetic OTLP gauge points, one double and one long,
  returned HTTP 200 and reached their corresponding Pinot tables through
  Collector -> external Kafka -> Pinot. These test points follow table retention.
- Existing Inspector ingestion remained current (latest event approximately
  four seconds old at the post-upgrade check).
- OTLP trace Service port 9998 accepted a TCP connection. This check verifies
  Service wiring, not complete OTLP trace export semantics.

One test also reproduced a **stock 3.1.1 application defect**: gauge data with
absent/zero `startTimeUnixNano` produces a null start-time exception and HTTP 500.
Nonzero start time succeeded. See [schema compatibility](SCHEMA-COMPATIBILITY.md).
The Helm release does not resolve that application code defect.

## Scope of the evidence

Runtime used the existing external HBase/HDFS, Kafka and Redis plus bundled
MySQL/Pinot on NFS. No new local Kubernetes cluster was created. Fresh SQL
initialization was tested in an isolated database, not with a second full staging
installation. Batch/Flink runtime, custom shards/exporters, sustained load,
retention over a full cycle, NFS outage recovery and all optional upstream
features are not qualified by this check. Existing HA backends were not upgraded
or subjected to failure injection. Publishing uses a feature-branch pull request and the repository release
workflow; these runtime checks do not replace pull-request CI.
