# Executed by HBase shell. Resume partially initialized stores one table at a
# time; never use a single sentinel table to skip the entire schema.
begin
  verified_tables = 0
  File.foreach(File.join(ENV.fetch('BASE_DIR'), 'hbase-create.hbase')) do |line|
    match = /^create '([^']+)'/.match(line)
    next unless match
    eval(line) unless exists(match[1])
    raise "Table #{match[1]} is disabled" unless is_enabled(match[1])
    verified_tables += 1
  end
  raise 'No Pinpoint table definitions found' if verified_tables == 0
  puts "Verified #{verified_tables} Pinpoint tables"
rescue => error
  warn error.message
  exit 1
end
