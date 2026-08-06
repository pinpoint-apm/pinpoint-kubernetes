# Pinpoint Helm Chart

![Version: 3.1.0](https://img.shields.io/badge/Version-3.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 3.1.0](https://img.shields.io/badge/AppVersion-3.1.0-informational?style=flat-square)

A Helm chart for deploying Pinpoint APM on Kubernetes.

The default deployment runs Pinpoint 3.1.0. Runtime SQL, Pinot, and Telegraf
assets are downloaded from the matching Pinpoint release tag so that chart
configuration cannot drift with the upstream `master` branch.

## Introduction

This chart bootstraps a [Pinpoint APM](https://pinpoint-apm.github.io/pinpoint/) deployment on a Kubernetes cluster using the Helm package manager.

## Installing the Chart

Add the Pinpoint chart repository and install the chart with the release name `pinpoint`:

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm install pinpoint pinpoint/pinpoint -n pinpoint --create-namespace
```

To install directly from source instead, clone the repository, run
`helm dependency build`, and use `helm install pinpoint .`.

### Verifying the chart repository

Run the repository smoke test to verify that a chart version is indexed,
downloadable, and renderable:

```bash
bash scripts/helm-repo-smoke.sh \
  https://pinpoint-apm.github.io/pinpoint-kubernetes
```

The version argument is optional and defaults to the version in `Chart.yaml`.
The script uses isolated Helm cache and configuration directories, so it does
not modify the repositories configured in the current user profile.

### Deployment modes

This chart supports two deployment modes:

**Metric Profile (default):**
```bash
helm install pinpoint pinpoint/pinpoint -n pinpoint --create-namespace
```
Deploys Kafka, Pinot, and Telegraf for advanced metrics collection.

**Classic Mode:**
```bash
helm install pinpoint pinpoint/pinpoint -n pinpoint --create-namespace --set global.metric.enabled=false
```
Deploys Batch and Flink modules for traditional APM processing.

Pinpoint 3.1.0 does not publish a Flink image. Classic mode therefore uses the
compatible `pinpoint-flink:3.0.3` image by default while the remaining Pinpoint
components run 3.1.0.

> **Note:** You may see warnings about `SessionAffinity is ignored for headless services`. These are harmless warnings and do not affect functionality.

### External Redis and Kafka

The bundled Redis and Kafka dependencies can be disabled independently. The
following example uses an existing Redis Secret and assumes Kafka topics are
managed outside this Helm release:

```yaml
global:
  redis:
    host: redis.example.internal
    port: 6380
    username: pinpoint
    passwordSecret:
      name: pinpoint-redis-credentials
      key: password
  kafka:
    bootstrapServers: kafka-0.example.internal:9092,kafka-1.example.internal:9092
    createTopics: false

redis:
  enabled: false

kafka:
  enabled: false
```

Use `global.redis.password` instead of `passwordSecret` only when storing a
plain-text password in Helm values is acceptable. When
`global.kafka.createTopics=true`, the chart's Kafka initialization job creates
the required Pinpoint topics on the configured external brokers.

### Network policies

Network isolation is opt-in. Enabling it restricts Pinpoint components,
MySQL, Redis, ZooKeeper, Kafka, and Pinot to release-internal traffic, DNS, and
the explicitly configured ingress and egress rules:

```yaml
networkPolicy:
  enabled: true
  web:
    ingressFrom:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-nginx
  collector:
    ingressFrom:
      - namespaceSelector:
          matchLabels:
            pinpoint-apm.io/agent-access: "true"
  externalEgress:
    - to:
        - ipBlock:
            cidr: 10.20.0.0/16
      ports:
        - port: 3306
          protocol: TCP
```

Label namespaces that run Pinpoint agents with
`pinpoint-apm.io/agent-access=true`. For agents outside the cluster, replace or
extend `networkPolicy.collector.ingressFrom` with narrow `ipBlock` CIDRs.
External services are addressed by CIDR because Kubernetes NetworkPolicy does
not support DNS names. Adjust the DNS selectors if your cluster does not run
CoreDNS in `kube-system` with the `k8s-app: kube-dns` label.

## Parameters

### Global parameters

| Name | Description | Value |
|------|-------------|-------|
| `global.metric.enabled` | Enable metric profile deployment | `true` |
| `global.pinpointVersion` | Pinpoint version | `"3.1.0"` |
| `global.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `global.datasource.enabled` | Enable global datasource configuration<br/>- `true` (default): Injects datasource env vars. Defaults to the bundled MySQL if `mysql.enabled` is true.<br/>- `false`: No datasource env vars are injected into Web/Batch. | `true` |
| `global.datasource.driverClassName` | JDBC driver class name<br/>- Defaults to the MySQL driver from the chart dependency | `""` |
| `global.datasource.jdbcUrl` | JDBC URL for external database<br/>- Defaults to the MySQL service from the chart dependency | `""` |
| `global.datasource.username` | Database username<br/>- Defaults to the MySQL username from the chart dependency | `""` |
| `global.datasource.passwordSecret.name` | Secret name containing password | `""` |
| `global.datasource.passwordSecret.key` | Key in the Secret containing the password | `""` |
| `global.datasource.password` | Database password (Not RECOMMENDED for production)<br/>- Defaults to the MySQL password from the chart dependency | `""` |
| `global.redis.host` | External Redis hostname; required when `redis.enabled=false` | `""` |
| `global.redis.port` | External Redis port | `6379` |
| `global.redis.username` | External Redis username | `""` |
| `global.redis.passwordSecret.name` | Secret containing the external Redis password | `""` |
| `global.redis.passwordSecret.key` | Password key in the external Redis Secret | `""` |
| `global.redis.password` | Plain-text external Redis password (not recommended) | `""` |
| `global.kafka.bootstrapServers` | External Kafka bootstrap servers; required when `kafka.enabled=false` | `""` |
| `global.kafka.createTopics` | Run the Kafka topic initialization job | `true` |
| `networkPolicy.enabled` | Create release-scoped ingress and egress policies | `false` |
| `networkPolicy.web.ingressFrom` | NetworkPolicy peers allowed to reach Web on TCP 8080 | ingress-nginx namespace |
| `networkPolicy.collector.ingressFrom` | NetworkPolicy peers allowed to reach Collector agent ports | labeled agent namespaces |
| `networkPolicy.externalEgress` | Additional raw egress rules for external services | `[]` |
| `redis.enabled` | Deploy the bundled Redis dependency | `true` |
| `kafka.enabled` | Optional override for bundled Kafka; otherwise inherits `global.metric.enabled` | unset |

## Accessing Pinpoint

After installation, you can access the Pinpoint services:

**Web UI:**
```bash
kubectl port-forward svc/pinpoint-web 8080:8080 -n pinpoint
```
Then open http://localhost:8080 in your browser.

**Pinot Controller UI (Real-time Data Management):**
```bash
kubectl port-forward svc/pinpoint-pinot-controller 9000:9000 -n pinpoint
```
Then open http://localhost:9000 in your browser.

## Uninstalling the Chart

To uninstall the `pinpoint` deployment:

```bash
helm uninstall pinpoint -n pinpoint
```

## Upgrading

Before upgrading a production deployment, back up MySQL and the HBase volume.
The bundled MySQL hook applies the Pinpoint 3.1 webhook column migration on
upgrade. Pinpoint's 3.1 HBase image initializes the new schema tables when its
`AgentId` marker table is absent. External databases remain operator-managed;
see [UPGRADING.md](UPGRADING.md) for the required checks and SQL.

## Chart publishing

Pull requests run the Helm lint and render validation matrix. Pushes to
`master`, and manual workflow runs dispatched from `master`, publish only after
the same validation job succeeds.

The release job creates the `gh-pages` branch on the first publication,
packages the chart, creates or reuses the corresponding GitHub Release, updates
the Helm repository index and landing page, and runs
`scripts/helm-repo-smoke.sh` against the published content. See
[RELEASING.md](RELEASING.md) for the one-time GitHub Pages configuration.

## Resources

- [Pinpoint Documentation](https://pinpoint-apm.gitbook.io/pinpoint/)
- [GitHub Issues](https://github.com/pinpoint-apm/pinpoint-kubernetes/issues)

## Screenshots

### Kubernetes Deployment
![Kubernetes Pods](docs/screenshots/01-kubectl-get-pods.png)

### Pinpoint Web Dashboard
![Application Map](docs/screenshots/02-web-ui-servermap.png)
![Performance Metrics](docs/screenshots/03-web-ui-inspector-metrics.png)
![System Metrics](docs/screenshots/05-web-ui-system-metrics.png)
