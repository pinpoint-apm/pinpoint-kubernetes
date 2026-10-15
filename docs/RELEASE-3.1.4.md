# Pinpoint chart 3.1.4 release notes

Chart **3.1.4** keeps Pinpoint application **3.1.1** and all locked dependencies.
It adds an opt-in, chart-managed external Collector Service.

- Configure `collector.externalService` in values instead of maintaining a
  separate agent-facing Service manifest. The internal Collector Service stays
  unchanged. The external Service is disabled by default.
- Expose only the three TCP agent gRPC receivers. Support fixed or allocated
  NodePorts, a custom Service name, annotations, `Cluster`/`Local` traffic policy
  and a LoadBalancer endpoint with optional source ranges.
- Validate the Service name/type, port types/ranges, duplicate explicit
  NodePorts, collisions with the internal Service name, and a disabled Collector.
  Kubernetes still checks the configured NodePort range and port availability.
- Add render regression checks to CI for default behavior, migration port
  mappings, custom release names, classic/metric profiles and invalid values.

No schema, retention, application image, storage or operator changes are included.
See [upgrade and Service adoption notes](UPGRADING.md#chart-313-to-314).

## Validation scope

Local validation passed with Helm 3.21.3:

- `bash scripts/helm-validate.sh`: lint, external Service regression checks,
  metric/classic profiles, initialization tests, backend checks and packaging.
- A render with cached DEV values plus the Service adoption overrides preserves
  the existing external Service's complete spec and annotations. All 33 existing
  application resources remain identical apart from chart-version labels.

Live Service adoption has not been tested. Before enabling this optional
endpoint for an existing deployment, verify in staging that its NodePorts,
ClusterIP and agent connectivity are preserved. No cluster was accessed for
these local checks. Render checks do not establish live-network or application
health; see the [release process](RELEASING.md).
