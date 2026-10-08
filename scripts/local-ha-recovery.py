#!/usr/bin/env python3
"""Kill individual backend JVMs and verify marker recovery on a loopback cluster.

This is an explicit local fault-injection test, not a production maintenance tool.
It does not test network partitions, physical disks, independent hosts or backups.
"""
import argparse
import json
import re
import shlex
import time
import uuid
from hbase_local_client import LocalHBaseClient


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--backend-name', default='pinpoint-storage')
    parser.add_argument('--roles', nargs='+', choices=['namenode', 'journalnode', 'datanode', 'master', 'regionserver'],
                        help='Run selected recovery cases; default is all five')
    parser.add_argument('--cleanup-fixtures', action='store_true',
                        help='Remove retained PinpointHA_<10 hex digits> test tables; do not run during another test')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', args.backend_name):
        parser.error('backend-name must be a DNS label')
    client = LocalHBaseClient(args.kubeconfig, args.namespace, args.backend_name + '-hbase')
    if args.cleanup_fixtures:
        output = client.ruby('''
connection = org.apache.hadoop.hbase.client.ConnectionFactory.createConnection(org.apache.hadoop.hbase.HBaseConfiguration.create)
connection.getAdmin.listTableNames.each do |name|
  fixture = name.getNameAsString
  next unless /^PinpointHA_[0-9a-f]{10}$/.match(fixture)
  disable fixture if is_enabled(fixture)
  drop fixture
  puts 'REMOVED_FIXTURE ' + fixture
end
connection.close
''')
        print('\n'.join(line for line in output.splitlines() if line.startswith('REMOVED_FIXTURE ')), flush=True)
        listing = client.hdfs('/stackable/hadoop/bin/hdfs dfs -ls /')
        for line in listing.splitlines():
            match = re.search(r'(/pinpoint-ha-test-[0-9a-f]{10})$', line)
            if match:
                path = match[1]
                client.hdfs(shlex.join(['/stackable/hadoop/bin/hdfs', 'dfs', '-rm', path]))
                print('REMOVED_HDFS_FIXTURE ' + path, flush=True)
        return
    token = uuid.uuid4().hex[:10]
    table = 'PinpointHA_' + token
    path = '/pinpoint-ha-test-' + token
    common = f'''
connection = org.apache.hadoop.hbase.client.ConnectionFactory.createConnection(org.apache.hadoop.hbase.HBaseConfiguration.create)
name = org.apache.hadoop.hbase.TableName.valueOf('{table}')
table = connection.getTable(name)
bytes = org.apache.hadoop.hbase.util.Bytes
'''

    def marker(label, write=False):
        operation = ''
        if write:
            operation = f'''
mutation = org.apache.hadoop.hbase.client.Put.new(bytes.toBytes('{label}'))
mutation.addColumn(bytes.toBytes('v'), bytes.toBytes('marker'), bytes.toBytes('{token}'))
mutation.setDurability(org.apache.hadoop.hbase.client.Durability::SYNC_WAL)
table.put(mutation)
'''
        return common + operation + f'''
result = table.get(org.apache.hadoop.hbase.client.Get.new(bytes.toBytes('{label}')))
raise 'Marker mismatch: {label}' unless bytes.toString(result.getValue(bytes.toBytes('v'), bytes.toBytes('marker'))) == '{token}'
puts 'MARKER_OK {label}'
table.close
connection.close
'''

    def hdfs(*arguments, stdin=None):
        command = shlex.join(['/stackable/hadoop/bin/hdfs'] + list(arguments))
        if stdin is not None:
            command = 'printf %s ' + shlex.quote(stdin) + ' | ' + command
        return client.hdfs(command)

    def active_nn():
        states = hdfs('haadmin', '-getAllServiceState')
        active = [pod_for_host(line.split()[0].rsplit(':', 1)[0]) for line in states.splitlines()
                  if line.split() and line.split()[-1] == 'active']
        if len(active) != 1:
            raise RuntimeError('Expected exactly one active NameNode: ' + states)
        return active[0]

    def pod_for_host(host):
        services = json.loads(client.run(['get', 'services', '-o', 'json']))['items']
        for service in services:
            if host == service['spec'].get('clusterIP') or host.split('.')[0] == service['metadata']['name']:
                selector = service['spec'].get('selector', {})
                if not selector:
                    raise RuntimeError('Discovery Service has no pod selector')
                expression = ','.join(k + '=' + v for k, v in selector.items())
                pods = json.loads(client.run(['get', 'pods', '-l', expression, '-o', 'json']))['items']
                if len(pods) != 1:
                    raise RuntimeError('Fault target Service must select exactly one pod')
                return pods[0]['metadata']['name']
        return host.split('.')[0]

    def kill_jvm(pod, container, java_class):
        before = json.loads(client.run(['get', 'pod', pod, '-o', 'json']))
        baseline = next(c['restartCount'] for c in before['status']['containerStatuses'] if c['name'] == container)
        script = r'''target_class=$1
found=0
for process in /proc/[0-9]*; do
  [ -r "$process/cmdline" ] || continue
  executable=$(tr '\000' '\n' < "$process/cmdline" | head -n 1) || continue
  case "$executable" in */java|java) ;; *) continue ;; esac
  arguments=$(tr '\000' ' ' < "$process/cmdline") || continue
  case " $arguments " in *" $target_class "*)
    test "$found" = 0
    found=${process##*/}
    ;; esac
done
test "$found" != 0
echo "Killing verified $target_class JVM pid=$found"
kill -KILL "$found"
'''
        print(client.run(['exec', pod, '-c', container, '--', 'bash', '-ec', script, '--', java_class]).strip(), flush=True)
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            current = json.loads(client.run(['get', 'pod', pod, '-o', 'json']))
            status = next(c for c in current['status'].get('containerStatuses', []) if c['name'] == container)
            if status['restartCount'] > baseline and status.get('ready'):
                return
            time.sleep(2)
        raise TimeoutError('JVM did not recover: ' + pod)

    client.ruby(f"create '{table}', 'v'\n" + marker('initial', write=True))
    print('SYNC_WAL fixture created: ' + table, flush=True)
    hdfs('dfs', '-put', '-', path, stdin=token)
    hdfs('dfs', '-setrep', '-w', '3', path)
    old_nn = active_nn()
    cases = [
        ('namenode', old_nn, 'namenode', 'org.apache.hadoop.hdfs.server.namenode.NameNode'),
        ('journalnode', args.backend_name + '-hdfs-journalnode-default-0', 'journalnode', 'org.apache.hadoop.hdfs.qjournal.server.JournalNode'),
        ('datanode', args.backend_name + '-hdfs-datanode-default-0', 'datanode', 'org.apache.hadoop.hdfs.server.datanode.DataNode'),
        ('master', None, 'hbase', 'org.apache.hadoop.hbase.master.HMaster'),
        ('regionserver', None, 'hbase', 'org.apache.hadoop.hbase.regionserver.HRegionServer'),
    ]
    for label, pod, container, java_class in cases:
        if args.roles and label not in args.roles:
            continue
        source = marker(label, write=True)
        if label == 'master':
            source = source.replace('table.close\nconnection.close', "puts 'TARGET ' + connection.getAdmin.getClusterMetrics.getMasterName.getHostname\ntable.close\nconnection.close")
        elif label == 'regionserver':
            source = source.replace('table.close\nconnection.close', f"puts 'TARGET ' + connection.getRegionLocator(name).getRegionLocation(bytes.toBytes('{label}')).getServerName.getHostname\ntable.close\nconnection.close")
        output = client.ruby(source)
        if pod is None:
            match = re.search(r'^TARGET ([a-z0-9.-]+)$', output, re.M)
            if not match:
                raise RuntimeError('HBase target discovery failed: ' + output)
            pod = pod_for_host(match[1])
        if not pod.startswith(args.backend_name + '-'):
            raise RuntimeError('Fault target is outside the test backend')
        started = time.monotonic()
        kill_jvm(pod, container, java_class)
        if label == 'namenode' and active_nn() == old_nn:
            raise RuntimeError('Standby NameNode did not take over')
        verification = marker(label) + marker(label + '_after', write=True)
        if label == 'master':
            verification = verification.replace('table.close\nconnection.close',
                "puts 'AFTER_MASTER ' + connection.getAdmin.getClusterMetrics.getMasterName.getHostname\ntable.close\nconnection.close")
        output = client.ruby(verification)
        if label == 'master':
            match = re.search(r'^AFTER_MASTER ([a-z0-9.-]+)$', output, re.M)
            if not match or pod_for_host(match[1]) == pod:
                raise RuntimeError('Standby HBase Master did not take over')
        check = 'test "$(/stackable/hadoop/bin/hdfs dfs -cat ' + shlex.quote(path) + ')" = ' + shlex.quote(token)
        client.hdfs(check + "\necho HDFS_MARKER_OK")
        print(f'{label}: pre-crash SYNC_WAL and HDFS block markers retained; fresh write/read passed ({time.monotonic()-started:.1f}s including client Job startup)', flush=True)
    client.ruby(f"disable '{table}'\ndrop '{table}'\nputs 'Fixture removed'\n")
    hdfs('dfs', '-rm', path)
    print('Selected individual JVM recovery tests passed; fixtures removed.', flush=True)


if __name__ == '__main__':
    main()
