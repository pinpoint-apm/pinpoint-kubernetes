{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "batch.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 47 chars because some Kubernetes name fields are limited to 63 (by the DNS naming spec),
as we append -master or -region to the names
If release name contains chart name it will be used as a full name.
*/}}
{{- define "batch.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 47 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 47 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Standard Labels from Helm documentation https://helm.sh/docs/chart_best_practices/#labels-and-annotations
*/}}

{{- define "batch.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{- end -}}

{{- define "batch.zookeeper.fullname" -}}
{{- $name := default "pinpoint-zookeeper-hbase" .Values.zookeeper.host -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "batch.flink.fullname" -}}
{{- $name := default "pinpoint-flink" .Values.flink.host -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "batch.mysql.fullname" -}}
{{- $name := default "pinpoint-mysql" .Values.mysql.serviceName -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "batch.mysql.url" -}}
{{- $host :=  default (include "batch.mysql.fullname" .) .Values.mysql.host }}
{{- $port :=  default 3306 .Values.mysql.port | int }}
{{- $database :=  default "pinpoint" .Values.mysql.database }}
{{- printf "jdbc:mysql://%s:%d/%s?characterEncoding=UTF-8" $host $port $database }}
{{- end }}

Create Mysql Username
*/}}
{{- define "batch.mysql.username" -}}
{{- default "admin" .Values.mysql.user -}}
{{- end }}

{{/*
Create Mysql Password
*/}}
{{- define "batch.mysql.password" -}}
{{- default "admin" .Values.mysql.password -}}
{{- end }}