#!/usr/bin/env bash

set -euo pipefail

bash -n scripts/helm-repo-smoke.sh
bash -n scripts/render-pages-site.sh

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
  --show-only templates/init-job-mysql.yaml > "${render_dir}/mysql-init.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-job-pinot.yaml > "${render_dir}/pinot-init.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/telegraf.yaml > "${render_dir}/telegraf.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/networkpolicy.yaml \
  --set networkPolicy.enabled=true > "${render_dir}/network-policy-enabled.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.image.registry=registry.example.com/mirror/ \
  --set global.metric.enabled=false \
  --set agent.enabled=true > "${render_dir}/custom-registry.yaml"

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

grep -q 'pinpointdocker/pinpoint-web:3.1.0-metric' "${render_dir}/metric.yaml"
grep -q 'pinpointdocker/pinpoint-collector:3.1.0-metric' "${render_dir}/metric.yaml"
grep -q 'pinpointdocker/pinpoint-hbase:3.1.0' "${render_dir}/metric.yaml"
grep -q 'pinpointdocker/pinpoint-flink:3.0.3' "${render_dir}/classic.yaml"
grep -q 'apachepinot/pinot:1.0.0-11-amazoncorretto' "${render_dir}/metric.yaml"
grep -q 'pinpoint/v3.1.0/web/src/main/resources/sql/CreateTableStatement-mysql.sql' "${render_dir}/mysql-init.yaml"
grep -q 'pinpoint/v3.1.0/metric-module/metric/src/main/pinot/pinot-tag-schema.json' "${render_dir}/pinot-init.yaml"
grep -q 'pinpoint/v3.1.0/metric-module/metric/src/main/telegraf/pinpoint-telegraf.conf' "${render_dir}/telegraf.yaml"
grep -q 'post-install,post-upgrade' "${render_dir}/mysql-init.yaml"
grep -q 'ALTER TABLE webhook MODIFY COLUMN application_id VARCHAR(127)' "${render_dir}/mysql-init.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-web:3.1.0' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-collector:3.1.0' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-hbase:3.1.0' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-agent:3.1.0' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-batch:3.1.0' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-flink:3.0.3' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-quickstart:2.5.4' "${render_dir}/custom-registry.yaml"

if grep -R -q 'pinpoint-apm/pinpoint/master' "${render_dir}"; then
  echo "Rendered manifests unexpectedly reference the mutable Pinpoint master branch" >&2
  exit 1
fi

if grep -q '^kind: NetworkPolicy' "${render_dir}/metric.yaml"; then
  echo "NetworkPolicy resources unexpectedly rendered while disabled" >&2
  exit 1
fi

if grep -q 'apachepinot/pinot:latest' "${render_dir}/metric.yaml"; then
  echo "Metric render unexpectedly uses the mutable Pinot latest tag" >&2
  exit 1
fi

test "$(grep -c '^kind: NetworkPolicy' "${render_dir}/network-policy-enabled.yaml")" -eq 9
grep -q 'name: pinpoint-mysql' "${render_dir}/network-policy-enabled.yaml"
grep -q 'name: pinpoint-zookeeper' "${render_dir}/network-policy-enabled.yaml"
grep -q 'name: pinpoint-kafka' "${render_dir}/network-policy-enabled.yaml"
grep -q 'name: pinpoint-pinot' "${render_dir}/network-policy-enabled.yaml"
grep -q 'pinpoint-apm.io/agent-access: "true"' "${render_dir}/network-policy-enabled.yaml"
grep -q 'kubernetes.io/metadata.name: ingress-nginx' "${render_dir}/network-policy-enabled.yaml"
grep -q 'cidr: 0.0.0.0/0' "${render_dir}/network-policy-enabled.yaml"
grep -q 'port: 443' "${render_dir}/network-policy-enabled.yaml"

if grep -q '# Source: pinpoint/charts/.*/templates/.*networkpolicy' "${render_dir}/metric.yaml"; then
  echo "Dependency NetworkPolicies unexpectedly bypass root policy management" >&2
  exit 1
fi

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

GITHUB_REPOSITORY=pinpoint-apm/pinpoint-kubernetes \
  bash scripts/render-pages-site.sh "${render_dir}/pages"
grep -q '<title>Pinpoint Helm Chart</title>' "${render_dir}/pages/index.html"
grep -q 'https://pinpoint-apm.github.io/pinpoint-kubernetes' "${render_dir}/pages/index.html"
grep -q 'Chart 3.1.0' "${render_dir}/pages/index.html"
grep -q 'Pinpoint 3.1.0' "${render_dir}/pages/index.html"
test -f "${render_dir}/pages/.nojekyll"

if grep -q '__[A-Z_]*__' "${render_dir}/pages/index.html"; then
  echo "Rendered Pages site still contains template placeholders" >&2
  exit 1
fi

echo "Helm lint and render validation passed."
