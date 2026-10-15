# Render-time contract for chart 3.1.5 security, compatibility and profile
# defaults. Runs `helm template` and inspects the parsed manifests.
require 'base64'
require 'open3'
require 'yaml'

CHART = ARGV.fetch(0, '.')

def render(*args)
  out, err, status = Open3.capture3('helm', 'template', 'pinpoint', CHART, '--namespace', 'pinpoint', *args)
  raise "helm template #{args.join(' ')} failed: #{err}" unless status.success?
  out.split(/^---\s*$/).filter_map do |chunk|
    source = chunk[/# Source: (\S+)/, 1]
    doc = YAML.safe_load(chunk)
    doc.is_a?(Hash) ? doc.merge('__source' => source) : nil
  end
end

def render_failure(expected, *args)
  _out, err, status = Open3.capture3('helm', 'template', 'pinpoint', CHART, '--namespace', 'pinpoint', *args)
  raise "Expected failure for #{args.join(' ')}" if status.success?
  raise "Missing '#{expected}' in: #{err}" unless err.include?(expected)
end

def pod_spec(doc)
  return nil unless %w[Deployment StatefulSet DaemonSet Job].include?(doc['kind'])
  doc.dig('spec', 'template', 'spec')
end

def containers(spec)
  [*spec['initContainers'], *spec['containers']]
end

def chart_owned(docs)
  docs.select { |doc| doc['__source'].to_s.start_with?('pinpoint/templates/') }
end

def env(container, name)
  (container['env'] || []).find { |entry| entry['name'] == name }
end

def find(docs, kind, name)
  docs.find { |doc| doc['kind'] == kind && doc.dig('metadata', 'name') == name } or
    raise "Missing #{kind}/#{name}"
end

# Pod Security "restricted" requirements checked per container.
def restricted_violations(spec, container)
  context = container['securityContext'] || {}
  pod = spec['securityContext'] || {}
  problems = []
  problems << 'allowPrivilegeEscalation' unless context['allowPrivilegeEscalation'] == false
  problems << 'capabilities' unless Array(context.dig('capabilities', 'drop')).include?('ALL')
  problems << 'runAsNonRoot' unless context['runAsNonRoot'] || pod['runAsNonRoot']
  problems << 'runAsUser=0' if (context['runAsUser'] || pod['runAsUser']) == 0
  seccomp = (context['seccompProfile'] || pod['seccompProfile'] || {})['type']
  problems << 'seccomp' unless %w[RuntimeDefault Localhost].include?(seccomp)
  problems
end

# --- Default evaluation profile --------------------------------------------
docs = render
web = find(docs, 'Deployment', 'pinpoint-web')
web_container = web.dig('spec', 'template', 'spec', 'containers').first
admin = env(web_container, 'ADMIN_PASSWORD')
raise 'ADMIN_PASSWORD must come from a Secret' unless admin.dig('valueFrom', 'secretKeyRef', 'name') == 'pinpoint-web-admin-api'
secret = find(docs, 'Secret', 'pinpoint-web-admin-api')
password = Base64.decode64(secret.dig('data', 'admin-password'))
raise 'Generated admin password is weak' unless password.match?(/\A[A-Za-z0-9]{32}\z/)
raise 'Usage reporting must default to off' unless env(web_container, 'CONFIG_SENDUSAGE')['value'] == 'false'
containers(web.dig('spec', 'template', 'spec')).each do |container|
  raise "Web #{container['name']} receives the MySQL root password" if env(container, 'MYSQL_ROOT_PASSWORD')
end

mysql_secret = docs.find { |doc| doc['kind'] == 'Secret' && doc['__source'].to_s.include?('charts/mysql/') }
%w[mysql-password mysql-root-password].each do |key|
  value = Base64.decode64(mysql_secret.dig('data', key))
  raise "Bundled MySQL #{key} uses a well-known default" if %w[pinpoint mysql].include?(value) || value.empty?
end

raise 'Standalone agent must not render' if docs.any? { |doc| doc.dig('metadata', 'name') == 'pinpoint-agent' }
raise 'Telegraf must be opt-in' if docs.any? { |doc| doc.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'telegraf' }

chart_owned(docs).each do |doc|
  spec = pod_spec(doc) or next
  name = doc.dig('metadata', 'name')
  component = doc.dig('metadata', 'labels', 'app.kubernetes.io/component')
  containers(spec).each do |container|
    raise "#{name}/#{container['name']} uses an unpinned busybox" if container['image'] == 'busybox'
    raise "#{name} mounts a hostPath" if Array(spec['volumes']).any? { |volume| volume['hostPath'] }
    raise "#{name}/#{container['name']} allows privilege escalation" unless container.dig('securityContext', 'allowPrivilegeEscalation') == false
    # Web, Collector, dependency checks and every Job meet "restricted". The
    # Quickstart agent copy keeps the demo image's root user for file ownership.
    strict = %w[web collector].include?(component) || doc['kind'] == 'Job' || container['name'].start_with?('wait-for-')
    next unless strict
    problems = restricted_violations(spec, container)
    raise "#{name}/#{container['name']} violates restricted: #{problems.join(', ')}" unless problems.empty?
  end
end

kafka_job = find(docs, 'Job', 'pinpoint-kafka-init')
script = kafka_job.dig('spec', 'template', 'spec', 'containers', 0, 'command', 2)
%w[url-stat system-metric-data-type system-metric-tag system-metric-double exception-trace
   inspector-stat-app inspector-stat-agent-00 heatmap-stat-app-00 otlp-metric-metadata
   otlp-metric-double-00 otlp-metric-long-00].each do |topic|
  raise "Kafka initializer misses #{topic}" unless script.match?(/^#{Regexp.escape(topic)} \d+$/)
end
raise 'Kafka initializer must repair partition counts' unless script.include?('--alter') && script.include?("<<'TOPICS'")

hbase = find(docs, 'StatefulSet', 'pinpoint-hbase').dig('spec', 'template', 'spec', 'containers', 0)
{ 'TRACEINDEX_TTL' => '604800', 'APPLICATION_TTL' => '31536000', 'AGENTID_TTL' => '5184000' }.each do |key, value|
  raise "HBase #{key} must default to #{value}" unless env(hbase, key)&.fetch('value') == value
end

# --- Registry, pull secrets and pod options ---------------------------------
[['--set', 'global.metric.enabled=true'], ['--set', 'global.metric.enabled=false']].each do |mode|
  # Bitnami charts refuse relocated images without allowInsecureImages.
  docs = render(*mode, '--set', 'global.imageRegistry=mirror.example.com',
                '--set', 'global.security.allowInsecureImages=true',
                '--set', 'global.imagePullSecrets[0].name=regcred', '--set', 'telegraf.enabled=true')
  docs.each do |doc|
    spec = pod_spec(doc) or next
    next if doc['__source'].to_s.include?('charts/pinot/')
    unless Array(spec['imagePullSecrets']).any? { |entry| entry['name'] == 'regcred' }
      raise "#{doc['kind']}/#{doc.dig('metadata', 'name')} ignores global.imagePullSecrets"
    end
    containers(spec).each do |container|
      next if container['image'].start_with?('mirror.example.com/')
      raise "#{doc.dig('metadata', 'name')}/#{container['name']} ignores global.imageRegistry: #{container['image']}"
    end
  end
end

docs = render('--set', 'web.adminApi.passwordSecret.name=pinpoint-admin',
              '--set', 'web.adminApi.passwordSecret.key=password',
              '--set', 'web.podLabels.team=observability', '--set', 'web.priorityClassName=critical',
              '--set', 'web.serviceAccountName=pinpoint-web',
              '--set', 'web.lifecycle.preStop.exec.command[0]=sleep', '--set-string', 'web.lifecycle.preStop.exec.command[1]=10')
raise 'Generated admin Secret must not render with an existing Secret' if docs.any? { |doc| doc.dig('metadata', 'name') == 'pinpoint-web-admin-api' }
web = find(docs, 'Deployment', 'pinpoint-web')
spec = web.dig('spec', 'template', 'spec')
raise 'Existing admin Secret is not referenced' unless env(spec['containers'][0], 'ADMIN_PASSWORD').dig('valueFrom', 'secretKeyRef') == { 'name' => 'pinpoint-admin', 'key' => 'password' }
raise 'podLabels missing' unless web.dig('spec', 'template', 'metadata', 'labels', 'team') == 'observability'
raise 'priorityClassName missing' unless spec['priorityClassName'] == 'critical'
raise 'serviceAccountName missing' unless spec['serviceAccountName'] == 'pinpoint-web'
raise 'lifecycle missing' unless spec.dig('containers', 0, 'lifecycle', 'preStop', 'exec', 'command') == %w[sleep 10]

# --- Telegraf ---------------------------------------------------------------
docs = render('--set', 'telegraf.enabled=true', '--set', 'telegraf.hostGroupName=production-nodes')
telegraf = find(docs, 'DaemonSet', 'pinpoint-telegraf')
paths = telegraf.dig('spec', 'template', 'spec', 'volumes').filter_map { |volume| volume.dig('hostPath', 'path') }
raise "Telegraf hostPath mounts must be /proc and /sys only: #{paths}" unless paths.sort == %w[/proc /sys]
raise 'Telegraf must report node names' unless env(telegraf.dig('spec', 'template', 'spec', 'containers', 0), 'NODE_NAME')
config = find(docs, 'ConfigMap', 'pinpoint-telegraf-config').dig('data', 'telegraf.conf')
raise 'Telegraf hostname substitution missing' unless config.include?('hostname = "${NODE_NAME}"')
raise 'Telegraf host group override missing' unless config.include?('hostGroupName = "production-nodes"')
raise 'Telegraf must target the Collector metric port' unless config.include?('http://pinpoint-collector:15200/telegraf')

# --- Gateway API ------------------------------------------------------------
docs = render('--set', 'web.httpRoute.enabled=true', '--set', 'web.httpRoute.parentRefs[0].name=shared',
              '--set', 'web.httpRoute.hostnames[0]=pinpoint.example.com')
route = find(docs, 'HTTPRoute', 'pinpoint-web')
raise 'HTTPRoute backend mismatch' unless route.dig('spec', 'rules', 0, 'backendRefs', 0) == { 'name' => 'pinpoint-web', 'port' => 8080 }
render_failure('web.httpRoute.parentRefs is required', '--set', 'web.httpRoute.enabled=true')

# --- Batch alarm mail (classic) --------------------------------------------
docs = render('--set', 'global.metric.enabled=false', '--set', 'batch.mail.enabled=true',
              '--set', 'batch.mail.host=smtp.example.com', '--set', 'batch.mail.username=alerts@example.com')
batch = find(docs, 'Deployment', 'pinpoint-batch').dig('spec', 'template', 'spec', 'containers', 0)
{ 'SPRING_MAIL_HOST' => 'smtp.example.com', 'SPRING_MAIL_PROPERTIES_MAIL_SMTP_AUTH' => 'true',
  'SPRING_MAIL_PROPERTIES_MAIL_SMTP_STARTTLS_ENABLE' => 'true',
  'SPRING_MAIL_PROPERTIES_MAIL_SMTP_FROM' => 'alerts@example.com' }.each do |key, value|
  raise "Batch #{key} must be #{value}" unless env(batch, key)&.fetch('value') == value
end
raise 'Batch must not set unused ALARM_MAIL_* or ADMIN_PASSWORD' if batch['env'].any? { |entry| entry['name'].start_with?('ALARM_MAIL_') || entry['name'] == 'ADMIN_PASSWORD' }
raise 'Classic Flink must use 3.0.5' unless find(docs, 'Deployment', 'pinpoint-flink-jobmanager').dig('spec', 'template', 'spec', 'containers', 0, 'image').end_with?(':3.0.5"') ||
                                           find(docs, 'Deployment', 'pinpoint-flink-jobmanager').dig('spec', 'template', 'spec', 'containers', 0, 'image').end_with?(':3.0.5')
render_failure('batch.mail.host is required', '--set', 'global.metric.enabled=false', '--set', 'batch.mail.enabled=true')

# --- Removed and invalid settings -------------------------------------------
render_failure('docs/AGENTS.md', '--set', 'agent.enabled=true')
render_failure('colector', '--set', 'colector.replicaCount=2')
render_failure('partitions', '--set', 'global.kafka.topics[0].name=agent-info', '--set', 'global.kafka.topics[0].partitions=0')

# --- Minimal profile fits a small single node --------------------------------
docs = render('-f', File.join(CHART, 'values-minimal.yaml'))
def memory_mi(value)
  number = value.to_s.to_f
  case value.to_s
  when /Gi\z/ then number * 1024
  when /Mi\z/ then number
  else number / (1024 * 1024)
  end
end
total = docs.sum do |doc|
  spec = pod_spec(doc)
  next 0 if spec.nil? || doc['kind'] == 'Job'
  replicas = doc.dig('spec', 'replicas') || 1
  spec['containers'].sum { |container| memory_mi(container.dig('resources', 'requests', 'memory')) } * replicas
end
raise format('values-minimal.yaml requests %.0f MiB; keep it below 8.5 GiB', total) if total > 8.5 * 1024
kafka = docs.select { |doc| doc['kind'] == 'StatefulSet' && doc.dig('metadata', 'name').start_with?('pinpoint-kafka') }
raise 'Minimal Kafka must run one node' unless kafka.sum { |doc| doc.dig('spec', 'replicas').to_i } == 1
puts format('Chart hardening contract passed (minimal profile requests %.1f GiB).', total / 1024)
