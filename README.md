# Pinpoint Helm Chart

[![Helm CI](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml/badge.svg)](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml)
![Chart version](https://img.shields.io/badge/chart-3.1.0-blue)
![Pinpoint version](https://img.shields.io/badge/Pinpoint-3.1.0-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

Open-source Helm chart for running
[Pinpoint APM](https://github.com/pinpoint-apm/pinpoint) on Kubernetes.

Chart `3.1.0` deploys Pinpoint `3.1.0`. Runtime SQL, Pinot, and Telegraf
assets use the matching Pinpoint release tag instead of the mutable upstream
`master` branch.

## Features

- Metric profile with Kafka, Pinot, and Telegraf enabled by default
- Classic profile with Batch and Flink
- Bundled or external Redis and Kafka
- Persistent HBase and MySQL storage
- Optional release-scoped Kubernetes NetworkPolicies
- Automated linting, rendering, packaging, GitHub Releases, and Helm repository publishing

## Requirements

- A Kubernetes cluster
- Helm 3
- `kubectl`

The default metric profile runs MySQL, HBase, ZooKeeper, Kafka, Redis, and
Pinot. Ensure a local cluster has sufficient CPU, memory, and storage before
installing it.

## Install from the Helm repository

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm upgrade --install pinpoint pinpoint/pinpoint \
  --namespace pinpoint \
  --create-namespace
```

## Test a local checkout

Build dependencies and validate the chart before installing it:

```bash
helm dependency build .
bash scripts/helm-validate.sh
```

Install the local chart and wait for its workloads and initialization jobs:

```bash
helm upgrade --install pinpoint . \
  --namespace pinpoint \
  --create-namespace \
  --wait \
  --wait-for-jobs \
  --timeout 20m
```

Check the deployment:

```bash
kubectl get pods,jobs,pvc -n pinpoint
kubectl get events -n pinpoint --sort-by=.lastTimestamp
```

When the Web pod is ready, open the Pinpoint UI locally:

```bash
kubectl port-forward service/pinpoint-web 8080:8080 -n pinpoint
```

Then visit <http://localhost:8080>.

## Deployment profiles

The metric profile is enabled by default:

```bash
helm upgrade --install pinpoint pinpoint/pinpoint \
  --namespace pinpoint \
  --create-namespace
```

Use classic Batch and Flink processing instead with:

```bash
helm upgrade --install pinpoint pinpoint/pinpoint \
  --namespace pinpoint \
  --create-namespace \
  --set global.metric.enabled=false
```

Pinpoint does not publish a `pinpoint-flink:3.1.0` image. Classic mode pins
Flink to the compatible `3.0.3` image while other Pinpoint components run
`3.1.0`.

## External Redis and Kafka

Disable the bundled dependencies and provide external endpoints through a
values file:

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
    createTopics: false

redis:
  enabled: false

kafka:
  enabled: false
```

`global.redis.host` is required when `redis.enabled=false`, and
`global.kafka.bootstrapServers` is required when `kafka.enabled=false`.

## Network policies

NetworkPolicies are disabled by default. Enable the chart-managed policies
with:

```yaml
networkPolicy:
  enabled: true
```

The default rules allow cluster DNS, release-internal communication,
Ingress-NGINX access to Pinpoint Web, and collectors to receive traffic from
namespaces labeled `pinpoint-apm.io/agent-access=true`. Customize
`networkPolicy.*` in [`values.yaml`](values.yaml) for the cluster's ingress,
DNS, agent, and external service topology.

## Common configuration

| Value | Default | Description |
| --- | --- | --- |
| `global.metric.enabled` | `true` | Use the metric profile |
| `global.pinpointVersion` | `3.1.0` | Pinpoint application version |
| `global.image.registry` | `""` | Optional image registry prefix |
| `hbase.persistence.enabled` | `true` | Persist HBase data |
| `redis.enabled` | `true` | Deploy bundled Redis |
| `kafka.enabled` | unset | Override bundled Kafka; otherwise follows metric mode |
| `web.ingress.enabled` | `false` | Create a Web Ingress |
| `networkPolicy.enabled` | `false` | Create chart-managed NetworkPolicies |

See [`values.yaml`](values.yaml) for every available value.

## Uninstall

```bash
helm uninstall pinpoint --namespace pinpoint
```

PersistentVolumeClaims may remain after uninstall. Review retained data before
deleting any PVCs.

## Upgrading

Back up MySQL and HBase before upgrading a production installation. See
[`docs/UPGRADING.md`](docs/UPGRADING.md) for the Pinpoint 3.1 schema and
compatibility notes.

## Development and releases

```bash
bash scripts/helm-validate.sh
```

Pull requests run the same lint and render matrix used before chart releases.
See [`docs/RELEASING.md`](docs/RELEASING.md) for the publishing process.

## Screenshots

The screenshots below will be refreshed after the final local deployment test.

![Kubernetes workloads](docs/screenshots/01-kubectl-get-pods.png)

![Pinpoint server map](docs/screenshots/02-web-ui-servermap.png)

![Pinpoint inspector metrics](docs/screenshots/03-web-ui-inspector-metrics.png)

## License

[Apache License 2.0](LICENSE)
