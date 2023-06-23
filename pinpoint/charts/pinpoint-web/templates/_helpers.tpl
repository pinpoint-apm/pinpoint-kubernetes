{{/*
Expand the name of the chart.
*/}}
{{- define "pinpoint-web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pinpoint-web.fullname" -}}
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
{{- define "pinpoint-web.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pinpoint-web.labels" -}}
helm.sh/chart: {{ include "pinpoint-web.chart" . }}
{{ include "pinpoint-web.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pinpoint-web.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pinpoint-web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "pinpoint-web"
{{- end }}

{{/*
Create Mysql Username
*/}}
{{- define "pinpoint-web.mysql.username" -}}
{{- default "admin" .Values.mysql.user -}}
{{- end }}

{{/*
Create Mysql Password 
*/}}
{{- define "pinpoint-web.mysql.password" -}}
{{- default "admin" .Values.mysql.password -}}
{{- end }}

{{/*
Create Mysql Database for Pinpoint
*/}}
{{- define "pinpoint-web.mysql.database" -}}
{{- default "pinpoint" .Values.mysql.database -}}
{{- end }}


{{- define "pinpoint-web.mysql.fullname" -}}
{{- $name := default "pinpoint-mysql" .Values.mysql.serviceName -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "pinpoint-web.mysql.url" -}}
{{- $host :=  default (include "pinpoint-web.mysql.fullname" .) .Values.mysql.host }}
{{- $port :=  default 3306 .Values.mysql.port | int }}
{{- printf "jdbc:mysql://%s:%d/%s?characterEncoding=UTF-8" $host $port (include "pinpoint-web.mysql.database" .) }}
{{- end }}

{{- define "pinpoint-web.zookeeper.fullname" -}}
{{- $name := default "pinpoint-zookeeper" .Values.zookeeper.host -}}
{{- printf "%s-%s" .Release.Name $name | trunc 47 | trimSuffix "-" -}}
{{- end -}}