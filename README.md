# Pinpoint Helm Chart

[![Helm CI](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml/badge.svg)](https://github.com/pinpoint-apm/pinpoint-kubernetes/actions/workflows/helm-ci.yaml)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

Deploy Pinpoint APM **3.1.1** with application chart **3.1.4**.
Chart and application versions are independent.

| Profile | Deployment |
| --- | --- |
| Default | Evaluation stack with Web, Collector, bundled backends and demo data |
| [Production](values-production.yaml) | Two Web and two Collector replicas using independently managed backends |

Metric mode uses HBase for traces, Kafka/Pinot for metrics, MySQL for Web
configuration, Redis for shared state, and ZooKeeper for coordination.
The bundled filesystem-backed HBase pod is intended for evaluation.

## Requirements

Kubernetes, Helm 3, kubectl and persistent storage for bundled databases.
Stock HBase/demo images require Linux amd64 nodes. The default stack requests
about **22.6 GiB RAM and 7.75 CPU cores**, excluding initialization Jobs and
cluster services. See [sizing and configuration](docs/CONFIGURATION.md).

## Quick start

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.4 --namespace pinpoint --create-namespace \
  --wait --timeout 20m
kubectl port-forward -n pinpoint service/pinpoint-web 8080:8080
```

Open http://localhost:8080. Quickstart supplies demo data.

## Production

1. Provision HBase, ZooKeeper, MySQL, Redis, Kafka and Pinot.
2. Copy [values-production.yaml](values-production.yaml); configure endpoints,
   Secret references, ingress/TLS and network access.
3. Initialize schemas and install with the reviewed values file:

```bash
helm upgrade --install pinpoint pinpoint/pinpoint \
  --version 3.1.4 --namespace pinpoint --create-namespace \
  -f my-production-values.yaml --wait --timeout 20m
```

Use the [production guide](docs/PRODUCTION.md) for schema setup and acceptance
checks. The optional [HBase/HDFS storage chart](backends/hbase-stackable/README.md)
and its Stackable operators have separate releases.
[Argo CD examples](examples/gitops/README.md) support Git-based values and upgrades.

## Connect agents

Collector uses **9991/TCP** for agent metadata, **9992/TCP** for statistics and
**9993/TCP** for spans. Agents outside Kubernetes need a reachable TCP endpoint,
separate from the Web ingress. An optional Service exposes just these gRPC ports:

```yaml
collector:
  externalService:
    enabled: true
    type: NodePort
    nodePorts:
      grpcAgent: 30991
      grpcStat: 30992
      grpcSpan: 30993
```

This creates `pinpoint-collector-external`; set `name` to retain an existing
Service name. `LoadBalancer` is also supported. Configure the agent's Collector
host/ports and a unique `agentId` per instance. Allow the traffic through your
firewalls and NetworkPolicies. See [configuration](docs/CONFIGURATION.md).

## Documentation

- [Production](docs/PRODUCTION.md): backends, storage, capacity and recovery.
- [Configuration](docs/CONFIGURATION.md): values, Secrets and external services.
- [Upgrades](docs/UPGRADING.md) and [schema compatibility](docs/SCHEMA-COMPATIBILITY.md).
- [Local testing](docs/LOCAL-TESTING.md) and [release process](docs/RELEASING.md).

Kafka SASL/TLS, Redis Sentinel/TLS and authenticated ZooKeeper clients require
additional integration. PostgreSQL requires [application/SQL changes](docs/POSTGRESQL.md).

For a checkout, run `helm dependency build .` and install from `.`.
Validate changes with `bash scripts/helm-validate.sh` (Helm 3, Python 3, Ruby).
