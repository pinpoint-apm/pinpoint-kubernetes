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
  load ARGV.fetch(0)
RUBY
expected = {'startup' => 0, 'timeout' => 1, 'auth' => 1, 'disabled' => 1}
expected.each do |scenario, code|
  out, err, status = Open3.capture3(
    {'SCENARIO' => scenario, 'HBASE_READY_TIMEOUT' => (scenario == 'startup' ? '5' : '1'), 'HBASE_READY_POLL_SECONDS' => '1',
     'PRE_SPLIT' => 'false', 'HBASE_SCHEMA_FILE' => "#{root}/backends/hbase-stackable/files/hbase-create.hbase"},
    'ruby', '-e', runner, "#{root}/backends/hbase-stackable/files/initialize-schema.rb")
  raise "#{scenario} exit #{status.exitstatus}: #{out} #{err}" unless status.exitstatus == code
  raise 'Startup did not finish schema verification' if scenario == 'startup' && !out.include?('Verified 22')
  raise 'Timeout was not reported' if scenario == 'timeout' && !err.include?('readiness timed out')
  if %w[auth disabled].include?(scenario) && err.include?('Waiting for HBase')
    raise 'Permanent failure was incorrectly retried'
  end
  puts "HBase schema #{scenario}: passed"
end
