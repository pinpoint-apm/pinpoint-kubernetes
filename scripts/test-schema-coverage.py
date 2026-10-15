#!/usr/bin/env python3
"""Validate versioned schema coverage and the rendered dependency probes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
manifest = json.loads((ROOT / 'files/schema-manifest-3.1.1.json').read_text())
for asset in manifest['assets']:
    assert hashlib.sha256((ROOT / asset['path']).read_bytes()).hexdigest() == asset['sha256'], asset['path']
spec = importlib.util.spec_from_file_location('pinot_init', ROOT / 'files/initialize-pinot.py')
pinot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinot)
definitions = pinot.load_definitions(ROOT / 'files/pinot/3.1.1', 'example:9092', 1)
assert len({s['schemaName'] for s, _ in definitions}) == 11
assert len(definitions) == 18
assert len(list((ROOT / 'files/pinot/3.1.1').glob('*.json'))) == 29
# Every supplied table must be initialized and every RT->OFFLINE task has a target.
typed = {(t['tableName'], t['tableType']) for _, t in definitions}
for path in (ROOT / 'files/pinot/3.1.1').glob('*-table.json'):
    table = json.loads(path.read_text())
    assert (table['tableName'], table['tableType']) in typed, path
    if 'RealtimeToOfflineSegmentsTask' in table.get('task', {}).get('taskTypeConfigsMap', {}):
        assert (table['tableName'], 'OFFLINE') in typed, path
rendered = subprocess.check_output(['helm', 'template', 'pinpoint', str(ROOT)], text=True)
# Topics come from global.kafka.topics; the rendered initializer lists one
# "<topic> <partitions>" line per topic.
for _, table in definitions:
    if table['tableType'] == 'REALTIME':
        topic = table['tableIndexConfig']['streamConfigs']['stream.kafka.topic.name']
        assert re.search(r'^\s*' + re.escape(topic) + r' \d+$', rendered, re.M), topic
sql_names = set()
for path in (ROOT / 'files/sql/3.1.1').glob('*.sql'):
    sql_names.update(re.findall(r'^CREATE TABLE\s+`?([A-Za-z0-9_]+)', path.read_text(), re.M))
assert len(sql_names) == 20, sql_names
assert {'service', 'feature_flag', 'application_metric_definition'} <= sql_names
hbase = (ROOT / 'files/hbase/3.1.1/hbase-create.hbase').read_text()
assert len(re.findall(r"^create '", hbase, re.M)) == 22
# Use actual dependency output, including probe paths and PVC requests.
subprocess.run(['ruby', '-e', '''
require 'yaml'
resources=STDIN.read.split(/^---\\s*$/).filter_map {|s| YAML.safe_load(s)}
%w[server controller].each do |role|
  sts=resources.find {|r| r['kind']=='StatefulSet' && r.dig('metadata','name')=="pinpoint-pinot-#{role}"}
  c=sts.dig('spec','template','spec','containers').find {|c| c['name']==role}
  %w[startup readiness liveness].each do |kind|
    probe=c.fetch("#{kind}Probe")
    raise 'startup budget' if kind=='startup' && probe.fetch('failureThreshold')!=180
    port=role=='server' ? 8097 : 9000
    path=role=='server' ? (kind=='readiness' ? '/health/readiness' : '/health/liveness') : '/health'
    raise 'probe endpoint' unless probe.dig('httpGet','port')==port && probe.dig('httpGet','path')==path
  end
  raise 'PVC default' if role=='server' && sts.dig('spec','volumeClaimTemplates',0,'spec','resources','requests','storage')!='20Gi'
end
'''], input=rendered, text=True, check=True)
classic = subprocess.check_output(['helm','template','pinpoint',str(ROOT),'--set','global.metric.enabled=false'],text=True)
assert '  create-otlp-metric.sql:' not in classic
assert 'value: "false"\n' in classic
assert 'pinot-otlpmetric-' not in classic
assert 'name: otlp-trace' not in classic
assert 'name: otlp-trace' in rendered
policy=subprocess.check_output(['helm','template','pinpoint',str(ROOT),'--set','networkPolicy.enabled=true'],text=True)
assert '{ port: 9998, protocol: TCP }' in policy
print('3.1.1 coverage: 20 SQL tables, 22 HBase tables, 11 Pinot schemas/18 typed tables, matching Kafka topics; probes/storage/profile renders OK')
