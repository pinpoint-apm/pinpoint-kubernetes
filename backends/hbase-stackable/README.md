# Pinpoint HBase/HDFS storage chart

Companion chart **0.1.4** runs independently of the Pinpoint application chart.
It uses Stackable **26.7.0** with HBase **2.6.6**, HDFS **3.4.3** and ZooKeeper **3.9.5**.

| Service | Default topology |
| --- | --- |
| ZooKeeper | 3 members; TLS for quorum traffic, plaintext client connections |
| HDFS | 2 NameNodes, 3 JournalNodes, 3 DataNodes; replication 3 |
| HBase | 2 Masters, 3 RegionServers; WALs and tables on HDFS |

## Requirements

- Kubernetes 1.31–1.36 and at least three schedulable workers.
- An explicit StorageClass with tested durability, capacity and latency.
  PVCs on one NFS server share a failure domain.
- Stackable operators 26.7.0 installed once per cluster; their CSI integrations
  are separate from the data-volume provisioner.
- About **44 GiB** of main-container memory, plus operators, CSI, initialization
  and the Pinpoint application. Size storage for workload and retention.

This is an HA qualification candidate; validate ingestion, failover and restore
on your infrastructure before production. See [backend operations](../../docs/PRODUCTION.md#stackable-backend-operations).

## Install

Install compatible operators first:

```bash
for operator in commons secret listener zookeeper hdfs hbase; do
  helm upgrade --install "$operator-operator" \
    "oci://oci.stackable.tech/sdp-charts/$operator-operator" \
    --version 26.7.0 --namespace pinpoint --create-namespace \
    --wait --timeout 10m
done
```

Review [values.yaml](values.yaml), select storage and install from the checkout:

```bash
helm upgrade --install pinpoint-storage backends/hbase-stackable \
  --namespace pinpoint --create-namespace \
  -f my-storage-values.yaml --wait --wait-for-jobs --timeout 30m
```

Published packages use `pinpoint/pinpoint-hbase-stackable --version 0.1.4`.
The application chart does not install these operators or this storage release.

## Connect Pinpoint

Use the application's production profile in the same namespace:

```yaml
global:
  hbase:
    zookeeperQuorum: ""
    discoveryConfigMap:
      name: pinpoint-storage-hbase-znode
      znodeSuffix: /hbase
  zookeeper:
    address: pinpoint-storage-zk-server.pinpoint.svc.cluster.local:2181
hbase:
  enabled: false
zookeeper:
  enabled: false
```

The names above assume storage release `pinpoint-storage` in namespace `pinpoint`.
MySQL, Redis, Kafka and Pinot need their own installations and connection settings.

## Configuration and upgrades

The schema Job verifies all 22 bundled Pinpoint 3.1.1 tables and preserves
existing TTLs/splits by default. `bootstrap.revision` reruns verification;
`bootstrap.preSplit=false` is available for small test installations.

Set `global.retention: {enabled: true, days: 7, applyToExisting: true}` to
reconcile existing history TTLs. Metadata and liveness tables are excluded.
Use the same block on the application release for Pinot retention. Reducing
days can expire older data; changing the policy creates a fresh schema Job.

WAL recovery defaults to bounded writers, two writer threads and one splitter
per RegionServer. Customize HBase properties through
`hbase.masters.configOverrides` or `hbase.regionServers.configOverrides`.
HDFS uses logical storage type `Disk`, including on physical SSDs.

Backend CRs request Argo CD server-side apply to preserve explicit null TLS
settings. Existing installations may need one sync when adopting it. Review
discovery ConfigMaps and restart affected roles when connection settings change.
CRs are retained on Helm uninstall by default; backup and restore remain separate.
See [upgrade notes](../../docs/UPGRADING.md) and [GitOps examples](../../examples/gitops/README.md).
