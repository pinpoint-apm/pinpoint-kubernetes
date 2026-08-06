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

helm lint "${chart_dir}" \
  --set redis.enabled=false \
  --set global.redis.host=redis.external.example \
  --set global.redis.port=6380 \
  --set global.redis.username=pinpoint \
  --set global.redis.passwordSecret.name=external-redis \
  --set global.redis.passwordSecret.key=password \
  --set kafka.enabled=false \
  --set global.kafka.bootstrapServers=kafka.external.example:9092 \
  --set global.kafka.createTopics=false

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set redis.enabled=false \
  --set global.redis.host=redis.external.example \
  --set global.redis.port=6380 \
  --set global.redis.username=pinpoint \
  --set global.redis.passwordSecret.name=external-redis \
  --set global.redis.passwordSecret.key=password \
  --set kafka.enabled=false \
  --set global.kafka.bootstrapServers=kafka.external.example:9092 \
  --set global.kafka.createTopics=false > "${render_dir}/external-services.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-job-kafka.yaml \
  --set kafka.enabled=false \
  --set global.kafka.bootstrapServers=kafka.external.example:9092 \
  > "${render_dir}/external-kafka-init.yaml"

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

grep -q 'value: "redis.external.example"' "${render_dir}/external-services.yaml"
grep -q 'value: "6380"' "${render_dir}/external-services.yaml"
grep -q 'value: "pinpoint"' "${render_dir}/external-services.yaml"
grep -q 'name: "external-redis"' "${render_dir}/external-services.yaml"
grep -q 'key: "password"' "${render_dir}/external-services.yaml"
grep -q 'value: "kafka.external.example:9092"' "${render_dir}/external-services.yaml"
grep -q 'name: pinpoint-kafka-init' "${render_dir}/external-kafka-init.yaml"
grep -q 'value: "kafka.external.example:9092"' "${render_dir}/external-kafka-init.yaml"

if grep -q '# Source: pinpoint/charts/redis/' "${render_dir}/external-services.yaml"; then
  echo "External-services render unexpectedly contains bundled Redis resources" >&2
  exit 1
fi

if grep -q '# Source: pinpoint/charts/kafka/' "${render_dir}/external-services.yaml"; then
  echo "External-services render unexpectedly contains bundled Kafka resources" >&2
  exit 1
fi

if grep -q 'name: pinpoint-kafka-init' "${render_dir}/external-services.yaml"; then
  echo "External-services render unexpectedly contains the Kafka init job" >&2
  exit 1
fi

if helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set redis.enabled=false > "${render_dir}/invalid-external-redis.yaml" 2>&1; then
  echo "Missing external Redis host unexpectedly rendered successfully" >&2
  exit 1
fi

if helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set kafka.enabled=false > "${render_dir}/invalid-external-kafka.yaml" 2>&1; then
  echo "Missing external Kafka bootstrap servers unexpectedly rendered successfully" >&2
  exit 1
fi

if helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.metric.enabled=false \
  --set redis.enabled=false \
  --set global.redis.host=redis.external.example \
  --set global.redis.password=inline-password \
  --set global.redis.passwordSecret.name=external-redis \
  --set global.redis.passwordSecret.key=password \
  > "${render_dir}/invalid-redis-auth.yaml" 2>&1; then
  echo "Conflicting external Redis authentication unexpectedly rendered successfully" >&2
  exit 1
fi

echo "Helm lint and render validation passed."
