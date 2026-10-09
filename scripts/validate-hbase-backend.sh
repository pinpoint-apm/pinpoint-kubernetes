#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
backend="$root/backends/hbase-stackable"
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
helm lint "$backend" --set storageClass=validated-ssd
helm template telemetry "$backend" --namespace telemetry --set storageClass=validated-ssd > "$temp/backend.yaml"
test "$(grep -c '^kind: ZookeeperZnode$' "$temp/backend.yaml")" -eq 2
test "$(grep -c 'requiredDuringSchedulingIgnoredDuringExecution:' "$temp/backend.yaml")" -eq 6
test "$(grep -c 'storageClass: validated-ssd' "$temp/backend.yaml")" -eq 4
test "$(grep -c 'podDisruptionBudget: {enabled: true, maxUnavailable: 1}' "$temp/backend.yaml")" -eq 6
test "$(grep -c 'helm.sh/resource-policy: keep' "$temp/backend.yaml")" -eq 5
grep -q 'dfsReplication: 3' "$temp/backend.yaml"
grep -q 'hdfsStorageType: Disk' "$temp/backend.yaml"
grep -q 'serverSecretClass: null' "$temp/backend.yaml"
grep -q 'quorumSecretClass: tls' "$temp/backend.yaml"
grep -q 'cluster-internal' "$temp/backend.yaml"
grep -q 'telemetry-storage-hbase-znode' "$temp/backend.yaml"
helm template telemetry "$backend" --namespace telemetry --set storageClass=validated-ssd \
  --show-only templates/networkpolicy.yaml > "$temp/network-same-namespace.yaml"
grep -q 'kubernetes.io/metadata.name: "telemetry"' "$temp/network-same-namespace.yaml"
helm template telemetry "$backend" --namespace telemetry --set storageClass=validated-ssd \
  --set networkPolicy.operatorNamespace=platform-operators \
  --show-only templates/networkpolicy.yaml > "$temp/network-other-namespace.yaml"
grep -q 'kubernetes.io/metadata.name: "platform-operators"' "$temp/network-other-namespace.yaml"
helm template very-long-release-name-with-many-characters "$backend" --set storageClass=validated-ssd > "$temp/long.yaml"
awk '/^  name:/ {if (length($2) > 63) exit 1}' "$temp/long.yaml"
helm template test "$backend" --set storageClass=validated-ssd \
  --set hbase.customImage=registry.example/hbase:qualified \
  --set imagePullSecrets[0].name=registry-credentials > "$temp/custom-image.yaml"
test "$(grep -c 'registry.example/hbase:qualified' "$temp/custom-image.yaml")" -eq 2
test "$(grep -c 'registry-credentials' "$temp/custom-image.yaml")" -eq 4
test "$(grep -c "^create '" "$backend/files/hbase-create.hbase")" -eq 22
for invalid in '' 'zookeeper.replicas=2' 'hdfs.nameNodes.replicas=1' 'hdfs.journalNodes.replicas=2' 'hdfs.dataNodes.replicas=2' 'hbase.masters.replicas=1' 'hbase.regionServers.replicas=1' 'hdfs.replication=1' 'hdfs.replication=3.5' 'bootstrap.readyTimeoutSeconds=0' 'bootstrap.readyTimeoutSeconds=1800'; do
  args=()
  if [[ -n "$invalid" ]]; then args=(--set storageClass=validated-ssd --set "$invalid"); fi
  if helm template test "$backend" "${args[@]}" > "$temp/invalid.yaml" 2>&1; then
    echo "Unsafe HA backend settings were accepted: $invalid" >&2
    exit 1
  fi
done
ruby "$root/scripts/test-hbase-schema.rb"
helm package "$backend" --destination "$temp"
helm lint "$temp/pinpoint-hbase-stackable-0.1.1.tgz" --set storageClass=validated-ssd
echo "HA backend render and packaging checks passed. Runtime HA qualification is separate."
