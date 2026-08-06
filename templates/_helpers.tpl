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
{{- printf "%s/" .Values.global.image.registry }}
{{- end }}
{{- end }}

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
    name: {{ .Release.Name }}-mysql
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
{{- define "pinpoint.kafka.bootstrapServers" -}}
{{- if .Values.global.kafka.bootstrapServers -}}
{{- .Values.global.kafka.bootstrapServers -}}
{{- else if and (hasKey .Values.kafka "enabled") (not .Values.kafka.enabled) -}}
{{- fail "global.kafka.bootstrapServers is required when kafka.enabled is false" -}}
{{- else -}}
{{- printf "%s-kafka:9092" .Release.Name -}}
{{- end -}}
{{- end -}}
