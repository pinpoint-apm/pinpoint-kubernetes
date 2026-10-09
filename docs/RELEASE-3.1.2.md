# Pinpoint chart 3.1.2 release notes

This chart patch continues to use Pinpoint **3.1.1** application images and
the same locked backend dependencies. Chart 3.1.1 remains an immutable release.

## Changes

- Bundle the upstream offline definitions for agent Inspector, URI statistics
  and system measurements. Their realtime-to-offline Minion tasks previously
  lacked destination tables. Retention is 14 days for agent Inspector and
  56 days for URI/system offline measurements, with configured replication.
  Plan disk capacity for this history; HBase trace retention is unchanged.
- Initialization still preserves existing schemas, table configs and data.
  A regression check covers repairing an otherwise complete installation and
  ensures each realtime-to-offline task has its offline destination.
- Increase bundled Pinot Server memory to **4 GiB request / 6 GiB limit**,
  leaving room for memory-mapped segments and native memory. CPU and JVM heap
  defaults are unchanged. The default evaluation stack reserves approximately
  **22.6 GiB RAM and 7.75 CPU cores**.
- Explain application services, the optional HBase/HDFS HA backend and the
  Stackable operator/CSI pod count in the README and companion guide. Companion
  chart 0.1.1 contains documentation changes only; backend versions/topology stay
  the same.

## Upgrade

See [UPGRADING.md](UPGRADING.md#chart-311-to-312). Review scheduling capacity,
back up persistent data, and verify Inspector ingestion and Minion tasks after
the upgrade. With `global.pinot.createTables=false`, the backend owner must
create the missing offline tables separately. Existing resource overrides are
not replaced automatically by changed defaults.

The production application profile continues to use independently managed
backends. Deployment storage, load, backup/restore and backend failover still
require environment-specific qualification; see [PRODUCTION.md](PRODUCTION.md).
