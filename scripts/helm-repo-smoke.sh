#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <helm-repository-url> [chart-version]" >&2
  exit 2
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to verify the published chart repository" >&2
  exit 1
fi

repository_url="${1%/}"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
chart_root=$(cd -- "${script_dir}/.." && pwd)
chart_name=$(awk '/^name:/ { print $2; exit }' "${chart_root}/Chart.yaml" | tr -d '\r')
chart_version=${2:-$(awk '/^version:/ { print $2; exit }' "${chart_root}/Chart.yaml" | tr -d '\r')}

if [[ -z "$chart_name" || -z "$chart_version" ]]; then
  echo "Unable to determine the chart name or version from Chart.yaml" >&2
  exit 1
fi

smoke_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "$smoke_dir"
}
trap cleanup EXIT

export HELM_CONFIG_HOME="${smoke_dir}/helm/config"
export HELM_CACHE_HOME="${smoke_dir}/helm/cache"
export HELM_DATA_HOME="${smoke_dir}/helm/data"
mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"

repository_name=pinpoint-smoke
helm repo add "$repository_name" "$repository_url"
helm repo update "$repository_name"

helm pull "${repository_name}/${chart_name}" \
  --version "$chart_version" \
  --destination "$smoke_dir"

chart_package="${smoke_dir}/${chart_name}-${chart_version}.tgz"
if [[ ! -f "$chart_package" ]]; then
  echo "Published chart package was not downloaded: ${chart_package}" >&2
  exit 1
fi

published_version=$(
  helm show chart "$chart_package" |
    awk '/^version:/ { print $2; exit }' |
    tr -d '\r'
)
if [[ "$published_version" != "$chart_version" ]]; then
  echo "Expected chart version ${chart_version}, found ${published_version:-none}" >&2
  exit 1
fi

helm template pinpoint-smoke "$chart_package" >/dev/null
echo "Verified ${chart_name}-${chart_version} from ${repository_url}"
