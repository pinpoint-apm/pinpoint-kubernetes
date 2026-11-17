{{- define "pinpoint.mysql.initSpec" -}}
backoffLimit: 3
activeDeadlineSeconds: 600
template:
  metadata:
    labels:
      {{- include "pinpoint.labels" . | nindent 6 }}
      app.kubernetes.io/component: mysql-init
  spec:
    {{- with .Values.global.imagePullSecrets }}
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    restartPolicy: OnFailure
    automountServiceAccountToken: false
    initContainers:
      - name: wait-for-mysql
        image: "{{ include "pinpoint.imageRegistry" . }}{{ .Values.mysql.image.repository }}:{{ .Values.mysql.image.tag }}"
        securityContext:
          {{- include "pinpoint.initSecurityContext" (dict "root" . "uid" 1001) | nindent 10 }}
        resources:
          {{- toYaml .Values.global.initResources.wait | nindent 10 }}
        env:
          - name: MYSQL_HOST
            value: {{ include "pinpoint.mysql.schemaHost" . | quote }}
          - name: MYSQL_PORT
            value: {{ include "pinpoint.mysql.schemaPort" . | quote }}
          - name: MYSQL_ROOT_PASSWORD
            valueFrom:
              secretKeyRef:
                name: {{ include "pinpoint.mysql.schemaSecret" . | quote }}
                key: {{ ternary "mysql-root-password" .Values.global.datasource.schema.rootPasswordSecret.key .Values.mysql.enabled | quote }}
        command:
          - 'sh'
          - '-c'
          - |
            export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
            echo "MYSQL Init Job: Waiting for MySQL database to be ready..."

            # Wait for MySQL to respond to ping
            until mysqladmin ping --connect-timeout=5 -P "$MYSQL_PORT" -h "$MYSQL_HOST" --user=root --silent; do
              echo "MYSQL Init Job: Waiting for MySQL..."
              sleep 5
            done

            # Ensure the target database exists and is ready
            until mysql --connect-timeout=5 -P "$MYSQL_PORT" -h "$MYSQL_HOST" -u root -e "USE {{ (include "pinpoint.mysql.schemaDatabase" .) }};" > /dev/null 2>&1; do
              echo "MYSQL Init Job: Waiting for database '{{ (include "pinpoint.mysql.schemaDatabase" .) }}'..."
              sleep 3
            done

            echo "MYSQL Init Job: MySQL and database are ready!"
    containers:
      - name: mysql-schema-init
        securityContext:
          {{- include "pinpoint.initSecurityContext" (dict "root" . "uid" 1001) | nindent 10 }}
        resources:
          {{- toYaml .Values.global.initResources.mysql | nindent 10 }}
        image: "{{ include "pinpoint.imageRegistry" . }}{{ .Values.mysql.image.repository }}:{{ .Values.mysql.image.tag }}"
        env:
          - name: MYSQL_PORT
            value: {{ include "pinpoint.mysql.schemaPort" . | quote }}
          - name: MYSQL_ROOT_PASSWORD
            valueFrom:
              secretKeyRef:
                name: {{ include "pinpoint.mysql.schemaSecret" . | quote }}
                key: {{ ternary "mysql-root-password" .Values.global.datasource.schema.rootPasswordSecret.key .Values.mysql.enabled | quote }}
          - name: MYSQL_HOST
            value: {{ include "pinpoint.mysql.schemaHost" . | quote }}
          - name: MYSQL_DATABASE
            value: {{ (include "pinpoint.mysql.schemaDatabase" .) | quote }}
          - name: PINPOINT_VERSION
            value: {{ .Values.global.pinpointVersion | quote }}
          - name: PINPOINT_METRIC_ENABLED
            value: {{ .Values.global.metric.enabled | quote }}
        command: ["sh", "/shared/initialize-mysql.sh"]
        volumeMounts:
          - name: sql-scripts
            mountPath: /shared
    volumes:
      - name: sql-scripts
        configMap:
          name: {{ .Release.Name }}-mysql-init-sql
          items:
            - key: initialize-mysql.sh
              path: initialize-mysql.sh
            - key: create-tables.sql
              path: create-tables.sql
            - key: create-batch-tables.sql
              path: create-batch-tables.sql
            {{- if semverCompare ">=4.0.0" .Values.global.pinpointVersion }}
            - key: create-alarm.sql
              path: create-alarm.sql
            {{- end }}
            - key: create-service.sql
              path: create-service.sql
            - key: create-feature-flag.sql
              path: create-feature-flag.sql
            {{- if .Values.global.metric.enabled }}
            - key: create-otlp-metric.sql
              path: create-otlp-metric.sql
            {{- end }}
{{- end -}}
