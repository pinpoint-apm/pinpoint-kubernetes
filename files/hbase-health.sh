#!/usr/bin/env bash
set -euo pipefail

# Check the actual daemons, not the image's long-lived tail process.
for daemon in master regionserver; do
  pid_file="${HBASE_PID_DIR}/hbase-${HBASE_IDENT_STRING}-${daemon}.pid"
  [[ -s "$pid_file" ]]
  daemon_pid=$(cat "$pid_file")
  [[ "$daemon_pid" =~ ^[0-9]+$ ]]
  kill -0 "$daemon_pid"
  case "$(tr '\000' ' ' < "/proc/${daemon_pid}/cmdline")" in
    *org.apache.hadoop.hbase.master.HMaster*|*org.apache.hadoop.hbase.regionserver.HRegionServer*) ;;
    *) exit 1 ;;
  esac
done

if [[ "${1:-live}" == ready ]]; then
  [[ -f /tmp/pinpoint-hbase-ready ]]
  # Lightweight socket checks avoid launching a JVM for every probe.
  # RPC listeners bind the pod address, not necessarily loopback.
  timeout 2 bash -c 'exec 3<>/dev/tcp/${HOSTNAME}/60000'
  timeout 2 bash -c 'exec 3<>/dev/tcp/${HOSTNAME}/60020'
fi
