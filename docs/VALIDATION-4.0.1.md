# Local qualification: chart 4.0.1

Pinpoint 4.0.1 was tested on Linux amd64 k3s 1.35.5 managed by k3d 5.9.0:
a single-node evaluation stack, then an application profile on two additional
workers. All virtual nodes share one physical host. The candidate is local and
unpublished. The companion storage chart
0.2.0 passed render/package checks; its 4.x runtime HA qualification is separate.

| Check | Result |
| --- | --- |
| Full Helm validation | Lint, profile/negative renders, schemas, security, retention, GitOps and packaged charts passed |
| Fresh Metric installation | All 12 workload pods Ready, zero container restarts; initialization Jobs completed |
| Native agent traffic | Fresh Inspector samples and current trace queries passed with 4.0.1 and legacy 3.1.1 agents |
| Services | Native 4.x agent and OTLP applications registered and queried under a named service |
| OTLP/HTTP | JSON export, application registration, scatter and trace detail passed |
| OTLP/gRPC | Export using official OpenTelemetry proto definitions and trace-detail readback passed |
| Login | Anonymous/invalid login rejected; Secure/HttpOnly/Lax JWT worked across two Web replicas |
| MySQL 8.4 | Required schema, partial repair, reruns, sequence/data preservation and dump/restore passed |
| Dependency startup | A temporarily unavailable MySQL endpoint recovered without repeated error logs |
| Pinot migration | Additive field update, controller normalization and idempotence passed against the live API |
| Application upgrade | 3.1.1 schema/data → 4.0.1 preserved an exact HBase trace-row hash and historical Pinot records |
| Retention | Readback confirmed 14 HBase history tables / 16 families and 15 Pinot history tables at 7 days; metadata policies preserved |
| Repeat Helm upgrade | Completed with preserved data and successful initialization |
| Production application profile | Two Web and two Collector replicas, shared login and separately managed test backends; native/OTLP smoke passed |
| Worker maintenance | Drain/uncordon passed; 1,255 authenticated API, Collector TCP and demo HTTP checks returned no errors |
| Disruption protection | Both PDBs rejected eviction of the last healthy replica; strict placement kept replacements Pending until the worker returned |
| Worker return | Both components recovered two Ready replicas on distinct workers without manual pod restarts |
| Network isolation | Unauthorized pod connections to Web and Collector rejected; allowed application traffic passed |
| Management access | Anonymous requests to management and application APIs redirected to login |
| Stability | Evaluation workload pods remained Ready with zero container restarts for over two days before final review |
| Final logs | 40 current application/backend/init container logs read successfully; no ERROR/FATAL entries or container restarts |

The application upgrade test started with MySQL already on 8.4. It does not
qualify upgrading an existing MySQL 8.0 data directory. Production load, storage
failure and distributed HA tests remain deployment-specific. Service Alarm's
custom image/notification paths and the separate legacy LOG process are not
covered by the default Metric qualification.

The production-profile test used existing singleton evaluation backends,
smaller application heaps and local Service traffic; it does not qualify
backend failover, production TLS/ingress, independent hosts or production load.
The default evaluation profile is not a production architecture. Promote the
application candidate through DEV and complete backend/restore/load acceptance
before declaring an installation production ready.

Reproduce the core checks with `bash scripts/helm-validate.sh`, a fresh local
install using `values-minimal.yaml` and `--wait --wait-for-jobs`, then
`scripts/local-smoke.py --check-v4` and `scripts/local-mysql-recovery.py` with
an explicitly selected loopback kubeconfig and disposable namespace.
