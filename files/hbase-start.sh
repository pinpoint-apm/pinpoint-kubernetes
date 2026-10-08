#!/usr/bin/env bash
set -euo pipefail

export HBASE_CONF_DIR=/tmp/pinpoint-hbase-conf
mkdir -p "$HBASE_CONF_DIR" "$HBASE_PID_DIR"
cp -a "$HBASE_HOME/conf/." "$HBASE_CONF_DIR/"
cp /opt/pinpoint-hbase/hbase-site.xml "$HBASE_CONF_DIR/hbase-site.xml"
rm -f /tmp/pinpoint-hbase-ready
bootstrap_pid=""

shutdown() {
  trap - TERM INT EXIT
  rm -f /tmp/pinpoint-hbase-ready
  if [[ -n "$bootstrap_pid" ]]; then
    kill "$bootstrap_pid" 2>/dev/null || true
  fi
  # Flush the RegionServer while Master and ZooKeeper are still available.
  timeout 240 "$HBASE_HOME/bin/hbase-daemon.sh" stop regionserver || true
  timeout 45 "$HBASE_HOME/bin/hbase-daemon.sh" stop master || true
}
trap 'shutdown; exit 0' TERM INT
trap shutdown EXIT

# Launch locally: no SSH server or image PID 1 shell is needed.
"$HBASE_HOME/bin/hbase-daemon.sh" start master
"$HBASE_HOME/bin/hbase-daemon.sh" start regionserver
/usr/local/bin/configure-hbase.sh

(
  until timeout 120 "$HBASE_HOME/bin/hbase" shell -n /opt/pinpoint-hbase/initialize-schema.rb; do
    echo 'HBase schema initialization is waiting for the cluster; retrying in 10 seconds.'
    sleep 10
  done
  touch /tmp/pinpoint-hbase-ready
  echo 'HBase daemons and all Pinpoint tables initialized.'
) &
bootstrap_pid=$!

# Daemon failure terminates the container so Kubernetes can restart it.
while sleep 10; do
  if ! /bin/bash /opt/pinpoint-hbase/health.sh live; then
    echo 'HBase Master or RegionServer exited; restarting the container.' >&2
    exit 1
  fi
done
