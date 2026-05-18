{{/*
CATALINA_OPTS / JAVA_OPTS assembly for Tomcat workloads.
Uses kramerius.perAppJavaagentCatalinaFlags and kramerius.otelJvmOpts from observability/_helpers.tpl.
*/}}

{{/*
Merge CATALINA_OPTS / JAVA_OPTS: memory, per-app javaagents, extra, OTEL, then global shadow.
Dict keys:
  globalShadow — appended last (Values.shadow.catalinaOpts)
*/}}
{{- define "kramerius.mergeCatalinaOpts" -}}
{{- $root := .root }}
{{- $memory := .memory | default "" | trim }}
{{- $javaagents := .javaagents | default list }}
{{- $extra := .extra | default "" | trim }}
{{- $otelComp := .otelComp | default dict }}
{{- $otelServiceName := .otelServiceName | default "" }}
{{- $out := $memory }}
{{- $jaFlags := include "kramerius.perAppJavaagentCatalinaFlags" (dict "javaagents" $javaagents) | trim }}
{{- if $jaFlags }}
{{- if $out }}
{{- $out = printf "%s %s" $out $jaFlags }}
{{- else }}
{{- $out = $jaFlags }}
{{- end }}
{{- end }}
{{- if $extra }}
{{- if $out }}
{{- $out = printf "%s %s" $out $extra }}
{{- else }}
{{- $out = $extra }}
{{- end }}
{{- end }}
{{- $otelOpts := include "kramerius.otelJvmOpts" (dict "root" $root "compOtel" $otelComp "serviceName" $otelServiceName) | trim }}
{{- if $otelOpts }}
{{- if $out }}
{{- $out = printf "%s %s" $out $otelOpts }}
{{- else }}
{{- $out = $otelOpts }}
{{- end }}
{{- end }}
{{- $gShadow := .globalShadow | default "" | trim }}
{{- if $gShadow }}
{{- if $out }}
{{- $out = printf "%s %s" $out $gShadow }}
{{- else }}
{{- $out = $gShadow }}
{{- end }}
{{- end }}
{{- $out }}
{{- end }}
