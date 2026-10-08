# Configuration reference

## Configuration

**Metric is the default:** Web/Collector use the `3.1.1-metric` images; Kafka,
Pinot and Telegraf are enabled; Batch and Flink are disabled. No profile flag
is needed for the installation in the README.

**Classic is optional**, for existing Batch/Flink users. It selects the classic
Web/Collector images and disables the default metric services. To select it:

```bash
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.1 \
  --namespace pinpoint \
  --create-namespace \
  --set global.metric.enabled=false \
  --wait \
  --timeout 20m
```

To use external Redis and Kafka, disable the bundled services and provide their
endpoints in a values file:

```yaml
global:
  redis:
    host: redis.example.internal
    port: 6379
    passwordSecret:
      name: pinpoint-redis
      key: password
  kafka:
    bootstrapServers: kafka-0.example.internal:9092,kafka-1.example.internal:9092

redis:
  enabled: false

kafka:
  enabled: false
```

External services do not block Pinpoint pod startup. Kafka topics are assumed
to be managed externally; set `global.kafka.manageExternalTopics=true` only if
this Helm release should create them.

### External service support

| Service | Chart support | Limits |
| --- | --- | --- |
| Redis | `redis.enabled=false` with `global.redis.*` | Host, port, ACL username and password/Secret; TLS and Sentinel are not exposed. This switches to external Redis, not a feature disable. |
| Kafka | `kafka.enabled=false` with `global.kafka.bootstrapServers` | Plaintext endpoints only: stock Pinpoint 3.1.1 producers do not bind SASL/TLS properties. External topics are operator-managed by default. |
| MySQL | `mysql.enabled=false` with `global.datasource.*` | External schema initialization and upgrades are operator-managed. Passwords can reference an existing Secret. |
| PostgreSQL | Custom JDBC configuration only | Stock Pinpoint 3.1.1 uses MySQL SQL and mappers. A PostgreSQL driver/JDBC URL alone is insufficient; custom application images, ported schemas and queries are required. |
| HBase | `hbase.enabled=false` + `global.hbase.*` | ZooKeeper quorum, client port, znode and namespace; tables/regions and backups are operator-managed. |
| ZooKeeper | `zookeeper.enabled=false` + `global.zookeeper.address` | Pinpoint coordination uses comma-separated host:port endpoints; it can be separate from HBase discovery. No client-authentication/TLS wiring. |
| Pinot | `pinot.enabled=false` + `global.pinot.jdbcUrl` | Tables/schemas are operator-managed unless `manageExternalTables=true` and `controllerUrl` are provided. No REST authentication wiring for the optional initializer. |

See [values-production.yaml](../values-production.yaml) and
[production deployment](PRODUCTION.md) for a complete external Metric profile.
HBase quorum entries are hostnames without ports; `global.hbase.clientPort`
supplies the port. `global.zookeeper.address` includes each endpoint's port.
Bundled HBase initializes only the `default` namespace; custom namespaces require
external HBase with an operator-provisioned schema.
External Pinot still needs its brokers reachable by the Web JDBC client, and
Kafka/HBase discovered broker/RegionServer addresses must be routable from pods.

