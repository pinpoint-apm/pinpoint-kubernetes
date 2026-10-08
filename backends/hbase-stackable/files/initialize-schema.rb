# Run by HBase Shell. Wait for transient Master startup errors in this pod;
# permanent failures (including disabled tables) still fail the Job.
begin
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Integer(ENV.fetch('HBASE_READY_TIMEOUT', '900'))
  loop do
    begin
      list # A successful Master table-list RPC requires initialized HBase.
      break
    rescue => error
      message = error.message
      transient = /KeeperErrorCode = NoNode|MasterNotRunningException|PleaseHoldException|ServerNotRunningYetException|Connection refused|ConnectionClosedException/.match(message)
      raise unless transient
      raise "HBase readiness timed out: #{message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      warn "Waiting for HBase Master initialization: #{message}"
      sleep Integer(ENV.fetch('HBASE_READY_POLL_SECONDS', '5'))
    end
  end
  verified_tables = 0
  File.foreach(ENV.fetch('HBASE_SCHEMA_FILE', '/schema/hbase-create.hbase')) do |line|
    match = /^create '([^']+)'/.match(line)
    next unless match
    if ENV['PRE_SPLIT'] == 'false'
      line = line.sub(/,\s*\{SPLITS.*$/, '').sub(/,\s*\{NUMREGIONS.*$/, '')
    end
    eval(line) unless exists(match[1])
    raise "Table #{match[1]} is disabled" unless is_enabled(match[1])
    verified_tables += 1
  end
  raise 'Expected 22 Pinpoint 3.1.1 tables' unless verified_tables == 22
  puts "Verified #{verified_tables} Pinpoint tables"
rescue => error
  warn error.message
  exit 1
end
