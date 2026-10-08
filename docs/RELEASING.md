# Releasing the Helm chart

The release workflow validates and packages the chart, creates a GitHub
release, updates the Helm repository index and landing page on the `gh-pages`
branch, and verifies that the published package can be downloaded and rendered.
It also packages the independent `pinpoint-hbase-stackable` companion chart.
The application release receives installation/upgrade links and is explicitly
marked Latest so a companion publication does not replace that marker.
Its version in `backends/hbase-stackable/Chart.yaml` follows its own release
cycle and must be bumped when that chart changes after publication.

## One-time repository setup

1. Ensure GitHub Actions may use a read/write `GITHUB_TOKEN` in the repository.
2. Run **Helm CI and Release** once from `master`; the workflow bootstraps the
   `gh-pages` branch automatically.
3. In **Settings > Pages**, select **Deploy from a branch**, then choose the
   `gh-pages` branch and the repository root.

## Publish a chart version

1. For a Pinpoint application release, update both `version` and `appVersion`
   in `Chart.yaml` to the supported Pinpoint version. A chart-only follow-up
   must use the next available chart patch because published versions are
   immutable; `appVersion` remains on the supported Pinpoint version.
2. Update `global.pinpointVersion`, the README version badges/examples, upgrade
   notes and validation expectations. Keep independently versioned components
   such as Flink and Pinot on verified compatible images.
3. Verify that all default images and versioned initialization assets exist.
   Run `bash scripts/helm-validate.sh`; it checks metric/classic modes, external
   services, Secrets, login validation, image overrides, custom release names
   and the packaged chart. It also runs initialization regression tests for
   partial installs, reruns, exact resource checks and HTTP/creation errors.
   When bundling upstream definitions, preserve their Apache license/NOTICE.
4. Test the release candidate on a staging cluster. Verify initialization hooks,
   trace ingestion, UI/Inspector queries, alarms, workload recovery and a
   persistent-volume upgrade from the previous chart. Record results in the PR;
   lint and render checks alone are insufficient for a production release.
5. Open and merge a pull request into `master` once the release checks pass.
   A push or merge to `master` automatically publishes the chart after CI, so
   keep unfinished release work on a feature branch.
6. Verify that **Helm CI and Release** created the GitHub release, updated
   `gh-pages/index.yaml` and `gh-pages/index.html`, and passed its repository
   smoke test.

The chart can then be installed from the published repository:

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm upgrade --install pinpoint pinpoint/pinpoint \
  --namespace pinpoint \
  --create-namespace \
  --wait \
  --timeout 20m
```
