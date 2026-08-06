#!/usr/bin/env bash

set -euo pipefail

chart_dir="${1:-.}"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm repo add pinot https://raw.githubusercontent.com/apache/pinot/master/helm --force-update
helm dependency build "${chart_dir}"

helm lint "${chart_dir}"
helm lint "${chart_dir}" --set global.metric.enabled=false

helm template pinpoint "${chart_dir}" --namespace pinpoint > "${render_dir}/metric.yaml"
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.metric.enabled=false > "${render_dir}/classic.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/web.yaml \
  --set web.ingress.enabled=true > "${render_dir}/web-ingress.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/hbase.yaml > "${render_dir}/hbase-persistent.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/hbase.yaml \
  --set hbase.persistence.enabled=false > "${render_dir}/hbase-ephemeral.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/hbase.yaml \
  --set hbase.persistence.storageClass=fast-ssd > "${render_dir}/hbase-storage-class.yaml"

grep -q 'volumeClaimTemplates:' "${render_dir}/hbase-persistent.yaml"
grep -q 'host: "pinpoint.localdev.me"' "${render_dir}/web-ingress.yaml"
grep -q 'path: "/"' "${render_dir}/web-ingress.yaml"

if grep -q 'volumeClaimTemplates:' "${render_dir}/hbase-ephemeral.yaml"; then
  echo "HBase ephemeral render unexpectedly contains volumeClaimTemplates" >&2
  exit 1
fi

grep -q 'emptyDir: {}' "${render_dir}/hbase-ephemeral.yaml"
grep -q 'storageClassName: "fast-ssd"' "${render_dir}/hbase-storage-class.yaml"

echo "Helm lint and render validation passed."
