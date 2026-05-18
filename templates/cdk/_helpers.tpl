{{/*
CDK helpers — configuration.properties fragment when Values.cdk.enabled.
Used by kramerius-public, kramerius-curator, and workers via
kramerius.configurationProperties.merged (includeCdk: true).
*/}}

{{/*
CDK configuration.properties part rendered from Values.cdk.
Merged after base chart sections and before per-workload shadow extras.

Expected values shape (maps to keys in configuration.properties.example):
  cdk:
    enabled: true
    server:
      # Optional. When omitted, cdk.server.mode mirrors cdk.enabled.
      # When set (including false), that value is used as-is (hasKey, not | default).
      mode: true|false
    forwardClient:
      maxConnections: int   # cdk.forward.apache.client.max_connections
      maxPerRoute: int      # cdk.forward.apache.client.max_per_route
    collections:
      sources:
        <sourceName>:
          # Typical keys per source (any extra keys are emitted too):
          baseurl, username, pswd, api, forwardurl, licenses
    shibbolethForwardHeaders: "<joined header names>"  # cdk.shibboleth.forward.headers
*/}}
{{- define "kramerius.cdk.configurationProperties.part" -}}
{{- $cdk := .Values.cdk | default dict }}
{{- if not ($cdk.enabled | default false) -}}
{{- "" -}}
{{- else -}}
{{- $lines := list }}
{{- $server := $cdk.server | default dict }}
{{- $forward := $cdk.forwardClient | default dict }}
{{- $collections := $cdk.collections | default dict }}
{{- $sources := $collections.sources | default dict }}

{{- $serverMode := ternary $server.mode ($cdk.enabled | default false) (hasKey $server "mode") }}
{{- $lines = append $lines (printf "cdk.server.mode=%v" $serverMode) }}
{{- $lines = append $lines "" }}

{{- if $forward.maxConnections }}
{{- $lines = append $lines (printf "cdk.forward.apache.client.max_connections=%v" $forward.maxConnections) }}
{{- end }}
{{- if $forward.maxPerRoute }}
{{- $lines = append $lines (printf "cdk.forward.apache.client.max_per_route=%v" $forward.maxPerRoute) }}
{{- end }}

{{- range $sourceName := sortAlpha (keys $sources) }}
{{- $source := index $sources $sourceName | default dict }}
{{- $lines = append $lines "" }}
{{- $lines = append $lines (printf "#%s" (upper $sourceName)) }}
{{- range $propName := sortAlpha (keys $source) }}
{{- $lines = append $lines (printf "cdk.collections.sources.%s.%s=%v" $sourceName $propName (index $source $propName)) }}
{{- end }}
{{- end }}

{{- if $cdk.shibbolethForwardHeaders }}
{{- $lines = append $lines "" }}
{{- $lines = append $lines (printf "cdk.shibboleth.forward.headers=%s" $cdk.shibbolethForwardHeaders) }}
{{- end }}

{{- join "\n" $lines }}
{{- end -}}
{{- end }}
