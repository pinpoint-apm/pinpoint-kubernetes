# Verify history retention, opt-in migrations and Helm wiring for both charts.
require 'open3'
require 'yaml'
require_relative '../files/hbase-retention'

ROOT = File.expand_path('..', __dir__)
policy = PinpointRetention.new('PINPOINT_RETENTION_ENABLED' => 'true',
                              'PINPOINT_RETENTION_APPLY_TO_EXISTING' => 'true',
                              'PINPOINT_RETENTION_DAYS' => '7')
tables = File.readlines("#{ROOT}/backends/hbase-stackable/files/hbase-create.hbase").filter_map do |line|
  name = line[/^create '([^']+)'/, 1]
  [name, line.scan(/NAME => '([^']+)'/).flatten] if name
end
raise 'Unexpected schema coverage' unless tables.size == 22 && PinpointRetention::HISTORY_TABLES.size == 14
state = tables.to_h { |table, families| [table, families.to_h { |family| [family, 5_184_000] }] }
state['TraceV2']['custom'] = 86_400
before = Marshal.load(Marshal.dump(state))
writes = []
reader = ->(table) { state.fetch(table).dup }
writer = lambda do |table, changes|
  writes << [table, changes]
  changes.each { |change| state[table][change.fetch('NAME')] = change.fetch('TTL') }
end
policy.reconcile(tables, reader, writer)
raise 'History coverage' unless writes.map(&:first).sort == PinpointRetention::HISTORY_TABLES.sort
state.each do |table, families|
  families.each do |family, ttl|
    expected = PinpointRetention::HISTORY_TABLES.include?(table) && family != 'custom' ? 604_800 : before[table][family]
    raise "Unexpected TTL #{table}/#{family}" unless ttl == expected
  end
end
count = writes.size
policy.reconcile(tables, reader, writer)
raise 'Migration is not idempotent' unless writes.size == count

[{}, {'PINPOINT_RETENTION_ENABLED' => 'true'}].each do |env|
  PinpointRetention.new(env).reconcile(tables, ->(*) { raise 'Unexpected read' }, ->(*) { raise 'Unexpected write' })
end
['0', '-1', '1.5', '3651', 'invalid', ''].each do |days|
  begin
    PinpointRetention.new('PINPOINT_RETENTION_DAYS' => days)
    raise 'Invalid retention accepted'
  rescue RuntimeError => error
    raise unless error.message.include?('Retention days')
  end
end
begin
  PinpointRetention.new('PINPOINT_RETENTION_APPLY_TO_EXISTING' => 'true')
  raise 'Opt-in accepted without enabled policy'
rescue RuntimeError => error
  raise unless error.message.include?('requires retention enabled')
end
begin
  policy.reconcile(tables, ->(table) { table == 'MapAppSelf' ? {} : reader.call(table) }, ->(*) { raise 'Partial write' })
  raise 'Missing family accepted'
rescue RuntimeError => error
  raise unless error.message.include?('Missing expected column families')
end
stale = ->(table) { before.fetch(table) }
begin
  policy.reconcile(tables, stale, ->(*) {})
  raise 'Unverified TTL accepted'
rescue RuntimeError => error
  raise unless error.message.include?('verification failed')
end
line = "create 'TraceV2', { NAME => 'S', TTL => 12345 }"
raise 'New-table TTL policy' unless policy.definition(line, 'TraceV2').include?('TTL => 604800')
raise 'Metadata definition changed' unless policy.definition(line, 'ApiMetaData') == line
raise 'Default definition changed' unless PinpointRetention.new.definition(line, 'TraceV2') == line
raise 'Policy copies drifted' unless File.binread("#{ROOT}/files/hbase-retention.rb") ==
                                     File.binread("#{ROOT}/backends/hbase-stackable/files/hbase-retention.rb")

def render(chart, *args)
  out, err, status = Open3.capture3('helm', 'template', 'pinpoint', chart, '--namespace', 'pinpoint', *args)
  raise err unless status.success?
  YAML.load_stream(out).compact
end
def find(docs, kind, component)
  docs.find { |d| d['kind'] == kind && d.dig('metadata', 'name').include?(component) } or raise "Missing #{component}"
end
def env_of(doc)
  doc.dig('spec', 'template', 'spec', 'containers', 0, 'env').to_h { |e| [e['name'], e['value']] }
end
flags = %w[--set global.retention.enabled=true --set global.retention.days=7 --set global.retention.applyToExisting=true]
docs = render(ROOT, *flags)
%w[pinot-init hbase].each do |component|
  doc = find(docs, component == 'hbase' ? 'StatefulSet' : 'Job', component)
  env = env_of(doc)
  raise 'Missing retention flags' unless env.values_at('PINPOINT_RETENTION_ENABLED', 'PINPOINT_RETENTION_DAYS',
                                                       'PINPOINT_RETENTION_APPLY_TO_EXISTING') == %w[true 7 true]
end
cm = find(docs, 'ConfigMap', 'hbase-config')
raise 'Missing policy script' unless cm['data']['hbase-retention.rb'].include?('class PinpointRetention')

backend = "#{ROOT}/backends/hbase-stackable"
storage = %w[--set storageClass=test]
original = find(render(backend, *storage), 'Job', 'schema')
updated = find(render(backend, *storage, *flags), 'Job', 'schema')
raise 'Backend Job immutable name not changed' if original.dig('metadata', 'name') == updated.dig('metadata', 'name')
raise 'Backend flags not wired' unless env_of(updated)['PINPOINT_RETENTION_DAYS'] == '7'
next_policy = find(render(backend, *storage, *flags, '--set', 'global.retention.days=14'), 'Job', 'schema')
raise 'Changing days must create a fresh Job' if next_policy.dig('metadata', 'name') == updated.dig('metadata', 'name')
raise 'Deterministic Job name' unless find(render(backend, *storage, *flags), 'Job', 'schema').dig('metadata', 'name') == updated.dig('metadata', 'name')

[[ROOT, []], [backend, storage]].each do |chart, extras|
  ['global.retention.days=0', 'global.retention.days=-1', 'global.retention.days=1.5',
   'global.retention.days=3651', 'global.retention.days=seven', 'global.retention.applyToExisting=true'].each do |invalid|
    _out, _err, status = Open3.capture3('helm', 'template', 'pinpoint', chart, *extras, '--set', invalid)
    raise "Invalid policy accepted: #{invalid}" if status.success?
  end
end
_out, _err, status = Open3.capture3('helm', 'template', 'pinpoint', ROOT, *flags, '--set', 'global.pinot.createTables=false')
raise 'Unmanaged Pinot retention accepted' if status.success?
_out, _err, status = Open3.capture3('helm', 'template', 'pinpoint', backend, *storage, *flags, '--set', 'bootstrap.enabled=false')
raise 'Disabled backend initializer accepted' if status.success?
puts 'HBase retention safety, idempotence, metadata preservation, Helm validation and immutable Job naming: passed'
