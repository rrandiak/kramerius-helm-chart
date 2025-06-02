{{- define "kramerius-admin-client.labels" -}}
app.kubernetes.io/name: kramerius-admin-client
app.kubernetes.io/component: admin-client
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
