{{- define "postgres.labels" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/component: database
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
