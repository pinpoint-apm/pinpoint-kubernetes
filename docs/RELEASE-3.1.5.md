# Pinpoint chart 3.1.5 release notes

Chart **3.1.5** keeps Pinpoint application **3.1.1** and all locked dependency
charts. It fixes insecure defaults, removes a broken component and aligns
several settings with what the stock 3.1.1 images actually read. Storage chart
**0.1.3** is released alongside it. Read the
[upgrade notes](UPGRADING.md#chart-314-to-315) before upgrading.

## Security

- Pinpoint Web's `/api/admin/**` endpoints used the fixed password `admin`.
  The chart now generates and keeps a random password Secret, or references
  `web.adminApi.passwordSecret`.
- Bundled MySQL no longer ships the `pinpoint`/`mysql` passwords; the MySQL
  chart generates them and existing releases keep theirs.
- UI usage reporting to Google Analytics (`config.sendUsage`) is off by default.
- Web no longer receives the MySQL root password for its startup wait.
- Dependency checks and bootstrap Jobs meet Pod Security `restricted`; HBase
  and the demo drop capabilities and disable privilege escalation.
- NetworkPolicies no longer allow Internet egress for initialization by default.
- `values.schema.json` rejects unknown top-level keys.

## Pinpoint 3.1.1 compatibility

- HBase TTL keys now cover the tables 3.1.1 writes: `TRACEINDEX_TTL`,
  `APPLICATION_TTL`, `AGENTID_TTL` and the v3 `MAP*_TTL` keys of the stock image.
  New `TraceIndex` tables follow `TraceV2`'s 7-day retention instead of 60 days.
- Batch alarm mail sets the Spring Mail properties Batch 3.1.1 reads (SMTP
  auth, STARTTLS, sender). The ignored `ALARM_MAIL_*` and `ADMIN_PASSWORD`
  variables are gone.
- Classic Flink uses 3.0.5, the newest published Flink image.
- Kafka topics are configurable in `global.kafka.topics` and match the eleven
  topics of the default 3.1.1 Collector modules. Topics auto-created with fewer
  partitions are raised to the configured count.

## Removed and changed

- The standalone `agent` Deployment is removed; it could not instrument other
  pods and used wrong stat/span ports. See [AGENTS.md](AGENTS.md).
- Telegraf is opt-in and runs as a DaemonSet reporting node names, without the
  `/etc` host mount.

## Added

- `values-minimal.yaml` runs the evaluation stack on one small node.
- `web.httpRoute` for the Gateway API.
- `global.imageRegistry` fallback, `global.waitImage`, pull secrets for every
  chart-owned pod, and Web/Collector `serviceAccountName`, `priorityClassName`,
  `podLabels` and `lifecycle`.
- A simpler Helm repository landing page.

## Storage chart 0.1.3

The schema Job name includes a hash of its inputs, so image or setting changes
no longer fail on Kubernetes' immutable Job template.

## Validation scope

Local validation used Helm 3.21.2 and a single-node kind cluster (Kubernetes
1.34, 4 CPU, 12 GiB) with `values-minimal.yaml`:

- `bash scripts/helm-validate.sh` passed, including the new
  `scripts/test-chart-hardening.rb`, the Kafka partition-repair tests and the
  storage Job-name checks.
- **Upgrade from the published chart 3.1.4**: `otlp-metric-metadata` was first
  recreated with the broker's auto-create defaults (one partition). The upgrade
  deployed without pod restarts; the initializer logged
  `Raising otlp-metric-metadata partitions from 1 to 3`. The MySQL Secret kept
  its existing passwords. `password=admin` was rejected by `/api/admin` and the
  generated password accepted. Existing HBase TTLs were unchanged.
  `scripts/local-smoke.py` passed (Web, demo traffic, Pinot ingestion,
  Inspector chart, HBase trace rows).
- **Fresh install with Telegraf**: random MySQL passwords, new `TraceIndex`
  TTL of 7 days, system metrics in Pinot under the node name, and
  `local-smoke.py` including the system metric tables passed. With
  `pod-security.kubernetes.io/warn=baseline`, only Telegraf's hostPath volumes
  were reported.
- On 3.1.4 the same cluster accepted `password=admin` on `/api/admin`, used the
  well-known MySQL passwords and created `TraceIndex` with a 60-day TTL.

Not covered: the production profile against external backends, classic
Batch/Flink runtime, Gateway API routing, arm64, and multi-node failure tests.
