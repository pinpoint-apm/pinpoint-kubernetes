#!/usr/bin/env bash
# Fail when packaged chart content changed without a Chart.yaml version bump.
# Released versions are immutable: the release job skips existing versions,
# so an unbumped change would never reach the Helm repository.
set -euo pipefail

base="${1:?usage: check-version-bump.sh <base-ref>}"
merge_base="$(git merge-base "${base}" HEAD)"
status=0

chart_version() {
  awk '$1 == "version:" { print $2; exit }'
}

check_chart() {
  local chart="$1"
  shift
  if git diff --quiet "${merge_base}" HEAD -- "$@"; then
    return
  fi
  local before after
  before="$(git show "${merge_base}:${chart}/Chart.yaml" 2>/dev/null | chart_version || true)"
  after="$(chart_version < "${chart}/Chart.yaml")"
  if [ -n "${before}" ] && [ "${before}" = "${after}" ]; then
    echo "${chart}: packaged files changed but version is still ${after}" >&2
    status=1
  else
    echo "${chart}: version ${before:-<new>} -> ${after}"
  fi
}

# Root chart package content (.helmignore excludes docs, examples, backends).
check_chart . Chart.yaml Chart.lock values.yaml values-*.yaml values.schema.json \
  templates files README.md LICENSE
check_chart backends/hbase-stackable backends/hbase-stackable
exit "${status}"
