#!/usr/bin/env ruby
# Public Service contract: stable agent ports, unchanged internal endpoint,
# release-scoped selectors, and validation before reaching the Kubernetes API.
require 'open3'
require 'tempfile'
require 'yaml'

chart = File.expand_path(ARGV.fetch(0, File.join(__dir__, '..')))

def render(chart, values = {}, release: 'pinpoint', error: nil)
  Tempfile.create(['collector-values', '.yaml']) do |file|
    file.write(YAML.dump(values))
    file.flush
    stdout, stderr, status = Open3.capture3(
      'helm', 'template', release, chart, '--namespace', 'telemetry', '-f', file.path
    )
    if error
      raise "Expected validation error containing #{error.inspect}" if status.success?
      output = stdout + stderr
      # Helm versions report JSON paths as dotted names or slash-separated paths.
      raise "Unexpected validation error: #{stderr}" unless output.include?(error) || output.tr('/', '.').include?(error)
      return nil
    end
    raise stderr unless status.success?
    return stdout.split(/^---\s*$/).filter_map { |document| YAML.safe_load(document) }
  end
end

def service(resources, name)
  resources.find { |r| r['kind'] == 'Service' && r.dig('metadata', 'name') == name }
end

defaults = render(chart)
raise 'External Service must be opt-in' if service(defaults, 'pinpoint-collector-external')
baseline = service(defaults, 'pinpoint-collector')
raise 'Internal Service default changed' unless baseline.dig('spec', 'type') == 'ClusterIP'

fixed = {
  'enabled' => true,
  'name' => 'pinpoint-collector-nodeport',
  'annotations' => { 'example.com/purpose' => 'agent access' },
  'nodePorts' => { 'grpcAgent' => 30991, 'grpcStat' => 30992, 'grpcSpan' => 30993 }
}
resources = render(chart, { 'collector' => { 'externalService' => fixed } })
external = service(resources, fixed['name'])
raise 'Internal Service changed when enabling external access' unless service(resources, 'pinpoint-collector') == baseline
raise 'Missing external Service' unless external
raise 'Lost custom annotation' unless external.dig('metadata', 'annotations', 'example.com/purpose') == 'agent access'
raise 'Incorrect traffic policy' unless external.dig('spec', 'externalTrafficPolicy') == 'Cluster'
ports = external.dig('spec', 'ports')
raise 'Unexpected receivers exposed' unless ports.map { |p| p['name'] } == %w[grpc-agent grpc-stat grpc-span]
raise 'Agent port mapping changed' unless ports.map { |p| [p['port'], p['targetPort'], p['nodePort'], p['protocol']] } ==
  [[9991, 9991, 30991, 'TCP'], [9992, 9992, 30992, 'TCP'], [9993, 9993, 30993, 'TCP']]
deployment = resources.find { |r| r['kind'] == 'Deployment' && r.dig('metadata', 'name') == 'pinpoint-collector' }
raise 'Selector does not match Collector pods' unless external.dig('spec', 'selector') == deployment.dig('spec', 'template', 'metadata', 'labels')

%w[metric classic].each do |profile|
  options = { 'global' => { 'metric' => { 'enabled' => profile == 'metric' } },
              'collector' => { 'externalService' => { 'enabled' => true } } }
  dynamic = service(render(chart, options, release: 'observability'), 'observability-pinpoint-collector-external')
  raise 'Unexpected explicit NodePort with automatic allocation' if dynamic.dig('spec', 'ports').any? { |p| p.key?('nodePort') }
  raise 'Selector is not release-scoped' unless dynamic.dig('spec', 'selector', 'app.kubernetes.io/instance') == 'observability'
  raise 'Default external Service type changed' unless dynamic.dig('spec', 'type') == 'NodePort'
end

lb = { 'enabled' => true, 'type' => 'LoadBalancer', 'externalTrafficPolicy' => 'Local',
       'loadBalancerSourceRanges' => ['192.0.2.0/24'] }
load_balancer = service(render(chart, { 'collector' => { 'externalService' => lb } }), 'pinpoint-collector-external')
raise 'LoadBalancer settings lost' unless load_balancer.dig('spec', 'type') == 'LoadBalancer' &&
  load_balancer.dig('spec', 'externalTrafficPolicy') == 'Local' &&
  load_balancer.dig('spec', 'loadBalancerSourceRanges') == ['192.0.2.0/24']

renamed = { 'fullnameOverride' => 'tracing', 'collector' => {
  'service' => { 'ports' => { 'grpcAgent' => 10991, 'grpcStat' => 10992, 'grpcSpan' => 10993 } },
  'externalService' => { 'enabled' => true }
} }
custom = service(render(chart, renamed), 'tracing-collector-external')
raise 'Service ports ignored or container ports changed' unless custom.dig('spec', 'ports').map { |p| [p['port'], p['targetPort']] } ==
  [[10991, 9991], [10992, 9992], [10993, 9993]]

render(chart, { 'collector' => { 'enabled' => false, 'externalService' => { 'enabled' => true } } }, error: 'requires collector.enabled=true')
render(chart, { 'collector' => { 'externalService' => fixed.merge('name' => 'pinpoint-collector') } }, error: 'must differ from the internal')
render(chart, { 'collector' => { 'externalService' => fixed.merge('nodePorts' => { 'grpcAgent' => 30991, 'grpcStat' => 30991 }) } }, error: 'must use distinct port numbers')
render(chart, { 'collector' => { 'externalService' => { 'enabled' => true, 'loadBalancerSourceRanges' => ['192.0.2.0/24'] } } }, error: 'requires type=LoadBalancer')
[
  { 'type' => 'ClusterIP' },
  { 'externalTrafficPolicy' => 'Invalid' },
  { 'name' => 'Invalid_Name' },
  { 'nodePorts' => { 'grpcAgent' => 0 } },
  { 'nodePorts' => { 'grpcAgent' => 65536 } },
  { 'nodePorts' => { 'grpcAgent' => '30991' } },
  { 'nodePorts' => { 'grpcAgent' => 30991.5 } },
  { 'nodePorts' => { 'unknown' => 30991 } }
].each do |invalid|
  render(chart, { 'collector' => { 'externalService' => invalid.merge('enabled' => true) } }, error: 'collector.externalService')
end
puts 'Collector external Service: defaults, fixed/allocated ports, profiles, LoadBalancer, selectors and invalid values OK'
