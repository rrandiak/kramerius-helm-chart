{{/*
Selector and pod template labels for process-manager (StatefulSet + Service).
*/}}
{{- define "kramerius.processManager.matchLabels" -}}
app.kubernetes.io/name: process-manager
app.kubernetes.io/component: process-manager
{{- end }}

{{/*
Process manager base URL for workers and Tomcat apps (cluster DNS; must match .Values.namespace).
*/}}
{{- define "kramerius.processManagerUrl" -}}
http://process-manager.{{ .Values.namespace }}.svc.cluster.local:80/process-manager/api/
{{- end }}

{{/*
Process manager host for configuration.properties (processManagerHost key).
*/}}
{{- define "kramerius.processManagerHost" -}}
http://process-manager.{{ .Values.namespace }}.svc.cluster.local:80
{{- end }}
