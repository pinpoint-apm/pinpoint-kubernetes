# Exercise the real bootstrap script with transient/permanent HBase responses.
require 'open3'
root = File.expand_path('..', __dir__)
runner = <<~RUBY
  def list
    @attempts = (@attempts || 0) + 1
    case ENV['SCENARIO']
    when 'startup'
      raise 'KeeperErrorCode = NoNode for /example/hbase/master' if @attempts <= 2
    when 'timeout'
      raise 'PleaseHoldException: Master is initializing'
    when 'auth'
      raise 'AccessDeniedException: authentication required'
    end
    []
  end
  def exists(name); true; end
  def is_enabled(name); ENV['SCENARIO'] != 'disabled'; end
  eval(File.read(ARGV.fetch(0)), binding)
RUBY
expected = {'startup' => 0, 'timeout' => 1, 'auth' => 1, 'disabled' => 1}
expected.each do |scenario, code|
  out, err, status = Open3.capture3(
    {'SCENARIO' => scenario, 'HBASE_READY_TIMEOUT' => (scenario == 'startup' ? '5' : '1'), 'HBASE_READY_POLL_SECONDS' => '1',
     'PRE_SPLIT' => 'false', 'HBASE_SCHEMA_FILE' => "#{root}/backends/hbase-stackable/files/hbase-create.hbase",
     'HBASE_RETENTION_FILE' => "#{root}/files/hbase-retention.rb"},
    'ruby', '-e', runner, "#{root}/backends/hbase-stackable/files/initialize-schema.rb")
  raise "#{scenario} exit #{status.exitstatus}: #{out} #{err}" unless status.exitstatus == code
  raise 'Startup did not finish schema verification' if scenario == 'startup' && !out.include?('Verified 22')
  raise 'Timeout was not reported' if scenario == 'timeout' && !err.include?('readiness timed out')
  if %w[auth disabled].include?(scenario) && err.include?('Waiting for HBase')
    raise 'Permanent failure was incorrectly retried'
  end
  puts "HBase schema #{scenario}: passed"
end

# Bundled image initialization uses chart-owned definitions and applies TTLs
# only to missing tables. Existing stores must never be recreated.
runner = <<~RUBYCODE
  NAME=:name; TTL=:ttl; DATA_BLOCK_ENCODING=:encoding; NUMREGIONS=:regions; SPLITALGO=:split; SPLITS=:splits; VERSIONS=:versions
  def exists(name); name != 'TraceV2'; end
  def is_enabled(name); true; end
  def create(name, *definitions)
    raise 'Existing table recreated' unless name == 'TraceV2'
    raise 'TTL override not applied' unless definitions.first[TTL] == Integer(ENV.fetch('EXPECTED_TTL', '12345'))
    @created = name
  end
  eval(File.read(ARGV.fetch(0)), binding)
  raise 'Missing table not repaired' unless @created == 'TraceV2'
RUBYCODE
out, err, status = Open3.capture3(
  {'TRACEV2_TTL'=>'12345', 'HBASE_SCHEMA_FILE'=>"#{root}/files/hbase/3.1.1/hbase-create.hbase",
   'HBASE_RETENTION_FILE'=>"#{root}/files/hbase-retention.rb"},
  'ruby', '-e', runner, "#{root}/files/hbase-initialize-schema.rb")
raise "Bundled schema failed: #{out} #{err}" unless status.success? && out.include?('Verified 22')
puts 'Bundled HBase schema partial repair and TTL preservation: passed'
out, err, status = Open3.capture3(
  {'TRACEV2_TTL'=>'12345', 'EXPECTED_TTL'=>'1209600', 'PINPOINT_RETENTION_ENABLED'=>'true',
   'PINPOINT_RETENTION_DAYS'=>'14', 'PINPOINT_RETENTION_APPLY_TO_EXISTING'=>'false',
   'HBASE_SCHEMA_FILE'=>"#{root}/files/hbase/3.1.1/hbase-create.hbase",
   'HBASE_RETENTION_FILE'=>"#{root}/files/hbase-retention.rb"},
  'ruby', '-e', runner, "#{root}/files/hbase-initialize-schema.rb")
raise "Bundled history policy failed: #{out} #{err}" unless status.success? && out.include?('Verified 22')
puts 'Bundled HBase new-table history policy takes precedence over per-table TTL: passed'
