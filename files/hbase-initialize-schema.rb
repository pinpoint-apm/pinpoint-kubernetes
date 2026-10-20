# Executed by HBase shell. Resume partially initialized stores one table at a
# time; never use a single sentinel table to skip the entire schema.
begin
  load ENV.fetch('HBASE_RETENTION_FILE', '/opt/pinpoint-hbase/hbase-retention.rb')
  retention = PinpointRetention.new
  tables = []
  verified_tables = 0
  ttl_keys = {
    'AgentInfo' => 'AGENTINFO_TTL', 'ApplicationIndex' => 'APPINDEX_TTL',
    'AgentLifeCycle' => 'AGENTLIFECYCLE_TTL', 'AgentEvent' => 'AGENTEVENT_TTL',
    'StringMetaData' => 'STRINGMETADATA_TTL', 'ApiMetaData' => 'APIMETADATA_TTL',
    'SqlMetaData_Ver2' => 'SQLMETADATA_TTL', 'TraceV2' => 'TRACEV2_TTL',
    'ApplicationTraceIndex' => 'APPTRACEINDEX_TTL',
    'ApplicationMapStatisticsCaller_Ver2' => 'APPMAPSTATCALLERV2_TTL',
    'ApplicationMapStatisticsCallee_Ver2' => 'APPMAPSTATCALLEV2_TTL',
    'ApplicationMapStatisticsSelf_Ver2' => 'APPMAPSTATSELFV2_TTL',
    'HostApplicationMap_Ver2' => 'HOSTAPPMAPV2_TTL',
    # Tables written by Pinpoint 3.1.1 v2 indexes and the optional v3 maps;
    # names match the stock pinpoint-hbase image's TTL variables.
    'TraceIndex' => 'TRACEINDEX_TTL', 'Application' => 'APPLICATION_TTL',
    'AgentId' => 'AGENTID_TTL', 'MapAppSelf' => 'MAPAPPSELF_TTL',
    'MapAgentSelf' => 'MAPAGENTSELF_TTL', 'MapAppOut' => 'MAPAPPOUT_TTL',
    'MapAppIn' => 'MAPAPPIN_TTL', 'MapAppHost' => 'MAPAPPHOST_TTL'
  }
  File.foreach(ENV.fetch('HBASE_SCHEMA_FILE', '/opt/pinpoint-hbase/hbase-create.hbase')) do |line|
    match = /^create '([^']+)'/.match(line)
    next unless match
    key = ttl_keys[match[1]]
    if key && ENV[key]
      ttl = Integer(ENV[key])
      raise 'HBase TTL must be positive' unless ttl > 0
      line = line.gsub(/TTL => \d+/, "TTL => #{ttl}")
    end
    line = retention.definition(line, match[1])
    tables << [match[1], line.scan(/NAME => '([^']+)'/).flatten]
    eval(line) unless exists(match[1])
    raise "Table #{match[1]} is disabled" unless is_enabled(match[1])
    verified_tables += 1
  end
  raise 'No Pinpoint table definitions found' if verified_tables == 0
  retention.reconcile_hbase(tables) { |table, changes| alter(table, *changes) }
  puts "Verified #{verified_tables} Pinpoint tables"
rescue => error
  warn error.message
  exit 1
end
