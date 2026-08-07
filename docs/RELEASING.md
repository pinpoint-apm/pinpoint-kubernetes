# Releasing the Helm chart

The release workflow validates and packages the chart, creates a GitHub
release, updates the Helm repository index and landing page on the `gh-pages`
branch, and verifies that the published package can be downloaded and rendered.

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
2. Update the version badge in `README.md`.
3. Open and merge a pull request into `master`.
4. Verify that **Helm CI and Release** created the GitHub release, updated
   `gh-pages/index.yaml` and `gh-pages/index.html`, and passed its repository
   smoke test.

The chart can then be installed from the published repository:

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm upgrade --install pinpoint pinpoint/pinpoint \
  --namespace pinpoint \
  --create-namespace
```
