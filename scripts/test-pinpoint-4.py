#!/usr/bin/env python3
"""Exercise additive 4.x schema migration and fresh/legacy chart contracts."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('pinot', ROOT / 'files/initialize-pinot.py')
pinot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinot)


def resources(rendered):
    script = 'puts JSON.generate(STDIN.read.split(/^---\\s*$/).filter_map { |s| YAML.safe_load(s) })'
    return json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e', script],
                                              input=rendered, text=True))


class Schemas:
    def __init__(self, schema):
        self.schema = copy.deepcopy(schema)
        self.writes = 0
    def request(self, method, path, payload=None):
        if method == 'GET': return 200, copy.deepcopy(self.schema)
        assert method == 'PUT'
        self.writes += 1
        self.schema = copy.deepcopy(payload)
        return 200, {}


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.schema = {'schemaName': 'exceptionTrace', 'dimensionFieldSpecs': [
            {'name': 'applicationName', 'dataType': 'STRING'},
            {'name': 'serviceName', 'dataType': 'STRING', 'defaultNullValue': 'DEFAULT'}]}
        self.old = copy.deepcopy(self.schema)
        self.old['dimensionFieldSpecs'].pop()
        self.old['dimensionFieldSpecs'].append({'name': 'customField', 'dataType': 'LONG'})
    def test_existing_data_requires_explicit_migration_opt_in(self):
        controller = Schemas(self.old)
        with self.assertRaises(pinot.InitializationError):
            pinot.schema_migration_plan(controller, [(self.schema, {})], False)
        self.assertEqual(controller.writes, 0)
    def test_additive_migration_preserves_custom_fields_and_is_idempotent(self):
        controller = Schemas(self.old)
        plans = pinot.schema_migration_plan(controller, [(self.schema, {})], True)
        pinot.apply_schema_migrations(controller, plans)
        self.assertIn({'name': 'customField', 'dataType': 'LONG'}, controller.schema['dimensionFieldSpecs'])
        self.assertEqual(controller.writes, 1)
        self.assertEqual(pinot.schema_migration_plan(controller, [(self.schema, {})], True), [])
    def test_incompatible_type_does_not_write(self):
        controller = Schemas(self.schema)
        controller.schema['dimensionFieldSpecs'][0]['dataType'] = 'LONG'
        with self.assertRaises(pinot.InitializationError):
            pinot.schema_migration_plan(controller, [(self.schema, {})], True)
        self.assertEqual(controller.writes, 0)
    def test_controller_normalization_does_not_hide_added_fields(self):
        class NormalizingSchemas(Schemas):
            def request(self, method, path, payload=None):
                status, body = super().request(method, path, payload)
                if method == 'PUT':
                    for field in self.schema['dimensionFieldSpecs']:
                        field.setdefault('singleValueField', True)
                return status, body
        controller = NormalizingSchemas(self.old)
        pinot.apply_schema_migrations(controller, pinot.schema_migration_plan(controller, [(self.schema, {})], True))
        self.assertEqual(controller.writes, 1)
        self.assertTrue(controller.schema['dimensionFieldSpecs'][-1]['singleValueField'])
    def test_incompatible_cardinality_does_not_write(self):
        controller = Schemas(self.schema)
        controller.schema['dimensionFieldSpecs'][0]['singleValueField'] = False
        with self.assertRaises(pinot.InitializationError):
            pinot.schema_migration_plan(controller, [(self.schema, {})], True)
        self.assertEqual(controller.writes, 0)
    def test_missing_field_without_default_requires_review(self):
        wanted = copy.deepcopy(self.schema)
        wanted['dimensionFieldSpecs'][-1].pop('defaultNullValue')
        with self.assertRaises(pinot.InitializationError):
            pinot.schema_migration_plan(Schemas(self.old), [(wanted, {})], True)
    def test_versioned_assets_and_alarm_ddl(self):
        for version, count in [('3.1.1', 20), ('4.0.1', 29)]:
            manifest = json.loads((ROOT / f'files/schema-manifest-{version}.json').read_text())
            for asset in manifest['assets']:
                self.assertEqual(hashlib.sha256((ROOT / asset['path']).read_bytes()).hexdigest(), asset['sha256'])
            definitions = pinot.load_definitions(ROOT / f'files/pinot/{version}', 'kafka:9092', 1, 14)
            self.assertEqual(len(definitions), 18)
            sql = '\n'.join(p.read_text() for p in (ROOT / f'files/sql/{version}').glob('*.sql'))
            self.assertEqual(len(set(re.findall(r'^CREATE TABLE\s+`?(\w+)', sql, re.M))), count)
        fields = json.loads((ROOT / 'files/pinot/4.0.1/pinot-exceptionTrace-schema.json').read_text())['dimensionFieldSpecs']
        self.assertIn({'name': 'serviceName', 'dataType': 'STRING', 'defaultNullValue': 'DEFAULT'}, fields)
    def test_external_mysql_init_and_alarm_feature_guards(self):
        external = ['--set', 'mysql.enabled=false', '--set', 'global.datasource.jdbcUrl=jdbc:mysql://db/pinpoint',
                    '--set', 'global.datasource.username=pinpoint', '--set', 'global.datasource.passwordSecret.name=db',
                    '--set', 'global.datasource.passwordSecret.key=password', '--set', 'global.datasource.schema.enabled=true',
                    '--set', 'global.datasource.schema.host=db', '--set', 'global.datasource.schema.rootPasswordSecret.name=db-root']
        rendered = subprocess.check_output(['helm', 'template', 'test', str(ROOT), *external], text=True)
        self.assertIn('create-alarm.sql:', rendered)
        self.assertIn('PINPOINT_VERSION', rendered)
        self.assertIn('value: "4.0.1"', rendered)
        self.assertIn('name: otlp-http', rendered)
        self.assertIn('--pinpoint.collector.type=BASIC,METRIC,OTLPTRACE', rendered)
        self.assertIn('9991 9992 9993 9995 9997 9998', rendered)
        self.assertIn('LOGGING_CONFIG', rendered)
        self.assertIn('wait-for-mysql-schema', rendered)
        self.assertIn('test-mysql-init-sql', rendered)
        self.assertNotIn('db-init-sql', rendered)
        result = subprocess.run(['helm', 'template', 'test', str(ROOT), '--set', 'alarmBatch.enabled=true'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compatible custom', result.stderr)
        valid = subprocess.check_output(['helm', 'template', 'test', str(ROOT), '--set', 'alarmBatch.enabled=true',
                                         '--set', 'alarmBatch.image.repository=example/qualified-alarm'], text=True)
        self.assertIn('-Dalarm.agent-stat.table.count=1', valid)
        self.assertIn('name: wait-for-mysql-schema', valid)
        self.assertIn('example/qualified-alarm:4.0.1', valid)

    def test_initialization_job_reconciles_changed_targets(self):
        base = ['helm', 'template', 'test', str(ROOT), '--show-only', 'templates/init-job-mysql.yaml']
        first = subprocess.check_output(base, text=True)
        self.assertEqual(first, subprocess.check_output(base, text=True))
        changed = subprocess.check_output(base + ['--set', 'global.initResources.mysql.limits.memory=300Mi'], text=True)
        name = lambda doc: re.search(r'^  name: (test-mysql-init-[a-f0-9]+)$', doc, re.M).group(1)
        self.assertNotEqual(name(first), name(changed))
        self.assertNotIn('helm.sh/hook', first)

    def test_production_spread_shutdown_and_disruption_budget(self):
        output = subprocess.check_output(['helm', 'template', 'test', str(ROOT), '-f',
                                          str(ROOT / 'values-production.yaml')], text=True)
        documents = resources(output)
        deployments = [doc for doc in documents if doc['kind'] == 'Deployment']
        self.assertEqual(len(deployments), 2)
        for deployment in deployments:
            self.assertEqual(deployment['spec']['replicas'], 2)
            pod = deployment['spec']['template']['spec']
            self.assertEqual(pod['topologySpreadConstraints'][0]['minDomains'], 2)
            self.assertEqual(pod['topologySpreadConstraints'][0]['whenUnsatisfiable'], 'DoNotSchedule')
            self.assertEqual(pod['terminationGracePeriodSeconds'], 120)
            self.assertEqual(pod['containers'][0]['lifecycle']['preStop']['exec']['command'], ['sh', '-c', 'sleep 10'])
        self.assertEqual(len([doc for doc in documents if doc['kind'] == 'PodDisruptionBudget']), 2)
        old_cluster = subprocess.run(['helm', 'template', 'test', str(ROOT), '-f',
                                     str(ROOT / 'values-production.yaml'), '--kube-version', '1.29.0'],
                                    text=True, capture_output=True)
        self.assertNotEqual(old_cluster.returncode, 0)
        self.assertIn('Kubernetes 1.30', old_cluster.stderr)

    def test_migration_opt_in_cannot_silently_skip_external_pinot(self):
        result = subprocess.run(['helm', 'template', 'test', str(ROOT), '-f',
                                 str(ROOT / 'values-production.yaml'), '--set',
                                 'global.pinot.migrateExistingSchemas=true'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires chart-managed Pinot initialization', result.stderr)

    def test_logging_override_is_unique_and_user_annotations_survive(self):
        for component in ('web', 'collector', 'alarmBatch'):
            flags = ['--set-string', component + '.extraEnv[0].name=LOGGING_CONFIG',
                     '--set-string', component + '.extraEnv[0].value=/custom/log4j2.xml',
                     '--set-string', component + '.podAnnotations.owner=platform']
            if component == 'alarmBatch':
                flags += ['--set', 'alarmBatch.enabled=true', '--set', 'alarmBatch.image.repository=example/qualified-alarm']
            rendered = subprocess.check_output(['helm', 'template', 'test', str(ROOT), *flags], text=True)
            name = 'test-pinpoint-' + ('alarm-batch' if component == 'alarmBatch' else component)
            resource = next(doc for doc in resources(rendered)
                            if doc and doc.get('kind') == 'Deployment' and doc['metadata']['name'] == name)
            annotations = resource['spec']['template']['metadata']['annotations']
            self.assertEqual(annotations['owner'], 'platform')
            self.assertNotIn('checksum/runtime-logging', annotations)
            env = resource['spec']['template']['spec']['containers'][0]['env']
            self.assertEqual([entry['value'] for entry in env if entry['name'] == 'LOGGING_CONFIG'], ['/custom/log4j2.xml'])

    def test_legacy_version_does_not_receive_v4_runtime_flags(self):
        legacy = subprocess.check_output(['helm', 'template', 'test', str(ROOT), '--set',
                                          'global.pinpointVersion=3.1.1', '--show-only', 'templates/collector.yaml'], text=True)
        self.assertNotIn('--pinpoint.collector.type=', legacy)
        self.assertNotIn('PINPOINT_MODULES_UID_VERSION', legacy)
        self.assertNotIn('9991 9992 9993 9995 9997 9998', legacy)
        self.assertIn('app.kubernetes.io/version: "3.1.1"', legacy)

    def test_unsupported_mysql_fails_before_schema_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            stub = Path(directory) / 'mysql'
            marker = Path(directory) / 'ddl-attempted'
            stub.write_text('''#!/bin/sh
case "$*" in
  *"SELECT VERSION();"*) printf '%s\\n' "$FAKE_DB_VERSION" ;;
  *) touch "$TEST_DDL_MARKER"; exit 19 ;;
esac
''')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                       MYSQL_HOST='fixture', MYSQL_DATABASE='fixture', MYSQL_ROOT_PASSWORD='unused',
                       PINPOINT_VERSION='4.0.1', TEST_DDL_MARKER=str(marker))
            for version in ('8.0.40', '10.11.11-MariaDB'):
                with self.subTest(version=version):
                    env['FAKE_DB_VERSION'] = version
                    result = subprocess.run(['sh', str(ROOT / 'files/initialize-mysql.sh')],
                                            env=env, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('MySQL', result.stderr)
                    self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
