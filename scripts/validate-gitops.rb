#!/usr/bin/env ruby

require 'open3'
require 'yaml'

root = File.expand_path('..', __dir__)
example = File.join(root, 'examples/gitops')
load_yaml = ->(path) { YAML.safe_load_file(path) }
check = ->(condition, message) { raise message unless condition }
documents = YAML.load_stream(File.read(File.join(example, 'application.yaml')))
project = documents.find { |doc| doc['kind'] == 'AppProject' }
application = documents.find { |doc| doc['kind'] == 'Application' }
storage = load_yaml.call(File.join(example, 'storage.yaml'))
bootstrap_docs = YAML.load_stream(File.read(File.join(example, 'bootstrap.yaml')))
bootstrap_project = bootstrap_docs.find { |doc| doc['kind'] == 'AppProject' }
bootstrap = bootstrap_docs.find { |doc| doc['kind'] == 'Application' }
kustomization = load_yaml.call(File.join(example, 'kustomization.yaml'))
check.call(kustomization['resources'] == %w[bootstrap.yaml application.yaml], 'Unexpected bootstrap resources')
check.call(bootstrap.dig('spec', 'source', 'path') == 'examples/gitops', 'Root must track the GitOps directory')
check.call(bootstrap.dig('spec', 'destination', 'namespace') == 'argocd', 'Root must deploy Argo CD resources')
check.call(bootstrap.dig('spec', 'source', 'repoURL') == application.dig('spec', 'sources', 2, 'repoURL'),
           'Bootstrap and environment values must track the same repository')
check.call(bootstrap_project.dig('spec', 'sourceRepos').include?(bootstrap.dig('spec', 'source', 'repoURL')),
           'Unapproved bootstrap repository')
check.call(bootstrap.dig('spec', 'syncPolicy', 'automated', 'prune') == false, 'Bootstrap pruning must remain opt-in')
app_version = load_yaml.call(File.join(root, 'Chart.yaml')).fetch('version')
storage_version = load_yaml.call(File.join(root, 'backends/hbase-stackable/Chart.yaml')).fetch('version')

[application, storage].each do |app|
  spec = app.fetch('spec')
  check.call(spec['project'] == project.dig('metadata', 'name'), 'GitOps project mismatch')
  check.call(spec.dig('syncPolicy', 'automated', 'prune') == false, 'Pruning must remain opt-in')
  spec.fetch('sources').each do |source|
    check.call(project.dig('spec', 'sourceRepos').include?(source.fetch('repoURL')), 'Unapproved source repository')
    next unless source['chart']
    check.call(source.dig('helm', 'releaseName') == app.dig('metadata', 'name'), 'Application/release label mismatch')
  end
end

sources = application.dig('spec', 'sources')
helm_source = sources.find { |source| source['chart'] }
check.call(helm_source['targetRevision'] == app_version, 'Application chart revision is stale')
defaults = sources.find { |source| source['ref'] == 'defaults' }
check.call(defaults['targetRevision'] == "pinpoint-#{app_version}", 'Production defaults must be pinned to the chart tag')
refs = sources.filter_map { |source| source['ref'] }
value_paths = helm_source.dig('helm', 'valueFiles').map do |reference|
  match = reference.match(%r{^\$([^/]+)/(.*)$})
  check.call(match && refs.include?(match[1]), "Unresolved values reference: #{reference}")
  File.join(root, match[2])
end

render = lambda do |chart, values_args|
  stdout, stderr, status = Open3.capture3('helm', 'template', chart == root ? 'pinpoint' : 'pinpoint-storage',
                                       chart, '--namespace', 'pinpoint', *values_args)
  raise stderr unless status.success?
  YAML.load_stream(stdout).compact
end
resources = render.call(root, value_paths.flat_map { |path| ['-f', path] })
deployments = resources.select { |resource| resource['kind'] == 'Deployment' }
check.call(deployments.map { |resource| resource.dig('metadata', 'name') }.sort == %w[pinpoint-collector pinpoint-web],
           'GitOps production example must render only Web/Collector deployments')
check.call(resources.none? { |resource| %w[StatefulSet Secret].include?(resource['kind']) },
           'GitOps application example must use existing backends and Secrets')
service = resources.find { |resource| resource.dig('metadata', 'name') == 'pinpoint-collector-external' }
check.call(service&.dig('spec', 'ports')&.map { |port| port['nodePort'] } == [30991, 30992, 30993],
           'External Collector NodePorts were not rendered')

check.call(storage.dig('spec', 'sources', 0, 'targetRevision') == storage_version, 'Storage chart revision is stale')
check.call(storage.dig('spec', 'syncPolicy', 'syncOptions').include?('ServerSideApply=true'), 'Storage requires server-side apply')
check.call(storage.dig('metadata', 'annotations', 'argocd.argoproj.io/compare-options') == 'ServerSideDiff=true',
           'Storage requires server-side diff')
backend_resources = render.call(File.join(root, 'backends/hbase-stackable'), ['--set', 'storageClass=example-storage'])
zookeeper = backend_resources.find { |resource| resource['kind'] == 'ZookeeperCluster' }
tls = zookeeper.dig('spec', 'clusterConfig', 'tls')
check.call(tls.key?('serverSecretClass') && tls['serverSecretClass'].nil?, 'Client TLS must be explicitly disabled')

puts 'GitOps sources, production rendering, external Collector Service and storage settings: passed'
