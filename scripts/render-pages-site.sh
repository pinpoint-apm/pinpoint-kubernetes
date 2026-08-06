#!/usr/bin/env bash

set -euo pipefail

target_dir="${1:?usage: render-pages-site.sh <target-directory>}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
chart_dir="$(cd -- "${script_dir}/.." && pwd)"
repository="${GITHUB_REPOSITORY:-pinpoint-apm/pinpoint-kubernetes}"
owner="${repository%%/*}"
repo_name="${repository#*/}"
helm_repository_url="https://${owner}.github.io/${repo_name}"
github_repository_url="https://github.com/${repository}"
chart_version="$(awk '$1 == "version:" { print $2; exit }' "${chart_dir}/Chart.yaml")"
app_version="$(awk '$1 == "appVersion:" { print $2; exit }' "${chart_dir}/Chart.yaml" | tr -d '"')"

mkdir -p "${target_dir}"

sed \
  -e "s|__HELM_REPOSITORY_URL__|${helm_repository_url}|g" \
  -e "s|__GITHUB_REPOSITORY_URL__|${github_repository_url}|g" \
  -e "s|__CHART_VERSION__|${chart_version}|g" \
  -e "s|__APP_VERSION__|${app_version}|g" \
  "${chart_dir}/docs/helm-repository/index.html" > "${target_dir}/index.html"

cp "${chart_dir}/docs/helm-repository/.nojekyll" "${target_dir}/.nojekyll"
