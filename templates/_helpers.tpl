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
{{- else if .Values.mysql.enabled -}}
{{- printf "jdbc:mysql://%s-mysql:3306/%s?characterEncoding=UTF-8&serverTimezone=UTC&useSSL=false&allowPublicKeyRetrieval=true" .Release.Name .Values.mysql.auth.database -}}
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
