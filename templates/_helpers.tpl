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
Web datasource JDBC URL
When mysql.enabled is false, you must provide web.datasource.jdbcUrl
*/}}
{{- define "pinpoint.web.datasource.jdbcUrl" -}}
{{- if .Values.web.datasource.jdbcUrl -}}
{{- .Values.web.datasource.jdbcUrl -}}
{{- else if .Values.mysql.enabled -}}
{{- printf "jdbc:mysql://%s-mysql:3306/%s?characterEncoding=UTF-8&serverTimezone=UTC&useSSL=false&allowPublicKeyRetrieval=true" .Release.Name .Values.mysql.auth.database -}}
{{- else -}}
{{- fail "web.datasource.jdbcUrl is required when mysql.enabled is false" -}}
{{- end -}}
{{- end -}}

{{/*
Web datasource username
When mysql.enabled is false, you must provide web.datasource.username
*/}}
{{- define "pinpoint.web.datasource.username" -}}
{{- if .Values.web.datasource.username -}}
{{- .Values.web.datasource.username -}}
{{- else if .Values.mysql.enabled -}}
{{- .Values.mysql.auth.username -}}
{{- else -}}
{{- fail "web.datasource.username is required when mysql.enabled is false" -}}
{{- end -}}
{{- end -}}

{{/*
Web datasource driver class name
*/}}
{{- define "pinpoint.web.datasource.driverClassName" -}}
{{- if .Values.web.datasource.driverClassName -}}
{{- .Values.web.datasource.driverClassName -}}
{{- else -}}
com.mysql.cj.jdbc.Driver
{{- end -}}
{{- end -}}

{{/*
Web datasource password - returns either custom value or secret reference
When mysql.enabled is false, you must provide either web.datasource.passwordSecret or web.datasource.password
*/}}
{{- define "pinpoint.web.datasource.password" -}}
{{- if .Values.web.datasource.passwordSecret -}}
{{- if not .Values.web.datasource.passwordSecret.name -}}
{{- fail "web.datasource.passwordSecret.name is required when passwordSecret is provided" -}}
{{- end -}}
{{- if not .Values.web.datasource.passwordSecret.key -}}
{{- fail "web.datasource.passwordSecret.key is required when passwordSecret is provided" -}}
{{- end -}}
valueFrom:
  secretKeyRef:
    name: {{ .Values.web.datasource.passwordSecret.name }}
    key: {{ .Values.web.datasource.passwordSecret.key }}
{{- else if .Values.web.datasource.password -}}
value: {{ .Values.web.datasource.password | quote }}
{{- else if .Values.mysql.enabled -}}
valueFrom:
  secretKeyRef:
    name: {{ .Release.Name }}-mysql
    key: mysql-password
{{- else -}}
{{- fail "web.datasource.password or web.datasource.passwordSecret is required when mysql.enabled is false" -}}
{{- end -}}
{{- end -}}
