# Kubernetes HBase/HDFS backend

This companion chart provisions Stackable-managed ZooKeeper, HDFS and HBase
in the **same Kubernetes cluster** as Pinpoint, under a separate Helm release.
It is an HA qualification candidate, not a claim that every storage platform
or Pinpoint workload is production-qualified. The root chart still defaults
to the smaller evaluation stack.

| Service | Default topology |
| --- | --- |
| ZooKeeper | 3 members, TLS for quorum traffic |
| HDFS | 2 NameNodes with automatic failover, 3 JournalNodes, 3 DataNodes, replication 3 |
| HBase | 2 Masters, 3 RegionServers; WALs and tables on HDFS |

Each role has required hostname anti-affinity and a one-pod disruption budget.
RegionServers move regions before graceful shutdown. Backend CRs are retained
when this Helm release is uninstalled by default. Manual CR/PVC deletion still
requires backup and recovery planning. Replication and HA do not replace backups.

## Components and pod count

| Component | Role |
| --- | --- |
| HBase Master / RegionServer | Masters coordinate region assignment and failover; RegionServers serve table data and write WALs to HDFS. |
| HDFS NameNode / JournalNode / DataNode | NameNodes maintain filesystem metadata, JournalNodes replicate the HA edit log, and DataNodes store replicated data blocks. |
| ZooKeeper | Coordinates leader election and failover. |
| HBase / HDFS / ZooKeeper operators | Reconcile backend CRs into configuration, Services and workloads. |
| Commons operator | Manages shared Stackable infrastructure resources used by the product operators. |
| Secret operator and CSI | Provision and mount pod-specific certificates/credentials used by the backend. |
| Listener operator and CSI | Create listener Services and mount their connection details into backend pods. |

The default backend has **16 data-service pods**. Installing its six operators
adds five controller pods, a Listener CSI provisioner/controller and two CSI DaemonSets
(Secret and Listener), each with one pod per eligible worker. With seven eligible
workers this is **20 infrastructure pods**, shared by Stackable-managed clusters.
Pinpoint Web/Collector, MySQL and Pinot add their own pods independently.

