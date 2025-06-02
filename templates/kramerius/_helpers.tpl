{{- define "kramerius.labels" -}}
app.kubernetes.io/name: kramerius
app.kubernetes.io/component: app
app.kubernetes.io/instance: {{ . }}
{{- end }}

{{/*
Generate CATALINA_OPTS from resources, jmx, and java agent
*/}}
{{- define "kramerius.catalinaOpts" -}}
{{- $opts := list -}}

{{- with .container.resources.requests.memory }}
  {{- $mem := regexReplaceAll "i" . "" }}  {{/* Convert Mi/Gi to M/G */}}
  {{- $opts = append $opts (printf "-Xms%s" $mem) }}
{{- end }}

{{- with .container.resources.limits.memory }}
  {{- $mem := regexReplaceAll "i" . "" }}
  {{- $opts = append $opts (printf "-Xmx%s" $mem) }}
{{- end }}

{{- if .jmxRemote.enabled }}
{{- $opts = append $opts "-Dcom.sun.management.jmxremote" }}
{{- $opts = append $opts "-Dcom.sun.management.jmxremote.port=9000" }}
{{- $opts = append $opts "-Dcom.sun.management.jmxremote.authenticate=false" }}
{{- $opts = append $opts "-Dcom.sun.management.jmxremote.ssl=false" }}
{{- end }}

{{- if .jmxPrometheus.enabled }}
{{- $opts = append $opts (printf "-javaagent:%s=5556:%s" .jmxPrometheus.jarPath .jmxPrometheus.configPath) }}
{{- end }}

{{- join " " $opts -}}
{{- end }}
