{{- define "backend.name" -}}
{{- $name := .Release.Name -}}
{{- if hasSuffix "-storage" .Release.Name -}}
{{- $name = .Release.Name -}}
{{- else -}}
{{- $name = printf "%s-storage" .Release.Name -}}
{{- end -}}
{{- /* Leave room for operator-generated role/group Service names. */ -}}
{{- if gt (len $name) 29 -}}
{{- printf "%s-%s" ($name | trunc 20 | trimSuffix "-") ($name | sha256sum | trunc 8) -}}
{{- else -}}
{{- $name -}}
{{- end -}}
{{- end -}}
{{- define "backend.metadata" -}}
labels:
  app.kubernetes.io/part-of: pinpoint-storage
  app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.keepResources }}
annotations:
  helm.sh/resource-policy: keep
{{- end }}
{{- end -}}
{{- define "backend.affinity" -}}
affinity:
  nodeSelector: {{ .root.Values.nodeSelector | toJson }}
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: {{ .root.Values.topologyKey | quote }}
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ .product }}
            app.kubernetes.io/instance: {{ .cluster }}
            app.kubernetes.io/component: {{ .role }}
{{- end -}}
{{- define "backend.resources" -}}
{{- $resources := deepCopy .resources -}}
{{- if hasKey $resources "storage" -}}
{{- range $disk, $config := $resources.storage -}}
{{- $_ := set $config "storageClass" $.root.Values.storageClass -}}
{{- end -}}
{{- end -}}
resources:
  {{- toYaml $resources | nindent 2 }}
{{- end -}}
{{- define "backend.image" -}}
{{- $settings := index .root.Values .product -}}
{{- if $settings.customImage -}}
{{- $settings.customImage -}}
{{- else -}}
{{- $image := .product -}}
{{- if eq .product "hdfs" -}}{{- $image = "hadoop" -}}{{- end -}}
{{- printf "oci.stackable.tech/sdp/%s:%s-stackable26.7.0" $image $settings.version -}}
{{- end -}}
{{- end -}}
