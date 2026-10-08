{{/*
Expand the name of the chart.
*/}}
{{- define "pinpoint.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pinpoint.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pinpoint.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pinpoint.labels" -}}
helm.sh/chart: {{ include "pinpoint.chart" . }}
{{ include "pinpoint.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pinpoint.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pinpoint.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Image registry
*/}}
{{- define "pinpoint.imageRegistry" -}}
{{- if .Values.global.image.registry }}
{{- printf "%s/" (trimSuffix "/" .Values.global.image.registry) }}
{{- end }}
{{- end }}

{{/* Explicit component tags are used verbatim; only default tags get a suffix. */}}
{{- define "pinpoint.applicationImageTag" -}}
{{- if .tag -}}
{{- .tag -}}
{{- else if .root.Values.global.metric.enabled -}}
{{- printf "%s-metric" .root.Values.global.pinpointVersion -}}
{{- else -}}
{{- .root.Values.global.pinpointVersion -}}
{{- end -}}
{{- end -}}

{{/*
Override Pinot 0.3.4's helper to default to the release's shared ZooKeeper
instead of requiring a fixed "pinpoint-zookeeper" address in values.yaml.
Keep its bundled ZooKeeper and explicit external URL behavior intact.
This helper is evaluated in the Pinot subchart's context.
*/}}
{{- define "zookeeper.url" -}}
{{- if .Values.zookeeper.enabled -}}
{{- printf "%s:%v" (include "pinot.zookeeper.fullname" .) .Values.zookeeper.port -}}
{{- else -}}
{{- default (default (printf "%s-zookeeper:2181" .Release.Name) .Values.global.zookeeper.address) .Values.zookeeper.urlOverride -}}
{{- end -}}
{{- end -}}

{{/* Honor the MySQL subchart's existing Secret in all application and hook references. */}}
{{- define "pinpoint.mysql.secretName" -}}
{{- default (printf "%s-mysql" .Release.Name) .Values.mysql.auth.existingSecret -}}
{{- end -}}

{{/*
datasource JDBC URL
- used by Web and Batch components
- When mysql.enabled is false, you must provide global.datasource.jdbcUrl
*/}}
{{- define "pinpoint.datasource.jdbcUrl" -}}
{{- if .Values.global.datasource.jdbcUrl -}}
{{- .Values.global.datasource.jdbcUrl -}}
{{- else if and .Values.mysql.enabled .Values.mysql.auth.database -}}
{{- printf "jdbc:mysql://%s-mysql:3306/%s?characterEncoding=UTF-8&serverTimezone=UTC&useSSL=false&allowPublicKeyRetrieval=true" .Release.Name .Values.mysql.auth.database -}}
{{- else if .Values.mysql.enabled -}}
{{- fail "mysql.auth.database is required when mysql.enabled is true and global.datasource.jdbcUrl is not set" -}}
{{- else -}}
{{- fail "global.datasource.jdbcUrl is required when mysql.enabled is false" -}}
{{- end -}}
{{- end -}}

{{/*
datasource username
- used by Web and Batch components
- When mysql.enabled is false, you must provide global.datasource.username
*/}}
{{- define "pinpoint.datasource.username" -}}
{{- if .Values.global.datasource.username -}}
{{- .Values.global.datasource.username -}}
{{- else if .Values.mysql.enabled -}}
{{- .Values.mysql.auth.username -}}
{{- else -}}
{{- fail "global.datasource.username is required when mysql.enabled is false" -}}
{{- end -}}
{{- end -}}

{{/*
datasource driver class name
- used by Web and Batch components
*/}}
{{- define "pinpoint.datasource.driverClassName" -}}
{{- if .Values.global.datasource.driverClassName -}}
{{- .Values.global.datasource.driverClassName -}}
{{- else -}}
com.mysql.cj.jdbc.Driver
{{- end -}}
{{- end -}}

{{/*
datasource password - returns either custom value or secret reference
- used by Web and Batch components
- When mysql.enabled is false, you must provide either global.datasource.passwordSecret or global.datasource.password
*/}}
{{- define "pinpoint.datasource.password" -}}
{{- if and .Values.global.datasource.passwordSecret (or .Values.global.datasource.passwordSecret.name .Values.global.datasource.passwordSecret.key) -}}
{{- if .Values.global.datasource.password -}}
{{- fail "Configuration conflict: Both 'global.datasource.password' and 'global.datasource.passwordSecret' are set. Please use only one authentication method." }}
{{- end -}}
{{- if not .Values.global.datasource.passwordSecret.name -}}
{{- fail "global.datasource.passwordSecret.name is required when passwordSecret.key is provided" -}}
{{- end -}}
{{- if not .Values.global.datasource.passwordSecret.key -}}
{{- fail "global.datasource.passwordSecret.key is required when passwordSecret.name is provided" -}}
{{- end -}}
valueFrom:
  secretKeyRef:
    name: {{ .Values.global.datasource.passwordSecret.name }}
    key: {{ .Values.global.datasource.passwordSecret.key }}
{{- else if .Values.global.datasource.password -}}
value: {{ .Values.global.datasource.password | quote }}
{{- else if .Values.mysql.enabled -}}
valueFrom:
  secretKeyRef:
    name: {{ include "pinpoint.mysql.secretName" . | quote }}
    key: mysql-password
{{- else -}}
{{- fail "global.datasource.password or global.datasource.passwordSecret is required when mysql.enabled is false" -}}
{{- end -}}
{{- end -}}

