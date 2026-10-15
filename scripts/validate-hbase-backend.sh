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
test "$(grep -c 'argocd.argoproj.io/sync-options: ServerSideApply=true' "$temp/backend.yaml")" -eq 5
grep -q 'dfsReplication: 3' "$temp/backend.yaml"
grep -q 'hdfsStorageType: Disk' "$temp/backend.yaml"
grep -q 'serverSecretClass: null' "$temp/backend.yaml"
grep -q 'quorumSecretClass: tls' "$temp/backend.yaml"
grep -q 'hbase.split.writer.creation.bounded: "true"' "$temp/backend.yaml"
grep -q 'hbase.regionserver.hlog.splitlog.writer.threads: "2"' "$temp/backend.yaml"
grep -q 'hbase.regionserver.wal.max.splitters: "1"' "$temp/backend.yaml"
helm template telemetry "$backend" --namespace telemetry --set storageClass=validated-ssd \
  --set-string 'hbase.regionServers.configOverrides.hbase-site\.xml.hbase\.regionserver\.hlog\.splitlog\.writer\.threads=4' \
  --set-string 'hbase.masters.configOverrides.hbase-site\.xml.hbase\.master\.namespace\.init\.timeout=1800000' \
  --show-only templates/hbase.yaml > "$temp/hbase-overrides.yaml"
grep -q 'hbase.regionserver.hlog.splitlog.writer.threads: "4"' "$temp/hbase-overrides.yaml"
grep -q 'hbase.master.namespace.init.timeout: "1800000"' "$temp/hbase-overrides.yaml"
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
# Jobs are immutable: any pod template input must yield a new Job name.
job_name() {
  helm template telemetry "$backend" --set storageClass=validated-ssd "$@" \
    --show-only templates/bootstrap.yaml | awk '/^kind: Job$/ {job=1} job && /^  name:/ {print $2; exit}'
}
default_job=$(job_name)
[[ "$default_job" =~ ^telemetry-storage-schema-311-1-[0-9a-f]{8}$ ]]
test "$(job_name)" = "$default_job"
for changed in hbase.version=2.6.7 bootstrap.preSplit=false bootstrap.resources.limits.memory=3Gi imagePullPolicy=Always; do
  test "$(job_name --set "$changed")" != "$default_job"
done
long_job=$(job_name --set bootstrap.revision=abcdefghij0123456789)
test "${#long_job}" -le 63
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
backend_version=$(helm show chart "$backend" | awk '/^version:/ {print $2}')
helm lint "$temp/pinpoint-hbase-stackable-$backend_version.tgz" --set storageClass=validated-ssd
echo "HA backend render and packaging checks passed. Runtime HA qualification is separate."
