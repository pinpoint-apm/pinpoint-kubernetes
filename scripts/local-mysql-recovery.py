#!/usr/bin/env python3
"""Exercise real MySQL schema repair and dump/restore on a loopback test cluster."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from urllib.parse import urlparse
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--release', default='pinpoint')
    args = parser.parse_args()
    kubectl = ['kubectl', '--kubeconfig', args.kubeconfig]

    def run(arguments, document=None):
        result = subprocess.run(kubectl + arguments, check=True, capture_output=True,
                                text=True, input=json.dumps(document) if document else None)
        return result.stdout

    config = json.loads(run(['config', 'view', '--minify', '-o', 'json']))
    server = config['clusters'][0]['cluster']['server']
    if urlparse(server).hostname not in ('127.0.0.1', 'localhost', '::1'):
        parser.error('Only a loopback Kubernetes API server is allowed')
    kubectl += ['--namespace', args.namespace]
    name = 'mysql-recovery-' + uuid.uuid4().hex[:8]
    database = name.replace('-', '_')
    root = Path(__file__).resolve().parent.parent
    data = {'initialize-mysql.sh': (root / 'files/initialize-mysql.sh').read_text(),
            'create-tables.sql': (root / 'files/sql/3.1.1/CreateTableStatement-mysql.sql').read_text(),
            'create-batch-tables.sql': (root / 'files/sql/3.1.1/SpringBatchJobRepositorySchema-mysql.sql').read_text()}
    statefulset = json.loads(run(['get', 'statefulset', args.release + '-mysql', '-o', 'json']))
    image = statefulset['spec']['template']['spec']['containers'][0]['image']
    run(['create', '-f', '-'], {'apiVersion': 'v1', 'kind': 'ConfigMap',
                               'metadata': {'name': name}, 'data': data})
    command = r'''set -eu
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
db() { mysql -h "$MYSQL_HOST" -u root -s -N "$@"; }
cleanup() { db -e "DROP DATABASE IF EXISTS $MYSQL_DATABASE; DROP DATABASE IF EXISTS ${MYSQL_DATABASE}_restore;"; }
trap cleanup EXIT
db -e "CREATE DATABASE $MYSQL_DATABASE;"
sh /shared/initialize-mysql.sh
db "$MYSQL_DATABASE" -e "INSERT INTO user_group(id) VALUES('preserved-marker'); UPDATE BATCH_JOB_SEQ SET ID=123; DROP TABLE webhook_send; ALTER TABLE user_group DROP INDEX id_idx;"
i=0
while [ "$i" -lt 20 ]; do db "$MYSQL_DATABASE" -e "CREATE TABLE unrelated_$i(id INT);"; i=$((i+1)); done
sh /shared/initialize-mysql.sh
sh /shared/initialize-mysql.sh
test "$(db "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM user_group WHERE id='preserved-marker';")" = 1
test "$(db "$MYSQL_DATABASE" -e 'SELECT ID FROM BATCH_JOB_SEQ;')" = 123
mysqldump -h "$MYSQL_HOST" -u root --single-transaction --set-gtid-purged=OFF "$MYSQL_DATABASE" > /tmp/backup.sql
db -e "CREATE DATABASE ${MYSQL_DATABASE}_restore;"
db "${MYSQL_DATABASE}_restore" < /tmp/backup.sql
test "$(db "${MYSQL_DATABASE}_restore" -e "SELECT COUNT(*) FROM user_group WHERE id='preserved-marker';")" = 1
test "$(db "${MYSQL_DATABASE}_restore" -e 'SELECT ID FROM BATCH_JOB_SEQ;')" = 123
echo 'Partial schema repaired; marker and sequence preserved across reruns and dump/restore: OK'
'''
    labels = {'app.kubernetes.io/name': 'pinpoint',
              'app.kubernetes.io/instance': args.release,
              'app.kubernetes.io/component': 'mysql-init'}
    pod = {'restartPolicy': 'Never', 'automountServiceAccountToken': False,
           'volumes': [{'name': 'scripts', 'configMap': {'name': name}}],
           'containers': [{'name': 'test', 'image': image, 'command': ['sh', '-c', command],
                           'volumeMounts': [{'name': 'scripts', 'mountPath': '/shared'}],
                           'env': [{'name': 'MYSQL_HOST', 'value': args.release + '-mysql'},
                                   {'name': 'MYSQL_DATABASE', 'value': database},
                                   {'name': 'MYSQL_ROOT_PASSWORD', 'valueFrom': {
                                       'secretKeyRef': {'name': args.release + '-mysql', 'key': 'mysql-root-password'}}}],
                           'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'},
                                         'limits': {'cpu': '500m', 'memory': '256Mi'}}}]}
    job = {'apiVersion': 'batch/v1', 'kind': 'Job', 'metadata': {'name': name},
           'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': 180,
                    'template': {'metadata': {'labels': labels}, 'spec': pod}}}
    run(['create', '-f', '-'], job)
    deadline = time.monotonic() + 210
    while time.monotonic() < deadline:
        status = json.loads(run(['get', 'job', name, '-o', 'json'])).get('status', {})
        conditions = {c['type']: c['status'] for c in status.get('conditions', [])}
        if conditions.get('Failed') == 'True' or conditions.get('Complete') == 'True':
            print(run(['logs', 'job/' + name]), end='', flush=True)
            if conditions.get('Failed') == 'True':
                raise RuntimeError('MySQL recovery test failed; Job/ConfigMap retained: ' + name)
            run(['delete', 'job,configmap', name, '--wait=false'])
            return
        time.sleep(2)
    raise TimeoutError('MySQL recovery test timed out; inspect Job ' + name)


if __name__ == '__main__':
    main()
