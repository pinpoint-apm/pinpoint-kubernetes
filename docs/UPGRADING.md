# Upgrading the Pinpoint chart

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