For an external MySQL instance, initialize the database with the versioned
[Pinpoint SQL scripts](https://github.com/pinpoint-apm/pinpoint/tree/v3.1.1/web/src/main/resources/sql),
then configure:

```yaml
mysql:
  enabled: false
global:
  datasource:
    jdbcUrl: "jdbc:mysql://mysql.example.internal:3306/pinpoint?sslMode=VERIFY_IDENTITY"
    username: pinpoint
    passwordSecret:
      name: pinpoint-database
      key: password
```

The Secret must exist in the release namespace. Configure the application's
JVM truststore for the database certificate when using `VERIFY_IDENTITY`.
`global.datasource.enabled=false` only stops environment variable injection;
it does not disable Pinpoint's database-dependent features.

`global.datasource.pool` bounds both primary and metadata Hikari pools in Web,
Collector and optional Batch. Defaults are `maximumPoolSize: 10`,
`minimumIdle: 2`, `connectionTimeout: 5000` milliseconds **per pool**. Budget
two pools per application replica plus rollout surge, hooks and administrative
connections; raising replicas without a database connection budget can exhaust
MySQL even without user traffic.

For bundled MySQL, set `mysql.auth.existingSecret` to a Secret containing
`mysql-root-password`, `mysql-password` and `mysql-replication-password`, as
required by the dependency. Web, Collector, Batch and SQL init hooks reference that same
Secret. Replace the evaluation defaults (`pinpoint` / `mysql`) before production;
when reusing a database volume, the Secret must match its existing credentials.

### Basic login

Pinpoint 3.1.1 requires a JWT secret when basic login is enabled. Create a Secret
in the release namespace containing `jwt-secret` (a random string of at least
24 characters) and `admin` (comma-separated `username:password` pairs), then set:

```yaml
web:
  login:
    enabled: true
    existingSecret: pinpoint-login
    # Optional regular users can be stored under a separate Secret key.
    userKey: users
    cookie:
      secure: true
      sameSite: Lax
```

Omit `userKey` if the Secret contains only administrators. Credentials and JWT
keys are read from the Secret and never generated as defaults by the chart.
Use HTTPS ingress with `cookie.secure=true`; local HTTP testing requires
`cookie.secure=false`. Login stays disabled by default, so protect the UI before
exposing it outside a trusted network.

Web/Collector default to UID/GID 1000, dropped capabilities, RuntimeDefault
seccomp, a read-only root filesystem and no service-account token. Writable
`/tmp` and `/app/logs` use bounded emptyDir volumes. A custom UID must exist in
the image's `/etc/passwd`: Hadoop's login fails with an unknown numeric UID.
Use `extraEnv`, `extraVolumes` and `extraVolumeMounts` to mount custom truststores.
`global.imagePullSecrets` applies to Web/Collector; configure dependency image
pull secrets separately when mirroring backend images.

Web/Collector support `replicaCount`, `pdb`, `strategy`, `nodeSelector`,
`tolerations`, `affinity`, `podAnnotations` and `topologySpreadConstraints`.
PDBs require at least two replicas. Default spreading is soft for single-node
evaluation; the production example requires distinct hostname placement.

### Images and production deployments

An empty Web or Collector image tag selects `3.1.1-metric` in metric mode and
`3.1.1` in classic mode. Explicit `web.image.tag` and `collector.image.tag`
values are used verbatim, including any `-metric` suffix.
Pinot defaults to the compatible `1.3.0` image. Its init job uses an independently
pinned Python image (`global.pinot.initImage.*`) and the controller REST API.
Flink remains independently pinned to `3.0.3`.

HBase, the optional Agent/Quickstart pods and classic Flink default to
`nodeSelector: {kubernetes.io/os: linux, kubernetes.io/arch: amd64}` because their
stock images (including the Quickstart agent init image) are amd64-only.
This prevents `exec format error` when a mixed cluster schedules them on arm64.
An arm64-only cluster needs compatible custom images and matching component
`nodeSelector` overrides; a selector change alone cannot add image support.

Defaults are a starting point for evaluation, not a complete HA production
deployment. The bundled HBase uses one pod with local filesystem storage;
it is not an HDFS-backed distributed HBase cluster. Before production use,
review the supplied resource requests/limits, storage classes, retention, authentication,
backup/restore procedures and availability requirements. Default topic/table
replication is one; configure `global.kafka.topicReplicationFactor` and
`global.pinot.tableReplicas` with enough brokers/Pinot servers before creating
resources. These settings do not change replication of existing resources.
Dependency images use Bitnami's legacy repositories and need an explicit
security/update policy for long-term operation.

Validate production changes on a staging installation, including ingesting
agent traces, viewing Inspector data, alarm delivery, pod recovery and an
upgrade with persistent data. Helm lint/render checks do not establish runtime
compatibility or production availability.

### HBase startup and recovery

For operator-managed HBase, set `hbase.enabled=false` and either provide
`global.hbase.zookeeperQuorum`/`clientPort`/`znodeParent`, or use
`global.hbase.discoveryConfigMap.name` in the application namespace. Its default
keys are `ZOOKEEPER_HOSTS`, `ZOOKEEPER_CLIENT_PORT` and `ZOOKEEPER_CHROOT`.
With Stackable 26.7 set `znodeSuffix: /hbase`, since the HBase operator appends
that path to the claim chroot. Kubernetes expands the suffix after loading the
ConfigMap env; no application API permissions are needed. Changing discovery
requires rolling the applications because env values are read at pod creation.
Do not configure both explicit quorum and a discovery ConfigMap.


The chart supervises the bundled image's Master and RegionServer processes.
A failed daemon exits the container so Kubernetes can restart it; the image's
original `tail -f /dev/null` entrypoint is not used. Startup/readiness require
all 22 Pinpoint tables and listening RPC ports. Bootstrap repairs missing
tables after a partial install, while preserving existing tables and data.

`hbase.heapSize` defaults to 1024 MiB **per daemon**. The shared pod requests
2 GiB and has a 4 GiB limit to accommodate both JVMs, native memory and schema
bootstrap. Increase heap and pod memory together for your workload. The startup
probe allows 30 minutes for schema/WAL recovery; liveness checks daemon
processes instead of interrupting recovery with aggressive query timeouts.
For large existing WAL backlogs, set Helm `--timeout` longer than the startup
budget plus bootstrap hooks (for example `--timeout 45m`).
The supervisor gives the RegionServer up to 240 seconds to flush, then the
Master up to 45 seconds to stop. The Kubernetes grace period defaults to
300 seconds. Probe and Kubernetes grace budgets are tunable under `hbase.*`;
the supervisor's per-daemon stop timeouts are fixed.

HBase connects through a separate ClusterIP Service for each ZooKeeper member.
This keeps client addresses stable when ZooKeeper pods receive new IPs. The
stock image bundles ZooKeeper 3.4.10, affected by
[ZOOKEEPER-2184](https://issues.apache.org/jira/browse/ZOOKEEPER-2184); a DNS TTL
change alone cannot fix that client's cached addresses. Service recreation
can still require restarting HBase; preserve Services during upgrades.

This improves single-pod recovery, not storage redundancy or HBase HA.
Readiness checks startup schema completion, processes and sockets, not every
region's ongoing availability. A node/storage outage still needs a suitable
volume backend and recovery plan. An NFS StorageClass was not tested; single-node
local-path results do not establish NFS WAL durability or production HA.

### Local runtime validation

See [local k3s testing](LOCAL-TESTING.md) for an isolated default installation,
traffic checks and the recorded validation scope. MySQL SQL, Pinot definitions
and Telegraf configuration are bundled; their bootstrap no longer requires
runtime GitHub downloads. Collector's metric Service port 15200 maps to the
3.1.1 MetricApp HTTP listener on 9995/TCP. Kafka defaults give each JVM a 1 GiB
maximum heap and each pod a 2 GiB memory limit; the dependency's original
768 MiB limit was insufficient under test traffic.

Enable the optional chart-managed NetworkPolicies with:

```yaml
networkPolicy:
  enabled: true
```

The CNI must enforce NetworkPolicy. Review allowed ingress and external egress
for your agents, ingress controller and external services. These policies
restrict network access; they do not encrypt traffic.

### Metric initialization and issue #41

The [Inspector failure in #41](https://github.com/pinpoint-apm/pinpoint-kubernetes/issues/41)
is relevant to this chart. Earlier production comments suggested enabling Kafka
SASL_SSL and ZooKeeper authentication without configuring the clients. Stock
[Pinpoint 3.1.1 KafkaConfiguration](https://github.com/pinpoint-apm/pinpoint/blob/v3.1.1/pinot/pinot-kafka/src/main/java/com/navercorp/pinpoint/pinot/kafka/KafkaConfiguration.java)
does not bind security properties. `SPRING_KAFKA_*` environment variables do
not configure that custom producer factory. ZooKeeper credentials are also not
wired to all consumers. The pinned ZooKeeper dependency uses
`zookeeper.auth.client.enabled`; the old `zookeeper.auth.enabled` setting is a
legacy key. Both are checked to avoid a misleading security configuration.
The chart now rejects these unsupported combinations
instead of installing workloads that cannot ingest data. Do not enable server
authentication alone or downgrade the security of an existing external service.
If encrypted/authenticated Kafka or ZooKeeper is mandatory, additional client
integration is required before this chart can meet that requirement.

Topic initialization checks every required topic with `--if-not-exists` and
fails when a creation fails. Pinot initialization validates all 17 bundled
3.1.1 JSON definitions before making changes, creates missing schemas/tables
by their actual names (including `inspectorStatApp` and both Heatmap table types), and preserves existing
configs. Retries and upgrades can repair a partially initialized cluster;
unrelated topics/tables cannot hide missing Pinpoint resources. HTTP permission
and server errors fail the hook rather than being treated as missing tables.
New realtime tables use Pinot 1.3's Kafka 3.0 consumer plugin.

Set `global.pinot.createTables=false` if schemas/tables are managed separately.
An explicit application version override without bundled definitions requires
this setting and operator-managed initialization. Existing schemas/table configs
are not migrated automatically. A successful init hook confirms resources
exist; validate Collector ingestion and Inspector queries separately before
closing #41 or promoting a release.

Failed initialization jobs are retained until the next install/upgrade replaces
them or an operator deletes them. Successful hook jobs are removed by Helm.
Inspect failures with short log output:

```bash
kubectl get jobs -n pinpoint
kubectl logs -n pinpoint job/pinpoint-kafka-init --tail=30
kubectl logs -n pinpoint job/pinpoint-pinot-init --tail=30
```

The jobs have a 600-second active deadline. Helm's overall wait timeout is set
by `--timeout`; use the documented `--timeout 20m` installation command.

See [`values.yaml`](../values.yaml) for all configuration options and
[upgrade notes](UPGRADING.md) before upgrading a production release.

## Values validation and initialization resources

`values.schema.json` rejects invalid types for chart-owned replica counts,
ports, datasource pool sizes and replication settings before resources are
submitted to Kubernetes. Dependency-specific and custom settings remain extensible.
PDBs accept nonnegative integer budgets (including zero) or percentages from
0% to 100%; configure exactly one of `minAvailable` and `maxUnavailable`.

`global.initResources.wait`, `.mysql` and `.kafka` configure dependency-check
containers and MySQL/Kafka initialization hooks. The Kafka CLI heap is bounded
to 256 MiB. `global.pinot.initResources` configures the Python initializer.
Hooks inherit `global.imagePullSecrets` and do not mount service-account tokens.
