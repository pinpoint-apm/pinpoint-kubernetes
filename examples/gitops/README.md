# Argo CD deployment

This example deploys application chart **3.1.5** (Pinpoint **3.1.1**) with
Git-managed values and independently managed backends. Argo CD 2.6+ is required
for multiple sources; the optional storage example uses server-side diff,
stable in Argo CD 3.1+.

| File | Purpose |
| --- | --- |
| `bootstrap.yaml` | Root Application that tracks this directory in your Git repository |
| `kustomization.yaml` | Selects Argo CD manifests; excludes Helm values |
| `application.yaml` | AppProject and automatically synchronized Pinpoint Application |
| `values.yaml` | Environment-specific endpoints, ingress and Collector access |
| `storage.yaml` | Optional HBase/HDFS/ZooKeeper Application; operators installed separately |

## Setup

1. Copy this directory to `examples/gitops/` in your Git repository. Replace
   `YOUR_ORG/YOUR_GITOPS_REPO` in the manifests; change `master` if needed.
   Register repository credentials in Argo CD when using a private repository.
2. Edit `values.yaml`: backend hosts, network CIDRs, ingress class/hostname/TLS,
   and available Collector NodePorts. Prepare schemas using the
   [production guide](../../docs/PRODUCTION.md).
3. Provision these Secrets in namespace `pinpoint` with your secret manager:

   | Secret | Required keys |
   | --- | --- |
   | `pinpoint-mysql-credentials` | `password` |
   | `pinpoint-redis-credentials` | `password` |
   | `pinpoint-login` | `admin`, `jwt-secret`, `admin-api-password` |
   | `pinpoint-web-tls` | `tls.crt`, `tls.key` |

4. Commit the directory, then bootstrap after the backends are ready:

   ```bash
   kubectl apply -f examples/gitops/bootstrap.yaml
   kubectl -n argocd get application pinpoint-bootstrap pinpoint
   ```

The Application merges the production profile from Git tag `pinpoint-3.1.5`
with your values file. Commit values changes to deploy configuration updates.
For chart upgrades, update both the Helm revision and the defaults Git tag,
review [upgrade notes](../../docs/UPGRADING.md), then commit.
Automatic pruning is disabled; resource removal remains explicit.
Argo CD manages resources directly, so `helm list` does not reflect its upgrades.

## Optional storage chart

Install Stackable operators using the [storage guide](../../backends/hbase-stackable/README.md).
Set `YOUR_STORAGE_CLASS` in `storage.yaml` and review its disk/resource defaults.
Create the AppProject from the first document of `application.yaml`, deploy
`storage.yaml`, and wait for schema initialization before deploying Pinpoint.
Configure application discovery as shown in the storage guide; `values.yaml`
already permits same-namespace storage RPC traffic.

After storage initialization, add `storage.yaml` to `kustomization.yaml` and
commit so the root Application also manages future storage chart revisions.
Storage uses server-side apply/diff to preserve null ZooKeeper TLS settings.
When adopting existing resources, run one sync if Argo CD still reports Synced
without applying the new method. See the storage upgrade notes for discovery
refresh and controlled restarts after connection changes.