{{/*
Redis host shared by Web and Collector.
*/}}
{{- define "pinpoint.redis.host" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s-redis-master" .Release.Name -}}
{{- else -}}
{{- required "global.redis.host is required when redis.enabled is false" .Values.global.redis.host -}}
{{- end -}}
{{- end -}}

{{/*
Redis port shared by Web and Collector.
*/}}
{{- define "pinpoint.redis.port" -}}
{{- if .Values.redis.enabled -}}
6379
{{- else -}}
{{- required "global.redis.port is required when redis.enabled is false" .Values.global.redis.port -}}
{{- end -}}
{{- end -}}

{{/*
Redis username shared by Web and Collector.
*/}}
{{- define "pinpoint.redis.username" -}}
{{- if .Values.redis.enabled -}}
{{- "" -}}
{{- else -}}
{{- .Values.global.redis.username -}}
{{- end -}}
{{- end -}}

{{/*
Redis password value or Secret reference shared by Web and Collector.
*/}}
{{- define "pinpoint.redis.password" -}}
{{- if .Values.redis.enabled -}}
{{- if .Values.redis.auth.enabled -}}
valueFrom:
  secretKeyRef:
    name: {{ default (printf "%s-redis" .Release.Name) .Values.redis.auth.existingSecret | quote }}
    key: {{ default "redis-password" .Values.redis.auth.existingSecretPasswordKey | quote }}
{{- else -}}
value: ""
{{- end -}}
{{- else -}}
{{- $secret := .Values.global.redis.passwordSecret -}}
{{- if or $secret.name $secret.key -}}
{{- if .Values.global.redis.password -}}
{{- fail "Configuration conflict: global.redis.password and global.redis.passwordSecret are mutually exclusive" -}}
{{- end -}}
{{- if not $secret.name -}}
{{- fail "global.redis.passwordSecret.name is required when passwordSecret.key is provided" -}}
{{- end -}}
{{- if not $secret.key -}}
{{- fail "global.redis.passwordSecret.key is required when passwordSecret.name is provided" -}}
{{- end -}}
valueFrom:
  secretKeyRef:
    name: {{ $secret.name | quote }}
    key: {{ $secret.key | quote }}
{{- else -}}
value: {{ .Values.global.redis.password | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Kafka bootstrap servers shared by Collector and initialization jobs.
*/}}
{{- define "pinpoint.kafka.internalEnabled" -}}
{{- if hasKey .Values.kafka "enabled" -}}
{{- ternary "true" "false" .Values.kafka.enabled -}}
{{- else -}}
{{- ternary "true" "false" .Values.global.metric.enabled -}}
{{- end -}}
{{- end -}}

{{/*
Kafka client image used by the root topic initialization job. Reuse the
bundled Kafka image so the client matches the broker and is already cached.
*/}}
{{- define "pinpoint.kafka.image" -}}
{{- $registry := .Values.kafka.image.registry -}}
{{- if .Values.global.image.registry -}}
{{- $registry = trimSuffix "/" .Values.global.image.registry -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry .Values.kafka.image.repository .Values.kafka.image.tag -}}
{{- end -}}

{{- define "pinpoint.kafka.bootstrapServers" -}}
{{- if .Values.global.kafka.bootstrapServers -}}
{{- .Values.global.kafka.bootstrapServers -}}
{{- else if and (hasKey .Values.kafka "enabled") (not .Values.kafka.enabled) -}}
{{- fail "global.kafka.bootstrapServers is required when kafka.enabled is false" -}}
{{- else -}}
{{- printf "%s-kafka:9092" .Release.Name -}}
{{- end -}}
{{- end -}}

{{/* Pinpoint coordination and HBase discovery can use separate ensembles. */}}
{{- define "pinpoint.zookeeper.address" -}}
{{- if .Values.zookeeper.enabled -}}
{{- printf "%s-zookeeper:2181" .Release.Name -}}
{{- else -}}
{{- required "global.zookeeper.address is required when zookeeper.enabled=false" .Values.global.zookeeper.address -}}
{{- end -}}
{{- end -}}

{{- define "pinpoint.hbase.quorum" -}}
{{- if .Values.global.hbase.zookeeperQuorum -}}
{{- .Values.global.hbase.zookeeperQuorum -}}
{{- else if and .Values.hbase.enabled .Values.zookeeper.enabled -}}
{{- $hosts := list -}}
{{- range $i := until (int .Values.zookeeper.replicaCount) -}}
{{- $hosts = append $hosts (printf "%s-zookeeper-client-%d.%s.svc.%s" $.Release.Name $i $.Release.Namespace $.Values.zookeeper.clusterDomain) -}}
{{- end -}}
{{- join "," $hosts -}}
{{- else -}}
{{- required "global.hbase.zookeeperQuorum is required for external HBase or ZooKeeper" .Values.global.hbase.zookeeperQuorum -}}
{{- end -}}
{{- end -}}

{{- define "pinpoint.hbase.clientEnv" }}
{{- if .Values.global.hbase.discoveryConfigMap.name }}
{{- range $field := list (dict "env" "HBASE_CLIENT_HOST" "key" "quorumKey") (dict "env" "HBASE_CLIENT_PORT" "key" "portKey") (dict "env" "HBASE_DISCOVERY_ZNODE" "key" "znodeKey") }}
- name: {{ $field.env }}
  valueFrom:
    configMapKeyRef:
      name: {{ $.Values.global.hbase.discoveryConfigMap.name | quote }}
      key: {{ index $.Values.global.hbase.discoveryConfigMap $field.key | quote }}
{{- end }}
- name: HBASE_CLIENT_ZNODE
  value: {{ printf "$(HBASE_DISCOVERY_ZNODE)%s" .Values.global.hbase.discoveryConfigMap.znodeSuffix | quote }}
{{- else }}
- name: HBASE_CLIENT_HOST
  value: {{ include "pinpoint.hbase.quorum" . | quote }}
- name: HBASE_CLIENT_PORT
  value: {{ .Values.global.hbase.clientPort | quote }}
- name: HBASE_CLIENT_ZNODE
  value: {{ .Values.global.hbase.znodeParent | quote }}
{{- end }}
- name: HBASE_NAMESPACE
  value: {{ .Values.global.hbase.namespace | quote }}
{{- end }}

{{- define "pinpoint.pinot.internalEnabled" -}}
{{- if hasKey .Values.pinot "enabled" -}}
{{- .Values.pinot.enabled -}}
{{- else -}}
{{- .Values.global.metric.enabled -}}
{{- end -}}
{{- end -}}

{{- define "pinpoint.pinot.jdbcUrl" -}}
{{- if eq (include "pinpoint.pinot.internalEnabled" .) "true" -}}
{{- printf "jdbc:pinot://%s-pinot-controller:9000" .Release.Name -}}
{{- else -}}
{{- required "global.pinot.jdbcUrl is required when pinot.enabled=false in Metric mode" .Values.global.pinot.jdbcUrl -}}
{{- end -}}
{{- end -}}

{{- define "pinpoint.pinot.controllerUrl" -}}
{{- if eq (include "pinpoint.pinot.internalEnabled" .) "true" -}}
{{- printf "http://%s-pinot-controller:9000" .Release.Name -}}
{{- else -}}
{{- required "global.pinot.controllerUrl is required when managing external Pinot tables" .Values.global.pinot.controllerUrl -}}
{{- end -}}
{{- end -}}

{{- define "pinpoint.pinot.initialize" -}}
{{- and .Values.global.metric.enabled .Values.global.pinot.createTables (or (eq (include "pinpoint.pinot.internalEnabled" .) "true") .Values.global.pinot.manageExternalTables) -}}
{{- end -}}

{{/* Default soft spread works on a single node; production can require distinct nodes. */}}
{{- define "pinpoint.applicationPodSpec" }}
terminationGracePeriodSeconds: {{ .config.terminationGracePeriodSeconds }}
automountServiceAccountToken: {{ .config.automountServiceAccountToken }}
{{- with .root.Values.global.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .config.nodeSelector }}
nodeSelector:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .config.tolerations }}
tolerations:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .config.affinity }}
affinity:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .config.podSecurityContext }}
securityContext:
{{ toYaml . | indent 2 }}
{{- end }}
topologySpreadConstraints:
{{- if .config.topologySpreadConstraints }}
{{ toYaml .config.topologySpreadConstraints | indent 2 }}
{{- else }}
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: {{ .config.topologySpreadWhenUnsatisfiable }}
    labelSelector:
      matchLabels:
{{ include "pinpoint.selectorLabels" .root | indent 8 }}
        app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}

{{- define "pinpoint.datasource.poolEnv" }}
{{- range $prefix := list "SPRING_DATASOURCE_HIKARI" "SPRING_METADATASOURCE_HIKARI" }}
- name: {{ $prefix }}_MAXIMUMPOOLSIZE
  value: {{ $.Values.global.datasource.pool.maximumPoolSize | quote }}
- name: {{ $prefix }}_MINIMUMIDLE
  value: {{ $.Values.global.datasource.pool.minimumIdle | quote }}
- name: {{ $prefix }}_CONNECTIONTIMEOUT
  value: {{ $.Values.global.datasource.pool.connectionTimeout | quote }}
{{- end }}
{{- end }}
