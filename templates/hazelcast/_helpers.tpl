{{- define "kramerius-hazelcast.labels" -}}
app.kubernetes.io/name: kramerius-hazelcast
app.kubernetes.io/component: lock-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /*
Build javaOpts for Hazelcast from resources.*.memory
*/ -}}
{{- define "hazelcast.javaOpts" -}}
{{- $opts := list }}

{{- with .container.resources.requests.memory }}
  {{- $memReq := . | trimSuffix "i" }}
  {{- $opts = append $opts (printf "-Xms%s" $memReq) }}
{{- end }}

{{- with .container.resources.limits.memory }}
  {{- $memLimit := . | trimSuffix "i" }}
  {{- $opts = append $opts (printf "-Xmx%s" $memLimit) }}
{{- end }}

{{- join " " $opts }}
{{- end }}