These CSI drivers are Stackable integrations for credentials and endpoints;
they do not replace the volume provisioner for HDFS PVCs. Operators and CSI
drivers are installed separately, once per cluster, and can be placed in a
platform namespace. Using already managed backends avoids installing this stack.
References: [Secret operator](https://docs.stackable.tech/home/26.7/secret-operator/)
and [Listener operator](https://docs.stackable.tech/home/26.7/listener-operator/).

## Prerequisites

- At least three schedulable storage workers; independently backed SSD disks
  through an explicit StorageClass. Prefer `WaitForFirstConsumer` binding and
  `Retain` reclamation. Three PVCs on one NFS server share a failure domain.
- Default main-container memory reservations total roughly **44 GiB**, plus
  bootstrap, operators, CSI services and the Pinpoint application/other backends.
  These are capacity starting points; load-test and size for retention.
- Stackable operators **26.7.0**, Kubernetes 1.31–1.36. They install cluster-wide
  CRDs/RBAC and CSI drivers. Secret CSI runs privileged on nodes; review the
  official operator deployment policies with the cluster owner.
- Private networking with an enforcing CNI. Stock Pinpoint ZooKeeper clients
  in this integration use plaintext; quorum traffic stays TLS protected.
  This profile does not configure HBase Kerberos or authenticated Pinpoint clients.

Versions are HBase 2.6.6, HDFS 3.4.3 and ZooKeeper 3.9.5, with matching
Stackable 26.7.0 images. Treat the operator and product image versions as an
explicit upgrade unit. Do not change a product version merely because the
Helm manifest renders; qualify the new combination.
Each product accepts `customImage` for a compatible Stackable image mirrored
to your registry or pinned by digest. `hbase.customImage` also supplies the
schema Job image. Configure `imagePullSecrets` for that registry; the named
Secrets must already exist in the backend namespace. The operators themselves
have a separate platform installation and image lifecycle.
HDFS volumes use logical type `Disk`, including on physical SSD storage.
Changing all volumes to logical `Ssd` without changing HDFS storage policies
prevents the default `HOT` policy from allocating blocks.

## Install

Use the intended kubeconfig explicitly. Operators are platform infrastructure
and installed once; do not add them as dependencies of each Pinpoint release.

```bash
export KUBECONFIG=/path/to/intended-kubeconfig
for operator in commons secret listener zookeeper hdfs hbase; do
  helm upgrade --install "$operator-operator" \
    "oci://oci.stackable.tech/sdp-charts/$operator-operator" \
    --version 26.7.0 --namespace pinpoint --create-namespace \
    --wait --timeout 10m
done

helm upgrade --install pinpoint-storage backends/hbase-stackable \
  --namespace pinpoint --create-namespace \
  --set storageClass=validated-ssd \
  --wait --wait-for-jobs --timeout 30m
```

Use a reviewed values file for node selectors, resources and disk capacities.
The release workflow publishes this chart separately as
`pinpoint/pinpoint-hbase-stackable`, version `0.1.1`. Until it is published, use
the checkout path in the command above. Installing the root chart does not
implicitly install these operators or this storage release.
Operator pods can share the `pinpoint` namespace with the application and
storage while retaining independent releases. Their CRDs/RBAC/CSI integration
still includes cluster-scoped resources; placing pods here does not restrict
their watch scope or permissions. Set `networkPolicy.operatorNamespace` if
operators live elsewhere (empty defaults to the storage release's namespace). All clients
in the backend namespace can connect; permit cross-namespace application clients
with `networkPolicy.clientNamespaces`. HDFS is kept private to the backend
namespace. `cluster-internal` listeners require no external LoadBalancer.

The normal schema Job waits for operator discovery and verifies all 22 bundled
Pinpoint 3.1.1 tables individually. Existing tables and TTL/split settings are
preserved. It creates missing tables and fails for disabled tables. Set
`bootstrap.readyTimeoutSeconds` to bound the in-pod wait for transient Master
startup errors (default 900 seconds); authentication/schema errors still fail.
Change `bootstrap.revision` to explicitly rerun verification after a restore/upgrade.
`bootstrap.preSplit=false` reduces table counts to one initial region each for
local tests; production defaults preserve the upstream presplits. Both the
table count and region count need consideration when sizing RegionServer heaps.
Use the discovery ConfigMap names reported by the installed release. Very long
release names are shortened with a hash to keep operator-generated Service
names within Kubernetes limits.

## Connect the application

Use `values-production.yaml` for the root chart and override its HBase section:

```yaml
global:
  hbase:
    zookeeperQuorum: ""
    discoveryConfigMap:
      name: pinpoint-storage-hbase-znode
      znodeSuffix: /hbase
hbase:
  enabled: false
```

The ConfigMap name above corresponds to backend release `pinpoint-storage`.
Keep application and storage releases in the same namespace: Kubernetes
`configMapKeyRef` cannot reference another namespace. They remain separate
releases with independent upgrade lifecycles. For different namespaces,
explicitly synchronize operator discovery through your configuration manager
or provide fixed quorum/port/znode settings after reading discovery.

HBase discovery and Pinpoint coordination are separate settings. Choose a
private coordination ensemble through `global.zookeeper.address`; this backend's
ZooKeeper client Service is `pinpoint-storage-zk-server.pinpoint.svc.cluster.local:2181`.
Do not use the HBase claim chroot for Pinpoint coordination. MySQL, Redis,
Kafka and Pinot still need their own managed installations/connection settings.

## Qualify before production

Run actual Pinpoint agent ingestion and query trace/Inspector data. Verify
active NameNode failover, JournalNode loss, DataNode loss, Master failover and
RegionServer WAL replay independently, while checking marker data retention.
Check voluntary worker maintenance, disk loss, quorum loss behavior, storage
capacity/latency alerts, and off-cluster snapshot export plus restore. Record
RTO/RPO and image digests. A three-node local k3s cluster shares one physical
host and cannot prove independent hardware/storage failure resilience.

Reference: [Stackable HBase](https://docs.stackable.tech/home/26.7/hbase/),
[HDFS resources](https://docs.stackable.tech/home/26.7/hdfs/usage-guide/resources/),
[26.7 release](https://hub.stackable.tech/releases/26.7).

The operator currently generates `shell(/bin/true)` as the NameNode fencing
method. Quorum Journal Manager protects the shared edit-log writer; that fencing
command does not terminate an isolated former active process. Qualify network
partitions and your platform's fencing requirements separately from pod/JVM
restart tests. Do not interpret a successful process failover as proof of
network-partition safety.

Operator-generated ConfigMap changes may require an explicit rolling restart
of the affected StatefulSet. Review generated configuration and plan one role
at a time; a Helm upgrade returning successfully is not configuration reload
evidence. Keep the companion chart, CRs, operator releases and storage backups
under your deployment lifecycle.
