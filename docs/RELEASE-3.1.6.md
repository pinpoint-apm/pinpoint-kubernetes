# Chart 3.1.6

Pinpoint remains on 3.1.1. The companion storage chart is 0.1.4; dependency
versions are unchanged.

`global.retention` configures history in days for bundled/Stackable HBase and
Pinot. It is disabled by default. New history tables use the configured window;
existing tables change only with `applyToExisting=true`. Metadata and agent
liveness retain their existing settings. See [configuration](CONFIGURATION.md#history-retention)
and [upgrade notes](UPGRADING.md).

Validation covers Helm lint/render/package checks, schema coverage, initialization
regressions, policy validation, metadata preservation and idempotent updates.
DEV tests used isolated chart-rendered initialization Jobs against an existing
Stackable HBase/Pinot installation: 14 HBase history tables and 15 Pinot typed
history tables were verified at seven days. This is not a full production or
Argo CD upgrade qualification; bundled HBase runtime migration is not covered
by that DEV test.
