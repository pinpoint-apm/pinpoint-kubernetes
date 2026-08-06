# Releasing the Helm chart

The release workflow packages the chart, creates a GitHub release, and updates
the Helm repository index on the `gh-pages` branch.

## One-time repository setup

1. Create a `gh-pages` branch in the GitHub repository.
2. In **Settings > Pages**, select **Deploy from a branch**, then choose the
   `gh-pages` branch and the repository root.
3. Ensure GitHub Actions is allowed to use a read/write `GITHUB_TOKEN` for the
   repository.

## Publish a chart version

1. Update `version` in `Chart.yaml` according to semantic versioning. Update
   `appVersion` only when the Pinpoint application version changes.
2. Update the version badge in `README.md`.
3. Open and merge a pull request into `master`.
4. Verify that the **Release Helm chart** workflow created the GitHub release
   and updated `gh-pages/index.yaml`.

The chart can then be installed from the published repository:

```bash
helm repo add pinpoint https://pinpoint-apm.github.io/pinpoint-kubernetes
helm repo update
helm install pinpoint pinpoint/pinpoint -n pinpoint --create-namespace
```
