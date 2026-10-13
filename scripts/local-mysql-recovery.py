#!/usr/bin/env python3
"""Exercise schema repair in a disposable database; remote tests require explicit opt-in."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from urllib.parse import urlparse
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--kubeconfig')
    target.add_argument('--context')
    parser.add_argument('--allow-remote-fixture-tests', action='store_true',
                        help='Explicitly allow creating a unique disposable database on the selected remote cluster')
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--release', default='pinpoint')
    args = parser.parse_args()
    kubectl = ['kubectl', '--kubeconfig', args.kubeconfig] if args.kubeconfig else ['kubectl', '--context', args.context]

    def run(arguments, document=None):
        result = subprocess.run(kubectl + arguments, check=True, capture_output=True,
                                text=True, input=json.dumps(document) if document else None)
        return result.stdout

    config = json.loads(run(['config', 'view', '--minify', '-o', 'json']))
    server = config['clusters'][0]['cluster']['server']
    if not args.allow_remote_fixture_tests and urlparse(server).hostname not in ('127.0.0.1', 'localhost', '::1'):
        parser.error('Only a loopback Kubernetes API server is allowed')
    kubectl += ['--namespace', args.namespace]
    name = 'mysql-recovery-' + uuid.uuid4().hex[:8]
    database = name.replace('-', '_')
    root = Path(__file__).resolve().parent.parent
    data = {'initialize-mysql.sh': (root / 'files/initialize-mysql.sh').read_text(),
            'create-tables.sql': (root / 'files/sql/3.1.1/CreateTableStatement-mysql.sql').read_text(),
            'create-batch-tables.sql': (root / 'files/sql/3.1.1/SpringBatchJobRepositorySchema-mysql.sql').read_text(),
            'create-service.sql': (root / 'files/sql/3.1.1/Service-mysql.sql').read_text(),
            'create-feature-flag.sql': (root / 'files/sql/3.1.1/FeatureFlag-mysql.sql').read_text(),
            'create-otlp-metric.sql': (root / 'files/sql/3.1.1/OtlpMetric-mysql.sql').read_text()}
    statefulset = json.loads(run(['get', 'statefulset', args.release + '-mysql', '-o', 'json']))
    spec = statefulset['spec']['template']['spec']
    container = spec['containers'][0]
    image = container['image']
    root_secret = next((e['valueFrom']['secretKeyRef']['name']
                        for e in container.get('env', [])
                        if e['name'] == 'MYSQL_ROOT_PASSWORD' and 'valueFrom' in e), None)
    if root_secret is None:
        root_secret = next(v['secret']['secretName'] for v in spec.get('volumes', [])
                           if v['name'] == 'mysql-credentials' and 'secret' in v)
    run(['create', '-f', '-'], {'apiVersion': 'v1', 'kind': 'ConfigMap',
                               'metadata': {'name': name}, 'data': data})
    command = r'''set -eu
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
db() { mysql -h "$MYSQL_HOST" -u root -s -N "$@"; }
cleanup() { db -e "DROP DATABASE IF EXISTS $MYSQL_DATABASE; DROP DATABASE IF EXISTS ${MYSQL_DATABASE}_restore;"; }
trap cleanup EXIT
db -e "CREATE DATABASE $MYSQL_DATABASE;"
sh /shared/initialize-mysql.sh
test "$(db -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE' AND table_name='application_metric_definition';")" = 0
export PINPOINT_METRIC_ENABLED=true
sh /shared/initialize-mysql.sh
db "$MYSQL_DATABASE" -e "INSERT INTO application_metric_definition VALUES('preserved-metric','{}',1); INSERT INTO service VALUES(123,'preserved-service'); INSERT INTO feature_flag VALUES('fixture','fixture','fixture','ENABLED');"
db "$MYSQL_DATABASE" -e "INSERT INTO user_group(id) VALUES('preserved-marker'); UPDATE BATCH_JOB_SEQ SET ID=123; DROP TABLE webhook_send; ALTER TABLE user_group DROP INDEX id_idx;"
i=0
while [ "$i" -lt 20 ]; do db "$MYSQL_DATABASE" -e "CREATE TABLE unrelated_$i(id INT);"; i=$((i+1)); done
sh /shared/initialize-mysql.sh
sh /shared/initialize-mysql.sh
test "$(db "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM user_group WHERE id='preserved-marker';")" = 1
test "$(db "$MYSQL_DATABASE" -e 'SELECT ID FROM BATCH_JOB_SEQ;')" = 123
test "$(db "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM application_metric_definition WHERE application_name='preserved-metric';")" = 1
test "$(db "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM service WHERE name='preserved-service';")" = 1
test "$(db "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM feature_flag WHERE feature_name='fixture';")" = 1
db "$MYSQL_DATABASE" -e "ALTER TABLE application_metric_definition DROP COLUMN schema_version;"
if sh /shared/initialize-mysql.sh > /tmp/invalid-schema.log 2>&1; then echo 'Malformed existing table was accepted' >&2; exit 1; fi
grep -q 'Missing required MySQL column: application_metric_definition.schema_version' /tmp/invalid-schema.log
db "$MYSQL_DATABASE" -e "DROP TABLE application_metric_definition; DROP TABLE service; DROP TABLE feature_flag;"
sh /shared/initialize-mysql.sh
test "$(db "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('application_metric_definition','service','feature_flag');")" = 3
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
                                       'secretKeyRef': {'name': root_secret, 'key': 'mysql-root-password'}}}],
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
