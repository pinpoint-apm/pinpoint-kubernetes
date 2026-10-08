"""Isolated HBase shell Jobs for loopback-only Stackable integration tests."""
import json
import re
import subprocess
import time
from urllib.parse import urlparse
import uuid


class LocalHBaseClient:
    def __init__(self, kubeconfig, namespace, cluster):
        if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', v)
               for v in (namespace, cluster)):
            raise ValueError('namespace and cluster must be DNS labels')
        self.base = ['kubectl', '--kubeconfig', kubeconfig]
        config = json.loads(self.run(['config', 'view', '--minify', '-o', 'json']))
        if urlparse(config['clusters'][0]['cluster']['server']).hostname not in ('127.0.0.1', 'localhost', '::1'):
            raise ValueError('Only a loopback Kubernetes API server is allowed')
        self.base += ['-n', namespace]
        self.cluster = cluster
        product = json.loads(self.run(['get', 'hbasecluster', cluster, '-o', 'json']))
        settings = product['spec']['image']
        self.image = settings.get('custom') or 'oci.stackable.tech/sdp/hbase:' + settings['productVersion'] + '-stackable26.7.0'
        self.pull_secrets = settings.get('pullSecrets') or []

    def run(self, arguments, document=None, timeout=120, stdin=None):
        if document is not None and stdin is not None:
            raise ValueError('Supply a Kubernetes document or stdin, not both')
        return subprocess.run(self.base + arguments, check=True, capture_output=True, text=True,
                              input=json.dumps(document) if document is not None else stdin,
                              timeout=timeout).stdout

    def ruby(self, source, timeout=180):
        source = 'begin\n' + source + '\nrescue => error\n  warn error.full_message\n  exit 1\nend\n'
        command = ('mkdir -p /tmp/conf; cp /stackable/hbase/conf/* /tmp/conf/; '
                   'cp /discovery/hbase-site.xml /tmp/conf/hbase-site.xml; '
                   '/stackable/hbase/bin/hbase --config /tmp/conf shell -n /scripts/test')
        return self._job(source, command, self.image, self.cluster,
                         [{'name': 'HBASE_HEAPSIZE', 'value': '384'}], timeout)

    def hdfs(self, command, timeout=180):
        cluster = self.cluster.removesuffix('-hbase') + '-hdfs'
        product = json.loads(self.run(['get', 'hdfscluster', cluster, '-o', 'json']))
        settings = product['spec']['image']
        image = settings.get('custom') or 'oci.stackable.tech/sdp/hadoop:' + settings['productVersion'] + '-stackable26.7.0'
        setup = ('mkdir -p /tmp/conf; cp -r /stackable/hadoop/etc/hadoop/. /tmp/conf/; '
                 'cp /discovery/*.xml /tmp/conf/; bash -euo pipefail /scripts/test')
        return self._job(command, setup, image, cluster,
                         [{'name': 'HADOOP_CONF_DIR', 'value': '/tmp/conf'},
                          {'name': 'HADOOP_HEAPSIZE_MAX', 'value': '256'}], timeout)

    def _job(self, source, command, image, discovery, env, timeout):
        name = 'backend-client-' + uuid.uuid4().hex[:10]
        self.run(['create', '-f', '-'], {'apiVersion': 'v1', 'kind': 'ConfigMap',
            'metadata': {'name': name}, 'data': {'test': source}})
        job = {'apiVersion': 'batch/v1', 'kind': 'Job', 'metadata': {'name': name},
            'spec': {'activeDeadlineSeconds': timeout, 'backoffLimit': 0,
                'template': {'spec': {'restartPolicy': 'Never', 'automountServiceAccountToken': False,
                    'imagePullSecrets': self.pull_secrets,
                    'securityContext': {'runAsNonRoot': True, 'runAsUser': 1000, 'runAsGroup': 1000,
                                        'seccompProfile': {'type': 'RuntimeDefault'}},
                    'containers': [{'name': 'client', 'image': image,
                        'command': ['/bin/bash', '-ec'], 'args': [command],
                        'env': [{'name': 'HOME', 'value': '/tmp'}, {'name': 'HBASE_LOG_DIR', 'value': '/tmp'}] + env,
                        'securityContext': {'readOnlyRootFilesystem': True, 'allowPrivilegeEscalation': False,
                                            'capabilities': {'drop': ['ALL']}},
                        'resources': {'requests': {'cpu': '100m', 'memory': '512Mi'},
                                      'limits': {'cpu': '2', 'memory': '768Mi'}},
                        'volumeMounts': [{'name': 'tmp', 'mountPath': '/tmp'},
                                        {'name': 'scripts', 'mountPath': '/scripts', 'readOnly': True},
                                        {'name': 'discovery', 'mountPath': '/discovery', 'readOnly': True}]}],
                    'volumes': [{'name': 'tmp', 'emptyDir': {'sizeLimit': '128Mi'}},
                                {'name': 'scripts', 'configMap': {'name': name}},
                                {'name': 'discovery', 'configMap': {'name': discovery}}]}}}}
        self.run(['create', '-f', '-'], job)
        deadline = time.monotonic() + timeout + 20
        while time.monotonic() < deadline:
            status = json.loads(self.run(['get', 'job', name, '-o', 'json'])).get('status', {})
            conditions = {c['type']: c['status'] for c in status.get('conditions', [])}
            if conditions.get('Failed') == 'True' or conditions.get('Complete') == 'True':
                output = self.run(['logs', 'job/' + name], timeout=30)
                if conditions.get('Failed') == 'True':
                    raise RuntimeError('Backend client test failed; retained Job ' + name + '\n' + output[-5000:])
                self.run(['delete', 'job,configmap', name, '--wait=false'])
                return output
            time.sleep(2)
        raise TimeoutError('Backend client test timed out; retained Job ' + name)
