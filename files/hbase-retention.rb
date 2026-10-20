# Retain telemetry history without changing metadata or agent-liveness tables.
class PinpointRetention
  HISTORY_TABLES = %w[
    TraceV2 TraceIndex ApplicationTraceIndex AgentEvent AgentLifeCycle
    ApplicationMapStatisticsCaller_Ver2 ApplicationMapStatisticsCallee_Ver2
    ApplicationMapStatisticsSelf_Ver2 HostApplicationMap_Ver2
    MapAgentSelf MapAppHost MapAppIn MapAppOut MapAppSelf
  ].freeze

  attr_reader :enabled, :days, :apply_to_existing

  def initialize(env = ENV)
    @enabled = boolean(env.fetch('PINPOINT_RETENTION_ENABLED', 'false'))
    @apply_to_existing = boolean(env.fetch('PINPOINT_RETENTION_APPLY_TO_EXISTING', 'false'))
    value = env.fetch('PINPOINT_RETENTION_DAYS', '7')
    raise 'Retention days must be an integer from 1 to 3650' unless value.match(/\A[0-9]+\z/)
    @days = Integer(value, 10)
    raise 'Retention days must be an integer from 1 to 3650' unless (1..3650).cover?(@days)
    raise 'Applying retention to existing tables requires retention enabled' if @apply_to_existing && !@enabled
  end

  def seconds
    @days * 86_400
  end

  def definition(line, table)
    return line unless @enabled && HISTORY_TABLES.include?(table)
    line.gsub(/TTL => \d+/, "TTL => #{seconds}")
  end

  def reconcile(tables, read_families, update_families)
    return unless @enabled && @apply_to_existing
    # Read every target before issuing any alterations; preserve custom families.
    plans = tables.map do |table, families|
      next unless HISTORY_TABLES.include?(table)
      current = read_families.call(table)
      raise "Missing expected column families in #{table}" unless (families - current.keys).empty?
      changes = families.map do |family|
        {'NAME' => family, 'TTL' => seconds} unless current.fetch(family) == seconds
      end
      [table, families, changes.compact]
    end
    plans.compact.each do |table, families, changes|
      unless changes.empty?
        update_families.call(table, changes)
        puts "Applied #{days}-day retention to #{table}"
      end
      current = read_families.call(table)
      raise "Retention verification failed for #{table}" unless families.all? { |family| current[family] == seconds }
    end
    puts "Verified #{days}-day HBase history retention; metadata and liveness TTLs preserved"
  end

  def reconcile_hbase(tables, &update_families)
    return unless @enabled && @apply_to_existing
    connection = org.apache.hadoop.hbase.client.ConnectionFactory.createConnection(
      org.apache.hadoop.hbase.HBaseConfiguration.create)
    begin
      admin = connection.getAdmin
      begin
        reader = lambda do |table|
          name = org.apache.hadoop.hbase.TableName.valueOf(table)
          descriptor = admin.getTableDescriptor(name)
          descriptor.getColumnFamilies.each_with_object({}) do |family, result|
            result[family.getNameAsString] = family.getTimeToLive
          end
        end
        reconcile(tables, reader, update_families)
      ensure
        admin.close
      end
    ensure
      connection.close
    end
  end

  private

  def boolean(value)
    raise 'Retention flags must be true or false' unless %w[true false].include?(value)
    value == 'true'
  end
end
