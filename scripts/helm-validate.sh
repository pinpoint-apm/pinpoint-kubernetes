#!/usr/bin/env bash

set -euo pipefail

bash -n scripts/helm-repo-smoke.sh
bash -n scripts/render-pages-site.sh
bash -n scripts/validate-hbase-backend.sh
python3 -m py_compile scripts/local-smoke.py scripts/local-ha-recovery.py scripts/local-mysql-recovery.py scripts/hbase_local_client.py
python3 -m py_compile examples/local-production/setup-local.py examples/local-production/verify-ingress.py

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

# Every chart-owned container, including sequential dependency checks, needs
# an explicit resource budget. Use the rendered Pod specs, not template text.
ruby - "${render_dir}/metric.yaml" "${render_dir}/classic.yaml" <<'RUBY'
require 'yaml'
ARGV.each do |filename|
  File.read(filename).split(/^---\s*$/).each do |document|
    next unless document.match?(%r{# Source: pinpoint/templates/})
    resource = YAML.safe_load(document)
    next unless resource.is_a?(Hash) && %w[Deployment StatefulSet Job].include?(resource['kind'])
    spec = resource.fetch('spec').fetch('template').fetch('spec')
    [*spec['containers'], *spec['initContainers']].each do |container|
      %w[requests limits].each do |budget|
        %w[cpu memory].each do |dimension|
          raise "#{resource.dig('metadata', 'name')}/#{container['name']}: missing #{budget}.#{dimension}" unless container.dig('resources', budget, dimension)
        end
      end
    end
  end
end
RUBY

# NetworkPolicy egress must remain a list with/without optional download rules.
# Lint accepts a valid YAML object here, but the Kubernetes API rejects it.
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set networkPolicy.enabled=true --show-only templates/networkpolicy.yaml \
  > "${render_dir}/network-downloads.yaml"
helm template services "${chart_dir}" --namespace pinpoint \
  -f "${chart_dir}/examples/local-production/services.yaml" \
  --show-only templates/networkpolicy.yaml > "${render_dir}/network-no-downloads.yaml"
python3 - "${render_dir}/network-downloads.yaml" "${render_dir}/network-no-downloads.yaml" <<'PY'
from pathlib import Path
import sys
for filename in sys.argv[1:]:
    lines = Path(filename).read_text().splitlines()
    for index, line in enumerate(lines):
        if line == '  egress:':
            following = next(value for value in lines[index + 1:] if value.strip())
            assert following.startswith('    - '), f'{filename}: egress must be a list'
assert '-asset-downloads' in Path(sys.argv[1]).read_text()
assert '-asset-downloads' not in Path(sys.argv[2]).read_text()
PY

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  -f "${chart_dir}/values-production.yaml" \
  -f "${chart_dir}/examples/local-production/application.yaml" \
  > "${render_dir}/local-production-application.yaml"
test "$(grep -c '^kind: Deployment$' "${render_dir}/local-production-application.yaml")" -eq 2
if grep -q '^kind: StatefulSet$' "${render_dir}/local-production-application.yaml"; then
  echo "The production application example unexpectedly provisions bundled backends" >&2
  exit 1
fi

# Dependency role overrides must actually bound the JVMs; a root Kafka
# heapOpts alone is ignored by its controller/broker defaults.
test "$(grep -A 1 'name: KAFKA_HEAP_OPTS' "${render_dir}/metric.yaml" | grep -c 'value: "-Xms512m -Xmx1g"')" -eq 2
grep -A 1 'name: ZOO_HEAP_SIZE' "${render_dir}/metric.yaml" | grep -q 'value: "512"'
grep -A 1 'name: JAVA_TOOL_OPTIONS' "${render_dir}/metric.yaml" | grep -q 'value: "-Xms512m -Xmx2g"'
grep -A 1 'name: JAVA_TOOL_OPTIONS' "${render_dir}/metric.yaml" | grep -q 'value: "-Xms512m -Xmx1536m"'

# Old HBase ZooKeeper clients need stable per-member IPs across pod rollouts.
test "$(grep -c 'name: pinpoint-zookeeper-client-[0-9]$' "${render_dir}/metric.yaml")" -eq 3
grep -q 'pinpoint-zookeeper-client-0.pinpoint.svc.cluster.local' "${render_dir}/metric.yaml"
grep -q 'statefulset.kubernetes.io/pod-name: pinpoint-zookeeper-2' "${render_dir}/metric.yaml"
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/hbase-config.yaml > "${render_dir}/hbase-config.yaml"
if grep -q 'pinpoint-zookeeper-0.pinpoint-zookeeper-headless' "${render_dir}/hbase-config.yaml"; then
  echo "HBase unexpectedly connects directly to a replaceable ZooKeeper pod IP" >&2
  exit 1
fi

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-job-mysql.yaml > "${render_dir}/mysql-init.yaml"
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-config-mysql.yaml > "${render_dir}/mysql-init-config.yaml"
# Helm accepts arbitrary metadata keys; ensure the executable is ConfigMap data.
awk '/^data:/ {in_data=1} in_data && /^  initialize-mysql.sh:/ {found=1} END {exit !found}' \
  "${render_dir}/mysql-init-config.yaml"
sh -n "${chart_dir}/files/initialize-mysql.sh"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-job-pinot.yaml > "${render_dir}/pinot-init.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-config-pinot.yaml > "${render_dir}/pinot-init-config.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.pinot.createTables=false > "${render_dir}/operator-managed-pinot.yaml"
if grep -q 'name: pinpoint-pinot-init' "${render_dir}/operator-managed-pinot.yaml"; then
  echo "Operator-managed Pinot unexpectedly renders init resources" >&2
  exit 1
fi

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.pinot.tableReplicas=3 --set pinot.server.replicaCount=3 \
  --set global.kafka.topicReplicationFactor=3 \
  --set global.pinot.initImage.repository=example/python \
  --set global.pinot.initImage.tag=custom-python \
  > "${render_dir}/replicated-metric.yaml"
grep -A 1 'name: PINOT_TABLE_REPLICAS' "${render_dir}/replicated-metric.yaml" | grep -q 'value: "3"'
grep -A 1 'name: TOPIC_REPLICATION_FACTOR' "${render_dir}/replicated-metric.yaml" | grep -q 'value: "3"'
grep -q 'image: "example/python:custom-python"' "${render_dir}/replicated-metric.yaml"

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
  --set global.kafka.bootstrapServers=kafka.external.example:9092

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set redis.enabled=false \
  --set global.redis.host=redis.external.example \
  --set global.redis.port=6380 \
  --set global.redis.username=pinpoint \
  --set global.redis.passwordSecret.name=external-redis \
  --set global.redis.passwordSecret.key=password \
  --set kafka.enabled=false \
  --set global.kafka.bootstrapServers=kafka.external.example:9092 > "${render_dir}/external-services.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/init-job-kafka.yaml \
  --set kafka.enabled=false \
  --set global.kafka.bootstrapServers=kafka.external.example:9092 \
  --set global.kafka.manageExternalTopics=true \
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

# External relational databases must not render MySQL resources or init hooks.
# Exercise both consumers (Web and Batch) through the classic profile.
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.metric.enabled=false \
  --set mysql.enabled=false \
  --set global.datasource.jdbcUrl='jdbc:mysql://mysql.external.example:3306/pinpoint?sslMode=VERIFY_IDENTITY' \
  --set global.datasource.username=pinpoint_external \
  --set global.datasource.passwordSecret.name=external-db \
  --set global.datasource.passwordSecret.key=db-password \
  > "${render_dir}/external-mysql.yaml"

# A custom JDBC driver can be passed to custom application images. This checks
# configuration wiring only; stock Pinpoint SQL is not PostgreSQL compatible.
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.metric.enabled=false \
  --set mysql.enabled=false \
  --set global.datasource.jdbcUrl='jdbc:postgresql://postgres.external.example:5432/pinpoint' \
  --set global.datasource.driverClassName=org.postgresql.Driver \
  --set global.datasource.username=pinpoint_external \
  --set global.datasource.passwordSecret.name=external-db \
  --set global.datasource.passwordSecret.key=db-password \
  --set web.image.repository=example/pinpoint-web-postgresql \
  --set batch.image.repository=example/pinpoint-batch-postgresql \
  > "${render_dir}/custom-jdbc.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set web.image.tag=3.1.1-metric \
  --set collector.image.tag=custom-collector \
  --set pinot.image.repository=example/pinot \
  --set pinot.image.tag=custom-pinot \
  > "${render_dir}/explicit-images.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/web.yaml \
  --set web.login.enabled=true \
  --set web.login.existingSecret=pinpoint-login \
  --set web.login.userKey=users \
  > "${render_dir}/web-login.yaml"

helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.metric.enabled=false --set mysql.auth.existingSecret=mysql-credentials \
  --show-only templates/web.yaml --show-only templates/batch.yaml \
  --show-only templates/init-job-mysql.yaml \
  > "${render_dir}/mysql-existing-secret.yaml"
test "$(grep -c 'name: "mysql-credentials"' "${render_dir}/mysql-existing-secret.yaml")" -eq 9
if grep -A 1 'secretKeyRef:' "${render_dir}/mysql-existing-secret.yaml" | grep -q 'name: pinpoint-mysql\|name: "pinpoint-mysql"'; then
  echo "Bundled MySQL references its generated Secret instead of mysql.auth.existingSecret" >&2
  exit 1
fi

# The production application tier must not create or modify external backends.
helm lint "${chart_dir}" -f "${chart_dir}/values-production.yaml"
helm template pinpoint "${chart_dir}" --namespace production \
  -f "${chart_dir}/values-production.yaml" > "${render_dir}/production.yaml"
if grep -Eq '# Source: pinpoint/charts/|kind: StatefulSet|kind: Job|name: wait-for-' "${render_dir}/production.yaml"; then
  echo "External production profile unexpectedly deploys or bootstraps backends" >&2
  exit 1
fi
test "$(grep -c '^kind: Deployment$' "${render_dir}/production.yaml")" -eq 2
test "$(grep -c '^kind: PodDisruptionBudget$' "${render_dir}/production.yaml")" -eq 2
test "$(grep -c 'whenUnsatisfiable: DoNotSchedule' "${render_dir}/production.yaml")" -eq 2
test "$(grep -c 'name: HBASE_CLIENT_HOST' "${render_dir}/production.yaml")" -eq 2
test "$(grep -c 'value: "hbase-zk-1.example.internal,hbase-zk-2.example.internal,hbase-zk-3.example.internal"' "${render_dir}/production.yaml")" -eq 2
# Operators allocate Znode claim paths at runtime. Kubernetes expands the
# suffix after loading the discovery env, without an API-reading sidecar.
helm template pinpoint "${chart_dir}" --namespace production \
  -f "${chart_dir}/values-production.yaml" \
  --set global.hbase.zookeeperQuorum= \
  --set global.hbase.discoveryConfigMap.name=pinpoint-storage-hbase-znode \
  --set global.hbase.discoveryConfigMap.znodeSuffix=/hbase \
  > "${render_dir}/operator-hbase.yaml"
test "$(grep -c 'name: HBASE_DISCOVERY_ZNODE' "${render_dir}/operator-hbase.yaml")" -eq 2
test "$(grep -c 'value: "$(HBASE_DISCOVERY_ZNODE)/hbase"' "${render_dir}/operator-hbase.yaml")" -eq 2
test "$(grep -c 'key: "ZOOKEEPER_HOSTS"' "${render_dir}/operator-hbase.yaml")" -eq 2
helm template telemetry "${chart_dir}" --namespace production \
  -f "${chart_dir}/values-production.yaml" > "${render_dir}/production-custom-release.yaml"
test "$(grep -c 'app.kubernetes.io/instance: telemetry' "${render_dir}/production-custom-release.yaml")" -ge 10
if grep -q 'app.kubernetes.io/instance: pinpoint$' "${render_dir}/production-custom-release.yaml"; then
  echo "Production placement selectors do not follow custom release name" >&2
  exit 1
fi
# Opt-in external Pinot initialization uses the supplied endpoint and creates no Pinot pods.
helm template pinpoint "${chart_dir}" -f "${chart_dir}/values-production.yaml" \
  --set global.pinot.createTables=true --set global.pinot.manageExternalTables=true \
  --set global.pinot.controllerUrl=http://pinot.external:9000 \
  --set global.pinot.tableReplicas=3 > "${render_dir}/external-pinot-init.yaml"
grep -A 1 'name: PINOT_CONTROLLER_URL' "${render_dir}/external-pinot-init.yaml" | grep -q 'value: "http://pinot.external:9000"'
if grep -q 'name: wait-for-pinot' "${render_dir}/external-pinot-init.yaml"; then
  echo "External Pinot initializer waits for a bundled controller" >&2
  exit 1
fi
# Classic consumers must receive external HBase and coordination settings too.
helm template pinpoint "${chart_dir}" -f "${chart_dir}/values-production.yaml" \
  --set global.metric.enabled=false > "${render_dir}/external-classic.yaml"
test "$(grep -c 'name: HBASE_CLIENT_HOST' "${render_dir}/external-classic.yaml")" -eq 4
if grep -Eq 'value: .*pinpoint-zookeeper|until nc .*pinpoint-zookeeper' "${render_dir}/external-classic.yaml"; then
  echo "Classic consumers still reference the bundled ZooKeeper" >&2
  exit 1
fi

# Users should be able to choose a release name other than "pinpoint".
helm template observability "${chart_dir}" --namespace telemetry \
  > "${render_dir}/custom-release.yaml"
helm template observability "${chart_dir}" --namespace telemetry \
  --set global.metric.enabled=false > "${render_dir}/custom-release-classic.yaml"
grep -q 'controller.zk.str=observability-zookeeper:2181' "${render_dir}/custom-release.yaml"
grep -q '"-zkAddress", "observability-zookeeper:2181"' "${render_dir}/custom-release.yaml"
grep -A 1 'name: HBASE_CLIENT_HOST' "${render_dir}/custom-release.yaml" | grep -q 'observability-zookeeper-client-0.telemetry.svc.cluster.local'
grep -q 'until nc -z -w3 observability-zookeeper 2181' "${render_dir}/custom-release.yaml"
grep -q 'until nc -z -w3 observability-pinpoint-flink-jobmanager 8081' "${render_dir}/custom-release-classic.yaml"
grep -q 'value: "http://observability-pinpoint-web:8080"' "${render_dir}/custom-release-classic.yaml"
if grep -Eq 'pinpoint-zookeeper:2181|observability-pinpoint-zookeeper' "${render_dir}/custom-release.yaml"; then
  echo "Custom release unexpectedly references the wrong shared ZooKeeper service" >&2
  exit 1
fi
helm template observability "${chart_dir}" --namespace telemetry \
  --set pinot.zookeeper.urlOverride=custom-zookeeper:2181 \
  > "${render_dir}/pinot-zookeeper-override.yaml"
grep -q 'controller.zk.str=custom-zookeeper:2181' "${render_dir}/pinot-zookeeper-override.yaml"

for file in external-mysql custom-jdbc; do
  if grep -Eq '# Source: pinpoint/charts/mysql/|name: .*mysql-init|name: wait-for-mysql' "${render_dir}/${file}.yaml"; then
    echo "External datasource unexpectedly renders bundled MySQL or an init hook" >&2
    exit 1
  fi
  # Web/Batch primary, legacy, metadata plus Collector primary/metadata use the Secret.
  test "$(grep -c 'name: external-db' "${render_dir}/${file}.yaml")" -eq 8
  test "$(grep -c 'key: db-password' "${render_dir}/${file}.yaml")" -eq 8
done
grep -q 'sslMode=VERIFY_IDENTITY' "${render_dir}/external-mysql.yaml"
test "$(grep -c 'value: "org.postgresql.Driver"' "${render_dir}/custom-jdbc.yaml")" -eq 8
test "$(grep -c 'name: SPRING_DATASOURCE_HIKARI_DRIVERCLASSNAME' "${render_dir}/custom-jdbc.yaml")" -eq 3
test "$(grep -c 'name: SPRING_METADATASOURCE_HIKARI_DRIVERCLASSNAME' "${render_dir}/custom-jdbc.yaml")" -eq 3
test "$(grep -c 'name: SPRING_DATASOURCE_HIKARI_JDBCURL' "${render_dir}/custom-jdbc.yaml")" -eq 3
grep -q 'pinpointdocker/pinpoint-web:3.1.1-metric"' "${render_dir}/explicit-images.yaml"
grep -q 'pinpointdocker/pinpoint-collector:custom-collector"' "${render_dir}/explicit-images.yaml"
grep -q 'image: "example/pinot:custom-pinot"' "${render_dir}/explicit-images.yaml"
if grep -q 'metric-metric\|custom-collector-metric\|apachepinot/pinot:' "${render_dir}/explicit-images.yaml"; then
  echo "An explicit application or Pinot image override was not honored" >&2
  exit 1
fi
grep -q 'value: "basicLogin"' "${render_dir}/web-login.yaml"
grep -q 'key: "users"' "${render_dir}/web-login.yaml"
grep -q 'key: "admin"' "${render_dir}/web-login.yaml"
grep -q 'key: "jwt-secret"' "${render_dir}/web-login.yaml"
test "$(grep -c 'name: "pinpoint-login"' "${render_dir}/web-login.yaml")" -eq 3
grep -A 1 'name: WEB_SECURITY_AUTH_JWT_COOKIE_HTTP_ONLY' "${render_dir}/web-login.yaml" | grep -q 'value: "true"'
grep -A 1 'name: WEB_SECURITY_AUTH_JWT_COOKIE_SECURE' "${render_dir}/web-login.yaml" | grep -q 'value: "true"'
grep -A 1 'name: WEB_SECURITY_AUTH_JWT_COOKIE_SAME_SITE' "${render_dir}/web-login.yaml" | grep -q 'value: "Lax"'

# Verify failures include the intended validation message rather than merely
# failing because a dependency or template is broken.
expect_render_failure() {
  local expected="$1"
  shift
  if helm template pinpoint "${chart_dir}" --namespace pinpoint "$@" > "${render_dir}/invalid-config.yaml" 2>&1; then
    echo "Invalid configuration unexpectedly rendered: ${expected}" >&2
    exit 1
  fi
  grep -Fq "${expected}" "${render_dir}/invalid-config.yaml"
}
expect_render_failure 'global.zookeeper.address is required' --set zookeeper.enabled=false
expect_render_failure 'global.hbase.zookeeperQuorum is required' --set hbase.enabled=false
expect_render_failure 'set hbase.enabled=false' --set global.hbase.discoveryConfigMap.name=discovery
expect_render_failure 'Set either global.hbase.discoveryConfigMap.name' --set hbase.enabled=false --set global.hbase.discoveryConfigMap.name=discovery --set global.hbase.zookeeperQuorum=zk
expect_render_failure 'global.hbase.discoveryConfigMap.quorumKey is required' --set hbase.enabled=false --set global.hbase.discoveryConfigMap.name=discovery --set-string global.hbase.discoveryConfigMap.quorumKey=
expect_render_failure 'znodeSuffix must be empty or an absolute path suffix' --set hbase.enabled=false --set global.hbase.discoveryConfigMap.name=discovery --set global.hbase.discoveryConfigMap.znodeSuffix=relative
expect_render_failure 'global.hbase.zookeeperQuorum is required' --set zookeeper.enabled=false --set global.zookeeper.address=zk:2181
expect_render_failure 'global.pinot.jdbcUrl is required' --set pinot.enabled=false
expect_render_failure 'global.pinot.controllerUrl is required' --set pinot.enabled=false \
  --set global.pinot.jdbcUrl=jdbc:pinot://external:9000 --set global.pinot.manageExternalTables=true
expect_render_failure 'web.pdb requires at least two replicas' --set web.pdb.enabled=true
expect_render_failure 'collector.pdb requires exactly one' --set collector.replicaCount=2 \
  --set collector.pdb.enabled=true --set collector.pdb.maxUnavailable=1
expect_render_failure 'minAvailable' --set collector.replicaCount=2 \
  --set collector.pdb.enabled=true --set collector.pdb.minAvailable=invalid
expect_render_failure 'replicaCount' --set web.replicaCount=1.5
expect_render_failure 'topologySpreadWhenUnsatisfiable' --set web.topologySpreadWhenUnsatisfiable=invalid
expect_render_failure 'global.datasource.pool requires' --set global.datasource.pool.minimumIdle=11
expect_render_failure 'connectionTimeout' --set global.datasource.pool.connectionTimeout=100
expect_render_failure 'Bundled HBase initializes the default namespace only' --set global.hbase.namespace=custom
expect_render_failure 'mysql.auth.database must contain only' --set mysql.auth.database=invalid-database
expect_render_failure 'web.login.existingSecret is required' --set web.login.enabled=true
expect_render_failure 'web.login.jwtSecretKey is required' \
  --set web.login.enabled=true --set web.login.existingSecret=pinpoint-login --set-string web.login.jwtSecretKey=
expect_render_failure 'web.login.userKey or web.login.adminKey is required' \
  --set web.login.enabled=true --set web.login.existingSecret=pinpoint-login --set-string web.login.adminKey=
expect_render_failure 'web.login.cookie.sameSite must be' \
  --set web.login.enabled=true --set web.login.existingSecret=pinpoint-login --set web.login.cookie.sameSite=invalid
expect_render_failure 'web.login.cookie.secure must be true' \
  --set web.login.enabled=true --set web.login.existingSecret=pinpoint-login \
  --set web.login.cookie.sameSite=None --set web.login.cookie.secure=false
expect_render_failure 'global.datasource.jdbcUrl is required' --set mysql.enabled=false
expect_render_failure 'global.datasource.username is required' \
  --set mysql.enabled=false --set global.datasource.jdbcUrl=jdbc:mysql://external:3306/pinpoint
expect_render_failure 'global.datasource.password or global.datasource.passwordSecret is required' \
  --set mysql.enabled=false --set global.datasource.jdbcUrl=jdbc:mysql://external:3306/pinpoint \
  --set global.datasource.username=pinpoint
expect_render_failure "Both 'global.datasource.password' and 'global.datasource.passwordSecret' are set" \
  --set global.datasource.password=inline-password \
  --set global.datasource.passwordSecret.name=external-db --set global.datasource.passwordSecret.key=password
expect_render_failure 'global.datasource.passwordSecret.key is required' \
  --set global.datasource.passwordSecret.name=external-db
expect_render_failure 'ZooKeeper client authentication is unsupported' --set zookeeper.auth.enabled=true
expect_render_failure 'ZooKeeper client authentication is unsupported' \
  --set zookeeper.auth.client.enabled=true \
  --set zookeeper.auth.client.clientUser=pinpoint --set zookeeper.auth.client.clientPassword=test-password \
  --set zookeeper.auth.client.serverUsers=pinpoint --set zookeeper.auth.client.serverPasswords=test-password
expect_render_failure 'zookeeper.tls.client.enabled is unsupported' \
  --set zookeeper.tls.client.enabled=true --set zookeeper.tls.client.autoGenerated=true
expect_render_failure 'kafka.listeners.client.protocol must be PLAINTEXT' --set kafka.listeners.client.protocol=SASL_SSL
expect_render_failure 'kafka.auth is a legacy configuration' --set kafka.auth.clientProtocol=SASL_SSL
expect_render_failure 'kafka.auth is a legacy configuration' --set kafka.auth.interBrokerProtocol=SASL_SSL
expect_render_failure 'kafka.auth is a legacy configuration' --set kafka.auth.sasl.enabled=true
expect_render_failure 'global.kafka.securityProtocol must be PLAINTEXT' \
  --set kafka.enabled=false --set global.kafka.bootstrapServers=external:9093 \
  --set global.kafka.securityProtocol=SASL_SSL
expect_render_failure 'pinot.zookeeper.auth.enabled is unsupported' \
  --set pinot.zookeeper.enabled=true --set pinot.zookeeper.auth.enabled=true
expect_render_failure 'tableReplicas' --set global.pinot.tableReplicas=0
expect_render_failure 'tableReplicas' --set global.pinot.tableReplicas=1.5
expect_render_failure 'global.pinot.tableReplicas cannot exceed pinot.server.replicaCount' --set global.pinot.tableReplicas=2
expect_render_failure 'topicReplicationFactor' --set global.kafka.topicReplicationFactor=0
expect_render_failure 'topicReplicationFactor' --set global.kafka.topicReplicationFactor=1.5
expect_render_failure 'No bundled Pinot definitions' --set global.pinpointVersion=9.9.9
expect_render_failure 'maximumPoolSize' --set global.datasource.pool.maximumPoolSize=10.5
expect_render_failure 'minimumIdle' --set global.datasource.pool.minimumIdle=2.5
expect_render_failure 'connectionTimeout' --set global.datasource.pool.connectionTimeout=5000.5
expect_render_failure 'clientPort' --set global.hbase.clientPort=2181.5
expect_render_failure 'port' --set global.redis.port=65536
expect_render_failure 'enabled' --set-string web.enabled=false
expect_render_failure 'minAvailable' --set web.replicaCount=2 --set web.pdb.enabled=true --set web.pdb.minAvailable=101%
helm template pinpoint "${chart_dir}" --show-only templates/pdb.yaml \
  --set web.replicaCount=2 --set web.pdb.enabled=true --set web.pdb.minAvailable=0 \
  > "${render_dir}/pdb-zero.yaml"
grep -q 'minAvailable: 0' "${render_dir}/pdb-zero.yaml"
helm template pinpoint "${chart_dir}" --show-only templates/pdb.yaml \
  --set web.replicaCount=2 --set web.pdb.enabled=true --set web.pdb.minAvailable=null --set web.pdb.maxUnavailable=0 \
  > "${render_dir}/pdb-zero-unavailable.yaml"
grep -q 'maxUnavailable: 0' "${render_dir}/pdb-zero-unavailable.yaml"
helm template pinpoint "${chart_dir}" --show-only templates/pdb.yaml \
  --set web.replicaCount=2 --set web.pdb.enabled=true --set web.pdb.minAvailable=50% \
  > "${render_dir}/pdb-percentage.yaml"
grep -q 'minAvailable: 50%' "${render_dir}/pdb-percentage.yaml"

grep -q 'volumeClaimTemplates:' "${render_dir}/hbase-persistent.yaml"
grep -q 'host: "pinpoint.localdev.me"' "${render_dir}/web-ingress.yaml"
grep -q 'path: "/"' "${render_dir}/web-ingress.yaml"

if grep -q 'volumeClaimTemplates:' "${render_dir}/hbase-ephemeral.yaml"; then
  echo "HBase ephemeral render unexpectedly contains volumeClaimTemplates" >&2
  exit 1
fi

grep -q 'emptyDir: {}' "${render_dir}/hbase-ephemeral.yaml"
grep -q 'storageClassName: "fast-ssd"' "${render_dir}/hbase-storage-class.yaml"
grep -q 'kubernetes.io/arch: amd64' "${render_dir}/hbase-persistent.yaml"
grep -q 'kubernetes.io/os: linux' "${render_dir}/hbase-persistent.yaml"
grep -q 'startupProbe:' "${render_dir}/hbase-persistent.yaml"
grep -q 'terminationGracePeriodSeconds: 300' "${render_dir}/hbase-persistent.yaml"
grep -q '/opt/pinpoint-hbase/start.sh' "${render_dir}/hbase-persistent.yaml"
if grep -q 'type: LoadBalancer' "${render_dir}/metric.yaml"; then
  echo "Default chart unexpectedly exposes a LoadBalancer and blocks hooks without external IPs" >&2
  exit 1
fi
if grep -q 'download-sql-scripts\|raw.githubusercontent.com' "${render_dir}/mysql-init.yaml"; then
  echo "MySQL bootstrap still depends on network asset downloads" >&2
  exit 1
fi
grep -A 1 '^      spec:' "${render_dir}/hbase-persistent.yaml" | grep -q 'accessModes:'
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --set global.metric.enabled=false --set agent.enabled=true --set quickstart.enabled=true \
  --show-only templates/hbase.yaml --show-only templates/agent.yaml \
  --show-only templates/quickstart.yaml --show-only templates/flink.yaml \
  > "${render_dir}/amd64-workloads.yaml"
test "$(grep -c 'kubernetes.io/arch: amd64' "${render_dir}/amd64-workloads.yaml")" -eq 5
helm template pinpoint "${chart_dir}" --namespace pinpoint \
  --show-only templates/hbase.yaml --set hbase.image.repository=example/arm64-hbase \
  --set 'hbase.nodeSelector.kubernetes\.io/arch=arm64' \
  > "${render_dir}/custom-hbase-architecture.yaml"
grep -q 'kubernetes.io/arch: arm64' "${render_dir}/custom-hbase-architecture.yaml"
grep -q 'example/arm64-hbase:3.1.1' "${render_dir}/custom-hbase-architecture.yaml"

grep -q 'pinpointdocker/pinpoint-web:3.1.1-metric' "${render_dir}/metric.yaml"
grep -q 'pinpointdocker/pinpoint-collector:3.1.1-metric' "${render_dir}/metric.yaml"
grep -q 'pinpointdocker/pinpoint-hbase:3.1.1' "${render_dir}/metric.yaml"
grep -q 'pinpointdocker/pinpoint-flink:3.0.3' "${render_dir}/classic.yaml"
grep -q 'apachepinot/pinot:1.3.0' "${render_dir}/metric.yaml"
grep -q 'name: pinpoint-mysql-init-sql' "${render_dir}/mysql-init.yaml"
grep -q 'image: "python:3.12.12-slim-bookworm"' "${render_dir}/pinot-init.yaml"
grep -q 'python3.*initialize-pinot.py' "${render_dir}/pinot-init.yaml"
helm template pinpoint "${chart_dir}" --show-only templates/telegraf.yaml --show-only templates/telegraf-config.yaml > "${render_dir}/telegraf.yaml"
grep -q 'http://pinpoint-collector:15200/telegraf' "${render_dir}/telegraf.yaml"
if grep -q 'download-pinpoint-telegraf-configuration' "${render_dir}/telegraf.yaml"; then exit 1; fi
grep -q 'pinot-inspector-stat-application-schema.json:' "${render_dir}/pinot-init-config.yaml"
test "$(grep -c '^  pinot-.*\.json: |' "${render_dir}/pinot-init-config.yaml")" -eq 20
grep -q 'pinot-inspector-stat-agent-offline-table.json:' "${render_dir}/pinot-init-config.yaml"
if grep -q 'raw.githubusercontent.com\|pinot-admin.sh\|EXISTING_TABLES' "${render_dir}/pinot-init.yaml"; then
  echo "Pinot initialization still downloads configs or uses count-based detection" >&2
  exit 1
fi
grep -q 'name: pinpoint-telegraf-config' "${render_dir}/telegraf.yaml"
grep -q 'targetPort: 9995' "${render_dir}/metric.yaml"
grep -q 'post-install,post-upgrade' "${render_dir}/mysql-init.yaml"
grep -q 'initialize-mysql.sh' "${render_dir}/mysql-init.yaml"
sh -n "${chart_dir}/files/initialize-mysql.sh"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-web:3.1.1' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-collector:3.1.1' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-hbase:3.1.1' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-agent:3.1.1' "${render_dir}/custom-registry.yaml"
grep -q 'registry.example.com/mirror/pinpointdocker/pinpoint-batch:3.1.1' "${render_dir}/custom-registry.yaml"
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
grep -q 'values: \[web, collector, batch, mysql-init\]' "${render_dir}/network-policy-enabled.yaml"
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
grep -q 'bitnamilegacy/kafka:4.0.0-debian-12-r10' "${render_dir}/external-kafka-init.yaml"
grep -q '/opt/bitnami/kafka/bin/kafka-topics.sh' "${render_dir}/external-kafka-init.yaml"
grep -q 'post-install,post-upgrade' "${render_dir}/external-kafka-init.yaml"
grep -q 'post-install,post-upgrade' "${render_dir}/pinot-init.yaml"
for job in mysql-init pinot-init external-kafka-init; do
  grep -q 'before-hook-creation,hook-succeeded' "${render_dir}/${job}.yaml"
  if grep -q 'ttlSecondsAfterFinished:\|helm.sh/hook-timeout' "${render_dir}/${job}.yaml"; then
    echo "Init job discards failed diagnostics or relies on a nonstandard hook timeout" >&2
    exit 1
  fi
done
grep -q 'name: wait-for-redis' "${render_dir}/metric.yaml"
grep -q 'name: wait-for-kafka' "${render_dir}/metric.yaml"

if grep -q 'confluentinc/cp-kafka' "${render_dir}/metric.yaml"; then
  echo "Kafka initialization unexpectedly uses a second Kafka distribution" >&2
  exit 1
fi

if grep -q 'name: wait-for-redis' "${render_dir}/external-services.yaml"; then
  echo "External Redis unexpectedly blocks application startup" >&2
  exit 1
fi

if grep -q 'name: wait-for-kafka' "${render_dir}/external-services.yaml"; then
  echo "External Kafka unexpectedly blocks application startup" >&2
  exit 1
fi

if grep -q '# Source: pinpoint/charts/redis/' "${render_dir}/external-services.yaml"; then
  echo "External-services render unexpectedly contains bundled Redis resources" >&2
  exit 1
fi

if grep -q '# Source: pinpoint/charts/kafka/' "${render_dir}/external-services.yaml"; then
  echo "External-services render unexpectedly contains bundled Kafka resources" >&2
  exit 1
fi

if grep -q 'name: pinpoint-kafka-init' "${render_dir}/external-services.yaml"; then
  echo "External Kafka topic management unexpectedly enabled without opt-in" >&2
  exit 1
fi

if grep -q 'Pinot init job is waiting for Kafka' "${render_dir}/pinot-init.yaml"; then
  echo "Pinot initialization unexpectedly blocks on Kafka availability" >&2
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
grep -q 'Chart 3.1.2' "${render_dir}/pages/index.html"
grep -q 'Pinpoint 3.1.1' "${render_dir}/pages/index.html"
test -f "${render_dir}/pages/.nojekyll"

if grep -q '__[A-Z_]*__' "${render_dir}/pages/index.html"; then
  echo "Rendered Pages site still contains template placeholders" >&2
  exit 1
fi

# Check what downstream users receive: all locked dependencies must be bundled
# in the archive, and it must render without another dependency download.
helm package "${chart_dir}" --destination "${render_dir}"
chart_package="${render_dir}/pinpoint-3.1.2.tgz"
test -f "${chart_package}"
helm lint "${chart_package}"
helm template observability "${chart_package}" --namespace telemetry \
  > "${render_dir}/packaged.yaml"
grep -q 'pinpointdocker/pinpoint-web:3.1.1-metric' "${render_dir}/packaged.yaml"
grep -q 'controller.zk.str=observability-zookeeper:2181' "${render_dir}/packaged.yaml"
tar -tf "${chart_package}" > "${render_dir}/package-files.txt"
test "$(grep -c 'files/pinot/3.1.1/.*\.json$' "${render_dir}/package-files.txt")" -eq 20
grep -q 'files/initialize-pinot.py$' "${render_dir}/package-files.txt"
if grep -Eq '^pinpoint/(docs|backends|examples|scripts)/|/\.(aws|codex|agents|git|github|venv)/|/__pycache__/|\.pyc$|^pinpoint/(lazygit|\.env[^/]*|values\..*local\.yaml|secrets[^/]*\.yaml)$|kubeconfig' "${render_dir}/package-files.txt"; then
  echo "Packaged chart contains development files, local configuration or Python cache" >&2
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 "${chart_dir}/scripts/test-initialization.py"
bash "${chart_dir}/scripts/validate-hbase-backend.sh"

echo "Helm lint and render validation passed."
